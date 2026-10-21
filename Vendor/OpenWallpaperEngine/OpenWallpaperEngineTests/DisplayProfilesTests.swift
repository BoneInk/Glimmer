import XCTest
@testable import OpenWallpaperEngine

/// Display profiles (WE's "Save Profile" / "Load Profile"): a named copy of the layout and the
/// displays' wallpapers, by display identity, that loads back onto whatever ids the displays have.
@MainActor
final class DisplayProfilesTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() async throws {
        fileURL = FileManager.default.temporaryDirectory
            .appending(path: "DisplayProfilesTests-\(UUID().uuidString)")
            .appending(path: "DisplayProfiles.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) // Optional cleanup.
    }

    private static func displays(_ ids: [String]) -> [DisplayIdentity] {
        zip(ids, ["UUID-A", "UUID-B", "UUID-C", "UUID-D"]).enumerated().map { index, pair in
            DisplayIdentity(screenId: pair.0, identity: pair.1,
                            frame: CGRect(x: CGFloat(index) * 1920, y: 0, width: 1920, height: 1080))
        }
    }

    private func wallpaper(_ folder: String) -> WEWallpaper {
        WEWallpaper(using: WEProject(file: "scene.json", preview: "preview.jpg", title: folder, type: "scene"),
                    where: URL(filePath: "/tmp/owe-profile-tests/\(folder)"))
    }

    private func model(_ ids: [String] = ["1", "2", "3", "4"]) -> WallpaperViewModel {
        let model = WallpaperViewModel(persistsWallpapers: false)
        let displays = Self.displays(ids)
        model.connectedDisplays = { displays }
        model.audioOutputEnabled = false
        model.refreshDisplayLayout()
        return model
    }

    private func titles(_ model: WallpaperViewModel) -> [String: String] {
        model.wallpapers.mapValues(\.project.title)
    }

    func testAProfileLoadsBackOntoTheSameDisplaysUnderNewIds() {
        let model = model()
        model.wallpapers = ["1": wallpaper("a"), "2": wallpaper("b"), "3": wallpaper("c"), "4": wallpaper("d")]
        model.setLayout(.clone)
        XCTAssertTrue(model.toggleFlip("2"))
        model.setLayout(.perDisplay)
        model.addStretchGroup(["1", "2"])
        model.split("3", DisplaySplit(direction: .vertical, position: 0.25))
        model.wallpapers["3/R"] = wallpaper("e")
        model.toggleMute("4")
        XCTAssertTrue(DisplayProfiles(model: model, fileURL: fileURL).save(name: "Desk"))

        // Another launch: the same displays under other ids, read from the file.
        let other = self.model(["11", "12", "13", "14"])
        other.wallpapers = ["11": wallpaper("x"), "14": wallpaper("y")]
        let profiles = DisplayProfiles(model: other, fileURL: fileURL)
        XCTAssertEqual(profiles.names, ["Desk"])
        XCTAssertTrue(profiles.load(name: "Desk"))

        XCTAssertEqual(other.displayLayout, model.displayLayout)
        XCTAssertEqual(titles(other), ["11": "a", "12": "b", "13": "c", "13/L": "c", "13/R": "e", "14": "d"])
        XCTAssertTrue(other.isStretched("11") && other.isStretched("12"))
        XCTAssertTrue(other.isSplitRegion("13/L") && other.isSplitRegion("13/R"))
        XCTAssertEqual(other.parentSplit(of: "13/L")?.split, DisplaySplit(direction: .vertical, position: 0.25))
        XCTAssertTrue(other.isMuted("14"))
        XCTAssertFalse(other.isMuted("13"))
        other.setLayout(.clone)
        XCTAssertTrue(other.isFlipped("12"), "the clone layout's flip comes back with the profile")
    }

    func testLoadingKeepsTheWallpapersOfDisplaysTheProfileDoesNotName() {
        let model = model(["1"])
        model.wallpapers = ["1": wallpaper("a")]
        DisplayProfiles(model: model, fileURL: fileURL).save(name: "One")

        let other = self.model(["1", "2"])
        other.wallpapers = ["1": wallpaper("x"), "1/L": wallpaper("old region"), "2": wallpaper("b")]
        XCTAssertTrue(DisplayProfiles(model: other, fileURL: fileURL).load(name: "One"))
        XCTAssertEqual(titles(other), ["1": "a", "2": "b"])
    }

    func testProfilesOfDisplaysNotConnectedAreSkipped() {
        let model = model(["1", "2"])
        model.wallpapers = ["1": wallpaper("a"), "2": wallpaper("b")]
        DisplayProfiles(model: model, fileURL: fileURL).save(name: "Two")

        let other = self.model(["7"])
        XCTAssertTrue(DisplayProfiles(model: other, fileURL: fileURL).load(name: "Two"))
        XCTAssertEqual(titles(other), ["7": "a"])
    }

    func testLoadingASplitSelectsItsRegionInsteadOfTheDisplay() {
        let model = model(["1"])
        model.wallpapers = ["1": wallpaper("a")]
        model.split("1", DisplaySplit())
        DisplayProfiles(model: model, fileURL: fileURL).save(name: "Split")

        let other = self.model(["1"])
        other.selectedScreenIds = ["1"]
        other.selectedScreenId = "1"
        DisplayProfiles(model: other, fileURL: fileURL).load(name: "Split")
        XCTAssertEqual(other.selectedScreenIds, ["1/L"])
        XCTAssertEqual(other.selectedScreenId, "1/L")
    }

    func testSavingANameAgainOverwritesItAndNamesSortIgnoringCase() {
        let model = model()
        let profiles = DisplayProfiles(model: model, fileURL: fileURL)
        profiles.save(name: "beta")
        profiles.save(name: "Alpha")
        model.setLayout(.clone)
        XCTAssertTrue(profiles.save(name: "  beta \n"))
        XCTAssertEqual(profiles.names, ["Alpha", "beta"])
        XCTAssertEqual(profiles.profile(named: "beta")?.layout.layout, .clone)
        XCTAssertEqual(DisplayProfiles(model: model, fileURL: fileURL).profiles, profiles.profiles)
    }

    func testAnEmptyNameIsRejected() {
        let profiles = DisplayProfiles(model: model(), fileURL: fileURL)
        XCTAssertFalse(profiles.save(name: "  "))
        XCTAssertTrue(profiles.names.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
    }

    func testDeleteRemovesTheProfileFromTheFile() {
        let model = model()
        let profiles = DisplayProfiles(model: model, fileURL: fileURL)
        profiles.save(name: "A")
        profiles.save(name: "B")
        profiles.delete(name: "A")
        XCTAssertEqual(profiles.names, ["B"])
        XCTAssertEqual(DisplayProfiles(model: model, fileURL: fileURL).names, ["B"])
    }

    func testABadProfileDoesNotDropTheOthers() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
        {"profiles": [
            {"name": "Good", "layout": {"layout": 2}},
            {"layout": {"layout": 0}},
            {"name": "Also", "selections": {"UUID-A": 7}}
        ]}
        """
        try Data(json.utf8).write(to: fileURL)
        let profiles = DisplayProfiles(model: model(), fileURL: fileURL)
        XCTAssertEqual(profiles.names, ["Also", "Good"])
        XCTAssertEqual(profiles.profile(named: "Good")?.layout.layout, .clone)
        XCTAssertEqual(profiles.profile(named: "Also")?.selections.isEmpty, true, "a bad selection is skipped")
    }

    func testLoadingAnUnknownNameChangesNothing() {
        let model = model()
        model.wallpapers = ["1": wallpaper("a")]
        model.addCloneGroup(["1", "2"])
        let layout = model.displayLayout
        let profiles = DisplayProfiles(model: model, fileURL: fileURL)
        XCTAssertFalse(profiles.load(name: "Nope"))
        XCTAssertEqual(model.displayLayout, layout)
        XCTAssertEqual(titles(model), ["1": "a"])
    }
}
