#!/usr/bin/env python3
"""Release notes helpers (stdlib only, Python >= 3.9).

  notes.py changelog --file CHANGELOG.md --version 1.2.3   section of that version (markdown) on stdout
  notes.py html [--title T] [--page]                       markdown (stdin) -> HTML (fragment, or page with --page)

The converter is deliberately minimal: it escapes ALL text before applying formatting and only allows
http(s) links. Notes are embedded in the (signed) appcast, so no arbitrary HTML may slip through.
"""
import argparse
import html
import re
import sys


def changelog_section(text, version):
    """Body of the `## [1.2.3]` / `## 1.2.3` section (optional date) up to the next `## `."""
    head = re.compile(r"^##\s+\[?v?%s\]?(\s|$|\()" % re.escape(version))
    out, inside = [], False
    for ln in text.splitlines():
        if inside and re.match(r"^##\s", ln):
            break
        if inside:
            out.append(ln)
        elif head.match(ln):
            inside = True
    return "\n".join(out).strip()


def _inline(s):
    s = html.escape(s, quote=True)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"\[([^\]]+)\]\((https?://[^\s)]+)\)", r'<a href="\2">\1</a>', s)
    return s


def md_to_html(md):
    out, para, items, kind, code = [], [], [], None, None

    def flush_para():
        if para:
            out.append("<p>%s</p>" % _inline(" ".join(para)))
            para.clear()

    def flush_list():
        nonlocal kind
        if items:
            out.append("<%s>%s</%s>" % (kind, "".join("<li>%s</li>" % _inline(i) for i in items), kind))
            items.clear()
        kind = None

    for raw in md.splitlines():
        if code is not None:
            if raw.strip().startswith("```"):
                out.append("<pre><code>%s</code></pre>" % html.escape("\n".join(code)))
                code = None
            else:
                code.append(raw)
            continue
        ln = raw.rstrip()
        if ln.strip().startswith("```"):
            flush_para()
            flush_list()
            code = []
            continue
        m = re.match(r"^(#{1,6})\s+(.*)$", ln)
        if m:
            flush_para()
            flush_list()
            n = min(len(m.group(1)) + 1, 6)  # h1 -> h2: the update window title is already the h1
            out.append("<h%d>%s</h%d>" % (n, _inline(m.group(2)), n))
            continue
        m = re.match(r"^\s*([-*]|\d+\.)\s+(.*)$", ln)
        if m:
            flush_para()
            k = "ol" if m.group(1)[0].isdigit() else "ul"
            if kind and kind != k:
                flush_list()
            kind = k
            items.append(m.group(2))
            continue
        if not ln.strip():
            flush_para()
            flush_list()
            continue
        flush_list()
        para.append(ln.strip())
    if code is not None:
        out.append("<pre><code>%s</code></pre>" % html.escape("\n".join(code)))
    flush_para()
    flush_list()
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("changelog")
    p.add_argument("--file", required=True)
    p.add_argument("--version", required=True)
    p = sub.add_parser("html")
    p.add_argument("--title", default="Release notes")
    p.add_argument("--page", action="store_true", help="full document instead of a fragment")
    a = ap.parse_args(argv)
    if a.cmd == "changelog":
        with open(a.file, encoding="utf-8") as f:
            sys.stdout.write(changelog_section(f.read(), a.version) + "\n")
        return 0
    body = md_to_html(sys.stdin.read())
    if a.page:
        body = ('<!DOCTYPE html>\n<html lang="en"><head><meta charset="utf-8"><title>%s</title></head>\n'
                '<body>\n<h1>%s</h1>\n%s\n</body></html>' % (html.escape(a.title), html.escape(a.title), body))
    sys.stdout.write(body + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
