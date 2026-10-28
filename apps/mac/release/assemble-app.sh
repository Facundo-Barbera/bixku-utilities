#!/usr/bin/env bash
# Assembles "Bixku Utilities.app" from the SwiftPM build, ready to be signed (macOS only).
#   1) swift build -c release (universal arm64 + x86_64 by default)
#   2) bundle layout: Contents/MacOS/<exe>, Contents/Resources (icon, SwiftPM resource bundles)
#   3) Info.plist rendered from Resources/Info.plist by render-plist.py (versions, bundle id, Sparkle keys)
#   4) Sparkle.framework embedded (embed-sparkle.sh) and sanity checks
#
# Env: SHORT_VERSION, BUILD_NUMBER (required); BUNDLE_ID (online.bixku.utilities), MIN_MACOS_VERSION (13.0),
#   UPDATES_BASE_URL (feed = <URL>/appcast.xml), SPARKLE_ED_PUBLIC_KEY, SPARKLE_AUTO_UPDATE (false),
#   SPARKLE_CHECK_INTERVAL (86400), UNIVERSAL (1), APP_OUT (apps/mac/build/release/Bixku Utilities.app),
#   RELEASE_MODE=release|dryrun (release: a missing feed URL or public key is an error).
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

[ "$(uname -s)" = Darwin ] || die "the app can only be assembled on macOS"
require_env SHORT_VERSION BUILD_NUMBER
OUT="${APP_OUT:-$MAC_DIR/build/release/$APP_BUNDLE}"
MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-13.0}"
MODE="${RELEASE_MODE:-release}"
EXE_NAME="$PRODUCT"

# 1) Build
archs=()
if [ "${UNIVERSAL:-1}" = 1 ]; then archs=(--arch arm64 --arch x86_64); fi
log "swift build -c release ${archs[*]:-}"
(cd "$MAC_DIR" && swift build -c release --product "$PRODUCT" ${archs[@]+"${archs[@]}"})
BIN_DIR="$(cd "$MAC_DIR" && swift build -c release ${archs[@]+"${archs[@]}"} --show-bin-path)"
[ -x "$BIN_DIR/$PRODUCT" ] || die "swift build did not produce $PRODUCT"

# 2) Bundle layout
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
ditto "$BIN_DIR/$PRODUCT" "$OUT/Contents/MacOS/$EXE_NAME"
# SwiftPM resource bundles (if any target declares resources)
for b in "$BIN_DIR"/*.bundle; do
  [ -d "$b" ] || continue
  ditto "$b" "$OUT/Contents/Resources/$(basename "$b")"
done
icon_args=()
if [ -f "$MAC_DIR/Resources/AppIcon.icns" ]; then
  ditto "$MAC_DIR/Resources/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
  icon_args=(--icon AppIcon)
elif [ -d "$MAC_DIR/Resources/AppIcon.iconset" ]; then
  iconutil -c icns "$MAC_DIR/Resources/AppIcon.iconset" -o "$OUT/Contents/Resources/AppIcon.icns"
  icon_args=(--icon AppIcon)
else
  warn "no Resources/AppIcon.icns or AppIcon.iconset: the app uses the generic icon"
fi
printf 'APPL????' > "$OUT/Contents/PkgInfo"

# 3) Info.plist
require_flag=()
if [ "$MODE" = release ]; then require_flag=(--require-sparkle); fi
python3 -I "$RELEASE_SCRIPTS/render-plist.py" --template "$MAC_DIR/Resources/Info.plist" --output "$OUT/Contents/Info.plist" \
  --set "EXECUTABLE_NAME=$EXE_NAME" --set "MARKETING_VERSION=$SHORT_VERSION" --set "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" \
  --set "BUNDLE_ID=${BUNDLE_ID:-online.bixku.utilities}" --set "MIN_MACOS_VERSION=$MIN_MACOS_VERSION" \
  --set "UPDATES_BASE_URL=${UPDATES_BASE_URL:-}" --set "SPARKLE_ED_PUBLIC_KEY=${SPARKLE_ED_PUBLIC_KEY:-}" \
  --set "SPARKLE_CHECK_INTERVAL=${SPARKLE_CHECK_INTERVAL:-86400}" --set "SPARKLE_AUTO_UPDATE=${SPARKLE_AUTO_UPDATE:-false}" \
  ${icon_args[@]+"${icon_args[@]}"} ${require_flag[@]+"${require_flag[@]}"}
plutil -lint "$OUT/Contents/Info.plist" >/dev/null

# 4) Sparkle.framework inside the bundle (and rpath)
bash "$RELEASE_SCRIPTS/embed-sparkle.sh" "$OUT"

# 5) The binary must run on the declared minimum system
EXE="$OUT/Contents/MacOS/$EXE_NAME"
minos="$(otool -l "$EXE" | awk '/LC_BUILD_VERSION/{f=1} f && $1=="minos"{print $2; exit} /LC_VERSION_MIN_MACOSX/{g=1} g && $1=="version"{print $2; exit}')"
if [ -n "$minos" ] && ! version_ge "$MIN_MACOS_VERSION" "$minos"; then
  die "the binary requires macOS $minos (Package.swift) but MIN_MACOS_VERSION=$MIN_MACOS_VERSION promises an older system"
fi
if [ "${UNIVERSAL:-1}" = 1 ]; then
  archs_found="$(lipo -archs "$EXE")"
  case " $archs_found " in *" arm64 "*) ;; *) die "the executable has no arm64 slice ($archs_found)" ;; esac
  case " $archs_found " in *" x86_64 "*) ;; *) die "the executable has no x86_64 slice ($archs_found)" ;; esac
fi
set_output app_path "$OUT"
log "app assembled: $APP_BUNDLE $SHORT_VERSION (build $BUILD_NUMBER), macOS >= $MIN_MACOS_VERSION"
