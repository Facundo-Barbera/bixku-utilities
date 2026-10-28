#!/usr/bin/env bash
# Builds the app icon from an SVG logo.
#
#   scripts/make-icon.sh [logo.svg] [--out DIR] [--iconset-dir DIR] [--no-xcassets]
#
# Defaults: logo = design/logo-proposals/logo-a.svg (provisional icon, proposal A),
#           --out = apps/mac/Resources.
# Produces:
#   <iconset-dir>/AppIcon.iconset/icon_<N>x<N>[@2x].png   16...512 @1x/@2x (1024 px max)
#   <out>/AppIcon.icns                                      iconutil on macOS, scripts/icon-tools.py elsewhere
#   <out>/Assets.xcassets/AppIcon.appiconset/               PNGs + Contents.json (skipped with --no-xcassets)
# The iconset is built in a temporary directory that is removed on exit unless --iconset-dir is given.
#
# SVG renderer, first one found: rsvg-convert, resvg, inkscape, ImageMagick (magick/convert), the Python
# `resvg_py` module, or `uv run --with resvg-py` (downloads a wheel into uv's cache; no sudo needed).
# Force the .icns writer with ICNS_PACKER=python|iconutil. Compatible with bash 3.2 (macOS).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/scripts/icon-tools.py"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

svg="$ROOT/design/logo-proposals/logo-a.svg"
out="$ROOT/apps/mac/Resources"
iconset_parent=""
xcassets=1
while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || die "--out needs a directory"; out="$2"; shift 2 ;;
    --iconset-dir) [ $# -ge 2 ] || die "--iconset-dir needs a directory"; iconset_parent="$2"; shift 2 ;;
    --no-xcassets) xcassets=0; shift ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) svg="$1"; shift ;;
  esac
done
[ -f "$svg" ] || die "logo not found: $svg"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

# --- renderer ---------------------------------------------------------------------------------------
PY_RESVG='import sys, resvg_py
png = resvg_py.svg_to_bytes(svg_path=sys.argv[1], width=int(sys.argv[2]), height=int(sys.argv[2]))
open(sys.argv[3], "wb").write(bytes(png))'

renderer=""
if command -v rsvg-convert >/dev/null 2>&1; then renderer=rsvg
elif command -v resvg >/dev/null 2>&1; then renderer=resvg
elif command -v inkscape >/dev/null 2>&1; then renderer=inkscape
elif command -v magick >/dev/null 2>&1; then renderer=magick
elif command -v convert >/dev/null 2>&1; then renderer=convert
elif python3 -c 'import resvg_py' >/dev/null 2>&1; then renderer=resvg-py
elif command -v uv >/dev/null 2>&1; then renderer=uv-resvg-py
else die "no SVG renderer found: install rsvg-convert, resvg, inkscape or ImageMagick (or uv)"; fi

render() { # <size> <out.png>
  case "$renderer" in
    rsvg) rsvg-convert -w "$1" -h "$1" -o "$2" "$svg" ;;
    resvg) resvg -w "$1" -h "$1" "$svg" "$2" ;;
    inkscape) inkscape -w "$1" -h "$1" --export-type=png --export-filename="$2" "$svg" >/dev/null ;;
    magick) magick -background none "$svg" -resize "${1}x${1}" "PNG32:$2" ;;
    convert) convert -background none "$svg" -resize "${1}x${1}" "PNG32:$2" ;;
    resvg-py) python3 -I -c "$PY_RESVG" "$svg" "$1" "$2" ;;
    uv-resvg-py) uv run --no-project --quiet --with resvg-py python -I -c "$PY_RESVG" "$svg" "$1" "$2" ;;
  esac
}

# --- iconset ----------------------------------------------------------------------------------------
work=""
cleanup() { if [ -n "$work" ]; then rm -rf "$work"; fi; }
trap cleanup EXIT
if [ -z "$iconset_parent" ]; then work="$(mktemp -d)"; iconset_parent="$work"; fi
iconset="$iconset_parent/AppIcon.iconset"
rm -rf "$iconset"
mkdir -p "$iconset" "$out"

log "rendering $(basename "$svg") with $renderer"
# Pixel size -> the iconset names that use it (16@2x and 32 share 32 px, and so on).
render 16 "$iconset/icon_16x16.png"
render 32 "$iconset/icon_16x16@2x.png";   cp "$iconset/icon_16x16@2x.png" "$iconset/icon_32x32.png"
render 64 "$iconset/icon_32x32@2x.png"
render 128 "$iconset/icon_128x128.png"
render 256 "$iconset/icon_128x128@2x.png"; cp "$iconset/icon_128x128@2x.png" "$iconset/icon_256x256.png"
render 512 "$iconset/icon_256x256@2x.png"; cp "$iconset/icon_256x256@2x.png" "$iconset/icon_512x512.png"
render 1024 "$iconset/icon_512x512@2x.png"

# --- .icns ------------------------------------------------------------------------------------------
packer="${ICNS_PACKER:-}"
if [ -z "$packer" ]; then
  if command -v iconutil >/dev/null 2>&1; then packer=iconutil; else packer=python; fi
fi
python3 -I "$TOOLS" check "$iconset"/*.png >/dev/null # sanity: valid PNGs before packing
case "$packer" in
  iconutil) iconutil -c icns "$iconset" -o "$out/AppIcon.icns" ;;
  python) python3 -I "$TOOLS" icns "$iconset" "$out/AppIcon.icns" ;;
  *) die "ICNS_PACKER must be iconutil or python" ;;
esac
log "wrote $out/AppIcon.icns ($packer)"

# --- asset catalog ----------------------------------------------------------------------------------
if [ "$xcassets" = 1 ]; then
  python3 -I "$TOOLS" appiconset "$iconset" "$out/Assets.xcassets/AppIcon.appiconset"
  log "wrote $out/Assets.xcassets/AppIcon.appiconset"
fi
if [ -z "$work" ]; then log "iconset kept at $iconset"; fi
