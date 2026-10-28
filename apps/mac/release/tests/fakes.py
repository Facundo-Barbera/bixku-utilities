"""Fake macOS/cloud executables for the release script tests (Linux, no credentials).

Each fake is a small script placed first in PATH. Calls are appended to $FAKE_LOG as one line per call
("<tool> <args...>") so tests can assert ordering. All data is fictitious.
"""
import os
import stat
import sys
import textwrap

HERE = os.path.dirname(os.path.abspath(__file__))
RELEASE = os.path.dirname(HERE)
sys.path.insert(0, RELEASE)
import appcast  # noqa: E402  (release/appcast.py)

PY = sys.executable


def _write(path, body):
    with open(path, "w") as f:
        f.write(body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def logging_fake(name, extra=""):
    """Bash fake that logs its arguments, then runs `extra` (bash)."""
    return textwrap.dedent("""\
        #!/usr/bin/env bash
        printf '%s' "{name}" >> "$FAKE_LOG"
        for a in "$@"; do printf ' %s' "$a" >> "$FAKE_LOG"; done
        printf '\\n' >> "$FAKE_LOG"
        {extra}
        exit 0
        """).format(name=name, extra=extra)


PLISTBUDDY = """#!{py}
import plistlib, sys
cmd, path = sys.argv[2], sys.argv[3]
assert cmd.startswith("Print :"), cmd
with open(path, "rb") as f:
    print(plistlib.load(f)[cmd[len("Print :"):]])
""".format(py=PY)

# codesign: logs; `-d` prints a signature description with hardened runtime
CODESIGN_EXTRA = """
for a in "$@"; do
  if [ "$a" = "-d" ]; then
    echo "Executable=/fake" >&2
    echo "CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+1 location=embedded" >&2
    echo "Timestamp=Jan 1, 2026" >&2
    echo "TeamIdentifier=ABCDE12345" >&2
  fi
done
"""

# xcrun: `stapler staple` fails until $FAKE_STAPLE_FAILS attempts were made (counter in $FAKE_STATE)
XCRUN_EXTRA = """
if [ "$1" = notarytool ] && [ "$2" = submit ]; then
  printf '{"id":"00000000-1111-2222-3333-444444444444","status":"%s"}\\n' "${FAKE_NOTARY_STATUS:-Accepted}"
  [ "${FAKE_NOTARY_STATUS:-Accepted}" = Accepted ] || exit 1
fi
if [ "$1" = stapler ] && [ "$2" = staple ]; then
  n=$(cat "$FAKE_STATE/staple" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$FAKE_STATE/staple"
  [ "$n" -gt "${FAKE_STAPLE_FAILS:-0}" ] || exit 65
fi
"""

# ditto -c -k ... <src> <zip>: writes a placeholder file so callers find the archive
DITTO_EXTRA = """
if [ "$1" = -c ]; then out="${@: -1}"; printf 'zip' > "$out"; fi
"""

# generate_appcast: real-looking feed signed with the ed key file (Ed25519 from release/appcast.py)
GENERATE_APPCAST = """#!{py}
import base64, os, sys, re, html
sys.path.insert(0, {release!r})
import appcast as A
args = sys.argv[1:]
opt = {{}}
i = 0
while i < len(args) - 1:
    if args[i].startswith("-"):
        if args[i] in ("--embed-release-notes",):
            i += 1
            continue
        opt[args[i]] = args[i + 1]
        i += 2
    else:
        i += 1
d = args[-1]
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write("generate_appcast " + " ".join(args) + "\\n")
seed = base64.b64decode(open(opt["--ed-key-file"]).read().strip())
prefix = opt["--download-url-prefix"]
build = opt.get("--versions", "1")
items = []
for name in sorted(os.listdir(d)):
    m = re.match(r"^BixkuUtilities-(.+)\\.zip$", name)
    if not m:
        continue
    data = open(os.path.join(d, name), "rb").read()
    sig = base64.b64encode(A.ed25519_sign(seed, data)).decode()
    chan = "<sparkle:channel>%s</sparkle:channel>" % opt["--channel"] if "--channel" in opt else ""
    items.append(
        "<item><title>%s</title><sparkle:version>%s</sparkle:version>"
        "<sparkle:shortVersionString>%s</sparkle:shortVersionString>"
        "<sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>%s"
        '<enclosure url="%s%s" length="%d" type="application/octet-stream" sparkle:edSignature="%s"/></item>'
        % (m.group(1), build, m.group(1), os.environ.get("FAKE_MIN_SYSTEM", "13.0"), chan, prefix, name, len(data), sig))
xml = ('<?xml version="1.0" encoding="utf-8"?>\\n<rss version="2.0" '
       'xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Feed</title>%s'
       '</channel></rss>\\n<!-- sparkle-signatures:\\nedSignature: fake\\nlength: 1\\n-->\\n') % "".join(items)
open(opt["-o"], "w").write(xml)
""".format(py=PY, release=RELEASE)

# sign_update: -p prints the signature of a file; --verify checks it
SIGN_UPDATE = """#!{py}
import base64, os, sys
sys.path.insert(0, {release!r})
import appcast as A
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write("sign_update " + " ".join(args) + "\\n")
key = args[args.index("--ed-key-file") + 1]
seed = base64.b64decode(open(key).read().strip())
if "--verify" in args:
    rest = [a for a in args if a not in ("--verify", "--ed-key-file", key)]
    data = open(rest[0], "rb").read()
    ok = A.ed25519_verify(A.ed25519_public_from_seed(seed), data, base64.b64decode(rest[1]))
    sys.exit(0 if ok else 1)
if "-p" in args:
    path = args[args.index("-p") + 1]
    print(base64.b64encode(A.ed25519_sign(seed, open(path, "rb").read())).decode())
""".format(py=PY, release=RELEASE)


# aws: an S3 bucket emulated in $FAKE_BUCKET (one directory per bucket name); logs every call
AWS = """#!{py}
import hashlib, os, shutil, sys
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write("aws " + " ".join(args) + "\\n")
if os.environ.get("FAKE_AWS_FAIL"):
    print("An error occurred (AccessDenied): Access Denied", file=sys.stderr)
    sys.exit(254)
root = os.environ["FAKE_BUCKET"]
def opt(name, default=None):
    return args[args.index(name) + 1] if name in args else default
def local(s3url):
    assert s3url.startswith("s3://"), s3url
    return os.path.join(root, s3url[len("s3://"):])
if "--endpoint-url" in args:
    i = args.index("--endpoint-url")
    del args[i:i + 2]
svc, op = args[0], args[1]
if svc == "s3api" and op == "head-object":
    path = os.path.join(root, opt("--bucket"), opt("--key"))
    if not os.path.isfile(path):
        print("An error occurred (404) when calling the HeadObject operation: Not Found", file=sys.stderr)
        sys.exit(254)
    size = os.path.getsize(path)
    if opt("--query") == "ContentLength":
        print(size)
    else:
        print("%s\\t%s\\t%d" % (hashlib.md5(open(path, "rb").read()).hexdigest(), int(os.path.getmtime(path)), size))
elif svc == "s3api" and op == "list-objects-v2":
    base = os.path.join(root, opt("--bucket"))
    keys = []
    for dp, _, files in os.walk(base):
        for fn in files:
            k = os.path.relpath(os.path.join(dp, fn), base)
            if k.startswith(opt("--prefix", "")):
                keys.append(k)
    keys.sort()
    if opt("--query") == "Contents[].Key":
        print("\\t".join(keys))
    else:
        for k in keys:
            print("%s\\t%d" % (k, os.path.getsize(os.path.join(base, k))))
elif svc == "s3" and op in ("cp", "mv"):
    src, dst = args[2], args[3]
    s = local(src) if src.startswith("s3://") else src
    d = local(dst) if dst.startswith("s3://") else dst
    os.makedirs(os.path.dirname(d) or ".", exist_ok=True)
    (shutil.move if op == "mv" else shutil.copyfile)(s, d)
else:
    print("fake aws: unsupported " + " ".join(args), file=sys.stderr)
    sys.exit(2)
""".format(py=PY)

# curl: serves https://<host>/<key> from the bucket directory $FAKE_BUCKET/$FAKE_CDN_BUCKET (custom domain = root)
CURL = """#!{py}
import os, shutil, sys
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write("curl " + " ".join(args) + "\\n")
url = [a for a in args if a.startswith("https://")][-1].split("?", 1)[0]
key = url.split("://", 1)[1].split("/", 1)[1] if "/" in url.split("://", 1)[1] else ""
path = os.path.join(os.environ["FAKE_BUCKET"], os.environ["FAKE_CDN_BUCKET"], key)
if not os.path.isfile(path):
    print("curl: (22) The requested URL returned error: 404", file=sys.stderr)
    sys.exit(22)
if "--output" in args and args[args.index("--output") + 1] != "/dev/null":
    shutil.copyfile(path, args[args.index("--output") + 1])
""".format(py=PY)


def install(bindir, names=None):
    """Writes every fake (or `names`) into bindir."""
    fakes = {
        "codesign": logging_fake("codesign", CODESIGN_EXTRA),
        "xcrun": logging_fake("xcrun", XCRUN_EXTRA),
        "spctl": logging_fake("spctl", 'echo "origin=Developer ID Application: Example (ABCDE12345)" >&2'),
        "ditto": logging_fake("ditto", DITTO_EXTRA),
        "aws": AWS,
        "curl": CURL,
        "PlistBuddy": PLISTBUDDY,
        "generate_appcast": GENERATE_APPCAST,
        "sign_update": SIGN_UPDATE,
    }
    os.makedirs(bindir, exist_ok=True)
    for name, body in fakes.items():
        if names is None or name in names:
            _write(os.path.join(bindir, name), body)
    return bindir
