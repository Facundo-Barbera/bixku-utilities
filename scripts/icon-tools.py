#!/usr/bin/env python3
"""Icon packaging helpers for scripts/make-icon.sh (Python standard library only).

  icon-tools.py icns <AppIcon.iconset> <AppIcon.icns>
      Validate an iconset (names, PNG signature, pixel dimensions) and write a .icns.
      This is the portable replacement for `iconutil -c icns` (macOS only).
  icon-tools.py appiconset <AppIcon.iconset> <AppIcon.appiconset>
      Copy the iconset PNGs into an asset-catalog image set and write its Contents.json.
  icon-tools.py check <file.png|file.icns> ...
      Print "<file> <width>x<height>" for PNGs and the embedded entries for .icns files.
"""
import json
import os
import shutil
import struct
import sys

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

# (point size, scale, icns type). The icns types embed PNG data directly.
SLOTS = [
    (16, 1, b"icp4"),
    (16, 2, b"ic11"),
    (32, 1, b"icp5"),
    (32, 2, b"ic12"),
    (128, 1, b"ic07"),
    (128, 2, b"ic13"),
    (256, 1, b"ic08"),
    (256, 2, b"ic14"),
    (512, 1, b"ic09"),
    (512, 2, b"ic10"),
]


def slot_name(points, scale):
    return "icon_%dx%d%s.png" % (points, points, "@2x" if scale == 2 else "")


def png_size(data, label):
    if data[:8] != PNG_SIGNATURE or data[12:16] != b"IHDR":
        raise SystemExit("error: %s is not a PNG" % label)
    return struct.unpack(">II", data[16:24])


def read_iconset(path):
    """Returns [(points, scale, icns_type, file name, png bytes)] after validating every slot."""
    slots = []
    for points, scale, icns_type in SLOTS:
        name = slot_name(points, scale)
        file = os.path.join(path, name)
        if not os.path.isfile(file):
            raise SystemExit("error: %s is missing from the iconset" % name)
        with open(file, "rb") as handle:
            data = handle.read()
        width, height = png_size(data, name)
        expected = points * scale
        if (width, height) != (expected, expected):
            raise SystemExit("error: %s is %dx%d, expected %dx%d" % (name, width, height, expected, expected))
        slots.append((points, scale, icns_type, name, data))
    return slots


def write_icns(iconset, out):
    chunks = b"".join(
        icns_type + struct.pack(">I", 8 + len(data)) + data for _, _, icns_type, _, data in read_iconset(iconset)
    )
    with open(out, "wb") as handle:
        handle.write(b"icns" + struct.pack(">I", 8 + len(chunks)) + chunks)


def write_appiconset(iconset, out):
    slots = read_iconset(iconset)
    os.makedirs(out, exist_ok=True)
    for entry in os.listdir(out):
        if entry.endswith(".png"):
            os.remove(os.path.join(out, entry))
    images = []
    for points, scale, _, name, _ in slots:
        shutil.copyfile(os.path.join(iconset, name), os.path.join(out, name))
        images.append(
            {"filename": name, "idiom": "mac", "scale": "%dx" % scale, "size": "%dx%d" % (points, points)}
        )
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    with open(os.path.join(out, "Contents.json"), "w", encoding="utf-8") as handle:
        json.dump(contents, handle, indent=2)
        handle.write("\n")
    # The catalog root needs its own Contents.json to be recognised by actool.
    root = os.path.join(os.path.dirname(os.path.abspath(out)), "Contents.json")
    if not os.path.exists(root):
        with open(root, "w", encoding="utf-8") as handle:
            json.dump({"info": {"author": "xcode", "version": 1}}, handle, indent=2)
            handle.write("\n")


def check(path):
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:4] == b"icns":
        total = struct.unpack(">I", data[4:8])[0]
        if total != len(data):
            raise SystemExit("error: %s declares %d bytes but has %d" % (path, total, len(data)))
        offset = 8
        while offset < len(data):
            icns_type = data[offset : offset + 4].decode("ascii")
            length = struct.unpack(">I", data[offset + 4 : offset + 8])[0]
            width, height = png_size(data[offset + 8 : offset + length], icns_type)
            print("%s %s %dx%d" % (path, icns_type, width, height))
            offset += length
    else:
        width, height = png_size(data, path)
        print("%s %dx%d" % (path, width, height))


def main(argv):
    if len(argv) >= 4 and argv[1] == "icns":
        write_icns(argv[2], argv[3])
    elif len(argv) >= 4 and argv[1] == "appiconset":
        write_appiconset(argv[2], argv[3])
    elif len(argv) >= 3 and argv[1] == "check":
        for path in argv[2:]:
            check(path)
    else:
        sys.stderr.write(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
