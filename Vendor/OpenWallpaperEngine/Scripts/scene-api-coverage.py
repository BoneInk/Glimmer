#!/usr/bin/env python3
"""Report which Wallpaper Engine script APIs the installed wallpapers use, and which of those
the SceneScript runtime does not implement yet.

    ./Scripts/scene-api-coverage.py [library-path]

Scripts live both inside each wallpaper's scene.json and in UserDefaults (per-object overrides
saved by the inspector), so both are scanned.
"""

import collections
import glob
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_LIBRARY = "/Volumes/980Pro/OpenWallpaperStorage"
BUNDLE_ID = "app.openwallpaperengine"
OBJECTS = ("thisScene", "thisLayer", "thisObject", "engine", "input")


def collect_scripts(library):
    """Returns [(wallpaper_id, script_source)]."""
    found = []
    for path in glob.glob(os.path.join(library, "*", "scene.json")):
        wallpaper = os.path.basename(os.path.dirname(path))
        raw = open(path, encoding="utf-8", errors="replace").read()
        for match in re.finditer(r'"script"\s*:\s*"((?:[^"\\]|\\.)*)"', raw):
            try:
                found.append((wallpaper, json.loads('"' + match.group(1) + '"')))
            except ValueError:
                pass
    try:
        defaults = subprocess.run(["/usr/bin/defaults", "read", BUNDLE_ID],
                                  capture_output=True, text=True, timeout=120).stdout
        for match in re.finditer(r'\\"script\\"\s*:\s*\\"((?:[^\\]|\\.)*?)\\"', defaults):
            found.append(("<user override>", match.group(1).replace("\\\\n", "\n")))
    except Exception as error:                                  # noqa: BLE001
        print(f"note: could not read UserDefaults ({error})", file=sys.stderr)
    return found


def required(relative):
    """A source this report reads. A missing one means the runtime moved: stop, don't report from
    a partial picture."""
    path = os.path.join(REPO, relative)
    if not os.path.exists(path):
        sys.exit(f"error: {relative} is missing; update {os.path.relpath(__file__, REPO)} to where it lives now")
    return path


def object_members(block_start, js):
    """Keys of the `{ name: … }` object literal that follows `block_start` in `js`."""
    found = set()
    for match in re.finditer(re.escape(block_start), js):
        depth, index = 0, match.end()
        while index < len(js):
            if js[index] == "{":
                depth += 1
            elif js[index] == "}":
                depth -= 1
                if depth < 0:
                    break
            index += 1
        found |= set(re.findall(r"^\s*(\w+)\s*:\s*\{", js[match.end():index], re.M))
    return found


def implemented():
    """APIs the runtime provides, read from the sources so this can't drift.

    The object model (thisScene, thisLayer, thisObject) is WE's typings, as listed in the fixture
    SceneScriptObjectTypingsTests checks member by member against the runtime. `engine` and
    `input` are what the runtime's JavaScript assigns to those globals."""
    fixture = required("Tests/Fixtures/SceneScript/object-model-members.json")
    typed = json.load(open(fixture, encoding="utf-8"))["interfaces"]
    for name in ("IScene", "IObject", "ILayer"):
        if not typed.get(name):
            sys.exit(f"error: {os.path.relpath(fixture, REPO)} has no {name} members")
    # ILayer extends IObject, IImageLayer, ISoundLayer, …: every layer has the whole union
    # (SceneScriptObjectTypingsTests.layerParts).
    layer_parts = ("IObject", "IImageLayer", "ISoundLayer", "IEffectLayer", "ITextLayer",
                   "IParticleSystem", "IModelLayer", "ICamera", "ILayer")
    layer = set().union(*(typed.get(name, []) for name in layer_parts))
    scene = set(typed["IScene"]) | set(typed["IObject"])

    js_dirs = [required("OpenWallpaperEngine/Resources/SceneScript"),
               required("OpenWallpaperEngine/Scene/Scripting")]
    js = "\n".join(open(path, encoding="utf-8").read()
                   for directory in js_dirs
                   for path in sorted(glob.glob(os.path.join(directory, "**", "*.js"), recursive=True)))
    engine = set(re.findall(r"\bengine\.(\w+)\s*=(?!=)", js)) | object_members("Object.defineProperties(engine, {", js)
    inputs = object_members("global.input = Object.defineProperties({}, {", js)
    for name, found in (("engine", engine), ("input", inputs)):
        if not found:
            sys.exit(f"error: found no `{name}` members in the runtime's JavaScript; update this script's parser")
    # thisObject is whatever the script is bound to: a layer, the scene, an effect, a material…
    anything = set().union(*typed.values())
    return {"thisScene": scene, "thisLayer": layer, "thisObject": anything,
            "engine": engine, "input": inputs}


def main():
    library = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_LIBRARY
    scripts = collect_scripts(library)
    if not scripts:
        print(f"No scripts found under {library}")
        return 1

    supported = implemented()
    usage = collections.defaultdict(collections.Counter)
    users = collections.defaultdict(lambda: collections.defaultdict(set))
    assigned = collections.defaultdict(set)
    for wallpaper, source in scripts:
        for obj in OBJECTS:
            for match in re.finditer(r"\b" + obj + r"\.(\w+)", source):
                usage[obj][match.group(1)] += 1
                users[obj][match.group(1)].add(wallpaper)
            assigned[obj] |= set(re.findall(r"\b" + obj + r"\.(\w+)\s*=(?!=)", source))

    print(f"library:          {library}")
    print(f"scripts analysed: {len(scripts)}\n")

    total_missing = 0
    for obj in OBJECTS:
        if not usage[obj]:
            continue
        impl = supported.get(obj, set())
        # A name a script assigns and the runtime doesn't define is the script's own field
        # (`thisScene.world = …`), not an API.
        own = sorted(n for n in usage[obj] if n not in impl and n in assigned[obj])
        missing = [(n, c) for n, c in usage[obj].most_common() if n not in impl and n not in own]
        total_missing += len(missing)
        used = len(usage[obj]) - len(own)
        print(f"=== {obj}: {used - len(missing)}/{used} supported ===")
        if own:
            print(f"    ({len(own)} script-defined fields not counted: {', '.join(own[:6])}{', …' if len(own) > 6 else ''})")
        for name, count in missing:
            affected = sorted(users[obj][name])
            shown = ", ".join(affected[:4]) + (", …" if len(affected) > 4 else "")
            print(f"    MISSING {count:4}x  {obj}.{name}")
            print(f"              used by: {shown}")
        if not missing:
            print("    (all used APIs supported)")
        print()

    print(f"total unimplemented APIs in use: {total_missing}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
