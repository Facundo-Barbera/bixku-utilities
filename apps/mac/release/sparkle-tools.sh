#!/usr/bin/env bash
# Downloads the Sparkle tools (generate_appcast, sign_update, BinaryDelta...) of the release PINNED in
# sparkle.version, verifies its SHA-256 and unpacks them into <dir>. Exports SPARKLE_BIN.
#   sparkle-tools.sh install <dir>
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=sparkle.version
source "${SPARKLE_VERSION_FILE:-$RELEASE_SCRIPTS/sparkle.version}"  # SPARKLE_VERSION_FILE: tests only

if [ "${1:-}" != install ] || [ -z "${2:-}" ]; then die "usage: sparkle-tools.sh install <dir>"; fi
DEST="$2"
mkdir -p "$DEST"
TARBALL="$DEST/Sparkle-$SPARKLE_VERSION.tar.xz"
URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"

if [ ! -f "$TARBALL" ]; then
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --retry 3 --output "$TARBALL" "$URL"
fi
actual="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
if [ "$actual" != "$SPARKLE_SHA256" ]; then
  rm -f "$TARBALL"
  die "SHA-256 of Sparkle $SPARKLE_VERSION does not match sparkle.version (expected $SPARKLE_SHA256, got $actual)"
fi
tar -xf "$TARBALL" -C "$DEST"
for t in generate_appcast sign_update; do
  [ -x "$DEST/bin/$t" ] || die "$t missing from the Sparkle tarball"
done
set_env SPARKLE_BIN "$DEST/bin"
log "Sparkle $SPARKLE_VERSION verified and installed in $DEST"
