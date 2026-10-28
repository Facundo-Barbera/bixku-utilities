#!/usr/bin/env python3
"""Appcast/Sparkle helpers for the release pipeline (stdlib only, Python >= 3.9).

Subcommands:
  gen-key                  prints a fresh EdDSA key pair (line 1: private seed, line 2: public key; base64).
                           Only for dry-runs without SPARKLE_ED_PRIVATE_KEY: an ephemeral, throw-away key.
  derive-public            reads the Sparkle EdDSA private key (base64) from stdin and prints the public key
  check-key --public B64   exit 0 if the private key (stdin) matches that public key
  verify-sig --public B64 --file F --sig B64   Ed25519 verification independent from sign_update
  get-sig --appcast F --version V   EdDSA signature (base64) of that version's archive, for sign_update --verify
  max-build --appcast F    prints the highest sparkle:version of the feed (empty when there is none)
  list-files --appcast F   file names (archives and deltas) referenced by the feed
  check-new ...            checks the new version can be published (monotonic, never overwrites a different zip)
  verify ...               validates the generated appcast (URLs, signatures, new item, minimum system, channel)
  find --appcast F --version V   short version -> build and associated files (zip and deltas)
  prune --appcast F --dir D --version V   drops the item and orphan deltas (emergency rollback; re-sign after)

Never prints private keys. The private key is only read from stdin.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SP = "{%s}" % NS


# ---------------------------------------------------------------------------
# Ed25519 (RFC 8032, section 6). Slow reference implementation, plenty for a few signatures;
# Sparkle uses standard Ed25519, so it verifies Sparkle's signatures.
# ---------------------------------------------------------------------------
_P = 2 ** 255 - 19
_Q = 2 ** 252 + 27742317777372353535851937790883648493
_D = -121665 * pow(121666, _P - 2, _P) % _P
_SQRT_M1 = pow(2, (_P - 1) // 4, _P)


def _inv(x):
    return pow(x, _P - 2, _P)


def _recover_x(y, sign):
    if y >= _P:
        return None
    x2 = (y * y - 1) * _inv(_D * y * y + 1)
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (_P + 3) // 8, _P)
    if (x * x - x2) % _P != 0:
        x = x * _SQRT_M1 % _P
    if (x * x - x2) % _P != 0:
        return None
    if (x & 1) != sign:
        x = _P - x
    return x


def _add(a, b):
    A, B = (a[1] - a[0]) * (b[1] - b[0]) % _P, (a[1] + a[0]) * (b[1] + b[0]) % _P
    C, D = 2 * a[3] * b[3] * _D % _P, 2 * a[2] * b[2] % _P
    E, F, G, H = B - A, D - C, D + C, B + A
    return (E * F % _P, G * H % _P, F * G % _P, E * H % _P)


def _mul(s, pt):
    q = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            q = _add(q, pt)
        pt = _add(pt, pt)
        s >>= 1
    return q


def _eq(a, b):
    return (a[0] * b[2] - b[0] * a[2]) % _P == 0 and (a[1] * b[2] - b[1] * a[2]) % _P == 0


_GY = 4 * _inv(5) % _P
_GX = _recover_x(_GY, 0)
_G = (_GX, _GY, 1, _GX * _GY % _P)


def _compress(pt):
    zinv = _inv(pt[2])
    x, y = pt[0] * zinv % _P, pt[1] * zinv % _P
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")


def _decompress(s):
    if len(s) != 32:
        return None
    y = int.from_bytes(s, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    x = _recover_x(y, sign)
    return None if x is None else (x, y, 1, x * y % _P)


def _expand(seed):
    if len(seed) != 32:
        raise ValueError("the seed must be 32 bytes")
    h = hashlib.sha512(seed).digest()
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return a, h[32:]


def ed25519_public_from_seed(seed):
    a, _ = _expand(seed)
    return _compress(_mul(a, _G))


def ed25519_sign(seed, msg):
    a, prefix = _expand(seed)
    public = _compress(_mul(a, _G))
    r = int.from_bytes(hashlib.sha512(prefix + msg).digest(), "little") % _Q
    r_bytes = _compress(_mul(r, _G))
    h = int.from_bytes(hashlib.sha512(r_bytes + public + msg).digest(), "little") % _Q
    s = (r + h * a) % _Q
    return r_bytes + int.to_bytes(s, 32, "little")


def ed25519_verify(public, msg, sig):
    if len(public) != 32 or len(sig) != 64:
        return False
    a_pt = _decompress(public)
    r_bytes = sig[:32]
    r_pt = _decompress(r_bytes)
    if a_pt is None or r_pt is None:
        return False
    s = int.from_bytes(sig[32:], "little")
    if s >= _Q:
        return False
    h = int.from_bytes(hashlib.sha512(r_bytes + public + msg).digest(), "little") % _Q
    return _eq(_mul(s, _G), _add(r_pt, _mul(h, a_pt)))


def public_from_sparkle_secret(secret_b64):
    """Public key from the secret exported by `generate_keys -x`.

    Current format: 32 bytes (seed). Legacy format: 96 bytes = 64-byte private key + 32-byte public key.
    """
    raw = base64.b64decode(secret_b64.strip(), validate=True)
    if len(raw) == 32:
        return ed25519_public_from_seed(raw)
    if len(raw) == 96:
        return raw[64:]
    raise ValueError("the Sparkle private key must decode to 32 or 96 bytes")


# ---------------------------------------------------------------------------
# Appcast
# ---------------------------------------------------------------------------
def version_key(v):
    """Sort key for dotted numeric versions (enough for CFBundleVersion)."""
    parts = []
    for p in re.split(r"[.]", v.strip()):
        m = re.match(r"^(\d+)(.*)$", p)
        parts.append((int(m.group(1)), m.group(2)) if m else (-1, p))
    while parts and parts[-1] == (0, ""):
        parts.pop()
    return parts


def load_items(path):
    """Feed items as flat dicts."""
    root = ET.parse(path).getroot()
    channel = root.find("channel")
    items = []
    if channel is None:
        return items
    for it in channel.findall("item"):
        enc = it.find("enclosure")
        if enc is None:
            continue
        rec = {
            "build": it.findtext(SP + "version") or enc.get(SP + "version") or "",
            "short": it.findtext(SP + "shortVersionString") or enc.get(SP + "shortVersionString") or "",
            "min_system": it.findtext(SP + "minimumSystemVersion") or "",
            "channel": it.findtext(SP + "channel") or "",
            "url": enc.get("url") or "",
            "sig": enc.get(SP + "edSignature") or "",
            "length": enc.get("length") or "",
            "deltas": [],
        }
        deltas = it.find(SP + "deltas")
        if deltas is not None:
            for d in deltas.findall("enclosure"):
                rec["deltas"].append({
                    "url": d.get("url") or "",
                    "sig": d.get(SP + "edSignature") or "",
                    "from": d.get(SP + "deltaFrom") or "",
                    "length": d.get("length") or "",
                })
        items.append(rec)
    return items


def basename_of(url):
    return url.split("?", 1)[0].rstrip("/").rsplit("/", 1)[-1]


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def cmd_check_new(a):
    """0 = publishable; 3 = already published and identical (idempotent retry); 1 = error."""
    zip_path = a.archive
    appcast = os.path.join(a.dir, "appcast.xml")
    items = load_items(appcast) if os.path.exists(appcast) else []
    status = 0
    same = [i for i in items if i["short"] == a.version]
    if same:
        remote_zip = os.path.join(a.dir, basename_of(same[0]["url"]))
        if os.path.exists(remote_zip) and sha256_file(remote_zip) == sha256_file(zip_path):
            print("version %s is already published with an identical zip: idempotent retry" % a.version)
            status = 3
        else:
            print("ERROR: version %s already exists in the appcast with different contents; a published release is "
                  "never overwritten (bump the version, or roll back explicitly first)" % a.version, file=sys.stderr)
            return 1
    others = [i for i in items if i["short"] != a.version]
    if others:
        top = max((i["build"] for i in others), key=version_key)
        if version_key(a.build) <= version_key(top):
            print("ERROR: CFBundleVersion %s is not greater than the highest published one (%s); Sparkle would not "
                  "offer it. If a newer release is queued, re-run this one after it" % (a.build, top), file=sys.stderr)
            return 1
    existing = os.path.join(a.dir, os.path.basename(zip_path))
    if os.path.exists(existing) and os.path.abspath(existing) != os.path.abspath(zip_path):
        if sha256_file(existing) != sha256_file(zip_path):
            print("ERROR: %s already exists in the bucket with different contents" % os.path.basename(zip_path),
                  file=sys.stderr)
            return 1
    return status


def _feed_is_signed(path):
    with open(path, "rb") as f:
        return b"sparkle-signatures" in f.read()


def cmd_verify(a):
    appcast = os.path.join(a.dir, "appcast.xml")
    errors = []
    items = load_items(appcast)
    base = a.base_url.rstrip("/") + "/"
    download = (a.download_prefix or base).rstrip("/") + "/"
    if not download.startswith(base):
        errors.append("the download prefix is not under UPDATES_BASE_URL")
    if not items:
        errors.append("the appcast has no items")
    new = [i for i in items if i["short"] == a.version and i["build"] == a.build] if a.version else []
    if a.version and len(new) != 1:
        errors.append("there must be exactly one item with version %s and build %s (found %d)" % (
            a.version, a.build, len(new)))
    if a.absent and any(i["short"] == a.absent for i in items):
        errors.append("version %s is still in the appcast" % a.absent)
    for i in items:
        label = i["short"] or i["build"]
        for enc in [{"url": i["url"], "sig": i["sig"]}] + i["deltas"]:
            if not enc["url"].startswith(download):
                errors.append("%s: URL outside the download prefix (%s)" % (label, download))
            if not enc["sig"]:
                errors.append("%s: enclosure without sparkle:edSignature" % label)
            name = basename_of(enc["url"])
            if not os.path.exists(os.path.join(a.dir, name)):
                errors.append("%s: the feed references %s but it is not in the directory to publish" % (label, name))
        if i["min_system"] and a.min_system and version_key(i["min_system"]) < version_key(a.min_system):
            errors.append("%s: minimumSystemVersion %s < %s" % (label, i["min_system"], a.min_system))
    if new:
        n = new[0]
        if not n["min_system"]:
            errors.append("the new item has no sparkle:minimumSystemVersion")
        elif a.min_system and version_key(n["min_system"]) != version_key(a.min_system):
            errors.append("the new item has minimumSystemVersion %s, expected %s" % (n["min_system"], a.min_system))
        if (n["channel"] or "") != (a.channel or ""):
            errors.append("channel of the new item '%s' != expected '%s'" % (n["channel"], a.channel or ""))
        if a.public:
            pub = base64.b64decode(a.public)
            zpath = os.path.join(a.dir, basename_of(n["url"]))
            if os.path.exists(zpath) and n["sig"]:
                with open(zpath, "rb") as f:
                    data = f.read()
                if not ed25519_verify(pub, data, base64.b64decode(n["sig"])):
                    errors.append("the EdDSA signature of the new zip does NOT match the public key (SUPublicEDKey)")
                if str(len(data)) != n["length"]:
                    errors.append("enclosure length != actual zip size")
            for d in n["deltas"]:
                dpath = os.path.join(a.dir, basename_of(d["url"]))
                if os.path.exists(dpath) and d["sig"]:
                    with open(dpath, "rb") as f:
                        ok = ed25519_verify(pub, f.read(), base64.b64decode(d["sig"]))
                    if not ok:
                        errors.append("the signature of a delta does not match the public key")
    if a.require_signed_feed and not _feed_is_signed(appcast):
        errors.append("the app sets SURequireSignedFeed but the appcast is not signed")
    for e in errors:
        print("ERROR: " + e, file=sys.stderr)
    if not errors:
        print("appcast OK: %d item(s)%s" % (len(items), ", new %s (build %s)" % (a.version, a.build) if a.version else ""))
    return 1 if errors else 0


def cmd_find(a):
    items = load_items(a.appcast)
    hit = [i for i in items if i["short"] == a.version]
    if not hit:
        print("version %s is not in the appcast" % a.version, file=sys.stderr)
        return 1
    it = hit[0]
    files = [basename_of(it["url"])]
    # deltas targeting it (in its own item) and deltas from it to other versions
    files += [basename_of(d["url"]) for d in it["deltas"]]
    for other in items:
        if other is not it:
            files += [basename_of(d["url"]) for d in other["deltas"] if d["from"] == it["build"]]
    print(json.dumps({"build": it["build"], "short": it["short"], "files": sorted(set(files)),
                      "remaining": len(items) - 1}))
    return 0


def cmd_get_sig(a):
    for i in load_items(a.appcast):
        if i["short"] == a.version and i["sig"]:
            print(i["sig"])
            return 0
    return 1


def cmd_prune(a):
    """Emergency rollback: drops the version's item and every delta whose file is no longer in --dir."""
    ET.register_namespace("sparkle", NS)
    ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")
    tree = ET.parse(a.appcast)
    channel = tree.getroot().find("channel")
    removed_items = removed_deltas = 0
    for it in list(channel.findall("item")):
        enc = it.find("enclosure")
        short = it.findtext(SP + "shortVersionString") or (enc.get(SP + "shortVersionString") if enc is not None else "")
        if short == a.version:
            channel.remove(it)
            removed_items += 1
            continue
        deltas = it.find(SP + "deltas")
        if deltas is None:
            continue
        for d in list(deltas.findall("enclosure")):
            if not os.path.exists(os.path.join(a.dir, basename_of(d.get("url") or ""))):
                deltas.remove(d)
                removed_deltas += 1
        if not deltas.findall("enclosure"):
            it.remove(deltas)
    tree.write(a.appcast, encoding="utf-8", xml_declaration=True)
    print("items removed: %d, orphan deltas removed: %d" % (removed_items, removed_deltas))
    return 0


def cmd_list_files(a):
    seen = []
    for i in load_items(a.appcast):
        for url in [i["url"]] + [d["url"] for d in i["deltas"]]:
            n = basename_of(url)
            if n and n not in seen:
                seen.append(n)
    print("\n".join(seen))
    return 0


def cmd_max_build(a):
    items = load_items(a.appcast)
    print(max((i["build"] for i in items), key=version_key) if items else "")
    return 0


def _read_stdin_secret():
    data = sys.stdin.read().strip()
    if not data:
        raise SystemExit("ERROR: no private key received on stdin")
    return data


def cmd_gen_key(_a):
    seed = os.urandom(32)
    print(base64.b64encode(seed).decode())
    print(base64.b64encode(ed25519_public_from_seed(seed)).decode())
    return 0


def cmd_derive_public(_a):
    print(base64.b64encode(public_from_sparkle_secret(_read_stdin_secret())).decode())
    return 0


def cmd_check_key(a):
    derived = public_from_sparkle_secret(_read_stdin_secret())
    if derived != base64.b64decode(a.public):
        print("ERROR: the private key (SPARKLE_ED_PRIVATE_KEY) does not match SPARKLE_ED_PUBLIC_KEY", file=sys.stderr)
        return 1
    print("Sparkle private and public keys match")
    return 0


def cmd_verify_sig(a):
    with open(a.file, "rb") as f:
        ok = ed25519_verify(base64.b64decode(a.public), f.read(), base64.b64decode(a.sig))
    if not ok:
        print("ERROR: the signature does not match the public key", file=sys.stderr)
    return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("gen-key").set_defaults(fn=cmd_gen_key)
    sub.add_parser("derive-public").set_defaults(fn=cmd_derive_public)
    p = sub.add_parser("check-key")
    p.add_argument("--public", required=True)
    p.set_defaults(fn=cmd_check_key)
    p = sub.add_parser("verify-sig")
    p.add_argument("--public", required=True)
    p.add_argument("--file", required=True)
    p.add_argument("--sig", required=True)
    p.set_defaults(fn=cmd_verify_sig)
    p = sub.add_parser("max-build")
    p.add_argument("--appcast", required=True)
    p.set_defaults(fn=cmd_max_build)
    p = sub.add_parser("get-sig")
    p.add_argument("--appcast", required=True)
    p.add_argument("--version", required=True)
    p.set_defaults(fn=cmd_get_sig)
    p = sub.add_parser("list-files")
    p.add_argument("--appcast", required=True)
    p.set_defaults(fn=cmd_list_files)
    p = sub.add_parser("check-new")
    p.add_argument("--dir", required=True)
    p.add_argument("--archive", required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--build", required=True)
    p.set_defaults(fn=cmd_check_new)
    p = sub.add_parser("verify")
    p.add_argument("--dir", required=True)
    p.add_argument("--base-url", required=True)
    p.add_argument("--download-prefix", default="", help="URL prefix of every enclosure (default: --base-url)")
    p.add_argument("--version", default="")
    p.add_argument("--build", default="")
    p.add_argument("--absent", default="", help="version that must NOT be in the feed (rollback)")
    p.add_argument("--min-system", default="")
    p.add_argument("--channel", default="")
    p.add_argument("--public", default="")
    p.add_argument("--require-signed-feed", action="store_true")
    p.set_defaults(fn=cmd_verify)
    p = sub.add_parser("find")
    p.add_argument("--appcast", required=True)
    p.add_argument("--version", required=True)
    p.set_defaults(fn=cmd_find)
    p = sub.add_parser("prune")
    p.add_argument("--appcast", required=True)
    p.add_argument("--dir", required=True)
    p.add_argument("--version", required=True)
    p.set_defaults(fn=cmd_prune)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
