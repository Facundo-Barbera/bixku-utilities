#!/usr/bin/env bash
# Embeds Sparkle.framework into <app>/Contents/Frameworks and points the executable rpath there. Idempotent.
#   embed-sparkle.sh <app>
# The framework comes from the SwiftPM artifact (the one the executable linked against); SPARKLE_FRAMEWORK_SRC
# overrides it. Fails when its version differs from sparkle.version (keeps framework and feed tools in sync).
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=sparkle.version
source "$RELEASE_SCRIPTS/sparkle.version"

APP="${1:-}"
[ -d "$APP/Contents" ] || die "usage: embed-sparkle.sh <app>"
PLISTBUDDY="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"
EXE="$APP/Contents/MacOS/$("$PLISTBUDDY" -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
[ -f "$EXE" ] || die "missing executable $EXE"

SRC="${SPARKLE_FRAMEWORK_SRC:-}"
if [ -z "$SRC" ]; then
  # Binary artifact downloaded and checksum-verified by SwiftPM (xcframework: universal arm64 + x86_64 slice)
  SRC="$(find "$MAC_DIR/.build" -maxdepth 8 -type d -path '*Sparkle.xcframework/macos-*/Sparkle.framework' 2>/dev/null | head -n 1)"
fi
if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then die "Sparkle.framework not found (did SwiftPM resolution fail?)"; fi

FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
rm -rf "$FRAMEWORKS/Sparkle.framework"
ditto "$SRC" "$FRAMEWORKS/Sparkle.framework"

got="$("$PLISTBUDDY" -c 'Print :CFBundleShortVersionString' "$FRAMEWORKS/Sparkle.framework/Resources/Info.plist" 2>/dev/null || true)"
[ "$got" = "$SPARKLE_VERSION" ] || die "Sparkle.framework is $got but sparkle.version pins $SPARKLE_VERSION (update Package.swift and sparkle.version together)"

if ! otool -l "$EXE" | grep '@executable_path/../Frameworks' >/dev/null; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$EXE"
fi
otool -L "$EXE" | grep 'Sparkle.framework' >/dev/null || die "the executable does not link Sparkle.framework (missing dependency in Package.swift?)"
log "Sparkle $got embedded in $(basename "$APP")"
