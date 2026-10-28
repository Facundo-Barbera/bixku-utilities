#!/usr/bin/env bash
# Tests for scripts/make-icon.sh (portable: Linux and macOS). Needs python3 and an SVG renderer
# (see make-icon.sh; `uv` is enough). Run: scripts/tests/test-make-icon.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAKE="$ROOT/scripts/make-icon.sh"
TOOLS="$ROOT/scripts/icon-tools.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
ok() { printf 'ok: %s\n' "$*"; }

expect_size() { # <png> <width>x<height>
  local got
  got="$(python3 -I "$TOOLS" check "$1" | awk '{print $2}')"
  if [ "$got" = "$2" ]; then ok "$(basename "$1") is $2"; else fail "$(basename "$1") is $got, expected $2"; fi
}

# 1) Default logo -> iconset, icns and asset catalog with the right dimensions
ICNS_PACKER=python "$MAKE" --out "$tmp/out" --iconset-dir "$tmp/work" >/dev/null
set_dir="$tmp/work/AppIcon.iconset"
for points in 16 32 128 256 512; do
  expect_size "$set_dir/icon_${points}x${points}.png" "${points}x${points}"
  expect_size "$set_dir/icon_${points}x${points}@2x.png" "$((points * 2))x$((points * 2))"
done
[ "$(find "$set_dir" -name '*.png' | wc -l | tr -d ' ')" = 10 ] || fail "iconset should hold 10 PNGs"

# 2) The .icns is well formed: declared length matches and every embedded PNG has the expected size
icns="$tmp/out/AppIcon.icns"
[ "$(head -c 4 "$icns")" = icns ] || fail "AppIcon.icns has no icns magic"
entries="$(python3 -I "$TOOLS" check "$icns" | awk '{print $2 " " $3}' | sort | tr '\n' ',')"
expected="ic07 128x128,ic08 256x256,ic09 512x512,ic10 1024x1024,ic11 32x32,ic12 64x64,ic13 256x256,ic14 512x512,icp4 16x16,icp5 32x32,"
if [ "$entries" = "$expected" ]; then ok "icns entries"; else fail "icns entries: $entries"; fi

# 3) The asset catalog has a valid Contents.json that points at existing, correctly sized files
set_path="$tmp/out/Assets.xcassets/AppIcon.appiconset"
[ -f "$tmp/out/Assets.xcassets/Contents.json" ] || fail "catalog root Contents.json missing"
if python3 -I - "$set_path" <<'PY'
import json, os, struct, sys
path = sys.argv[1]
contents = json.load(open(os.path.join(path, "Contents.json")))
images = contents["images"]
assert len(images) == 10, len(images)
seen = set()
for image in images:
    assert image["idiom"] == "mac"
    points = int(image["size"].split("x")[0])
    scale = int(image["scale"].rstrip("x"))
    data = open(os.path.join(path, image["filename"]), "rb").read()
    assert struct.unpack(">II", data[16:24]) == (points * scale,) * 2, image
    seen.add((points, scale))
assert seen == {(p, s) for p in (16, 32, 128, 256, 512) for s in (1, 2)}, seen
PY
then ok "appiconset Contents.json"; else fail "appiconset Contents.json"; fi

# 4) Another logo + --no-xcassets
"$MAKE" "$ROOT/design/logo-proposals/logo-c.svg" --out "$tmp/out2" --iconset-dir "$tmp/work2" --no-xcassets >/dev/null
[ -f "$tmp/out2/AppIcon.icns" ] || fail "logo-c: AppIcon.icns missing"
[ ! -e "$tmp/out2/Assets.xcassets" ] || fail "--no-xcassets still wrote the catalog"
expect_size "$tmp/work2/AppIcon.iconset/icon_512x512@2x.png" 1024x1024
if cmp -s "$icns" "$tmp/out2/AppIcon.icns"; then fail "logo-c produced the same icns as logo-a"; else ok "different logos give different icns"; fi

# 5) Errors: missing logo, unknown option, broken iconset
if "$MAKE" "$tmp/missing.svg" --out "$tmp/x" >/dev/null 2>&1; then fail "missing logo should fail"; else ok "missing logo fails"; fi
if "$MAKE" --bogus >/dev/null 2>&1; then fail "unknown option should fail"; else ok "unknown option fails"; fi
rm "$set_dir/icon_32x32.png"
if python3 -I "$TOOLS" icns "$set_dir" "$tmp/broken.icns" >/dev/null 2>&1; then fail "incomplete iconset should fail"; else ok "incomplete iconset fails"; fi

# 6) The committed icon matches the app bundle contract used by release/assemble-app.sh
if [ -f "$ROOT/apps/mac/Resources/AppIcon.icns" ]; then ok "AppIcon.icns committed"; else fail "apps/mac/Resources/AppIcon.icns missing"; fi

if [ "$failures" -ne 0 ]; then printf '%d check(s) failed\n' "$failures" >&2; exit 1; fi
echo "all checks passed"
