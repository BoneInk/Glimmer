import XCTest
@testable import OpenWallpaperEngine

/// Importing the display layout of a Wallpaper Engine `config.json`: WE's monitors (Windows device
/// paths) matched to the connected displays by order, its groups, splits, clone source and flips,
/// and the screen saver's layout. The configs are written for these tests.
@MainActor
final class WallpaperEngineDisplayConfigTests: XCTestCase {
    private let displays = [DisplayIdentity(screenId: "1", identity: "UUID-A"),
                            DisplayIdentity(screenId: "2", identity: "UUID-B"),
                            DisplayIdentity(screenId: "3", identity: "UUID-C")]

    /// A clone group of the first two monitors (the second its main display, the first flipped),
    /// the third split twice, the clone layout's own source, and a screen saver cloned on its own.
    private let config = ##"""
    {
        "?installdirectory": "C:\\Program Files (x86)\\Steam\\steamapps\\common\\wallpaper_engine",
        "someone": {
            "general": {
                "wallpaperconfig": {
                    "layout": 0,
                    "profile": {
                        "groups": {
                            "group_123": {
                                "monitors": ["\\\\?\\DISPLAY#AAA#1", "\\\\?\\DISPLAY#BBB#2"],
                                "layout": 2,
                                "source": "\\\\?\\DISPLAY#BBB#2",
                                "monitorconfig": {"\\\\?\\DISPLAY#AAA#1": {"flip": true}}
                            },
                            "group_bad": {"layout": 1}
                        },
                        "splits": {
                            "\\\\?\\DISPLAY#CCC#3": {"direction": 0, "position": 0.3},
                            "\\\\?\\DISPLAY#CCC#3/L": {"direction": 1, "position": 0.5}
                        },
                        "source": "\\\\?\\DISPLAY#CCC#3"
                    },
                    "selectedwallpapers": {"Monitor0": {"file": "C:\\wallpapers\\a\\scene.json"}}
                },
                "wallpaperconfigscreensaver": {"layout": 2, "sameaswallpaper": false}
            }
        }
    }
    """##

    func testGroupsSplitsAndTheCloneSourceMatchTheDisplaysByOrder() throws {
        let imported = try WallpaperEngineDisplayConfig(data: Data(config.utf8))
        let layout = imported.layout(on: displays)
        XCTAssertEqual(layout.layout, .perDisplay)

        let group = try XCTUnwrap(layout.group(containing: "UUID-A"))
        XCTAssertEqual(group.members, ["UUID-A", "UUID-B"])
        XCTAssertEqual(group.layout, .clone)
        XCTAssertEqual(group.mainDisplay, "UUID-B")
        XCTAssertEqual(group.flipped, ["UUID-A"])
        XCTAssertEqual(layout.groups.count, 1, "a group that can't be read is skipped")

        XCTAssertEqual(layout.splits(of: "UUID-C"), ["": DisplaySplit(direction: .vertical, position: 0.3),
                                                     "/L": DisplaySplit(direction: .horizontal, position: 0.5)])
        var clone = layout
        clone.layout = .clone
        XCTAssertEqual(clone.clone(containing: "UUID-A", connected: displays.map(\.identity))?.mainDisplay, "UUID-C")

        XCTAssertEqual(imported.screenSaverLayout, ScreenSaverDisplayLayout(sameAsWallpaper: false, layout: .clone))
    }

    func testMonitorsWithoutADisplayAreSkippedWithTheirGroup() throws {
        let imported = try WallpaperEngineDisplayConfig(data: Data(config.utf8))
        let layout = imported.layout(on: Array(displays.prefix(1)))
        XCTAssertTrue(layout.groups.isEmpty, "the group's second monitor has no display")
        XCTAssertTrue(layout.splits.isEmpty, "the split monitor has no display")
    }

    func testMonitorNamesWithAnIndexTakeThatDisplay() {
        let matched = WallpaperEngineDisplayConfig.match(["Monitor1", "\\\\?\\DISPLAY#ZZZ"], to: ["UUID-A", "UUID-B"])
        XCTAssertEqual(matched, ["Monitor1": "UUID-B", "\\\\?\\DISPLAY#ZZZ": "UUID-A"])
    }

    func testAConfigWithoutAProfileHasOnlyItsLayout() throws {
        let json = #"{"u": {"general": {"wallpaperconfig": {"layout": 1, "profile": null, "selectedwallpapers": null}}}}"#
        let imported = try WallpaperEngineDisplayConfig(data: Data(json.utf8))
        XCTAssertEqual(imported.layout(on: displays), DisplayLayoutConfiguration(layout: .stretch))
        XCTAssertNil(imported.screenSaverLayout)
    }

    func testAFileThatIsNotAConfigThrows() {
        XCTAssertThrowsError(try WallpaperEngineDisplayConfig(data: Data("[]".utf8))) {
            XCTAssertEqual($0 as? WallpaperEngineDisplayConfig.ImportError, .notAConfig)
        }
        XCTAssertThrowsError(try WallpaperEngineDisplayConfig(data: Data(#"{"u": {"general": {}}}"#.utf8))) {
            XCTAssertEqual($0 as? WallpaperEngineDisplayConfig.ImportError, .noDisplayLayout)
        }
    }

    func testImportingSavesAProfileAndTakesTheScreenSaverLayout() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "WEDisplayConfigTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) } // Optional cleanup.
        let configURL = folder.appending(path: "config.json")
        try Data(config.utf8).write(to: configURL)

        let model = WallpaperViewModel(persistsWallpapers: false)
        model.connectedDisplays = { [displays] in displays }
        let profiles = DisplayProfiles(model: model, fileURL: folder.appending(path: "DisplayProfiles.json"))
        let profile = try profiles.importWallpaperEngineConfig(at: configURL)
        XCTAssertEqual(profile.name, "Wallpaper Engine")
        XCTAssertTrue(profile.selections.isEmpty, "WE's selections are Windows paths")
        XCTAssertEqual(profiles.names, ["Wallpaper Engine"])
        XCTAssertEqual(model.screenSaverLayout, ScreenSaverDisplayLayout(sameAsWallpaper: false, layout: .clone))

        XCTAssertTrue(profiles.load(name: "Wallpaper Engine"))
        XCTAssertTrue(model.isCloned("1") && model.isMainCloneDisplay("2"))
    }
}
