#!/usr/bin/env python3
"""Plans which test classes a CI run or shard runs.

  ci-test-plan.py classes                         every test class, one per line
  ci-test-plan.py serial                          the classes that run serially (.github/test-map.yml)
  ci-test-plan.py affected --files CHANGED        "all", "none", or the classes the changed files select
  ci-test-plan.py shard --index I --count N [--select SELECTION]
                                                  the classes of shard I (1-based) of N
  ci-test-plan.py check --enumeration JSON        fails if the built bundle has a class this misses

SELECTION is "all" (the default), "none", or class names separated by spaces or newlines.
Test classes are read from OpenWallpaperEngineTests/**/*.swift: every class that inherits from
XCTestCase, directly or through another test class, and declares at least one test. Shards are
balanced by test count, a serial class weighing three times its count (it gets no parallel
workers). The script uses only the standard library, so it runs on any runner.
"""

import argparse
import fnmatch
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEST_DIR = os.path.join(ROOT, "OpenWallpaperEngineTests")
MAP_FILE = os.path.join(ROOT, ".github", "test-map.yml")
SERIAL_WEIGHT = 3

CLASS_RE = re.compile(r"\bclass\s+(\w+)\s*:\s*([\w.]+)")
EXTENSION_RE = re.compile(r"\bextension\s+(\w+)\b")
TEST_RE = re.compile(r"\bfunc\s+(test\w*)\s*\(")


# --- test-map.yml ---------------------------------------------------------------------------

def _scalar(text):
    text = text.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        return text[1:-1]
    return text


def _flow_list(text):
    inner = text.strip()[1:-1]
    return [_scalar(item) for item in inner.split(",") if item.strip()]


def _strip_comment(line):
    quote = None
    for i, ch in enumerate(line):
        if ch in "\"'":
            quote = None if quote == ch else (quote or ch)
        elif ch == "#" and quote is None and (i == 0 or line[i - 1].isspace()):
            return line[:i]
    return line


def _parse_map_yaml(text):
    """The subset test-map.yml uses: top-level keys holding a list, or a map whose values are
    lists (block `- item` lines or a flow `[a, b]`)."""
    data, top, sub = {}, None, None
    for raw in text.splitlines():
        line = _strip_comment(raw).rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        body = line.strip()
        if indent == 0:
            top, sub = _scalar(body.rstrip(":")), None
            data[top] = None
        elif body.startswith("- "):
            item = _scalar(body[2:])
            if sub is not None and indent > 2:
                data[top][sub].append(item)
            else:
                data[top] = (data[top] or []) + [item]
        else:
            key, _, value = body.partition(":")
            key, value = _scalar(key), value.strip()
            if data[top] is None:
                data[top] = {}
            data[top][key] = _flow_list(value) if value.startswith("[") else []
            sub = key
    return data


def load_map():
    with open(MAP_FILE, encoding="utf-8") as f:
        text = f.read()
    try:
        import yaml  # optional; the fallback parser reads the same file
        data = yaml.safe_load(text)
    except ImportError:
        data = _parse_map_yaml(text)
    for key in ("serial", "always", "all", "ignore"):
        data[key] = list(data.get(key) or [])
    for key in ("groups", "map"):
        data[key] = dict(data.get(key) or {})
    return data


# --- test classes ---------------------------------------------------------------------------

def scan_tests():
    """Returns ({class: test count}, {relative file path: [classes]})."""
    decls, files = [], {}
    for dirpath, _, names in os.walk(TEST_DIR):
        for name in sorted(names):
            if name.endswith(".swift"):
                path = os.path.join(dirpath, name)
                with open(path, encoding="utf-8", errors="replace") as f:
                    files[os.path.relpath(path, ROOT)] = f.read()
    supers = {}
    for text in files.values():
        for m in CLASS_RE.finditer(text):
            supers[m.group(1)] = m.group(2).split(".")[-1]
    test_classes = set()
    changed = True
    while changed:
        changed = False
        for cls, sup in supers.items():
            if cls not in test_classes and (sup == "XCTestCase" or sup in test_classes):
                test_classes.add(cls)
                changed = True
    counts = {cls: 0 for cls in test_classes}
    by_file = {}
    for rel, text in files.items():
        marks = [(m.start(), m.group(1)) for m in CLASS_RE.finditer(text) if m.group(1) in test_classes]
        marks += [(m.start(), m.group(1)) for m in EXTENSION_RE.finditer(text) if m.group(1) in test_classes]
        marks.sort()
        if marks:
            by_file[rel] = sorted({cls for _, cls in marks})
        for m in TEST_RE.finditer(text):
            owner = None
            for pos, cls in marks:
                if pos > m.start():
                    break
                owner = cls
            if owner:
                counts[owner] += 1
    # A class without tests of its own (a shared base) runs through its subclasses.
    counts = {cls: n for cls, n in counts.items() if n > 0}
    by_file = {f: [c for c in cs if c in counts] for f, cs in by_file.items()}
    return counts, by_file


def glob_match(path, pattern):
    regex = ""
    i = 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            regex += "(?:.*/)?"
            i += 3
        elif pattern.startswith("**", i):
            regex += ".*"
            i += 2
        elif pattern[i] == "*":
            regex += "[^/]*"
            i += 1
        elif pattern[i] == "?":
            regex += "[^/]"
            i += 1
        else:
            regex += re.escape(pattern[i])
            i += 1
    return re.fullmatch(regex, path) is not None


def expand(patterns, groups):
    out = []
    for p in patterns:
        if p.startswith("@"):
            if p[1:] not in groups:
                sys.exit(f"test-map.yml: unknown group {p}")
            out += expand(groups[p[1:]], groups)
        else:
            out.append(p)
    return out


def affected(changed, counts, by_file, tmap):
    """Returns ("all" | "none" | "some", classes, reasons)."""
    selected, reasons = set(), []
    for path in changed:
        if any(glob_match(path, g) for g in tmap["all"]):
            return "all", [], [f"{path}: runs everything"]
        if any(glob_match(path, g) for g in tmap["ignore"]):
            continue
        if path in by_file or (path.startswith("OpenWallpaperEngineTests/") and path.endswith(".swift")):
            # A test file: its own classes (none when it was deleted).
            selected.update(by_file.get(path, []))
            continue
        mapped = [ps for g, ps in tmap["map"].items() if glob_match(path, g)]
        if not mapped:
            return "all", [], [f"{path}: not in .github/test-map.yml, runs everything"]
        for ps in mapped:
            for p in expand(ps, tmap["groups"]):
                selected.update(c for c in counts if fnmatch.fnmatchcase(c, p))
    if not selected:
        return "none", [], reasons
    for p in tmap["always"]:
        selected.update(c for c in counts if fnmatch.fnmatchcase(c, p))
    return "some", sorted(selected), reasons


def shard(classes, counts, serial, index, count):
    bins = [[0, i, []] for i in range(count)]
    weight = lambda c: counts.get(c, 1) * (SERIAL_WEIGHT if c in serial else 1)
    for cls in sorted(classes, key=lambda c: (-weight(c), c)):
        target = min(bins, key=lambda b: (b[0], b[1]))
        target[0] += weight(cls)
        target[2].append(cls)
    return sorted(bins[index - 1][2])


def parse_selection(text, counts):
    text = (text or "all").strip()
    if text == "all":
        return sorted(counts)
    if text == "none":
        return []
    names = text.split()
    unknown = [n for n in names if n not in counts]
    if unknown:
        sys.exit("unknown test classes: " + " ".join(unknown))
    return sorted(set(names))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("classes")
    sub.add_parser("serial")
    a = sub.add_parser("affected")
    a.add_argument("--files", required=True, help="a file listing the changed paths, one per line")
    c = sub.add_parser("check")
    c.add_argument("--enumeration", required=True,
                   help="the JSON of xcodebuild test-without-building -enumerate-tests -test-enumeration-style flat")
    s = sub.add_parser("shard")
    s.add_argument("--index", type=int, required=True)
    s.add_argument("--count", type=int, required=True)
    s.add_argument("--select", default="all")
    args = ap.parse_args()

    tmap = load_map()
    if args.cmd == "serial":
        print("\n".join(tmap["serial"]))
        return
    counts, by_file = scan_tests()
    if args.cmd == "classes":
        print("\n".join(sorted(counts)))
    elif args.cmd == "affected":
        with open(args.files, encoding="utf-8") as f:
            changed = [line.strip() for line in f if line.strip()]
        mode, classes, reasons = affected(changed, counts, by_file, tmap)
        for r in reasons:
            print(r, file=sys.stderr)
        print(mode if mode != "some" else " ".join(classes))
    elif args.cmd == "check":
        # -only-testing runs only the classes this script finds, so a class it misses would
        # silently never run. Compare with what the built test bundle enumerates.
        import json
        with open(args.enumeration, encoding="utf-8") as f:
            data = json.load(f)
        built = {t["identifier"].split("/")[1]
                 for v in data.get("values", []) for t in v.get("enabledTests", [])
                 if t["identifier"].count("/") >= 2}
        missing = sorted(built - set(counts))
        if missing:
            sys.exit("test classes the shards would not run: " + " ".join(missing)
                     + "\nScripts/ci-test-plan.py doesn't recognise how they are declared.")
        print(f"all {len(built)} test classes are sharded")
    elif args.cmd == "shard":
        if not 1 <= args.index <= args.count:
            sys.exit("--index must be within 1...--count")
        classes = parse_selection(args.select, counts)
        print("\n".join(shard(classes, counts, set(tmap["serial"]), args.index, args.count)))


if __name__ == "__main__":
    main()
