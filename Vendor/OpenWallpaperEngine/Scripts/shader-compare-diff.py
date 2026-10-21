#!/usr/bin/env python3
"""Diffs two shader comparison runs (ShaderComparisonSuiteTests, Scripts/shader-compare.sh).

    Scripts/shader-compare-diff.py <before run> <after run> [--mean-abs 2.0] [--ssim 0.98] [--noise <run>] [-o diff.json]

Reads each run's shaders.json, and the after run's renders.json (compared with the before run
when it was rendered with OWE_SHADER_COMPARE_BASELINE=<before run>), and prints a JSON summary:
newly failing and newly passing shaders, outputs that changed, and renders past the threshold
(mean absolute difference above --mean-abs, 0-255, or SSIM below --ssim). Exits 1 when a shader
newly fails.
"""
import argparse
import json
import os
import sys


def load(path):
    with open(path) as f:
        return json.load(f)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("before")
    parser.add_argument("after")
    parser.add_argument("--mean-abs", type=float, default=2.0)
    parser.add_argument("--ssim", type=float, default=0.98)
    parser.add_argument("--noise", help="a repeat run of the before build against it: scenes past the "
                        "threshold there differ run to run and are listed apart")
    parser.add_argument("-o", "--output")
    args = parser.parse_args()

    before = load(os.path.join(args.before, "shaders.json"))["items"]
    after = load(os.path.join(args.after, "shaders.json"))["items"]
    newly_failing, newly_passing, changed, missing, added = [], [], [], [], []
    for key, old in sorted(before.items()):
        new = after.get(key)
        if new is None:
            missing.append(key)
        elif old["ok"] and not new["ok"]:
            newly_failing.append({"shader": key, "error": new.get("error")})
        elif not old["ok"] and new["ok"]:
            newly_passing.append({"shader": key, "was": old.get("error")})
        elif old["ok"] and new["ok"] and old.get("hash") != new.get("hash"):
            changed.append(key)
    for key in sorted(set(after) - set(before)):
        added.append({"shader": key, "ok": after[key]["ok"], "error": after[key].get("error")})

    noisy = set()
    if args.noise:
        for name, record in load(os.path.join(args.noise, "renders.json"))["scenes"].items():
            if record.get("meanAbs") is not None and (record["meanAbs"] > args.mean_abs or record["ssim"] < args.ssim):
                noisy.add(name)
    renders = {"compared": 0, "past_threshold": [], "noisy_past_threshold": [], "failed": [], "newly_failed": []}
    renders_path = os.path.join(args.after, "renders.json")
    if os.path.exists(renders_path):
        after_renders = load(renders_path)["scenes"]
        before_path = os.path.join(args.before, "renders.json")
        before_renders = load(before_path)["scenes"] if os.path.exists(before_path) else {}
        for name, record in sorted(after_renders.items()):
            if not record["ok"]:
                renders["failed"].append({"scene": name, "error": record.get("error")})
                if before_renders.get(name, {}).get("ok"):
                    renders["newly_failed"].append(name)
                continue
            if record.get("meanAbs") is None:
                continue
            renders["compared"] += 1
            if record["meanAbs"] > args.mean_abs or record["ssim"] < args.ssim:
                entry = {"scene": name, "meanAbs": round(record["meanAbs"], 3), "ssim": round(record["ssim"], 4)}
                renders["noisy_past_threshold" if name in noisy else "past_threshold"].append(entry)

    def counts(items):
        ok = sum(1 for r in items.values() if r["ok"])
        return {"variants": len(items), "ok": ok, "failed": len(items) - ok}

    summary = {
        "before": counts(before),
        "after": counts(after),
        "thresholds": {"meanAbs": args.mean_abs, "ssim": args.ssim},
        "newly_failing": newly_failing,
        "newly_passing": newly_passing,
        "changed_output": len(changed),
        "changed_output_examples": changed[:40],
        "missing_in_after": missing,
        "added_in_after": added,
        "renders": renders,
    }
    text = json.dumps(summary, indent=2)
    if args.output:
        with open(args.output, "w") as f:
            f.write(text + "\n")
    print(text)
    return 1 if newly_failing else 0


if __name__ == "__main__":
    sys.exit(main())
