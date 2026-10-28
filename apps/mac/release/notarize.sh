#!/usr/bin/env bash
# Notarizes an app or a disk image with an App Store Connect API key, staples the ticket and verifies it.
#   notarize.sh <app|dmg>
# An .app is zipped (ditto) to a temporary file for submission and the ticket is stapled to the .app;
# a .dmg is submitted as is and stapled itself.
# Env: ASC_API_KEY_P8_BASE64, ASC_API_KEY_ID, ASC_API_ISSUER_ID; NOTARY_TIMEOUT (30m);
#      STAPLE_ATTEMPTS (6): the stapler fetches the ticket from Apple's CDN, which may lag behind the
#      "Accepted" status for a while, so stapling is retried with exponential backoff.
# When Apple rejects the submission, `notarytool log` (no secrets) is printed and the script fails. The .p8 only
# lives in a 0600 temporary file deleted on exit (and by the cleanup step of the workflow).
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TARGET="${1:-}"
TARGET="$(strip_slash "$TARGET")"
case "$TARGET" in
  *.app) [ -d "$TARGET/Contents" ] || die "not an app bundle: $TARGET" ;;
  *.dmg) [ -f "$TARGET" ] || die "disk image not found: $TARGET" ;;
  *) die "usage: notarize.sh <app|dmg>" ;;
esac
require_env ASC_API_KEY_P8_BASE64 ASC_API_KEY_ID ASC_API_ISSUER_ID
TMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
KEY="$TMP/bixku-notary-$$.p8"
RESULT="$TMP/bixku-notary-result-$$.json"
SUBMIT_ZIP="$TMP/bixku-notary-submit-$$.zip"
trap 'rm -f "$KEY" "$RESULT" "$SUBMIT_ZIP"' EXIT
( umask 077; printf '%s' "$ASC_API_KEY_P8_BASE64" | base64 --decode > "$KEY" )
auth=(--key "$KEY" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID")

submit="$TARGET"
if [[ "$TARGET" == *.app ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$TARGET" "$SUBMIT_ZIP"
  submit="$SUBMIT_ZIP"
fi
log "submitting $(basename "$TARGET") for notarization (waiting up to ${NOTARY_TIMEOUT:-30m})"
rc=0
xcrun notarytool submit "$submit" "${auth[@]}" --wait --timeout "${NOTARY_TIMEOUT:-30m}" --output-format json > "$RESULT" || rc=$?
parsed="$(python3 -I -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
print(d.get("id", ""))
print(d.get("status", ""))
' "$RESULT")"
sub_id="$(printf '%s\n' "$parsed" | sed -n 1p)"
status="$(printf '%s\n' "$parsed" | sed -n 2p)"
if [ "$rc" -ne 0 ] || [ "$status" != "Accepted" ]; then
  printf '::error::notarization not accepted (status: %s, exit code: %s)\n' "${status:-unknown}" "$rc" >&2
  if [ -n "$sub_id" ]; then
    echo "--- notarytool log ($sub_id) ---"
    xcrun notarytool log "$sub_id" "${auth[@]}" || true
  else
    echo "--- notarytool response ---"
    cat "$RESULT" || true
  fi
  exit 1
fi
log "notarization accepted ($sub_id)"

retry "${STAPLE_ATTEMPTS:-6}" 15 xcrun stapler staple "$TARGET"
retry 3 10 xcrun stapler validate "$TARGET"
# spctl prints "origin=Developer ID Application: <name> (<TeamID>)": hidden in case the logger did not mask it
if [[ "$TARGET" == *.app ]]; then
  spctl --assess --type execute -vv "$TARGET" 2>&1 | sed 's/^origin=.*/origin=<hidden>/'
  codesign --verify --deep --strict --verbose=2 "$TARGET"
else
  spctl --assess --type open --context context:primary-signature -vv "$TARGET" 2>&1 | sed 's/^origin=.*/origin=<hidden>/'
fi
log "Gatekeeper, stapled ticket and signature verified for $(basename "$TARGET")"
