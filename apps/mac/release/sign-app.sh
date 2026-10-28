#!/usr/bin/env bash
# Signs the app inside-out (hardened runtime + secure timestamp + minimal entitlements).
#   sign-app.sh <app>
# Env: SIGN_IDENTITY (SHA-1 of the Developer ID Application identity; "-" = ad-hoc for dry-runs),
#      SIGN_KEYCHAIN (temporary keychain, optional), ENTITLEMENTS (default Resources/BixkuUtilities.entitlements),
#      RELEASE_MODE (release refuses ad-hoc signatures),
#      APPLE_TEAM_ID (when set and the signature is real, the resulting TeamIdentifier must match).
# Order: every nested piece of code (Sparkle's XPC services, Autoupdate, Updater.app, loose Mach-O binaries...)
# from the deepest to the shallowest, then Sparkle.framework and finally the app. That is the order Sparkle
# requires with hardened runtime; sorting by path depth gets it without hard-coding Sparkle's internal layout.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

APP="${1:-}"
[ -d "$APP/Contents" ] || die "usage: sign-app.sh <app>"
IDENTITY="${SIGN_IDENTITY:-}"
[ -n "$IDENTITY" ] || die "missing SIGN_IDENTITY (use '-' for an ad-hoc signature)"
# A real release never ships with an ad-hoc signature
if [ "${RELEASE_MODE:-}" = release ] && [ "$IDENTITY" = "-" ]; then die "RELEASE_MODE=release does not allow ad-hoc signing"; fi
ENTITLEMENTS="${ENTITLEMENTS:-$MAC_DIR/Resources/$PRODUCT.entitlements}"
[ -f "$ENTITLEMENTS" ] || die "entitlements file not found"
PLISTBUDDY="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"
EXE="$APP/Contents/MacOS/$("$PLISTBUDDY" -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"

sign_one() { # path [extra codesign args]
  local path="$1"
  shift
  local -a args=(--force --sign "$IDENTITY" --options runtime)
  if [ "$IDENTITY" = "-" ]; then args+=(--timestamp=none); else args+=(--timestamp); fi
  if [ -n "${SIGN_KEYCHAIN:-}" ]; then args+=(--keychain "$SIGN_KEYCHAIN"); fi
  codesign "${args[@]}" ${1+"$@"} "$path"
}

# Nested code: bundles (.xpc .app .framework .bundle) and loose Mach-O binaries, deepest first
nested_code() {
  {
    find "$APP/Contents" -type d \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' -o -name '*.bundle' \) -print
    find "$APP/Contents" -type f -print | while IFS= read -r f; do
      if [ "$f" != "$EXE" ] && is_macho "$f"; then printf '%s\n' "$f"; fi
    done
  } | awk -F/ '{print NF "\t" $0}' | sort -t "$(printf '\t')" -k1,1nr -k2 | cut -f2-
}

count=0
while IFS= read -r item; do
  [ -n "$item" ] || continue
  log "signing ${item#"$APP"/}"
  # Sparkle's XPC services and helpers keep the entitlements they were built with
  sign_one "$item" --preserve-metadata=entitlements
  count=$((count + 1))
done < <(nested_code)

log "signing the app (minimal entitlements)"
sign_one "$APP" --entitlements "$ENTITLEMENTS"

codesign --verify --deep --strict --verbose=2 "$APP"
# Hardened runtime on (and secure timestamp on real signatures); identities are never printed
codesign -d --verbose=2 "$APP" 2>&1 | grep 'flags=0x[0-9a-f]*(.*runtime' >/dev/null || die "the signed app has no hardened runtime"
if [ "$IDENTITY" != "-" ]; then
  codesign -d --verbose=2 "$APP" 2>&1 | grep '^Timestamp=' >/dev/null || die "the signature has no secure timestamp"
  if [ -n "${APPLE_TEAM_ID:-}" ]; then
    codesign -d --verbose=2 "$APP" 2>&1 | grep -x "TeamIdentifier=$APPLE_TEAM_ID" >/dev/null || die "the TeamIdentifier of the signature does not match APPLE_TEAM_ID"
  fi
fi
log "signature verified ($count nested component(s))"
