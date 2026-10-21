#!/usr/bin/env python3
"""Tests appcast.py: python3 Scripts/release/test_appcast.py"""
import os
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "appcast.py")
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"

# What generate_appcast writes for three archives (trimmed), the newest with two deltas.
GENERATED = """<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>Open Wallpaper Engine</title>
        <item>
            <title>1.1.0</title>
            <pubDate>Mon, 28 Sep 2026 03:17:51 -0230</pubDate>
            <sparkle:channel>beta</sparkle:channel>
            <sparkle:version>22</sparkle:version>
            <sparkle:shortVersionString>1.1.0</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="https://example.com/OpenWallpaperEngine-1.1.0.zip" length="207909" type="application/octet-stream" sparkle:edSignature="SIGNEW"/>
            <sparkle:deltas>
                <enclosure url="https://example.com/Open%20Wallpaper%20Engine22-21.delta" sparkle:deltaFrom="21" length="1214" type="application/octet-stream" sparkle:edSignature="D21"/>
                <enclosure url="https://example.com/Open%20Wallpaper%20Engine22-20.delta" sparkle:deltaFrom="20" length="1210" type="application/octet-stream" sparkle:edSignature="D20"/>
            </sparkle:deltas>
        </item>
        <item>
            <title>1.0.1</title>
            <sparkle:version>21</sparkle:version>
            <enclosure url="https://example.com/OpenWallpaperEngine-1.0.1.zip" length="1" type="application/octet-stream" sparkle:edSignature="OLD"/>
        </item>
    </channel>
</rss>
"""

EXISTING = """<?xml version='1.0' encoding='utf-8'?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>Open Wallpaper Engine</title>
        <item>
            <title>1.0.0</title>
            <sparkle:version>20</sparkle:version>
            <enclosure url="https://github.com/o/r/releases/download/v1.0.0/OpenWallpaperEngine-1.0.0.zip" length="1" sparkle:edSignature="A"/>
        </item>
        <item>
            <title>1.0.1</title>
            <sparkle:version>21</sparkle:version>
            <enclosure url="https://github.com/o/r/releases/download/v1.0.1/OpenWallpaperEngine-1.0.1.zip" length="1" sparkle:edSignature="B"/>
        </item>
        <item>
            <title>0.9.9</title>
            <sparkle:version>7</sparkle:version>
            <enclosure url="https://github.com/o/r/releases/download/v0.9.9/OpenWallpaperEngine-0.9.9.zip" length="1" sparkle:edSignature="C"/>
        </item>
    </channel>
</rss>
"""


def run(*args):
    return subprocess.run([sys.executable, SCRIPT, *args], capture_output=True, text=True)


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = self.dir.name
        self.archives = os.path.join(self.root, "archives")
        os.mkdir(self.archives)
        for name in ["Open Wallpaper Engine22-21.delta", "Open Wallpaper Engine22-20.delta"]:
            open(os.path.join(self.archives, name), "w").close()
        self.generated = os.path.join(self.root, "generated.xml")
        with open(self.generated, "w") as f:
            f.write(GENERATED)
        self.appcast = os.path.join(self.root, "appcast.xml")
        with open(self.appcast, "w") as f:
            f.write(EXISTING)
        self.notes = os.path.join(self.root, "notes.html")
        with open(self.notes, "w") as f:
            f.write("<ul><li>New &amp; better</li></ul>\n")

    def tearDown(self):
        self.dir.cleanup()

    def merge(self, *extra, appcast=None, label="1.1.0-beta.1", tag="v1.1.0-beta.1"):
        return run("merge", "--generated", self.generated, "--appcast", appcast or self.appcast, "--build", "22",
                   "--label", label, "--tag", tag, "--repo", "o/r", "--archives", self.archives, *extra)

    def test_previous_lists_the_newest_full_archives(self):
        result = run("previous", "--appcast", self.appcast, "--count", "2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), [
            "https://github.com/o/r/releases/download/v1.0.1/OpenWallpaperEngine-1.0.1.zip",
            "https://github.com/o/r/releases/download/v1.0.0/OpenWallpaperEngine-1.0.0.zip"])

    def test_previous_of_a_missing_feed_is_empty(self):
        result = run("previous", "--appcast", os.path.join(self.root, "none.xml"))
        self.assertEqual((result.returncode, result.stdout), (0, ""))

    def test_merge_a_prerelease(self):
        result = self.merge("--channel", "beta", "--notes-html", self.notes)
        self.assertEqual(result.returncode, 0, result.stderr)
        uploads = result.stdout.split("\n")[:-1]
        self.assertEqual([os.path.basename(p) for p in uploads], [
            "OpenWallpaperEngine-1.1.0-beta.1-from-21.delta", "OpenWallpaperEngine-1.1.0-beta.1-from-20.delta"])
        for path in uploads:
            self.assertTrue(os.path.exists(path))

        items = ET.parse(self.appcast).getroot().find("channel").findall("item")
        self.assertEqual([i.findtext(S + "version") for i in items], ["22", "20", "21", "7"], "new item first, old kept")
        item = items[0]
        prefix = "https://github.com/o/r/releases/download/v1.1.0-beta.1/"
        self.assertEqual(item.findtext("title"), "1.1.0-beta.1")
        self.assertEqual(item.findtext(S + "shortVersionString"), "1.1.0-beta.1")
        self.assertEqual(item.findtext(S + "channel"), "beta")
        self.assertEqual(item.findtext(S + "minimumSystemVersion"), "14.0")
        self.assertEqual(item.find("enclosure").get("url"), prefix + "OpenWallpaperEngine-1.1.0.zip")
        self.assertEqual(item.find("enclosure").get(S + "edSignature"), "SIGNEW")
        deltas = item.find(S + "deltas").findall("enclosure")
        self.assertEqual([d.get("url") for d in deltas], [prefix + "OpenWallpaperEngine-1.1.0-beta.1-from-21.delta",
                                                          prefix + "OpenWallpaperEngine-1.1.0-beta.1-from-20.delta"])
        self.assertEqual([d.get(S + "edSignature") for d in deltas], ["D21", "D20"])
        self.assertEqual(item.findtext(S + "fullReleaseNotesLink"), "https://github.com/o/r/releases/tag/v1.1.0-beta.1")
        self.assertEqual(item.findtext("description"), "<ul><li>New &amp; better</li></ul>")

    def test_merge_a_final_release_drops_the_channel_and_replaces_its_build(self):
        self.assertEqual(self.merge("--channel", "beta").returncode, 0)
        # Re-running (e.g. the workflow re-run) for the same build replaces the item.
        for name in ["Open Wallpaper Engine22-21.delta", "Open Wallpaper Engine22-20.delta"]:
            open(os.path.join(self.archives, name), "w").close()
        result = self.merge(label="1.1.0", tag="v1.1.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        items = ET.parse(self.appcast).getroot().find("channel").findall("item")
        self.assertEqual([i.findtext(S + "version") for i in items].count("22"), 1)
        self.assertIsNone(items[0].find(S + "channel"))
        self.assertEqual(items[0].findtext(S + "shortVersionString"), "1.1.0")

    def test_merge_into_a_new_feed_and_missing_deltas(self):
        os.remove(os.path.join(self.archives, "Open Wallpaper Engine22-20.delta"))
        fresh = os.path.join(self.root, "fresh.xml")
        result = self.merge(appcast=fresh)
        self.assertEqual(result.returncode, 0, result.stderr)
        root = ET.parse(fresh).getroot()
        self.assertEqual(root.find("channel").findtext("title"), "Open Wallpaper Engine")
        deltas = root.find("channel").find("item").find(S + "deltas").findall("enclosure")
        self.assertEqual([d.get(S + "deltaFrom") for d in deltas], ["21"])

    def test_merge_fails_without_the_build(self):
        result = run("merge", "--generated", self.generated, "--appcast", self.appcast, "--build", "99",
                     "--label", "9.9.9", "--tag", "v9.9.9", "--repo", "o/r", "--archives", self.archives)
        self.assertEqual(result.returncode, 1)


if __name__ == "__main__":
    unittest.main()
