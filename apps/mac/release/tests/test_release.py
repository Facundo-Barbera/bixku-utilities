"""Tests of the macOS release pipeline (no credentials, no macOS).

They run the REAL scripts of apps/mac/release with fake executables first in PATH (see fakes.py) and check the
GitHub Actions workflows. Fictitious data only: example.* hosts, toy keys, made-up Team ID.

    python3 -m unittest discover -s apps/mac/release/tests -v
"""
import base64
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fakes  # noqa: E402

appcast = fakes.appcast
RELEASE = fakes.RELEASE
MAC = os.path.dirname(RELEASE)
ROOT = os.path.dirname(os.path.dirname(MAC))
WORKFLOWS = os.path.join(ROOT, ".github", "workflows")
sys.path.insert(0, RELEASE)
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location("render_plist", os.path.join(RELEASE, "render-plist.py"))
render_plist = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(render_plist)

try:
    import yaml
except ImportError:  # pragma: no cover - without PyYAML only the text checks run
    yaml = None

SIGN_SECRETS = ["MACOS_CERT_P12_BASE64", "MACOS_CERT_PASSWORD", "KEYCHAIN_PASSWORD",
                "ASC_API_KEY_P8_BASE64", "ASC_API_KEY_ID", "ASC_API_ISSUER_ID"]
PUBLISH_SECRETS = ["SPARKLE_ED_PRIVATE_KEY", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"]
REQUIRED_VARS = ["APPLE_TEAM_ID", "BUNDLE_ID", "SIGNING_IDENTITY", "SPARKLE_ED_PUBLIC_KEY",
                 "R2_ACCOUNT_ID", "R2_BUCKET", "UPDATES_BASE_URL"]
SEED = bytes(range(32))  # toy key
PUB_B64 = base64.b64encode(appcast.ed25519_public_from_seed(SEED)).decode()
PRIV_B64 = base64.b64encode(SEED).decode()
BASE_URL = "https://updates.example.com/my-app"


def valid_release_env():
    env = {n: "set" for n in SIGN_SECRETS + PUBLISH_SECRETS}
    env.update({
        "APPLE_TEAM_ID": "ABCDE12345",
        "BUNDLE_ID": "online.bixku.utilities",
        "SIGNING_IDENTITY": "Developer ID Application: Example Dev (ABCDE12345)",
        "SPARKLE_ED_PUBLIC_KEY": PUB_B64,
        "R2_ACCOUNT_ID": "0123456789abcdef0123456789abcdef",
        "R2_BUCKET": "example-updates",
        "UPDATES_BASE_URL": BASE_URL,
    })
    return env


class ScriptCase(unittest.TestCase):
    """Runs scripts in a clean environment with the fakes first in PATH."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="bixku-release-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = fakes.install(os.path.join(self.tmp, "bin"))
        self.log = os.path.join(self.tmp, "calls.log")
        self.state = os.path.join(self.tmp, "state")
        self.bucket = os.path.join(self.tmp, "bucket")
        os.makedirs(self.state)
        os.makedirs(os.path.join(self.bucket, "example-updates"))
        open(self.log, "w").close()

    def run_script(self, script, *args, env=None, cwd=None):
        base = {
            "PATH": self.bin + os.pathsep + "/usr/bin:/bin",
            "HOME": self.tmp,
            "TMPDIR": self.tmp,
            "RUNNER_TEMP": self.tmp,
            "FAKE_LOG": self.log,
            "FAKE_STATE": self.state,
            "FAKE_BUCKET": self.bucket,
            "FAKE_CDN_BUCKET": "example-updates",
            "PLISTBUDDY": os.path.join(self.bin, "PlistBuddy"),
            "RETRY_SLEEP": "true",
            "LC_ALL": "C",
        }
        base.update(env or {})
        cmd = [os.path.join(RELEASE, script)] if script.endswith(".sh") else [sys.executable, os.path.join(RELEASE, script)]
        if script.endswith(".sh"):
            cmd = ["bash"] + cmd
        return subprocess.run(cmd + list(args), env=base, cwd=cwd or self.tmp,
                              capture_output=True, text=True, timeout=120)

    def calls(self):
        with open(self.log) as f:
            return [ln.rstrip("\n") for ln in f if ln.strip()]

    def outputs(self, proc):
        return dict(ln.split("=", 1) for ln in proc.stdout.splitlines() if re.match(r"^[a-z0-9_]+=", ln))


# --------------------------------------------------------------------------------------------- version.sh
class VersionTests(ScriptCase):
    def test_stable_tag(self):
        p = self.run_script("version.sh", "--ref-type", "tag", "--ref-name", "v1.2.3", env={"BUILD_NUMBER": "202601020304"})
        self.assertEqual(p.returncode, 0, p.stderr)
        o = self.outputs(p)
        self.assertEqual(o["tag"], "v1.2.3")
        self.assertEqual(o["short_version"], "1.2.3")
        self.assertEqual(o["build_number"], "202601020304")
        self.assertEqual(o["channel"], "")
        self.assertEqual(o["prerelease"], "false")

    def test_prerelease_goes_to_beta(self):
        o = self.outputs(self.run_script("version.sh", "--ref-type", "tag", "--ref-name", "v2.0.0-beta.1"))
        self.assertEqual(o["short_version"], "2.0.0-beta.1")
        self.assertEqual(o["channel"], "beta")
        self.assertEqual(o["prerelease"], "true")
        self.assertRegex(o["build_number"], r"^\d{12}$")

    def test_rejects_invalid_tags(self):
        for bad in ("1.2.3", "v1.2", "v01.2.3", "v1.2.3+build.5", "vX.Y.Z", "v1.2.3-"):
            p = self.run_script("version.sh", "--ref-type", "tag", "--ref-name", bad)
            self.assertNotEqual(p.returncode, 0, bad)

    def test_branch_requires_dry_run(self):
        self.assertNotEqual(self.run_script("version.sh", "--ref-type", "branch", "--ref-name", "main").returncode, 0)
        p = self.run_script("version.sh", "--ref-type", "branch", "--ref-name", "main", "--dry-run")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.outputs(p)["short_version"], "0.0.0-dryrun")
        self.assertEqual(self.outputs(p)["tag"], "")

    def test_dry_run_from_tag_has_no_tag(self):
        o = self.outputs(self.run_script("version.sh", "--ref-type", "tag", "--ref-name", "v1.0.0", "--dry-run"))
        self.assertEqual(o["tag"], "")
        self.assertEqual(o["short_version"], "1.0.0")

    def test_build_number_must_be_numeric(self):
        p = self.run_script("version.sh", "--ref-type", "tag", "--ref-name", "v1.0.0", env={"BUILD_NUMBER": "12a"})
        self.assertNotEqual(p.returncode, 0)


# ------------------------------------------------------------------------------------------- preflight.sh
class PreflightTests(ScriptCase):
    def test_release_lists_every_missing_name(self):
        p = self.run_script("preflight.sh", "release")
        self.assertEqual(p.returncode, 1)
        for name in SIGN_SECRETS + PUBLISH_SECRETS + REQUIRED_VARS:
            self.assertIn(name, p.stderr)

    def test_release_ok_with_everything(self):
        p = self.run_script("preflight.sh", "release", env=valid_release_env())
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_release_reports_only_what_is_missing(self):
        env = valid_release_env()
        del env["R2_BUCKET"], env["ASC_API_KEY_ID"]
        p = self.run_script("preflight.sh", "release", env=env)
        self.assertEqual(p.returncode, 1)
        self.assertIn("Missing 2 required", p.stderr)
        self.assertIn("R2_BUCKET (var)", p.stderr)
        self.assertIn("ASC_API_KEY_ID (secret)", p.stderr)

    def test_summary_table(self):
        summary = os.path.join(self.tmp, "summary.md")
        self.run_script("preflight.sh", "release", env={"GITHUB_STEP_SUMMARY": summary})
        with open(summary) as f:
            text = f.read()
        self.assertIn("| `MACOS_CERT_P12_BASE64` | secret |", text)

    def test_dry_run_needs_nothing(self):
        out = os.path.join(self.tmp, "out")
        p = self.run_script("preflight.sh", "release", env={"PREFLIGHT_MODE": "dryrun", "GITHUB_OUTPUT": out})
        self.assertEqual(p.returncode, 0, p.stderr)
        with open(out) as f:
            text = f.read()
        self.assertIn("r2_ready=false", text)
        self.assertIn("sparkle_key_ready=false", text)
        self.assertIn("::notice::", p.stdout)

    def test_dry_run_detects_r2_and_sparkle(self):
        env = valid_release_env()
        env["PREFLIGHT_MODE"] = "dryrun"
        o = self.outputs(self.run_script("preflight.sh", "release", env=env))
        self.assertEqual(o["r2_ready"], "true")
        self.assertEqual(o["sparkle_key_ready"], "true")
        del env["R2_SECRET_ACCESS_KEY"]
        self.assertEqual(self.outputs(self.run_script("preflight.sh", "release", env=env))["r2_ready"], "false")

    def test_dry_run_still_rejects_malformed_vars(self):
        p = self.run_script("preflight.sh", "release", env={"PREFLIGHT_MODE": "dryrun", "UPDATES_BASE_URL": "http://x.example.com"})
        self.assertEqual(p.returncode, 1)
        self.assertIn("UPDATES_BASE_URL", p.stderr)

    def test_formats(self):
        cases = {
            "UPDATES_BASE_URL": ["http://updates.example.com", "https://updates.example.com/app/", "https://u.example.com/?a=1"],
            "SPARKLE_ED_PUBLIC_KEY": ["abc", base64.b64encode(b"x" * 31).decode()],
            "APPLE_TEAM_ID": ["abcde12345", "ABC"],
            "R2_ACCOUNT_ID": ["nothex"],
            "R2_BUCKET": ["Bad_Bucket"],
            "SIGNING_IDENTITY": ["Apple Development: X (ABCDE12345)", "Developer ID Application: X (ZZZZZ99999)"],
            "BUNDLE_ID": ["not a bundle id", "com.example.app"],
        }
        for name, values in cases.items():
            for v in values:
                env = valid_release_env()
                env[name] = v
                p = self.run_script("preflight.sh", "release", env=env)
                self.assertEqual(p.returncode, 1, "%s=%r should fail" % (name, v))
                self.assertIn(name, p.stderr)

    def test_production_layout_example_is_valid(self):
        env = valid_release_env()
        env.update({"UPDATES_BASE_URL": "https://updates.example.online/bixku-utilities", "R2_BUCKET": "example-updates"})
        self.assertEqual(self.run_script("preflight.sh", "release", env=env).returncode, 0)

    def test_rollback_scope(self):
        p = self.run_script("preflight.sh", "rollback")
        self.assertEqual(p.returncode, 1)
        self.assertNotIn("MACOS_CERT_P12_BASE64", p.stderr)
        for name in PUBLISH_SECRETS + ["SPARKLE_ED_PUBLIC_KEY", "R2_ACCOUNT_ID", "R2_BUCKET", "UPDATES_BASE_URL"]:
            self.assertIn(name, p.stderr)

    def test_never_prints_secret_flags_as_values(self):
        env = valid_release_env()
        env["MACOS_CERT_PASSWORD"] = "super-secret-value"
        p = self.run_script("preflight.sh", "release", env=env)
        self.assertNotIn("super-secret-value", p.stdout + p.stderr)


# -------------------------------------------------------------------------------------- render-plist.py
class RenderPlistTests(ScriptCase):
    TEMPLATE = os.path.join(MAC, "Resources", "Info.plist")
    BASE = {"EXECUTABLE_NAME": "BixkuUtilities", "MARKETING_VERSION": "1.2.3", "CURRENT_PROJECT_VERSION": "202601010000"}

    def template(self):
        with open(self.TEMPLATE, "rb") as f:
            return plistlib.load(f)

    def test_template_has_expected_keys(self):
        t = self.template()
        self.assertEqual(t["CFBundleIdentifier"], "online.bixku.utilities")
        self.assertEqual(t["SUFeedURL"], "$(UPDATES_BASE_URL)/appcast.xml")
        self.assertEqual(t["SUPublicEDKey"], "$(SPARKLE_ED_PUBLIC_KEY)")
        self.assertIs(t["SUEnableAutomaticChecks"], True)
        self.assertIn("SUScheduledCheckInterval", t)

    def test_full_render(self):
        values = dict(self.BASE, UPDATES_BASE_URL=BASE_URL + "/", SPARKLE_ED_PUBLIC_KEY=PUB_B64,
                      BUNDLE_ID="online.bixku.utilities", MIN_MACOS_VERSION="13.0", SPARKLE_CHECK_INTERVAL="3600")
        plist, sparkle = render_plist.render(self.template(), values, icon="AppIcon", require_sparkle=True)
        self.assertTrue(sparkle)
        self.assertEqual(plist["CFBundleExecutable"], "BixkuUtilities")
        self.assertEqual(plist["CFBundleShortVersionString"], "1.2.3")
        self.assertEqual(plist["CFBundleVersion"], "202601010000")
        self.assertEqual(plist["SUFeedURL"], BASE_URL + "/appcast.xml")
        self.assertEqual(plist["SUPublicEDKey"], PUB_B64)
        self.assertEqual(plist["SUScheduledCheckInterval"], 3600)
        self.assertIs(plist["SUAutomaticallyUpdate"], False)
        self.assertEqual(plist["CFBundleIconFile"], "AppIcon")
        self.assertEqual(plist["LSMinimumSystemVersion"], "13.0")
        self.assertNotIn("$(", plistlib.dumps(plist).decode())

    def test_without_sparkle_values_keys_are_removed(self):
        plist, sparkle = render_plist.render(self.template(), dict(self.BASE))
        self.assertFalse(sparkle)
        self.assertFalse([k for k in plist if k.startswith("SU")])
        self.assertNotIn("$(", plistlib.dumps(plist).decode())

    def test_release_requires_sparkle(self):
        with self.assertRaises(render_plist.RenderError):
            render_plist.render(self.template(), dict(self.BASE), require_sparkle=True)
        with self.assertRaises(render_plist.RenderError):
            render_plist.render(self.template(), dict(self.BASE, UPDATES_BASE_URL="http://insecure.example.com",
                                                      SPARKLE_ED_PUBLIC_KEY=PUB_B64), require_sparkle=True)

    def test_invalid_values(self):
        bad = [
            dict(self.BASE, MARKETING_VERSION="1.2"),
            dict(self.BASE, CURRENT_PROJECT_VERSION="abc"),
            dict(self.BASE, UPDATES_BASE_URL=BASE_URL, SPARKLE_ED_PUBLIC_KEY=PUB_B64, SPARKLE_CHECK_INTERVAL="60"),
            dict(self.BASE, UPDATES_BASE_URL=BASE_URL, SPARKLE_ED_PUBLIC_KEY=PUB_B64, SPARKLE_AUTO_UPDATE="yes"),
            dict(self.BASE, MIN_MACOS_VERSION="thirteen"),
        ]
        for values in bad:
            with self.assertRaises(render_plist.RenderError, msg=values):
                render_plist.render(self.template(), values)

    def test_unresolved_placeholder_fails(self):
        t = self.template()
        t["Custom"] = "$(NOT_PROVIDED)"
        with self.assertRaises(render_plist.RenderError):
            render_plist.render(t, dict(self.BASE))

    def test_cli(self):
        out = os.path.join(self.tmp, "Info.plist")
        p = self.run_script("render-plist.py", "--template", self.TEMPLATE, "--output", out,
                            *sum([["--set", "%s=%s" % kv] for kv in dict(
                                self.BASE, UPDATES_BASE_URL=BASE_URL, SPARKLE_ED_PUBLIC_KEY=PUB_B64).items()], []),
                            "--require-sparkle")
        self.assertEqual(p.returncode, 0, p.stderr)
        with open(out, "rb") as f:
            self.assertEqual(plistlib.load(f)["SUFeedURL"], BASE_URL + "/appcast.xml")
        p = self.run_script("render-plist.py", "--template", self.TEMPLATE, "--output", out,
                            "--set", "EXECUTABLE_NAME=X", "--set", "MARKETING_VERSION=1.0.0",
                            "--set", "CURRENT_PROJECT_VERSION=1", "--require-sparkle")
        self.assertEqual(p.returncode, 1)
        self.assertIn("::error::", p.stderr)


# ------------------------------------------------------------------------------------------ appcast.py
def make_feed(directory, entries, prefix=BASE_URL + "/releases/", signed=True, seed=SEED):
    """entries: list of (short, build, data, channel)."""
    items = []
    for short, build, data, channel in entries:
        name = "BixkuUtilities-%s.zip" % short
        with open(os.path.join(directory, name), "wb") as f:
            f.write(data)
        sig = base64.b64encode(appcast.ed25519_sign(seed, data)).decode()
        items.append(
            '<item><sparkle:version>%s</sparkle:version><sparkle:shortVersionString>%s</sparkle:shortVersionString>'
            '<sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>%s'
            '<enclosure url="%s%s" length="%d" sparkle:edSignature="%s"/></item>'
            % (build, short, "<sparkle:channel>%s</sparkle:channel>" % channel if channel else "", prefix, name, len(data), sig))
    xml = ('<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
           '<channel>%s</channel></rss>%s' % ("".join(items), "\n<!-- sparkle-signatures:\n-->" if signed else ""))
    with open(os.path.join(directory, "appcast.xml"), "w") as f:
        f.write(xml)


class AppcastTests(ScriptCase):
    def test_rfc8032_vector(self):
        seed = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        pub = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        sig = bytes.fromhex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
        self.assertEqual(appcast.ed25519_public_from_seed(seed), pub)
        self.assertEqual(appcast.ed25519_sign(seed, b""), sig)
        self.assertTrue(appcast.ed25519_verify(pub, b"", sig))
        self.assertFalse(appcast.ed25519_verify(pub, b"x", sig))

    def test_gen_key_and_check_key(self):
        p = self.run_script("appcast.py", "gen-key")
        priv, pub = p.stdout.split()
        self.assertEqual(len(base64.b64decode(priv)), 32)
        ok = subprocess.run([sys.executable, os.path.join(RELEASE, "appcast.py"), "check-key", "--public", pub],
                            input=priv, capture_output=True, text=True)
        self.assertEqual(ok.returncode, 0, ok.stderr)
        bad = subprocess.run([sys.executable, os.path.join(RELEASE, "appcast.py"), "check-key", "--public", PUB_B64],
                             input=priv, capture_output=True, text=True)
        self.assertEqual(bad.returncode, 1)
        self.assertNotIn(priv, ok.stdout + ok.stderr + bad.stdout + bad.stderr)

    def test_legacy_96_byte_secret(self):
        legacy = base64.b64encode(b"\0" * 64 + appcast.ed25519_public_from_seed(SEED)).decode()
        self.assertEqual(base64.b64encode(appcast.public_from_sparkle_secret(legacy)).decode(), PUB_B64)

    def test_check_new(self):
        d = os.path.join(self.tmp, "feed")
        os.makedirs(d)
        make_feed(d, [("1.0.0", "202601010000", b"one", "")])
        new = os.path.join(self.tmp, "BixkuUtilities-1.1.0.zip")
        with open(new, "wb") as f:
            f.write(b"two")
        ok = lambda *a: self.run_script("appcast.py", "check-new", "--dir", d, "--archive", *a).returncode  # noqa: E731
        self.assertEqual(ok(new, "--version", "1.1.0", "--build", "202602010000"), 0)
        self.assertEqual(ok(new, "--version", "1.1.0", "--build", "202512010000"), 1)  # not monotonic
        same = os.path.join(self.tmp, "same", "BixkuUtilities-1.0.0.zip")
        os.makedirs(os.path.dirname(same))
        with open(same, "wb") as f:
            f.write(b"one")
        self.assertEqual(ok(same, "--version", "1.0.0", "--build", "202601010000"), 3)  # idempotent retry
        with open(same, "wb") as f:
            f.write(b"different")
        self.assertEqual(ok(same, "--version", "1.0.0", "--build", "202601010000"), 1)  # never overwrite

    def test_verify(self):
        d = os.path.join(self.tmp, "feed")
        os.makedirs(d)
        make_feed(d, [("1.0.0", "1", b"one", ""), ("1.1.0-beta.1", "2", b"two", "beta")])
        args = ["verify", "--dir", d, "--base-url", BASE_URL, "--download-prefix", BASE_URL + "/releases/",
                "--min-system", "13.0", "--public", PUB_B64, "--require-signed-feed"]
        p = self.run_script("appcast.py", *args, "--version", "1.1.0-beta.1", "--build", "2", "--channel", "beta")
        self.assertEqual(p.returncode, 0, p.stderr)
        # wrong channel, wrong key, unsigned feed, wrong prefix, absent version still present
        self.assertEqual(self.run_script("appcast.py", *args, "--version", "1.1.0-beta.1", "--build", "2").returncode, 1)
        other = base64.b64encode(appcast.ed25519_public_from_seed(b"\1" * 32)).decode()
        bad_key = [a if a != PUB_B64 else other for a in args]
        self.assertEqual(self.run_script("appcast.py", *bad_key, "--version", "1.0.0", "--build", "1").returncode, 1)
        self.assertEqual(self.run_script("appcast.py", *args, "--absent", "1.0.0").returncode, 1)
        make_feed(d, [("1.0.0", "1", b"one", "")], signed=False)
        self.assertEqual(self.run_script("appcast.py", *args).returncode, 1)
        make_feed(d, [("1.0.0", "1", b"one", "")], prefix=BASE_URL + "/")
        self.assertEqual(self.run_script("appcast.py", *args).returncode, 1)

    def test_find_and_prune(self):
        d = os.path.join(self.tmp, "feed")
        os.makedirs(d)
        make_feed(d, [("1.0.0", "1", b"one", ""), ("1.1.0", "2", b"two", "")])
        p = self.run_script("appcast.py", "find", "--appcast", os.path.join(d, "appcast.xml"), "--version", "1.1.0")
        info = json.loads(p.stdout)
        self.assertEqual(info["files"], ["BixkuUtilities-1.1.0.zip"])
        self.assertEqual(info["remaining"], 1)
        self.run_script("appcast.py", "prune", "--appcast", os.path.join(d, "appcast.xml"), "--dir", d, "--version", "1.1.0")
        items = appcast.load_items(os.path.join(d, "appcast.xml"))
        self.assertEqual([i["short"] for i in items], ["1.0.0"])


# ------------------------------------------------------------------------------------- dmg-background.py
class DmgBackgroundTests(ScriptCase):
    def png_size(self, path):
        with open(path, "rb") as f:
            data = f.read()
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        w, h = struct.unpack(">II", data[16:24])
        # every chunk CRC is valid
        pos = 8
        while pos < len(data):
            length = struct.unpack(">I", data[pos:pos + 4])[0]
            body = data[pos + 4:pos + 8 + length]
            self.assertEqual(struct.unpack(">I", data[pos + 8 + length:pos + 12 + length])[0], zlib.crc32(body) & 0xFFFFFFFF)
            pos += 12 + length
        return w, h

    def test_png_and_determinism(self):
        a, b = os.path.join(self.tmp, "a.png"), os.path.join(self.tmp, "b.png")
        self.assertEqual(self.run_script("dmg-background.py", a).returncode, 0)
        self.run_script("dmg-background.py", b)
        self.assertEqual(self.png_size(a), (660, 400))
        with open(a, "rb") as fa, open(b, "rb") as fb:
            self.assertEqual(fa.read(), fb.read())
        retina = os.path.join(self.tmp, "r.png")
        self.run_script("dmg-background.py", retina, "--scale", "2", "--width", "200", "--height", "100",
                        "--app-x", "40", "--apps-x", "160", "--icon-y", "50")
        self.assertEqual(self.png_size(retina), (400, 200))

    def test_layout_matches_dmg_script(self):
        with open(os.path.join(RELEASE, "dmg.sh")) as f:
            text = f.read()
        self.assertIn("WIN_W=660 WIN_H=400 ICON=128 APP_X=170 APPS_X=490 ICON_Y=190", text)
        self.assertIn("ln -s /Applications", text)


# -------------------------------------------------------------------------------------------- lib.sh
class LibTests(ScriptCase):
    def lib(self, snippet, env=None):
        script = os.path.join(self.tmp, "t.sh")
        with open(script, "w") as f:
            f.write('set -euo pipefail\nsource "%s"\n%s\n' % (os.path.join(RELEASE, "lib.sh"), snippet))
        e = {"PATH": "/usr/bin:/bin", "RETRY_SLEEP": "true", "HOME": self.tmp}
        e.update(env or {})
        return subprocess.run(["bash", script], capture_output=True, text=True, env=e)

    def test_url_key_prefix(self):
        cases = {
            "https://updates.example.com": "",
            "https://updates.example.com/": "",
            "https://updates.example.com/my-app": "my-app/",
            "https://updates.example.com/my-app/test/42/": "my-app/test/42/",
        }
        for url, want in cases.items():
            self.assertEqual(self.lib('printf "[%%s]" "$(url_key_prefix "%s")"' % url).stdout, "[%s]" % want)

    def test_version_ge(self):
        p = self.lib('version_ge 13.0 13 && version_ge 14.1 13.5 && ! version_ge 12.9 13.0 && echo ok')
        self.assertEqual(p.stdout.strip(), "ok")

    def test_retry(self):
        counter = os.path.join(self.tmp, "n")
        p = self.lib('f() { n=$(cat "%s" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "%s"; [ $n -ge 3 ]; }\n'
                     'retry 5 1 f && echo done' % (counter, counter))
        self.assertIn("done", p.stdout)
        self.assertEqual(p.stderr.count("::warning::"), 2)
        p = self.lib('retry 2 1 false')
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("failed after 2 attempt(s)", p.stderr)


# ------------------------------------------------------------------------------------------- sign-app.sh
class SignAppTests(ScriptCase):
    def make_app(self):
        app = os.path.join(self.tmp, "Bixku Utilities.app")
        fw = os.path.join(app, "Contents", "Frameworks", "Sparkle.framework", "Versions", "B")
        for d in ("XPCServices/Installer.xpc/Contents/MacOS", "XPCServices/Downloader.xpc/Contents/MacOS",
                  "Updater.app/Contents/MacOS"):
            os.makedirs(os.path.join(fw, d))
        macho = b"\xcf\xfa\xed\xfe" + b"\0" * 32
        for f in ("Sparkle", "Autoupdate", "XPCServices/Installer.xpc/Contents/MacOS/Installer",
                  "XPCServices/Downloader.xpc/Contents/MacOS/Downloader", "Updater.app/Contents/MacOS/Updater"):
            with open(os.path.join(fw, f), "wb") as fh:
                fh.write(macho)
        os.makedirs(os.path.join(app, "Contents", "MacOS"))
        with open(os.path.join(app, "Contents", "MacOS", "BixkuUtilities"), "wb") as fh:
            fh.write(macho)
        with open(os.path.join(app, "Contents", "Info.plist"), "wb") as fh:
            plistlib.dump({"CFBundleExecutable": "BixkuUtilities"}, fh)
        with open(os.path.join(app, "Contents", "Resources.txt"), "w") as fh:
            fh.write("not code")
        return app

    def test_inside_out_order(self):
        app = self.make_app()
        p = self.run_script("sign-app.sh", app, env={"SIGN_IDENTITY": "-"})
        self.assertEqual(p.returncode, 0, p.stderr)
        signed = [c[c.index(self.tmp):] for c in self.calls() if c.startswith("codesign --force")]
        self.assertEqual(signed[-1], app)  # the app is last
        idx = {os.path.relpath(s, app): i for i, s in enumerate(signed)}
        fw = "Contents/Frameworks/Sparkle.framework"
        self.assertLess(idx[fw + "/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"],
                        idx[fw + "/Versions/B/XPCServices/Installer.xpc"])
        for nested in ("/Versions/B/XPCServices/Installer.xpc", "/Versions/B/XPCServices/Downloader.xpc",
                       "/Versions/B/Updater.app", "/Versions/B/Autoupdate", "/Versions/B/Sparkle"):
            self.assertLess(idx[fw + nested], idx[fw], nested)
        self.assertNotIn("Contents/Resources.txt", idx)
        self.assertNotIn("Contents/MacOS/BixkuUtilities", idx)  # main executable is signed with the bundle
        for c in self.calls():
            if c.startswith("codesign --force"):
                self.assertIn("--options runtime", c)
                self.assertIn("--timestamp=none", c)  # ad-hoc
        self.assertIn("--entitlements", [c for c in self.calls() if c.startswith("codesign --force")][-1])

    def test_release_refuses_ad_hoc(self):
        p = self.run_script("sign-app.sh", self.make_app(), env={"SIGN_IDENTITY": "-", "RELEASE_MODE": "release"})
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual([c for c in self.calls() if c.startswith("codesign")], [])

    def test_real_identity_uses_timestamp_and_keychain(self):
        p = self.run_script("sign-app.sh", self.make_app(), env={
            "SIGN_IDENTITY": "0" * 40, "SIGN_KEYCHAIN": "/tmp/k.keychain-db", "APPLE_TEAM_ID": "ABCDE12345"})
        self.assertEqual(p.returncode, 0, p.stderr)
        for c in self.calls():
            if c.startswith("codesign --force"):
                self.assertIn(" --timestamp ", c + " ")
                self.assertIn("--keychain /tmp/k.keychain-db", c)

    def test_wrong_team_fails(self):
        p = self.run_script("sign-app.sh", self.make_app(), env={"SIGN_IDENTITY": "0" * 40, "APPLE_TEAM_ID": "ZZZZZ99999"})
        self.assertNotEqual(p.returncode, 0)


# ------------------------------------------------------------------------------------------ notarize.sh
class NotarizeTests(ScriptCase):
    ENV = {"ASC_API_KEY_P8_BASE64": base64.b64encode(b"-----FAKE KEY-----").decode(),
           "ASC_API_KEY_ID": "ABC123DEFG", "ASC_API_ISSUER_ID": "00000000-0000-0000-0000-000000000000"}

    def app(self):
        app = os.path.join(self.tmp, "Bixku Utilities.app")
        os.makedirs(os.path.join(app, "Contents"))
        return app

    def test_staple_is_retried(self):
        p = self.run_script("notarize.sh", self.app(), env=dict(self.ENV, FAKE_STAPLE_FAILS="2"))
        self.assertEqual(p.returncode, 0, p.stderr)
        staples = [c for c in self.calls() if c.startswith("xcrun stapler staple")]
        self.assertEqual(len(staples), 3)
        self.assertIn("origin=<hidden>", p.stdout)
        self.assertNotIn("ABCDE12345", p.stdout + p.stderr)
        self.assertFalse([f for f in os.listdir(self.tmp) if f.startswith("bixku-notary")])  # key file removed

    def test_gives_up_after_attempts(self):
        p = self.run_script("notarize.sh", self.app(), env=dict(self.ENV, FAKE_STAPLE_FAILS="10", STAPLE_ATTEMPTS="3"))
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(len([c for c in self.calls() if c.startswith("xcrun stapler staple")]), 3)

    def test_rejected_prints_log(self):
        p = self.run_script("notarize.sh", self.app(), env=dict(self.ENV, FAKE_NOTARY_STATUS="Invalid"))
        self.assertNotEqual(p.returncode, 0)
        self.assertTrue([c for c in self.calls() if c.startswith("xcrun notarytool log")])
        self.assertFalse([c for c in self.calls() if c.startswith("xcrun stapler")])

    def test_dmg_is_submitted_directly(self):
        dmg = os.path.join(self.tmp, "BixkuUtilities-1.0.0.dmg")
        open(dmg, "w").close()
        p = self.run_script("notarize.sh", dmg, env=self.ENV)
        self.assertEqual(p.returncode, 0, p.stderr)
        submit = [c for c in self.calls() if c.startswith("xcrun notarytool submit")][0]
        self.assertIn(dmg, submit)
        self.assertIn("--type open", "\n".join(self.calls()))

    def test_requires_credentials(self):
        p = self.run_script("notarize.sh", self.app())
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("ASC_API_KEY_P8_BASE64", p.stderr)


# ------------------------------------------------------------------------------ r2.sh / publish.sh / rollback
class PublishTests(ScriptCase):
    def r2_env(self, base=BASE_URL, test_only="0"):
        return {"R2_ACCOUNT_ID": "0123456789abcdef0123456789abcdef", "R2_ACCESS_KEY_ID": "fake-id",
                "R2_SECRET_ACCESS_KEY": "fake-secret", "R2_BUCKET": "example-updates",
                "UPDATES_BASE_URL": base, "R2_TEST_ONLY": test_only}

    def publish_env(self, version, build, **extra):
        env = self.r2_env()
        env.update({"SPARKLE_BIN": self.bin, "SPARKLE_ED_PRIVATE_KEY": PRIV_B64, "SPARKLE_ED_PUBLIC_KEY": PUB_B64,
                    "VERSION": version, "BUILD_NUMBER": build, "TAG": "v" + version, "CHANNEL": "",
                    "NOTES_VERSION": version})
        env.update(extra)
        return env

    def zip(self, version, data=None):
        d = os.path.join(self.tmp, "dist")
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, "BixkuUtilities-%s.zip" % version)
        with open(path, "wb") as f:
            f.write(data or ("zip of %s" % version).encode())
        return path

    def uploads(self):
        """Destinations of every `aws s3 cp` towards the bucket, in call order."""
        out = []
        for c in self.calls():
            if c.startswith("aws") and " s3 cp " in c:
                dst = c.split(" s3 cp ")[1].split()[1]
                if dst.startswith("s3://"):
                    out.append(dst)
        return out

    def key(self, *parts):
        return os.path.join(self.bucket, "example-updates", *parts)

    def test_release_publishes_in_order(self):
        p = self.run_script("publish.sh", self.zip("1.0.0"), env=self.publish_env("1.0.0", "202601010000"))
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertTrue(os.path.isfile(self.key("my-app", "appcast.xml")))
        self.assertTrue(os.path.isfile(self.key("my-app", "releases", "BixkuUtilities-1.0.0.zip")))
        self.assertTrue(os.path.isfile(self.key("my-app", "notes", "1.0.0.html")))
        targets = self.uploads()
        self.assertTrue(targets[-1].endswith("my-app/appcast.xml"), targets)
        self.assertLess(targets.index("s3://example-updates/my-app/releases/BixkuUtilities-1.0.0.zip"), len(targets) - 1)
        feed = self.key("my-app", "appcast.xml")
        items = appcast.load_items(feed)
        self.assertEqual(items[0]["url"], BASE_URL + "/releases/BixkuUtilities-1.0.0.zip")
        gen = [c for c in self.calls() if c.startswith("generate_appcast")][0]
        self.assertIn("--download-url-prefix %s/releases/" % BASE_URL, gen)
        self.assertNotIn(PRIV_B64, p.stdout + p.stderr)
        self.assertFalse([f for f in os.listdir(self.tmp) if f.startswith("bixku-sparkle-key")])

        # second release: monotonic, keeps the first zip
        p = self.run_script("publish.sh", self.zip("1.1.0"), env=self.publish_env("1.1.0", "202602010000"))
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertTrue(os.path.isfile(self.key("my-app", "releases", "BixkuUtilities-1.0.0.zip")))
        # older build number is refused, the feed is untouched
        before = read(self.key("my-app", "appcast.xml"))
        p = self.run_script("publish.sh", self.zip("1.2.0"), env=self.publish_env("1.2.0", "202501010000"))
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(read(self.key("my-app", "appcast.xml")), before)

    def test_wrong_private_key_is_refused(self):
        env = self.publish_env("1.0.0", "1", SPARKLE_ED_PRIVATE_KEY=base64.b64encode(b"\2" * 32).decode())
        p = self.run_script("publish.sh", self.zip("1.0.0"), env=env)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("does not match SPARKLE_ED_PUBLIC_KEY", p.stderr)
        self.assertFalse(os.path.exists(self.key("my-app", "appcast.xml")))

    def test_r2_errors_are_not_a_first_publication(self):
        p = self.run_script("publish.sh", self.zip("1.0.0"), env=self.publish_env("1.0.0", "1", FAKE_AWS_FAIL="1"))
        self.assertNotEqual(p.returncode, 0)
        self.assertFalse([c for c in self.calls() if c.startswith("generate_appcast")])

    def test_dry_run_stays_under_test_prefix(self):
        # production feed exists and must not change
        p = self.run_script("publish.sh", self.zip("1.0.0"), env=self.publish_env("1.0.0", "202601010000"))
        self.assertEqual(p.returncode, 0, p.stderr)
        prod = read(self.key("my-app", "appcast.xml"))
        open(self.log, "w").close()
        env = self.publish_env("0.0.0-dryrun", "202603010000", DRY_RUN="true", R2_TEST_ONLY="1",
                               UPDATES_BASE_URL=BASE_URL + "/test/777", SPARKLE_ED_PRIVATE_KEY="", SPARKLE_ED_PUBLIC_KEY="")
        snap = os.path.join(self.tmp, "snap")
        self.assertEqual(self.run_script("r2.sh", "prod-snapshot", snap, env=env).returncode, 0)
        p = self.run_script("publish.sh", self.zip("0.0.0-dryrun"), env=env)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("ephemeral", p.stdout)
        self.assertIn("::add-mask::", p.stdout)
        self.assertTrue(os.path.isfile(self.key("my-app", "test", "777", "appcast.xml")))
        self.assertTrue(os.path.isfile(self.key("my-app", "test", "777", "releases", "BixkuUtilities-0.0.0-dryrun.zip")))
        uploads = self.uploads()
        self.assertTrue(uploads)
        for dst in uploads:
            self.assertTrue(dst.startswith("s3://example-updates/my-app/test/777/"), dst)
        self.assertEqual(read(self.key("my-app", "appcast.xml")), prod)
        self.assertEqual(self.run_script("r2.sh", "prod-assert-unchanged", snap, env=env).returncode, 0)
        ls = self.run_script("r2.sh", "ls", env=env)
        self.assertIn("my-app/test/777/appcast.xml", ls.stdout)

    def test_dry_run_offline_uploads_nothing(self):
        out = os.path.join(self.tmp, "test-feed")
        env = {"SPARKLE_BIN": self.bin, "VERSION": "0.0.0-dryrun", "BUILD_NUMBER": "1", "DRY_RUN": "true",
               "R2_OFFLINE": "1", "R2_TEST_ONLY": "1", "UPDATES_BASE_URL": "https://updates.example.invalid/my-app/test/9",
               "APPCAST_OUT": out}
        p = self.run_script("publish.sh", self.zip("0.0.0-dryrun"), env=env)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertTrue(os.path.isfile(os.path.join(out, "appcast.xml")))
        self.assertFalse([c for c in self.calls() if c.startswith(("aws", "curl"))])

    def test_dry_run_guard(self):
        env = self.r2_env(test_only="1")  # production URL with the test guard on
        p = self.run_script("r2.sh", "ls", env=env)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("R2_TEST_ONLY=1", p.stderr)
        env = self.publish_env("0.0.0-dryrun", "1", DRY_RUN="true")  # dry-run without the guard
        self.assertNotEqual(self.run_script("publish.sh", self.zip("0.0.0-dryrun"), env=env).returncode, 0)
        env = self.publish_env("1.0.0", "1", R2_OFFLINE="1")  # offline is dry-run only
        self.assertNotEqual(self.run_script("publish.sh", self.zip("1.0.0"), env=env).returncode, 0)

    def test_existing_zip_with_other_size_is_not_overwritten(self):
        os.makedirs(self.key("my-app", "releases"))
        with open(self.key("my-app", "releases", "BixkuUtilities-1.0.0.zip"), "wb") as f:
            f.write(b"something else entirely")
        d = os.path.join(self.tmp, "feed")
        os.makedirs(d)
        make_feed(d, [("1.0.0", "1", b"zip", "")])
        p = self.run_script("r2.sh", "push", d, env=self.r2_env())
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("not overwriting", p.stderr)
        self.assertFalse(os.path.exists(self.key("my-app", "appcast.xml")))

    def test_rollback(self):
        for v, b in (("1.0.0", "202601010000"), ("1.1.0", "202602010000")):
            p = self.run_script("publish.sh", self.zip(v), env=self.publish_env(v, b))
            self.assertEqual(p.returncode, 0, p.stderr)
        env = self.publish_env("", "")
        p = self.run_script("rollback.sh", "1.1.0", env=env)  # dry-run by default
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(len(appcast.load_items(self.key("my-app", "appcast.xml"))), 2)
        p = self.run_script("rollback.sh", "1.1.0", env=dict(env, ROLLBACK_DRY_RUN="false"))
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual([i["short"] for i in appcast.load_items(self.key("my-app", "appcast.xml"))], ["1.0.0"])
        self.assertTrue(os.path.isfile(self.key("my-app", "retired", "BixkuUtilities-1.1.0.zip")))
        self.assertFalse(os.path.exists(self.key("my-app", "releases", "BixkuUtilities-1.1.0.zip")))
        # never leaves the feed empty
        p = self.run_script("rollback.sh", "1.0.0", env=dict(env, ROLLBACK_DRY_RUN="false"))
        self.assertNotEqual(p.returncode, 0)


# ------------------------------------------------------------------------------- workflows and repository
def read(*parts):
    with open(os.path.join(*parts), encoding="utf-8") as f:
        return f.read()


class WorkflowTests(unittest.TestCase):
    FILES = ["release-mac.yml", "rollback-mac.yml", "release-tooling.yml"]

    def test_actions_pinned_by_sha(self):
        for name in self.FILES:
            for m in re.finditer(r"uses:\s*(\S+)", read(WORKFLOWS, name)):
                self.assertRegex(m.group(1), r"^[\w.-]+/[\w.-]+@[0-9a-f]{40}$", "%s: %s" % (name, m.group(1)))

    @unittest.skipIf(yaml is None, "PyYAML not installed")
    def test_structure(self):
        wf = yaml.safe_load(read(WORKFLOWS, "release-mac.yml"))
        on = wf.get("on", wf.get(True))
        self.assertEqual(set(on), {"push", "workflow_dispatch"})
        self.assertEqual(on["push"], {"tags": ["v*"]})
        self.assertIs(on["workflow_dispatch"]["inputs"]["dry_run"]["default"], True)
        self.assertEqual(wf["permissions"], {"contents": "read"})
        jobs = wf["jobs"]
        self.assertEqual(list(jobs), ["preflight", "build", "publish"])
        self.assertEqual(jobs["build"]["runs-on"], "macos-15")
        self.assertEqual(jobs["publish"]["runs-on"], "macos-15")
        self.assertEqual(jobs["publish"]["environment"], "release")
        self.assertEqual(jobs["publish"]["concurrency"]["group"], "mac-updates-feed")
        rb = yaml.safe_load(read(WORKFLOWS, "rollback-mac.yml"))
        self.assertEqual(rb["jobs"]["rollback"]["concurrency"]["group"], "mac-updates-feed")
        self.assertEqual(set(rb.get("on", rb.get(True))), {"workflow_dispatch"})

    def test_preflight_knows_every_secret_and_var(self):
        wf = read(WORKFLOWS, "release-mac.yml") + read(WORKFLOWS, "rollback-mac.yml")
        used = set(re.findall(r"secrets\.([A-Z0-9_]+)", wf)) | set(re.findall(r"vars\.([A-Z0-9_]+)", wf))
        pre = read(RELEASE, "preflight.sh")
        for name in used:
            self.assertIn('"%s|' % name, pre, name)
        self.assertEqual(set(re.findall(r"secrets\.([A-Z0-9_]+)", wf)), set(SIGN_SECRETS + PUBLISH_SECRETS))
        self.assertEqual(set(re.findall(r"vars\.([A-Z0-9_]+)", wf)), set(REQUIRED_VARS))

    def test_preflight_gets_only_flags(self):
        text = read(WORKFLOWS, "release-mac.yml")
        block = text[text.index("- name: Required secrets and variables"):text.index("run: bash apps/mac/release/preflight.sh release")]
        for m in re.finditer(r"\$\{\{\s*secrets\.(\w+)([^}]*)\}\}", block):
            self.assertIn("!= ''", m.group(2), m.group(1))

    def test_sparkle_version_matches_package(self):
        pinned = re.search(r"^SPARKLE_VERSION=(\S+)$", read(RELEASE, "sparkle.version"), re.M).group(1)
        pkg = read(MAC, "Package.swift")
        self.assertIn('.package(url: "https://github.com/sparkle-project/Sparkle", exact: "%s")' % pinned, pkg)
        self.assertRegex(read(RELEASE, "sparkle.version"), r"SPARKLE_SHA256=[0-9a-f]{64}")

    def test_updater_is_wired(self):
        src = read(MAC, "Sources", "BixkuUtilities", "Updates", "UpdaterController.swift")
        self.assertIn("SPUStandardUpdaterController", src)
        self.assertIn("Check for Updates…", src)
        sources = ""
        for dp, _, files in os.walk(os.path.join(MAC, "Sources")):
            sources += "".join(read(dp, f) for f in files if f.endswith(".swift") and f != "UpdaterController.swift")
        self.assertIn("CheckForUpdatesMenuItems(", sources)
        self.assertIn("UpdaterController.shared", read(MAC, "Sources", "BixkuUtilities", "BixkuUtilitiesApp.swift"))

    def test_no_personal_data(self):
        """Release files carry no hosts, IPs, user paths or account identifiers."""
        forbidden = [r"/[h]ome/", r"/[U]sers/", r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b",
                     r"[\w.+-]+@(?!users\.noreply\.github\.com)[A-Za-z][\w-]*\.[A-Za-z]{2,}"]
        paths = [os.path.join(WORKFLOWS, f) for f in self.FILES] + [os.path.join(ROOT, "docs", "release.md")]
        for dp, _, files in os.walk(RELEASE):
            if "__pycache__" not in dp:
                paths += [os.path.join(dp, f) for f in files if not f.endswith(".pyc")]
        for p in paths:
            if not os.path.exists(p):
                continue
            text = read(p)
            for pat in forbidden:
                self.assertIsNone(re.search(pat, text), "%s matches %s" % (os.path.relpath(p, ROOT), pat))


@unittest.skipIf(shutil.which("shellcheck") is None, "shellcheck not installed")
class ShellcheckTests(unittest.TestCase):
    def test_scripts(self):
        scripts = sorted(os.path.join(RELEASE, f) for f in os.listdir(RELEASE) if f.endswith(".sh"))
        p = subprocess.run(["shellcheck", "-x", "-P", "SCRIPTDIR", "-s", "bash"] + scripts, capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)


if __name__ == "__main__":
    unittest.main()
