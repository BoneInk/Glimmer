import XCTest
@testable import OpenWallpaperEngine

/// WE's splits (`profile.splits`): a display divided into nested left/right or top/bottom
/// regions, each a display of its own with its own wallpaper, playback and view size.
@MainActor
final class DisplaySplitTests: XCTestCase {
    private let displays = [
        DisplayIdentity(screenId: "1", identity: "UUID-A", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
        DisplayIdentity(screenId: "2", identity: "UUID-B", frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440))
    ]

    private func wallpaper(_ folder: String) -> WEWallpaper {
        WEWallpaper(using: WEProject(file: "scene.json", preview: "preview.jpg", title: folder, type: "scene"),
                    where: URL(filePath: "/tmp/owe-split-tests/\(folder)"))
    }

    private func model() -> WallpaperViewModel {
        let model = WallpaperViewModel(persistsWallpapers: false)
        model.connectedDisplays = { [displays] in displays }
        model.audioOutputEnabled = false
        model.enabledScreens = ["1", "2"]
        model.wallpapers = ["1": wallpaper("a"), "2": wallpaper("b")]
        return model
    }

    // MARK: Geometry

    func testAVerticalSplitPutsTheRegionsSideBySide() {
        let frame = CGRect(x: 100, y: 50, width: 1920, height: 1080)
        let regions = DisplaySplitLayout.regions(of: frame, splits: ["": DisplaySplit(direction: .vertical, position: 0.25)])
        XCTAssertEqual(regions.map(\.path), ["/L", "/R"])
        XCTAssertEqual(regions.map(\.rect), [CGRect(x: 100, y: 50, width: 480, height: 1080),
                                             CGRect(x: 580, y: 50, width: 1440, height: 1080)])
    }

    func testAHorizontalSplitPutsTheFirstRegionOnTop() {
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let regions = DisplaySplitLayout.regions(of: frame, splits: ["": DisplaySplit(direction: .horizontal, position: 0.5)])
        XCTAssertEqual(regions.map(\.rect), [CGRect(x: 0, y: 540, width: 1920, height: 540),
                                             CGRect(x: 0, y: 0, width: 1920, height: 540)],
                       "AppKit's y runs up: the top region is the upper one")
    }

    func testNestedSplitsDivideTheirRegionInWholePoints() {
        let frame = CGRect(x: 0, y: 0, width: 1001, height: 600)
        let splits: [String: DisplaySplit] = ["": DisplaySplit(direction: .vertical, position: 0.5),
                                              "/R": DisplaySplit(direction: .horizontal, position: 1.0 / 3)]
        let regions = DisplaySplitLayout.regions(of: frame, splits: splits)
        XCTAssertEqual(regions.map(\.path), ["/L", "/R/L", "/R/R"])
        XCTAssertEqual(regions.map(\.rect), [CGRect(x: 0, y: 0, width: 501, height: 600),
                                             CGRect(x: 501, y: 400, width: 500, height: 200),
                                             CGRect(x: 501, y: 0, width: 500, height: 400)])
        XCTAssertEqual(regions.reduce(0) { $0 + $1.rect.width * $1.rect.height }, 1001 * 600, "no seam, no overlap")
        XCTAssertEqual(DisplaySplitLayout.rect(of: "/R", in: frame, splits: splits), CGRect(x: 501, y: 0, width: 500, height: 600))
        XCTAssertNil(DisplaySplitLayout.rect(of: "/L/L", in: frame, splits: splits), "/L isn't split")
    }

    func testTheOnlyLimitIsAPointOnEachSideAsInWE() {
        XCTAssertEqual(DisplaySplit.clampedPosition(0, extent: 1920), 1.0 / 1920)
        XCTAssertEqual(DisplaySplit.clampedPosition(1, extent: 1920), 1919.0 / 1920)
        XCTAssertEqual(DisplaySplit.clampedPosition(0.5, extent: 2), 0.5)
        XCTAssertNil(DisplaySplit.clampedPosition(0.5, extent: 1), "a one-point region can't be split")
        // No depth limit: a region keeps splitting while it has two points.
        var splits: [String: DisplaySplit] = [:]
        var path = ""
        for _ in 0..<10 {
            splits[path] = DisplaySplit(direction: .vertical, position: 0.5)
            path += DisplaySplit.first
        }
        XCTAssertEqual(DisplaySplitLayout.regions(of: CGRect(x: 0, y: 0, width: 1024, height: 10), splits: splits).count, 11)
    }

    func testSplitsKeepWEsShape() throws {
        let json = #"{"layout":0,"splits":{"UUID-A":{"direction":1,"position":0.25},"UUID-A/L":"broken"}}"#
        let layout = try JSONDecoder().decode(DisplayLayoutConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(layout.splits, ["UUID-A": DisplaySplit(direction: .horizontal, position: 0.25)],
                       "one unreadable split doesn't drop the others")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(layout)) as? [String: Any]
        let split = (encoded?["splits"] as? [String: Any])?["UUID-A"] as? [String: Any]
        XCTAssertEqual(split?["direction"] as? Int, 1)
        XCTAssertEqual(split?["position"] as? Double, 0.25)
    }

    // MARK: The model

    func testASplitDisplaysRegionsAreDisplaysOfTheirOwn() {
        let model = model()
        model.split("1", DisplaySplit(direction: .vertical, position: 0.5))
        XCTAssertEqual(model.layoutResolution.regions["1"]?.map(\.id), ["1/L", "1/R"])
        XCTAssertEqual(model.wallpaper(for: "1/L").project.title, "a", "the first region takes what the display showed, as in WE")
        XCTAssertNil(model.displayedWallpapers["1"], "the split display shows nothing of its own")
        model.setWallpaper(wallpaper("c"), for: "1/R")
        XCTAssertNotEqual(model.instanceKey(for: "1/L"), model.instanceKey(for: "1/R"))
        XCTAssertTrue(model.isScreenEnabled("1/R"))
        XCTAssertTrue(model.routedScreens.isSuperset(of: ["1/L", "1/R", "2"]))
        // A wallpaper set on the display goes to its regions.
        model.setWallpaper(wallpaper("d"), for: "1")
        XCTAssertEqual(["1/L", "1/R"].map { model.wallpaper(for: $0).project.title }, ["d", "d"])
    }

    func testRegionsTakeTheirDisplaysPlaybackAndMute() {
        let model = model()
        model.split("2", DisplaySplit(direction: .horizontal, position: 0.5))
        model.rulePlayback = ["2": .pause]
        XCTAssertEqual(model.displayPlayback, ["2": .pause, "2/L": .pause, "2/R": .pause])
        model.rulePlayback = [:]
        model.toggleMute("2/L")
        XCTAssertTrue(model.isMuted("2/R"), "mute is the display's")
        XCTAssertEqual(model.displayPlayback, ["2": .mute, "2/L": .mute, "2/R": .mute])
    }

    func testRemoveSplitAndRemoveAllSplits() {
        let model = model()
        model.split("1", DisplaySplit(direction: .vertical, position: 0.5))
        model.split("1/R", DisplaySplit(direction: .horizontal, position: 0.5))
        XCTAssertEqual(model.layoutResolution.regions["1"]?.map(\.id), ["1/L", "1/R/L", "1/R/R"])
        model.selectScreen("1/R/R", extendingSelection: false)
        model.removeSplit("1/R/L")
        XCTAssertEqual(model.layoutResolution.regions["1"]?.map(\.id), ["1/L", "1/R"], "the split it came from goes")
        XCTAssertEqual(model.selectedScreenId, "1/R", "the selection moves to the region left")
        model.removeAllSplits("1/L")
        XCTAssertNil(model.layoutResolution.regions["1"])
        XCTAssertEqual(model.selectedScreenId, "1")
        XCTAssertEqual(model.wallpaper(for: "1").project.title, "a", "the display's own pick shows again")
    }

    func testEditingASplitMovesItsDivider() throws {
        let model = model()
        model.split("1", DisplaySplit(direction: .vertical, position: 0.5))
        let parent = try XCTUnwrap(model.parentSplit(of: "1/R"))
        XCTAssertEqual(parent.id, "1")
        model.editSplit(parent.id, DisplaySplit(direction: .vertical, position: 0.25))
        XCTAssertEqual(model.layoutResolution.regions["1"]?.first?.rect.width, 480)
    }

    func testGroupsAndSplitsExcludeEachOther() {
        let model = model()
        model.split("1", DisplaySplit(direction: .vertical, position: 0.5))
        model.addStretchGroup(["1", "2"])
        XCTAssertNil(model.layoutResolution.regions["1"], "a stretch group removes its displays' splits, as in WE")
        XCTAssertTrue(model.displayLayout.splits.isEmpty)
        XCTAssertFalse(model.canSplit("1"), "WE doesn't offer a split on a grouped display")
        model.removeGroup(containing: "1")
        XCTAssertTrue(model.canSplit("1"))
        model.setLayout(.clone)
        XCTAssertFalse(model.canSplit("1"), "splits are for a wallpaper per display")
    }
}
