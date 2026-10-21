#!/usr/bin/env python3
"""Lists every test's duration from one or more .xcresult bundles, slowest first, with where the
time went when the run recorded phases (OWE_TEST_PHASES, see TestPhaseTimer.swift).

  ci-test-durations.py [--text] [--top N] [--csv OUT.csv] [--phases DIR] RESULT.xcresult...

Prints the N slowest tests (25 by default) as Markdown (for $GITHUB_STEP_SUMMARY), or as plain
text with --text, each with its dominant phase and a short breakdown:

  SceneLayerAnalysisTests/testCleanFrames  111.0 s  shader translate 62.0 s, render 30.0 s (120 frames), compare 12.0 s

--csv writes every test: its duration, result, bundle, dominant phase and each phase's seconds.
Phase times are each phase's own time summed over threads, so work on several queues can add up
to more than the test's duration. It reads `xcrun xcresulttool get test-results tests` (Xcode 16
and newer). Bundles that don't exist are skipped. Exits 0.
"""

import argparse
import csv
import glob
import json
import os
import re
import subprocess

PHASES = ["scene load", "shader translate", "pipeline", "texture", "particles/models",
          "render", "GPU wait", "scripts", "readback", "compare"]
DURATION_PART_RE = re.compile(r"([\d.,]+)\s*(ms|h|m|s)")


def parse_duration(node):
    value = node.get("durationInSeconds")
    if isinstance(value, (int, float)):
        return float(value)
    text = node.get("duration") or ""
    total = 0.0
    for number, unit in DURATION_PART_RE.findall(text):
        n = float(number.replace(",", "."))
        total += {"ms": n / 1000, "s": n, "m": n * 60, "h": n * 3600}[unit]
    return total


def key_of(identifier):
    """`Class/test()` and `Class/test` name the same test."""
    return identifier[:-2] if identifier.endswith("()") else identifier


def tests_in(bundle):
    out = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle,
                          "--format", "json"], capture_output=True, text=True)
    if out.returncode != 0:
        return None
    found = []

    def walk(n, suite):
        kind = n.get("nodeType")
        if kind == "Test Suite":
            suite = n.get("name", suite)
        if kind == "Test Case":
            ident = key_of(n.get("nodeIdentifier") or f"{suite}/{n.get('name', '?')}")
            found.append((ident, n.get("result", "?"), parse_duration(n)))
            return
        for c in n.get("children", []):
            walk(c, suite)

    for n in json.loads(out.stdout).get("testNodes", []):
        walk(n, "")
    return found


def load_phases(folder):
    """{test: {phase: {seconds, calls, frames?}}}; a retried test keeps its last run."""
    phases = {}
    for path in sorted(glob.glob(os.path.join(folder, "*.jsonl"))):
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                phases[key_of(entry.get("test", ""))] = entry.get("phases") or {}
    return phases


def fmt(seconds):
    return f"{seconds:.1f} s" if seconds >= 0.95 else f"{seconds * 1000:.0f} ms"


def breakdown(phases, limit=3):
    """(dominant phase, 'shader translate 62.0 s, render 30.0 s (120 frames), …')."""
    ranked = sorted(((p, v) for p, v in phases.items() if v.get("seconds", 0) > 0),
                    key=lambda item: -item[1]["seconds"])
    if not ranked:
        return "", ""
    parts = []
    for name, v in ranked[:limit]:
        frames = int(v.get("frames", 0))
        parts.append(f"{name} {fmt(v['seconds'])}" + (f" ({frames} frames)" if frames else ""))
    return ranked[0][0], ", ".join(parts)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--text", action="store_true")
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--csv")
    ap.add_argument("--phases")
    ap.add_argument("bundles", nargs="*")
    args = ap.parse_args()

    phases = load_phases(args.phases) if args.phases and os.path.isdir(args.phases) else {}
    rows = []
    for bundle in args.bundles:
        if not os.path.isdir(bundle):
            continue
        tests = tests_in(bundle)
        if tests is None:
            print(f"{os.path.basename(bundle)}: could not read the result bundle")
            continue
        for ident, result, seconds in tests:
            rows.append((ident, result, seconds, os.path.basename(bundle)))
    rows.sort(key=lambda r: -r[2])

    if args.csv:
        extra = sorted({p for v in phases.values() for p in v} - set(PHASES))
        names = PHASES + extra
        os.makedirs(os.path.dirname(os.path.abspath(args.csv)), exist_ok=True)
        with open(args.csv, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["test", "result", "seconds", "bundle", "dominant_phase"]
                       + [f"{p}_s" for p in names] + ["render_frames"])
            for ident, result, seconds, bundle in rows:
                p = phases.get(ident, {})
                dominant, _ = breakdown(p)
                w.writerow([ident, result, f"{seconds:.3f}", bundle, dominant]
                           + [f"{p[n]['seconds']:.3f}" if n in p else "" for n in names]
                           + [int(p.get("render", {}).get("frames", 0)) or ""])

    if not rows:
        return
    total = sum(r[2] for r in rows)
    top = rows[:args.top]
    out = []
    if args.text:
        out.append(f"Slowest {len(top)} of {len(rows)} tests ({fmt(total)} in all):")
        width = max(len(r[0]) for r in top)
        for ident, result, seconds, _ in top:
            _, parts = breakdown(phases.get(ident, {}))
            mark = "" if result == "Passed" else f" [{result}]"
            out.append(f"  {ident.ljust(width)}  {fmt(seconds):>9}{mark}" + (f"  {parts}" if parts else ""))
    else:
        out.append(f"### Slowest {len(top)} of {len(rows)} tests ({fmt(total)} in all)")
        out.append("")
        out.append("| Test | Time | Result | Where the time went |")
        out.append("|---|---:|---|---|")
        for ident, result, seconds, _ in top:
            _, parts = breakdown(phases.get(ident, {}))
            out.append(f"| `{ident}` | {fmt(seconds)} | {result} | {parts or '–'} |")
    out.append("")
    print("\n".join(out))


if __name__ == "__main__":
    main()
