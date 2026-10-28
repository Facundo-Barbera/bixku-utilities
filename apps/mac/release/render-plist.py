#!/usr/bin/env python3
"""Renders apps/mac/Resources/Info.plist (a template with $(VAR) placeholders) into the bundle's Info.plist.

Portable (stdlib only, Python >= 3.9): runs and is tested on Linux.

    render-plist.py --template Info.plist --output out/Info.plist \
        --set EXECUTABLE_NAME=BixkuUtilities --set MARKETING_VERSION=1.2.3 --set CURRENT_PROJECT_VERSION=202601010000 \
        [--set BUNDLE_ID=...] [--set MIN_MACOS_VERSION=13.0] [--set UPDATES_BASE_URL=https://...] \
        [--set SPARKLE_ED_PUBLIC_KEY=...] [--set SPARKLE_CHECK_INTERVAL=86400] [--set SPARKLE_AUTO_UPDATE=false] \
        [--icon AppIcon] [--require-sparkle]

Rules:
- Every $(VAR) in a string value is replaced; an unresolved placeholder is an error (never ships "$(...)").
- BUNDLE_ID and MIN_MACOS_VERSION, when given, override CFBundleIdentifier and LSMinimumSystemVersion.
- Sparkle is enabled only when UPDATES_BASE_URL (https) and SPARKLE_ED_PUBLIC_KEY (base64 of 32 bytes) are
  both set. Otherwise every SU* key is removed (updater disabled), unless --require-sparkle, which fails.
- SUScheduledCheckInterval becomes an integer (>= 3600) and SUAutomaticallyUpdate a bool.
"""
import argparse
import base64
import binascii
import plistlib
import re
import sys

PLACEHOLDER = re.compile(r"\$\(([A-Z0-9_]+)\)")
DEFAULTS = {"SPARKLE_CHECK_INTERVAL": "86400", "SPARKLE_AUTO_UPDATE": "false"}
SEMVER = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?$")
HTTPS_URL = re.compile(r"^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~-]+)*$")


class RenderError(Exception):
    pass


def _substitute(value, env, unresolved):
    if isinstance(value, str):
        def repl(m):
            name = m.group(1)
            if env.get(name, "") == "":
                unresolved.add(name)
                return m.group(0)
            return env[name]
        return PLACEHOLDER.sub(repl, value)
    if isinstance(value, dict):
        return {k: _substitute(v, env, unresolved) for k, v in value.items()}
    if isinstance(value, list):
        return [_substitute(v, env, unresolved) for v in value]
    return value


def sparkle_config_problems(env):
    """Reasons why Sparkle cannot be enabled with these values (empty list = usable)."""
    problems = []
    url = env.get("UPDATES_BASE_URL", "")
    key = env.get("SPARKLE_ED_PUBLIC_KEY", "")
    if not url:
        problems.append("UPDATES_BASE_URL is empty")
    elif not HTTPS_URL.match(url):
        problems.append("UPDATES_BASE_URL must be an https:// URL without query, fragment or trailing slash")
    if not key:
        problems.append("SPARKLE_ED_PUBLIC_KEY is empty")
    else:
        try:
            if len(base64.b64decode(key, validate=True)) != 32:
                problems.append("SPARKLE_ED_PUBLIC_KEY must be base64 of 32 bytes")
        except (binascii.Error, ValueError):
            problems.append("SPARKLE_ED_PUBLIC_KEY is not valid base64")
    return problems


def render(template, values, icon=None, require_sparkle=False):
    """Returns (plist dict, sparkle_enabled)."""
    env = dict(DEFAULTS)
    env.update({k: v for k, v in values.items() if v is not None})
    env["UPDATES_BASE_URL"] = env.get("UPDATES_BASE_URL", "").rstrip("/")

    for name in ("EXECUTABLE_NAME", "MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        if not env.get(name):
            raise RenderError("%s is required" % name)
    if not SEMVER.match(env["MARKETING_VERSION"]):
        raise RenderError("MARKETING_VERSION must be semver X.Y.Z[-prerelease]")
    if not re.match(r"^\d{1,15}$", env["CURRENT_PROJECT_VERSION"]):
        raise RenderError("CURRENT_PROJECT_VERSION must be numeric")

    problems = sparkle_config_problems(env)
    sparkle = not problems
    if not sparkle and require_sparkle:
        raise RenderError("Sparkle is required for this build: " + "; ".join(problems))
    if not sparkle:
        template = {k: v for k, v in template.items() if not k.startswith("SU")}

    unresolved = set()
    plist = _substitute(template, env, unresolved)
    if unresolved:
        raise RenderError("unresolved placeholders: " + ", ".join(sorted(unresolved)))

    if env.get("BUNDLE_ID"):
        plist["CFBundleIdentifier"] = env["BUNDLE_ID"]
    if env.get("MIN_MACOS_VERSION"):
        if not re.match(r"^\d+(\.\d+){0,2}$", env["MIN_MACOS_VERSION"]):
            raise RenderError("MIN_MACOS_VERSION must look like 13.0")
        plist["LSMinimumSystemVersion"] = env["MIN_MACOS_VERSION"]
    if icon:
        plist["CFBundleIconFile"] = icon

    if sparkle:
        interval = str(plist.get("SUScheduledCheckInterval", ""))
        if not re.match(r"^\d+$", interval) or int(interval) < 3600:
            raise RenderError("SPARKLE_CHECK_INTERVAL must be an integer >= 3600 (seconds)")
        plist["SUScheduledCheckInterval"] = int(interval)
        auto = str(plist.get("SUAutomaticallyUpdate", "false"))
        if auto not in ("true", "false"):
            raise RenderError("SPARKLE_AUTO_UPDATE must be true or false")
        plist["SUAutomaticallyUpdate"] = auto == "true"
    return plist, sparkle


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--template", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--set", action="append", default=[], metavar="VAR=VALUE")
    ap.add_argument("--icon", default="")
    ap.add_argument("--require-sparkle", action="store_true")
    a = ap.parse_args(argv)

    values = {}
    for item in a.set:
        if "=" not in item:
            ap.error("--set expects VAR=VALUE")
        k, v = item.split("=", 1)
        values[k] = v
    with open(a.template, "rb") as f:
        template = plistlib.load(f)
    try:
        plist, sparkle = render(template, values, icon=a.icon or None, require_sparkle=a.require_sparkle)
    except RenderError as e:
        print("::error::Info.plist: %s" % e, file=sys.stderr)
        return 1
    with open(a.output, "wb") as f:
        plistlib.dump(plist, f, fmt=plistlib.FMT_XML, sort_keys=True)
    print("Info.plist rendered (version %s, build %s, sparkle %s)" % (
        plist["CFBundleShortVersionString"], plist["CFBundleVersion"], "enabled" if sparkle else "disabled"))
    if not sparkle:
        print("::warning::Sparkle keys removed (no UPDATES_BASE_URL/SPARKLE_ED_PUBLIC_KEY): the updater is disabled in this build")
    return 0


if __name__ == "__main__":
    sys.exit(main())
