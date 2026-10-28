#!/usr/bin/env bash
# Builds the drag-to-Applications disk image (macOS only):
#   window with a background (dmg-background.py), the app on the left and an /Applications symlink (Finder shows
#   the Applications folder icon) on the right; volume icon = app icon when there is one. Compressed (UDZO) and,
#   unless SIGN_IDENTITY is "-" or empty, signed with the Developer ID identity (notarize.sh notarizes/staples it).
#   dmg.sh <app> <output.dmg>
# Env: SIGN_IDENTITY, SIGN_KEYCHAIN (optional), VOLUME_NAME (default: app name),
#      DMG_LAYOUT_TIMEOUT (60 s for the Finder layout script; when Finder automation is not available, the image
#      is still produced with the Applications link but without the custom layout, and a warning is emitted).
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

APP="$(strip_slash "${1:-}")"; DMG="${2:-}"
if [ ! -d "$APP/Contents" ] || [ -z "$DMG" ]; then die "usage: dmg.sh <app> <output.dmg>"; fi
[ "$(uname -s)" = Darwin ] || die "disk images can only be built on macOS"
VOLNAME="${VOLUME_NAME:-$APP_NAME}"
APP_BASENAME="$(basename "$APP")"
# Layout in points; dmg-background.py draws the arrow between the same coordinates
WIN_W=660 WIN_H=400 ICON=128 APP_X=170 APPS_X=490 ICON_Y=190

work="$(mktemp -d)"
mnt=""
cleanup() {
  if [ -n "$mnt" ] && [ -d "$mnt" ]; then hdiutil detach "$mnt" -force >/dev/null 2>&1 || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

# 1) Staging folder
stage="$work/stage"
mkdir -p "$stage/.background"
ditto "$APP" "$stage/$APP_BASENAME"
ln -s /Applications "$stage/Applications"
python3 -I "$RELEASE_SCRIPTS/dmg-background.py" "$work/bg.png" --width "$WIN_W" --height "$WIN_H" --app-x "$APP_X" --apps-x "$APPS_X" --icon-y "$ICON_Y"
python3 -I "$RELEASE_SCRIPTS/dmg-background.py" "$work/bg@2x.png" --scale 2 --width "$WIN_W" --height "$WIN_H" --app-x "$APP_X" --apps-x "$APPS_X" --icon-y "$ICON_Y"
bg_name="background.png"
if command -v tiffutil >/dev/null 2>&1 && tiffutil -cathidpicheck "$work/bg.png" "$work/bg@2x.png" -out "$stage/.background/background.tiff" >/dev/null 2>&1; then
  bg_name="background.tiff"
else
  cp "$work/bg.png" "$stage/.background/background.png"
fi
icns="$APP/Contents/Resources/AppIcon.icns"
if [ -f "$icns" ]; then cp "$icns" "$stage/.VolumeIcon.icns"; fi

# 2) Read-write image, mounted at a private mount point for the layout
rw="$work/rw.dmg"
size_mb=$(( $(du -sm "$stage" | awk '{print $1}') + 40 ))
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$stage" -fs HFS+ -format UDRW -size "${size_mb}m" -ov "$rw"
# Mounted where Finder can see it (a -nobrowse mount would hide it from the layout script)
attach_rw() {
  local out
  out="$(hdiutil attach -readwrite -noverify -noautoopen "$rw")" || return 1
  mnt="$(printf '%s\n' "$out" | grep -o '/Volumes/.*' | head -n 1)"
  [ -n "$mnt" ] && [ -d "$mnt" ]
}
retry 3 5 attach_rw

if [ -f "$mnt/.VolumeIcon.icns" ] && command -v SetFile >/dev/null 2>&1; then
  SetFile -a C "$mnt" || warn "could not set the custom volume icon flag"
fi

# 3) Finder layout (icon view, background, icon positions). Finder addresses the disk by its mount point.
layout_script="$work/layout.applescript"
cat > "$layout_script" <<APPLESCRIPT
on run argv
  set mnt to POSIX file (item 1 of argv) as alias
  tell application "Finder"
    open mnt
    set w to container window of folder mnt
    set current view of w to icon view
    set toolbar visible of w to false
    set statusbar visible of w to false
    set bounds of w to {200, 120, 200 + $WIN_W, 120 + $WIN_H}
    set opts to icon view options of w
    set arrangement of opts to not arranged
    set icon size of opts to $ICON
    set text size of opts to 13
    set background picture of opts to file ".background:$bg_name" of folder mnt
    set position of item "$APP_BASENAME" of folder mnt to {$APP_X, $ICON_Y}
    set position of item "Applications" of folder mnt to {$APPS_X, $ICON_Y}
    update folder mnt without registering applications
    delay 1
    close w
  end tell
end run
APPLESCRIPT
layout_ok=0
osascript "$layout_script" "$mnt" >/dev/null 2>&1 &
osa_pid=$!
for _ in $(seq 1 "${DMG_LAYOUT_TIMEOUT:-60}"); do
  if ! kill -0 "$osa_pid" 2>/dev/null; then break; fi
  sleep 1
done
if kill -0 "$osa_pid" 2>/dev/null; then
  kill "$osa_pid" 2>/dev/null || true
  wait "$osa_pid" 2>/dev/null || true
elif wait "$osa_pid"; then
  layout_ok=1
fi
if [ "$layout_ok" = 1 ] && [ -f "$mnt/.DS_Store" ]; then
  log "Finder layout applied"
else
  warn "Finder layout could not be applied (no Finder automation?): the image keeps the Applications link without the custom background"
fi

chmod -Rf go-w "$mnt" 2>/dev/null || true
rm -rf "$mnt/.fseventsd" "$mnt/.Trashes" 2>/dev/null || true
sync
retry 5 3 hdiutil detach -quiet "$mnt"
mnt=""

# 4) Compressed, read-only image
mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
hdiutil convert -quiet "$rw" -format UDZO -imagekey zlib-level=9 -o "$DMG"

# 5) Signature (real identity only; dry-runs ship an unsigned image)
if [ -n "${SIGN_IDENTITY:-}" ] && [ "$SIGN_IDENTITY" != "-" ]; then
  args=(--force --sign "$SIGN_IDENTITY" --timestamp)
  if [ -n "${SIGN_KEYCHAIN:-}" ]; then args+=(--keychain "$SIGN_KEYCHAIN"); fi
  codesign "${args[@]}" "$DMG"
  codesign --verify --strict --verbose=2 "$DMG"
  log "disk image signed"
elif [ "${RELEASE_MODE:-}" = release ]; then
  die "RELEASE_MODE=release requires a Developer ID signature for the disk image"
fi
hdiutil verify -quiet "$DMG"
# No checksum here: notarize.sh staples the ticket into the image afterwards, which changes its bytes
set_output dmg_name "$(basename "$DMG")"
log "disk image: $(basename "$DMG") ($(wc -c < "$DMG" | tr -d ' ') bytes)"
