#!/usr/bin/env python3
"""Draws the background of the drag-to-Applications disk image as a PNG (stdlib only, portable).

    dmg-background.py <output.png> [--width 660] [--height 400] [--scale 1]
                      [--app-x 170] [--apps-x 490] [--icon-y 190]

A soft vertical gradient with an arrow pointing from the app icon to the Applications folder. Coordinates are
in points (the Finder window layout in dmg.sh uses the same ones); --scale 2 renders a Retina variant.
Deterministic: the same arguments always produce the same bytes.
"""
import argparse
import struct
import sys
import zlib

TOP = (250, 250, 252)
BOTTOM = (232, 234, 240)
ARROW = (150, 156, 170)


def _png(width, height, rows):
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + bytes(r) for r in rows)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def _in_arrow(x, y, x0, x1, cy, shaft, head_len, head_half):
    """Point inside the arrow (shaft rectangle + triangular head pointing right)."""
    head_start = x1 - head_len
    if x0 <= x <= head_start and abs(y - cy) <= shaft / 2:
        return True
    if head_start <= x <= x1:
        half = head_half * (x1 - x) / head_len
        return abs(y - cy) <= half
    return False


def render(width, height, scale=1, app_x=170, apps_x=490, icon_y=190):
    w, h = width * scale, height * scale
    # Arrow between the two icons (128 pt wide), leaving a margin around them
    x0, x1 = (app_x + 84) * scale, (apps_x - 84) * scale
    cy = icon_y * scale
    shaft, head_len, head_half = 6 * scale, 22 * scale, 16 * scale
    bbox = (x0 - 1, x1 + 1, cy - head_half - 1, cy + head_half + 1)
    sub = [(i + 0.5) / 4 for i in range(4)]  # 4x4 supersampling for anti-aliased edges
    rows = []
    for py in range(h):
        t = py / max(h - 1, 1)
        bg = [round(TOP[c] + (BOTTOM[c] - TOP[c]) * t) for c in range(3)]
        row = bytearray()
        for px in range(w):
            cov = 0.0
            if x1 > x0 and bbox[0] <= px <= bbox[1] and bbox[2] <= py <= bbox[3]:
                hits = sum(1 for sy in sub for sx in sub
                           if _in_arrow(px + sx, py + sy, x0, x1, cy, shaft, head_len, head_half))
                cov = hits / 16.0
            row += bytes(round(bg[c] * (1 - cov) + ARROW[c] * cov) for c in range(3))
        rows.append(row)
    return _png(w, h, rows)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("output")
    ap.add_argument("--width", type=int, default=660)
    ap.add_argument("--height", type=int, default=400)
    ap.add_argument("--scale", type=int, default=1, choices=(1, 2))
    ap.add_argument("--app-x", type=int, default=170)
    ap.add_argument("--apps-x", type=int, default=490)
    ap.add_argument("--icon-y", type=int, default=190)
    a = ap.parse_args(argv)
    data = render(a.width, a.height, a.scale, a.app_x, a.apps_x, a.icon_y)
    with open(a.output, "wb") as f:
        f.write(data)
    print("background: %dx%d px -> %s" % (a.width * a.scale, a.height * a.scale, a.output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
