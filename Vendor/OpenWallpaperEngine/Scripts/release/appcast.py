#!/usr/bin/env python3
"""Maintains site/appcast.xml, the Sparkle feed on GitHub Pages (docs/releasing.md).

    appcast.py previous --appcast site/appcast.xml [--count 3]
        Prints the download URL of the full archive of the newest COUNT items, one per line, so
        the publish workflow can fetch them and let generate_appcast make deltas from them.

    appcast.py merge --generated G --appcast site/appcast.xml --build N --label L --tag T
                     --repo OWNER/REPO --archives DIR [--channel beta] [--notes-html FILE]
        Takes the item for build N from G (generate_appcast's output for the new archive and
        the previous ones), points its archive and deltas at the release's assets, renames the
        delta files in DIR to match, sets its version label, channel and release notes, and puts
        it first in the appcast (replacing an item for the same build). Prints the delta files
        to upload, one per line.

Standard library only; runs on the macOS runners' python3.
"""
import argparse
import email.utils
import os
import sys
import urllib.parse
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", DC)
MINIMUM_SYSTEM_VERSION = "14.0"


def q(name):
    return "{%s}%s" % (SPARKLE, name)


def empty_feed():
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Open Wallpaper Engine"
    ET.SubElement(channel, "link").text = "https://openwallpaperengine.app/appcast.xml"
    ET.SubElement(channel, "description").text = "Open Wallpaper Engine updates"
    ET.SubElement(channel, "language").text = "en"
    return ET.ElementTree(rss)


def load(path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return empty_feed()
    return ET.parse(path)


def build_of(item):
    text = item.findtext(q("version")) or "0"
    try:
        return int(text)
    except ValueError:
        return 0


def items_newest_first(tree):
    return sorted(tree.getroot().find("channel").findall("item"), key=build_of, reverse=True)


def previous(args):
    tree = load(args.appcast)
    for item in items_newest_first(tree)[: args.count]:
        enclosure = item.find("enclosure")
        if enclosure is not None and enclosure.get("url"):
            print(enclosure.get("url"))
    return 0


def set_child(item, tag, text):
    element = item.find(tag)
    if element is None:
        element = ET.SubElement(item, tag)
    element.text = text
    return element


def merge(args):
    generated = ET.parse(args.generated)
    new_item = None
    for item in generated.getroot().find("channel").findall("item"):
        if item.findtext(q("version")) == str(args.build):
            new_item = item
    if new_item is None:
        print("error: %s has no item for build %s" % (args.generated, args.build), file=sys.stderr)
        return 1

    prefix = "https://github.com/%s/releases/download/%s/" % (args.repo, urllib.parse.quote(args.tag))
    enclosure = new_item.find("enclosure")
    if enclosure is None or not enclosure.get(q("edSignature")):
        print("error: the new item has no signed archive", file=sys.stderr)
        return 1
    archive_name = os.path.basename(urllib.parse.unquote(urllib.parse.urlparse(enclosure.get("url")).path))
    enclosure.set("url", prefix + urllib.parse.quote(archive_name))

    # Delta files: generate_appcast names them "<app name><new build>-<old build>.delta"; the
    # app name has spaces, which GitHub rewrites in asset names. Rename to a stable form.
    uploads = []
    deltas = new_item.find(q("deltas"))
    for delta in list(deltas) if deltas is not None else []:
        old_name = os.path.basename(urllib.parse.unquote(urllib.parse.urlparse(delta.get("url")).path))
        new_name = "OpenWallpaperEngine-%s-from-%s.delta" % (args.label, delta.get(q("deltaFrom")))
        source = os.path.join(args.archives, old_name)
        if not os.path.exists(source):
            print("warning: %s is missing; dropping that delta" % old_name, file=sys.stderr)
            deltas.remove(delta)
            continue
        os.replace(source, os.path.join(args.archives, new_name))
        delta.set("url", prefix + urllib.parse.quote(new_name))
        uploads.append(os.path.join(args.archives, new_name))
    if deltas is not None and len(deltas) == 0:
        new_item.remove(deltas)

    set_child(new_item, "title", args.label)
    set_child(new_item, q("shortVersionString"), args.label)
    set_child(new_item, q("minimumSystemVersion"), MINIMUM_SYSTEM_VERSION)
    if new_item.find("pubDate") is None:
        set_child(new_item, "pubDate", email.utils.formatdate(usegmt=True))
    channel = new_item.find(q("channel"))
    if args.channel:
        set_child(new_item, q("channel"), args.channel)
    elif channel is not None:
        new_item.remove(channel)
    release_page = "https://github.com/%s/releases/tag/%s" % (args.repo, urllib.parse.quote(args.tag))
    set_child(new_item, q("fullReleaseNotesLink"), release_page)
    set_child(new_item, "link", release_page)
    if args.notes_html:
        with open(args.notes_html, encoding="utf-8") as handle:
            notes = handle.read().strip()
        if notes:
            set_child(new_item, "description", notes)  # HTML, Sparkle's default format

    tree = load(args.appcast)
    feed = tree.getroot().find("channel")
    for item in feed.findall("item"):
        if build_of(item) == args.build:
            feed.remove(item)
    # First item after the channel's own elements.
    first = next((i for i, child in enumerate(list(feed)) if child.tag == "item"), len(feed))
    feed.insert(first, new_item)
    ET.indent(tree, space="    ")
    tree.write(args.appcast, encoding="utf-8", xml_declaration=True)
    with open(args.appcast, "a", encoding="utf-8") as handle:
        handle.write("\n")
    for path in uploads:
        print(path)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("previous")
    p.add_argument("--appcast", required=True)
    p.add_argument("--count", type=int, default=3)
    m = commands.add_parser("merge")
    m.add_argument("--generated", required=True)
    m.add_argument("--appcast", required=True)
    m.add_argument("--build", type=int, required=True)
    m.add_argument("--label", required=True)
    m.add_argument("--tag", required=True)
    m.add_argument("--repo", required=True)
    m.add_argument("--archives", required=True)
    m.add_argument("--channel", default="")
    m.add_argument("--notes-html")
    args = parser.parse_args()
    return previous(args) if args.command == "previous" else merge(args)


if __name__ == "__main__":
    sys.exit(main())
