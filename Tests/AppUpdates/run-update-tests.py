#!/usr/bin/env python3
"""Exercise the real Sparkle installer using only temporary, signed test apps."""
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import threading
import time
import uuid
import xml.etree.ElementTree as ET

ROOT, WORK, BIN = map(Path, sys.argv[1:4])
WEB = WORK / "web"
WEB.mkdir()
KEY = WORK / "test.ed25519.key"
IDENTITY = os.environ["GW_SIGNING_IDENTITY"]
requests = []
test_ids = []
results = []


def run(*args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, text=True, capture_output=True, **kwargs)


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        requests.append((time.time(), self.path))
        super().do_GET()

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(WEB)))
threading.Thread(target=server.serve_forever, daemon=True).start()
base_url = f"http://127.0.0.1:{server.server_port}"
public = run("xcrun", "swift", ROOT / "scripts/update-signing.swift", "create", KEY).stdout.strip()
BASE = WORK / "base/UpdateProbe.app"
(BASE / "Contents/MacOS").mkdir(parents=True)
(BASE / "Contents/Resources").mkdir()
shutil.copy2(WORK / "UpdateProbe", BASE / "Contents/MacOS/UpdateProbe")
run("bash", ROOT / "scripts/embed-app-updater.sh", BASE)


def log_entries(path):
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def make_app(path, info, build):
    shutil.copytree(BASE, path, symlinks=True)
    info = dict(info, CFBundleVersion=str(build), CFBundleShortVersionString=f"0.0.{build}")
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    run("codesign", "--force", "--timestamp=none", "--sign", IDENTITY, path)
    run("codesign", "--verify", "--deep", "--strict", path)


def write_feed(path, name, signature, length, version="2"):
    s = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    ET.register_namespace("sparkle", s[1:-1])
    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Glimmer isolated update test"
    if version == "empty":
        ET.ElementTree(rss).write(path, encoding="utf-8", xml_declaration=True)
        run(BIN / "sign_update", "--ed-key-file", KEY, path)
        return
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "Glimmer Update Test 0.0.2"
    ET.SubElement(item, s + "version").text = version
    ET.SubElement(item, s + "shortVersionString").text = "0.0.2"
    ET.SubElement(item, s + "minimumSystemVersion").text = "26.0.0"
    ET.SubElement(item, "description").text = "Updates inside the app after confirmation."
    ET.SubElement(item, "enclosure", {
        "url": f"{base_url}/{name}/update.zip",
        s + "edSignature": signature, "length": str(length), "type": "application/octet-stream",
    })
    ET.ElementTree(rss).write(path, encoding="utf-8", xml_declaration=True)
    run(BIN / "sign_update", "--ed-key-file", KEY, path)
    run(BIN / "sign_update", "--ed-key-file", KEY, "--verify", path)


def wait_for(proc, log, expected, seconds=65):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        entries = log_entries(log)
        phases = {entry["phase"] for entry in entries}
        if expected in phases:
            return entries
        if "timeout" in phases:
            raise AssertionError(f"probe timed out: {entries}")
        if proc.poll() is not None and expected != "relaunched":
            raise AssertionError(f"probe exited before {expected}: {entries}")
        time.sleep(0.1)
    raise AssertionError(f"did not reach {expected}: {log_entries(log)}")


def run_case(name, native=False):
    case = WORK / name
    case.mkdir()
    served = WEB / name
    served.mkdir()
    log = case / "events.jsonl"
    bundle_id = f"com.boneinkzhong.glimmer.update-test.{uuid.uuid4().hex}"
    test_ids.append(bundle_id)
    info = {
        "CFBundleName": "Glimmer Update Test", "CFBundleDisplayName": "Glimmer 更新验证",
        "CFBundleIdentifier": bundle_id, "CFBundleExecutable": "UpdateProbe",
        "CFBundlePackageType": "APPL", "NSPrincipalClass": "NSApplication",
        "LSMinimumSystemVersion": "26.0", "NSHighResolutionCapable": True,
        "CFBundleLocalizations": ["zh_CN", "en"], "CFBundleDevelopmentRegion": "zh_CN",
        "SUFeedURL": f"{base_url}/{name}/appcast.xml", "SUPublicEDKey": public,
        "SUEnableAutomaticChecks": True, "SUAutomaticallyUpdate": False,
        "SUAllowsAutomaticUpdates": False, "SUVerifyUpdateBeforeExtraction": True,
        "SURequireSignedFeed": True, "SUEnableSystemProfiling": False,
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
        "GWUpdateProbeLog": str(log), "GWUpdateProbeMode": "native" if native else name,
    }
    installed = case / "installed/UpdateProbe.app"
    update = case / "new/UpdateProbe.app"
    make_app(installed, info, "1")
    make_app(update, info, "2")
    user_data = case / "user-data.json"
    user_data.write_text('{"wallpapers":["preserved"],"settings":{"reminders":true}}')
    original_data = hashlib.sha256(user_data.read_bytes()).hexdigest()
    archive = served / "update.zip"
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", update, archive)
    signature = run(BIN / "sign_update", "--ed-key-file", KEY, "-p", archive).stdout.strip()
    if name == "bad-archive":
        with archive.open("ab") as file:
            file.write(b"tampered after signing")
    feed = served / "appcast.xml"
    version = "empty" if name == "empty-feed" else "1" if name == "no-update" else "2"
    write_feed(feed, name, signature, archive.stat().st_size, version)
    if name == "bad-feed":
        feed.write_bytes(feed.read_bytes().replace(b"Glimmer isolated update test", b"Untrusted modified title"))
    executable = installed / "Contents/MacOS/UpdateProbe"
    processes = []
    output = (case / "process.log").open("w")
    try:
        if name == "manual-disabled":
            disabled_info = dict(info, SUEnableAutomaticChecks=False, GWUpdateProbeMode="toggle-off",
                                 CFBundleVersion="1", CFBundleShortVersionString="0.0.1")
            (installed / "Contents/Info.plist").write_bytes(plistlib.dumps(disabled_info))
            run("codesign", "--force", "--timestamp=none", "--sign", IDENTITY, installed)
            first = subprocess.Popen([str(executable)], stdout=output, stderr=output)
            processes.append(first)
            wait_for(first, log, "reminders-disabled")
            first.wait(timeout=10)
            # Restore the enabled build default. The persisted user choice must
            # still disable reminders in the next process.
            (installed / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(
                info, CFBundleVersion="1", CFBundleShortVersionString="0.0.1")))
            run("codesign", "--force", "--timestamp=none", "--sign", IDENTITY, installed)
        proc = subprocess.Popen([str(executable)], stdout=output, stderr=output)
        processes.append(proc)
        if native:
            print(f"Native update prompt: {installed}", flush=True)
            print(f"Probe PID: {proc.pid}", flush=True)
        expected = {"decline": "terminated", "bad-archive": "error", "bad-feed": "error",
                    "no-update": "no-update", "empty-feed": "no-update"}.get(name, "relaunched")
        entries = wait_for(proc, log, expected, 100 if native else 65)
        proc.wait(timeout=15)
        phases = [entry["phase"] for entry in log_entries(log)]
        downloads = [(stamp, path) for stamp, path in requests if path == f"/{name}/update.zip"]
        started = [entry for entry in entries if entry["phase"] == "started"]
        assert started and all(entry["downloads"] == "false" for entry in started), entries
        if name in {"decline", "bad-feed", "no-update", "empty-feed"}:
            assert not downloads, f"unconfirmed update was downloaded: {downloads}"
        if name in {"accept", "bad-archive", "manual-disabled"}:
            confirmed = next(float(entry["time"]) for entry in entries if entry["phase"] == "confirmed")
            assert downloads and all(stamp >= confirmed for stamp, _ in downloads), downloads
        if name == "manual-disabled":
            manual = next(entry for entry in entries if entry["phase"] == "manual-check")
            assert manual["checks"] == "false", entries
            assert all(stamp >= float(manual["time"]) for stamp, path in requests if path.startswith(f"/{name}/"))
        build = plistlib.loads((installed / "Contents/Info.plist").read_bytes())["CFBundleVersion"]
        assert build == ("2" if expected == "relaunched" else "1"), (name, build)
        if expected == "relaunched":
            assert all(phase in phases for phase in ["draining", "drained", "terminated", "relaunched"]), phases
            run("codesign", "--verify", "--deep", "--strict", installed)
        assert hashlib.sha256(user_data.read_bytes()).hexdigest() == original_data
        results.append({"case": name, "phases": phases, "downloads": len(downloads), "build": build})
        print(f"PASS {name}: build={build}, archive downloads={len(downloads)}, user data unchanged", flush=True)
    except Exception:
        print(f"FAILED {name}: {log_entries(log)}", file=sys.stderr)
        output.flush()
        print((case / "process.log").read_text()[-6000:], file=sys.stderr)
        raise
    finally:
        for proc in processes:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
        output.close()


try:
    cases = os.environ.get("GW_UPDATE_TEST_CASES", "").split()
    if not cases:
        cases = ["native"] if os.environ.get("GW_UPDATE_TEST_NATIVE") == "1" else [
            "accept", "decline", "bad-archive", "bad-feed", "no-update", "empty-feed", "manual-disabled"]
    for case in cases:
        run_case(case, native=case == "native")
    evidence = os.environ.get("GW_UPDATE_TEST_REPORT")
    if evidence:
        Path(evidence).write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")
    print(f"App update integration: {len(results)} scenarios passed", flush=True)
finally:
    server.shutdown()
    for bundle_id in test_ids:
        subprocess.run(["/usr/bin/defaults", "delete", bundle_id], capture_output=True)
        cache = Path.home() / "Library/Caches" / bundle_id
        if cache.is_dir() and not cache.is_symlink():
            shutil.rmtree(cache)
