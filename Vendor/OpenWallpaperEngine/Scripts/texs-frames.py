#!/usr/bin/env python3
"""Every animated `.tex` of the library, read with a reader independent of the app's, as the
fixture of TEXSpriteFramesTests.

    ./Scripts/texs-frames.py [--items ID,...] [--out FILE]   # default Tests/Fixtures/Library/texs-frames.json

A texture is animated when it has a `TEXS000n` block (docs/timeline-plan.md §1.2); the last one in
the file is read, as `TEXSpriteFrames.frames` reads it. Each entry has the root ("storage" or
"workshop"), the item, the file (item-relative; `x.pkg::entry` inside a package), the block's
version, its frame count and frame times (float32, 0 s frames included), the duration they sum to
in float32, and the SHA-256 of the texture's bytes, which the test uses to tell a texture that
changed since the fixture from a parser regression. `--items` keeps only those items; `--out -`
writes to stdout. The roots are OpenWallpaperStorage (`OWE_LIBRARY`) and the Steam workshop folder
(`OWE_WORKSHOP`). Plain Python 3, no packages.
"""

import argparse
import hashlib
import json
import os
import struct
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(REPO, "Tests", "Fixtures", "Library", "texs-frames.json")
MAXIMUM_COUNT = 100000


def roots():
    return [
        ("storage", os.environ.get("OWE_LIBRARY") or "/Volumes/980Pro/OpenWallpaperStorage"),
        ("workshop", os.environ.get("OWE_WORKSHOP")
         or "/Volumes/980Pro/Crossover/bottles/Steam Bottle/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960"),
    ]


def f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


def read_pkg(path):
    data = open(path, "rb").read()
    offset = 4 + struct.unpack_from("<I", data, 0)[0]
    count = struct.unpack_from("<I", data, offset)[0]
    offset += 4
    entries = []
    for _ in range(count):
        size = struct.unpack_from("<I", data, offset)[0]
        offset += 4
        name = data[offset:offset + size].decode("utf-8", "replace")
        offset += size
        start, length = struct.unpack_from("<II", data, offset)
        offset += 8
        entries.append((name, start, length))
    return [(name, data[offset + start:offset + start + length]) for name, start, length in entries]


def texs(blob):
    """(version, frame times) of the last TEXS block, or None."""
    index = len(blob)
    while True:
        index = blob.rfind(b"TEXS000", 0, index)
        if index < 0:
            return None
        if index + 9 <= len(blob) and blob[index + 8] == 0 and blob[index + 7:index + 8] in (b"1", b"2", b"3"):
            break
    version = blob[index:index + 8].decode("ascii")
    offset = index + 9
    if offset + 4 > len(blob):
        return None
    count = struct.unpack_from("<I", blob, offset)[0]
    offset += 4
    if count > MAXIMUM_COUNT:
        return None
    if version == "TEXS0003":
        offset += 8
    if offset + 32 * count > len(blob):
        return None
    return version, [struct.unpack_from("<f", blob, offset + 4 + 32 * k)[0] for k in range(count)]


def entry(root, item, file, blob):
    parsed = texs(blob)
    if parsed is None:
        return None
    version, times = parsed
    duration = 0.0
    for time in times:
        duration = f32(duration + time)
    return dict(root=root, item=item, file=file, version=version, frameCount=len(times), frameTimes=times,
                duration=duration, sha256=hashlib.sha256(blob).hexdigest())


def textures(items=None):
    found = []
    for root, path in roots():
        if not os.path.isdir(path):
            continue
        for item in sorted(os.listdir(path)):
            base = os.path.join(path, item)
            if not os.path.isdir(base) or (items is not None and item not in items):
                continue
            files = sorted(os.path.relpath(os.path.join(d, f), base) for d, _, names in os.walk(base) for f in names)
            for rel in files:
                if rel.endswith(".pkg"):
                    try:
                        entries = read_pkg(os.path.join(base, rel))
                    except (OSError, struct.error) as error:
                        print("error: %s/%s: %s" % (item, rel, error), file=sys.stderr)
                        continue
                    for name, blob in sorted(entries, key=lambda e: e[0]):
                        if name.endswith(".tex"):
                            found.append(entry(root, item, rel + "::" + name, blob))
                elif rel.endswith(".tex"):
                    with open(os.path.join(base, rel), "rb") as handle:
                        found.append(entry(root, item, rel, handle.read()))
    found = [texture for texture in found if texture is not None]
    return sorted(found, key=lambda t: (t["item"], t["root"], t["file"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--items", help="comma-separated item ids to keep")
    parser.add_argument("--out", default=DEFAULT_OUT)
    args = parser.parse_args()
    items = set(filter(None, args.items.split(","))) if args.items else None
    lines = [json.dumps(texture, ensure_ascii=False) for texture in textures(items)]
    text = "[\n" + ",\n".join(lines) + "\n]\n"
    if args.out == "-":
        sys.stdout.write(text)
    else:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text)
        print("wrote %s (%d textures)" % (os.path.relpath(args.out, REPO), len(lines)))


if __name__ == "__main__":
    main()
