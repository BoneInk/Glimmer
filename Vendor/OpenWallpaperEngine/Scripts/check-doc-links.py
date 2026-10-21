#!/usr/bin/env python3
"""Checks that relative links and images in the docs resolve.

Scans README.md, CONTRIBUTING.md, SECURITY.md, CHANGELOG.md, docs/, resources/readme/ and site/
(Markdown links and images, HTML href/src). For each relative target it checks that the file
exists and, for a `#fragment` into a Markdown file, that a heading with that anchor exists.
External URLs (http, https, mailto) are not fetched.

Usage: Scripts/check-doc-links.py [repo root]   (exit status 1 when a link is broken)
"""
import os
import re
import sys
import unicodedata

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), ".."))
FILES = ["README.md", "CONTRIBUTING.md", "SECURITY.md", "CHANGELOG.md"]
DIRS = ["docs", "resources/readme", "site"]

MD_LINK = re.compile(r"!?\[(?:[^\[\]]|\[[^\]]*\])*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
HTML_LINK = re.compile(r"""(?:href|src)\s*=\s*["']([^"']+)["']""")
CODE_FENCE = re.compile(r"^(```|~~~)")


def slug(heading):
    """GitHub's heading anchor: lower case, punctuation dropped, spaces to hyphens."""
    text = re.sub(r"<[^>]+>", "", heading.strip()).lower()
    text = re.sub(r"[`*_~]", "", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    out = []
    for ch in text:
        cat = unicodedata.category(ch)
        if ch in " -":
            out.append("-" if ch == " " else ch)
        elif ch == "_" or cat[0] in "LNM":
            out.append(ch)
    return "".join(out)


_anchor_cache = {}


def anchors(path):
    if path not in _anchor_cache:
        found, counts, fenced = set(), {}, False
        with open(path, encoding="utf-8") as f:
            for line in f:
                if CODE_FENCE.match(line.strip()):
                    fenced = not fenced
                    continue
                m = None if fenced else re.match(r"^#{1,6}\s+(.*?)\s*#*\s*$", line)
                if m:
                    base = slug(m.group(1))
                    n = counts.get(base, 0)
                    counts[base] = n + 1
                    found.add(base if n == 0 else f"{base}-{n}")
                for a in re.findall(r"""<a\s+(?:name|id)=["']([^"']+)["']""", line):
                    found.add(a)
        _anchor_cache[path] = found
    return _anchor_cache[path]


def targets(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if path.endswith(".md"):
        text = re.sub(r"^(```|~~~).*?^\1", "", text, flags=re.S | re.M)
        text = re.sub(r"`[^`\n]*`", "", text)
        for m in MD_LINK.finditer(text):
            yield m.group(1)
        for m in HTML_LINK.finditer(text):
            yield m.group(1)
    else:
        text = re.sub(r"<script\b.*?</script>", "", text, flags=re.S)
        for m in HTML_LINK.finditer(text):
            yield m.group(1)


def sources():
    for name in FILES:
        p = os.path.join(ROOT, name)
        if os.path.isfile(p):
            yield p
    for d in DIRS:
        for dp, _, fns in os.walk(os.path.join(ROOT, d)):
            for fn in sorted(fns):
                if fn.endswith((".md", ".html")):
                    yield os.path.join(dp, fn)


def main():
    broken = checked = 0
    for src in sources():
        for target in targets(src):
            if re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I) or target.startswith("//"):
                continue
            checked += 1
            path, _, frag = target.partition("#")
            path = path.split("?")[0]
            resolved = os.path.normpath(os.path.join(os.path.dirname(src), path)) if path else src
            rel = os.path.relpath(src, ROOT)
            if not os.path.exists(resolved):
                print(f"{rel}: missing {target}")
                broken += 1
            elif frag and resolved.endswith(".md") and frag.lower() not in anchors(resolved):
                print(f"{rel}: no heading #{frag} in {os.path.relpath(resolved, ROOT)}")
                broken += 1
    print(f"{checked} relative links checked, {broken} broken")
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
