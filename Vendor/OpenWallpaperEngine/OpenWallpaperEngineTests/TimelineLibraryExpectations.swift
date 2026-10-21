import XCTest
@testable import OpenWallpaperEngine

/// The reference model's values for the library's timelines, per item: the committed
/// `Timeline/library-expected.json` for an item it covers as it is now (every file it read has the
/// same SHA-256, and every group found is listed), otherwise the output of
/// `Scripts/timeline-reference.py library --items …` run now. The library keeps gaining and
/// updating wallpapers, so an item the fixture doesn't cover is checked against the same model
/// rather than failing for being new; without a python3 it is skipped and listed in `unchecked`.
/// An item the fixture lists that the library no longer has is skipped.
struct TimelineLibraryExpectations {
    var tolerance: Float
    /// The groups to check, keyed as `TimelineLibrarySweepTests.groupID` keys what it finds.
    var groups: [String: SceneJSON] = [:]
    /// Items checked against the script's output of this run: new, or changed since the fixture.
    var live: [String] = []
    /// New or changed items that couldn't be checked (no python3).
    var unchecked: [String] = []
    /// Items of the fixture the library no longer has.
    var removed: [String] = []

    init(found: [TimelineLibrarySweepTests.Found], scannedItems: Set<String>, roots: [URL]) throws {
        let fixture = try TimelineOracle.load(Fixtures.url("Timeline/library-expected.json"))
        tolerance = try TimelineOracle.float(XCTUnwrap(fixture[oracle: "tolerance"]))
        let fixtureGroups = fixture[oracle: "groups"]?.oracleArray ?? []

        var digests: [String: String] = [:]
        for timeline in found { digests["\(timeline.item)\u{0}\(timeline.file)"] = timeline.digest }

        var fixtureItems: [String: [(id: String, group: SceneJSON)]] = [:]
        var fixtureFiles = Set<String>()
        var needsScript = Set<String>()
        for group in fixtureGroups {
            let item = group[oracle: "item"]?.oracleString ?? ""
            let file = group[oracle: "file"]?.oracleString ?? ""
            fixtureItems[item, default: []].append((Self.id(group), group))
            fixtureFiles.insert("\(item)\u{0}\(file)")
            // A file changed, or gone from an item still in the library.
            if scannedItems.contains(item), digests["\(item)\u{0}\(file)"] != group[oracle: "sha256"]?.oracleString {
                needsScript.insert(item)
            }
        }
        removed = fixtureItems.keys.filter { !scannedItems.contains($0) }.sorted()
        let covered = Set(fixtureItems.values.joined().map(\.id))
        // A group in a file the fixture didn't read (a new item, or a file an item gained) is a
        // change. One in a file it read, unchanged, that it doesn't list is the walk disagreeing
        // with the script's: that stays with the fixture, and the sweep fails on it.
        for group in TimelineLibrarySweepTests.linkGroups(found) {
            let id = TimelineLibrarySweepTests.groupID(group)
            if !covered.contains(id), !fixtureFiles.contains("\(group[0].item)\u{0}\(group[0].file)") {
                needsScript.insert(group[0].item)
            }
        }
        for (item, entries) in fixtureItems where scannedItems.contains(item) && !needsScript.contains(item) {
            for entry in entries { groups[entry.id] = entry.group }
        }
        guard !needsScript.isEmpty else { return }
        guard ReferenceScript.python != nil else {
            unchecked = needsScript.sorted()
            return
        }
        let output = FileManager.default.temporaryDirectory.appending(path: "owe-timeline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) } // scratch cleanup
        try ReferenceScript.run("timeline-reference.py",
                                arguments: ["library", "--items", needsScript.sorted().joined(separator: ","),
                                            "--out", output.path],
                                environment: ["OWE_LIBRARY": roots.map(\.path).joined(separator: ":")])
        let current = try TimelineOracle.load(output.appending(path: "library-expected.json"))
        for group in current[oracle: "groups"]?.oracleArray ?? [] { groups[Self.id(group)] = group }
        live = needsScript.sorted()
    }

    /// Whether the fixture, or this run's script output, covers `item`.
    func checks(_ item: String) -> Bool { !unchecked.contains(item) }

    /// The groups of `item`, in id order.
    func groups(of item: String) -> [SceneJSON] {
        groups.sorted { $0.key < $1.key }.map(\.value).filter { $0[oracle: "item"]?.oracleString == item }
    }

    static func id(_ group: SceneJSON) -> String {
        let item = group[oracle: "item"]?.oracleString ?? ""
        let file = group[oracle: "file"]?.oracleString ?? ""
        let paths = (group[oracle: "paths"]?.oracleArray ?? []).compactMap(\.oracleString)
        return "\(item) \(file) \(paths.joined(separator: " + "))"
    }

    /// What the run checked beyond the fixture, for the test's log.
    var notes: [String] {
        var lines: [String] = []
        if !live.isEmpty {
            lines.append("\(live.count) items new or changed since Timeline/library-expected.json, checked against "
                         + "Scripts/timeline-reference.py run now: \(live.joined(separator: ", "))")
        }
        if !unchecked.isEmpty {
            lines.append("\(unchecked.count) items new or changed since Timeline/library-expected.json NOT checked "
                         + "(no python3 to run Scripts/timeline-reference.py): \(unchecked.joined(separator: ", "))")
        }
        if !removed.isEmpty {
            lines.append("\(removed.count) items of the fixture no longer in the library, skipped: \(removed.joined(separator: ", "))")
        }
        if !lines.isEmpty { lines.append("Refresh the fixture: Scripts/timeline-reference.py library") }
        return lines
    }
}
