#!/usr/bin/env python3
"""Lists the failing tests of one or more .xcresult bundles, with each assertion message and its
file:line, and the tests that failed once and passed on the retry.

  ci-test-summary.py [--text] [--env] RESULT.xcresult...

Markdown by default (for $GITHUB_STEP_SUMMARY); --text for a terminal. --env adds the macOS and
Xcode versions. It reads `xcrun xcresulttool get test-results tests` (Xcode 16 and newer) and
falls back to `xcresulttool get --legacy`. Bundles that don't exist are skipped, so it can run
after a step that failed before any test ran. Exits 0; the test step's own status is the verdict.
"""

import json
import os
import re
import subprocess
import sys
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAX_MESSAGES = 10
MAX_MESSAGE_LENGTH = 400
NAME_LOCATION_RE =re.compile(r"^(?P<file>[^:\s][^:]*\.swift):(?P<line>\d+): (?P<message>.*)$", re.S)


def run(args):
    out = subprocess.run(args, capture_output=True, text=True)
    return out.stdout if out.returncode == 0 else None


def relpath(path):
    if not path:
        return ""
    for base in (os.environ.get("GITHUB_WORKSPACE"), ROOT):
        if base and path.startswith(base.rstrip("/") + "/"):
            return path[len(base.rstrip("/")) + 1:]
    return path


def location(file, line):
    file = relpath(file)
    return f"{file}:{line}" if file and line else file


def messages_of(node):
    """Every failure message below a node, as (location, message); retries repeat a message,
    so each one is listed once."""
    found = []

    def walk(n):
        if n.get("nodeType") == "Failure Message":
            text, loc = n.get("name", ""), ""
            src = n.get("sourceLocation") or {}
            if src.get("filePath"):
                loc = location(src["filePath"], src.get("lineNumber"))
            else:
                m = NAME_LOCATION_RE.match(text)
                if m:
                    loc, text = location(m["file"], m["line"]), m["message"]
            if (loc, text) not in found:
                found.append((loc, text))
        for c in n.get("children", []):
            walk(c)

    walk(node)
    return found


def from_test_results(bundle):
    raw = run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle, "--format", "json"])
    if raw is None:
        return None
    failed, flaky = [], []

    def walk(n, suite):
        kind = n.get("nodeType")
        if kind == "Test Suite":
            suite = n.get("name", suite)
        if kind == "Test Case":
            ident = n.get("nodeIdentifier") or f"{suite}/{n.get('name', '?')}"
            msgs = messages_of(n)
            if n.get("result") == "Failed":
                failed.append((ident, msgs))
            elif msgs and n.get("result") == "Passed":
                flaky.append((ident, msgs))
            return
        for c in n.get("children", []):
            walk(c, suite)

    for n in json.loads(raw).get("testNodes", []):
        walk(n, "")
    return failed, flaky


def _value(obj, *keys):
    for k in keys:
        if not isinstance(obj, dict):
            return None
        obj = obj.get(k)
    if isinstance(obj, dict) and "_value" in obj:
        return obj["_value"]
    return obj


def from_legacy(bundle):
    raw = run(["xcrun", "xcresulttool", "get", "--legacy", "--format", "json", "--path", bundle])
    if raw is None:
        raw = run(["xcrun", "xcresulttool", "get", "--format", "json", "--path", bundle])
    if raw is None:
        return None
    by_test = {}
    for action in (_value(json.loads(raw), "actions", "_values") or []):
        summaries = _value(action, "actionResult", "issues", "testFailureSummaries", "_values") or []
        for s in summaries:
            name = _value(s, "testCaseName") or "?"
            url = _value(s, "documentLocationInCreatingWorkspace", "url") or ""
            loc = ""
            if url:
                parsed = urllib.parse.urlparse(url)
                frag = urllib.parse.parse_qs(parsed.fragment)
                line = frag.get("StartingLineNumber", [None])[0]
                # The legacy format counts lines from 0.
                loc = location(urllib.parse.unquote(parsed.path), int(line) + 1 if line else None)
            entry = (loc, _value(s, "message") or "")
            msgs = by_test.setdefault(name, [])
            if entry not in msgs:
                msgs.append(entry)
    # The legacy summary can't tell a retried pass from a failure; list them all as failures.
    return sorted(by_test.items()), []


def one_line(msg):
    msg = " ".join(msg.split())
    return msg if len(msg) <= MAX_MESSAGE_LENGTH else msg[:MAX_MESSAGE_LENGTH] + " …"


def env_line(text):
    macos = (run(["sw_vers", "-productVersion"]) or "?").strip()
    build = (run(["sw_vers", "-buildVersion"]) or "?").strip()
    xcode = " ".join((run(["xcodebuild", "-version"]) or "?").split())
    return f"macOS {macos} ({build}), {xcode}" if text else f"Runner: macOS {macos} ({build}), {xcode}"


def main():
    args = sys.argv[1:]
    text = "--text" in args
    env = "--env" in args
    bundles = [a for a in args if not a.startswith("--")]
    out = []
    if env:
        out.append(env_line(text))
        out.append("")
    for bundle in bundles:
        if not os.path.isdir(bundle):
            continue
        result = from_test_results(bundle) or from_legacy(bundle)
        name = os.path.basename(bundle)
        if result is None:
            out.append(f"{name}: could not read the result bundle")
            continue
        failed, flaky = result
        for title, items in (("failed", failed), ("failed once, passed on the retry", flaky)):
            if not items:
                continue
            if text:
                out.append(f"{name}: {len(items)} {title}")
            else:
                out.append(f"### {name}: {len(items)} {title}")
                out.append("")
            for ident, msgs in items:
                # A sweep test can fail with thousands of messages; the bundle keeps them all.
                more = len(msgs) - MAX_MESSAGES
                msgs = [(loc, one_line(msg)) for loc, msg in msgs[:MAX_MESSAGES]]
                msgs += [("", f"… and {more} more")] if more > 0 else []
                msgs = msgs or [("", "(no message)")]
                if text:
                    out.append(f"  {ident}")
                    out += [f"      {loc + ': ' if loc else ''}{msg}" for loc, msg in msgs]
                else:
                    out.append(f"- **{ident}**")
                    out += [f"  - {'`' + loc + '` ' if loc else ''}{msg.replace('`', "'")}" for loc, msg in msgs]
            out.append("")
    print("\n".join(out))


if __name__ == "__main__":
    main()
