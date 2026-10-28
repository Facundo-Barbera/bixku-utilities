#!/usr/bin/env bash
# Generates/updates <dir>/appcast.xml with generate_appcast (pinned Sparkle) and validates it.
#   appcast.sh <dir> [--new-build N --version V] [--channel C]
#     --new-build N  new release: only that build enters as a new item (--versions N); the other versions and
#                    their signatures are kept as they are in the downloaded appcast.
#     (no --new-build)  regenerate the feed from what is in <dir> (rollback: the retired version is gone).
# <dir> holds the previous appcast.xml (if any), the zips/deltas it references and, for the new version, its
# BixkuUtilities-<V>.zip and BixkuUtilities-<V>.html (release notes, embedded in the feed).
# Enclosure URLs are <UPDATES_BASE_URL>/releases/<file>.
# Env: SPARKLE_BIN, SPARKLE_ED_PRIVATE_KEY (base64; written to a 0600 temp file that is always deleted, never
#      printed), SPARKLE_ED_PUBLIC_KEY, UPDATES_BASE_URL,
#      SPARKLE_ED_SIGNING_PUBLIC_KEY (optional: public key of the SIGNING key; only differs during a key rotation),
#      MIN_MACOS_VERSION (13.0), MAX_DELTAS (3), MAX_VERSIONS (5), DELTA_COMPRESSION (lzma),
#      PHASED_ROLLOUT_INTERVAL (empty = no phased rollout), FULL_RELEASE_NOTES_URL (optional), ABSENT_VERSION.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

DIR="${1:-}"; shift || true
NEW_BUILD="" VERSION="" CHANNEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --new-build) NEW_BUILD="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -d "$DIR" ] || die "usage: appcast.sh <dir> [--new-build N --version V] [--channel C]"
require_env SPARKLE_BIN SPARKLE_ED_PRIVATE_KEY SPARKLE_ED_PUBLIC_KEY UPDATES_BASE_URL
[ -x "$SPARKLE_BIN/generate_appcast" ] || die "generate_appcast not found in SPARKLE_BIN"
BASE="$(strip_slash "$UPDATES_BASE_URL")"
DOWNLOAD="$BASE/releases/"
MIN="${MIN_MACOS_VERSION:-13.0}"
SIGNING_PUB="${SPARKLE_ED_SIGNING_PUBLIC_KEY:-$SPARKLE_ED_PUBLIC_KEY}"

# The private key must pair with the expected public key, otherwise no client would accept the update
printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" | python3 -I "$RELEASE_SCRIPTS/appcast.py" check-key --public "$SIGNING_PUB"

work="$(mktemp -d)"
KEY_FILE="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/bixku-sparkle-key-$$"
trap 'rm -f "$KEY_FILE"; rm -rf "$work"' EXIT
( umask 077; printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" > "$KEY_FILE" )

args=(--ed-key-file "$KEY_FILE" -o "$DIR/appcast.xml" --download-url-prefix "$DOWNLOAD" --maximum-versions "${MAX_VERSIONS:-5}"
  --maximum-deltas "${MAX_DELTAS:-3}" --delta-compression "${DELTA_COMPRESSION:-lzma}" --embed-release-notes)
if [ -n "$NEW_BUILD" ]; then
  args+=(--versions "$NEW_BUILD")
  if [ -n "$CHANNEL" ]; then args+=(--channel "$CHANNEL"); fi
  # Phased rollout is for the stable channel; betas reach everyone who opted in
  if [ -n "${PHASED_ROLLOUT_INTERVAL:-}" ] && [ -z "$CHANNEL" ]; then args+=(--phased-rollout-interval "$PHASED_ROLLOUT_INTERVAL"); fi
fi
if [ -n "${FULL_RELEASE_NOTES_URL:-}" ]; then args+=(--full-release-notes-url "$FULL_RELEASE_NOTES_URL"); fi

log "generate_appcast (deltas<=${MAX_DELTAS:-3}, versions<=${MAX_VERSIONS:-5}${NEW_BUILD:+, new build $NEW_BUILD}${CHANNEL:+, channel $CHANNEL})"
(cd "$work" && "$SPARKLE_BIN/generate_appcast" "${args[@]}" "$DIR")
[ -f "$DIR/appcast.xml" ] || die "generate_appcast did not produce appcast.xml"

verify_args=(--dir "$DIR" --base-url "$BASE" --download-prefix "$DOWNLOAD" --min-system "$MIN" --public "$SIGNING_PUB" --require-signed-feed)
if [ -n "$NEW_BUILD" ]; then verify_args+=(--version "$VERSION" --build "$NEW_BUILD" --channel "$CHANNEL"); fi
if [ -n "${ABSENT_VERSION:-}" ]; then verify_args+=(--absent "$ABSENT_VERSION"); fi
if ! python3 -I "$RELEASE_SCRIPTS/appcast.py" verify "${verify_args[@]}"; then
  # Rollback: generate_appcast may keep the retired item or deltas to files that are gone (it does not clean
  # <sparkle:deltas> of existing items); they are pruned by hand and the feed is signed again with sign_update
  if [ -n "${ABSENT_VERSION:-}" ]; then
    log "pruning the feed by hand (item $ABSENT_VERSION and orphan deltas) and re-signing"
    python3 -I "$RELEASE_SCRIPTS/appcast.py" prune --appcast "$DIR/appcast.xml" --dir "$DIR" --version "$ABSENT_VERSION"
    (cd "$work" && "$SPARKLE_BIN/sign_update" --ed-key-file "$KEY_FILE" "$DIR/appcast.xml")
    python3 -I "$RELEASE_SCRIPTS/appcast.py" verify "${verify_args[@]}" || die "the pruned appcast does not validate"
  else
    die "the generated appcast does not validate"
  fi
fi

# Second opinion with the official tool: sign_update signs the new zip with the same key; Ed25519 is
# deterministic, so its signature must equal the one generate_appcast wrote into the feed, and verify.
if [ -n "$NEW_BUILD" ]; then
  zip="$DIR/$PRODUCT-$VERSION.zip"
  sig="$(python3 -I "$RELEASE_SCRIPTS/appcast.py" get-sig --appcast "$DIR/appcast.xml" --version "$VERSION")"
  own="$(cd "$work" && "$SPARKLE_BIN/sign_update" --ed-key-file "$KEY_FILE" -p "$zip")"
  [ "$own" = "$sig" ] || die "the sign_update signature differs from the one in the appcast"
  (cd "$work" && "$SPARKLE_BIN/sign_update" --verify --ed-key-file "$KEY_FILE" "$zip" "$sig")
  log "sign_update: the EdDSA signature of the zip equals the feed's and verifies"
fi
