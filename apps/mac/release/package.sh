#!/usr/bin/env bash
# Creates the FINAL zip (after stapling), reopens it to check it and writes its SHA-256.
#   package.sh <app> <output.zip>     [REQUIRE_STAPLE=1 requires the stapled ticket]
# `ditto -c -k --sequesterRsrc --keepParent` is the format Sparkle expects (keeps symlinks and xattrs).
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

APP="$(strip_slash "${1:-}")"; ZIP="${2:-}"
if [ ! -d "$APP/Contents" ] || [ -z "$ZIP" ]; then die "usage: package.sh <app> <output.zip>"; fi
mkdir -p "$(dirname "$ZIP")"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

check="$(mktemp -d)"
trap 'rm -rf "$check"' EXIT
ditto -x -k "$ZIP" "$check"
unpacked="$check/$(basename "$APP")"
[ -d "$unpacked" ] || die "the zip does not contain $(basename "$APP") at its root"
codesign --verify --deep --strict --verbose=2 "$unpacked"
if [ "${REQUIRE_STAPLE:-0}" = 1 ]; then xcrun stapler validate "$unpacked"; fi

sum="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
printf '%s  %s\n' "$sum" "$(basename "$ZIP")" > "$ZIP.sha256"
set_output zip_name "$(basename "$ZIP")"
set_output zip_sha256 "$sum"
log "final zip: $(basename "$ZIP") ($(wc -c < "$ZIP" | tr -d ' ') bytes)"
