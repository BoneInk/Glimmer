import XCTest
@testable import OpenWallpaperEngine

/// WE's "Copy to" and "Swap with" in the Displays sheet's menu: offered under a wallpaper per
/// display, from a display that shows a wallpaper, to the displays outside a clone or stretch; the
/// wallpaper and its display options move, and a display without one leaves the other without one.
@MainActor
final class DisplayTransferTests: XCTestCase {
    private let displays = [DisplayIdentity(screenId: "1", identity: "UUID-A"),
                            DisplayIdentity(screenId: "2", identity: "UUID-B"),
                            DisplayIdentity(screenId: "3", identity: "UUID-C")]

    private func wallpaper(_ folder: String) -> WEWallpaper {
        WEWallpaper(using: WEProject(file: "scene.json", preview: "preview.jpg", title: folder, type: "scene"),
                    where: URL(filePath: "/tmp/owe-transfer-tests/\(folder)"))
    }

    private func model() -> WallpaperViewModel {
        let model = WallpaperViewModel(persistsWallpapers: false)
        model.connectedDisplays = { [displays] in displays }
        model.audioOutputEnabled = false
        model.wallpapers = ["1": wallpaper("a"), "2": wallpaper("b"), "3": wallpaper("c")]
        model.refreshDisplayLayout()
        return model
    }

    private func titles(_ model: WallpaperViewModel) -> [String] {
        ["1", "2", "3"].map { model.wallpaper(for: $0).project.title }
    }

    func testTargetsAreTheOtherDisplaysOutsideGroupsUnderAWallpaperPerDisplay() {
        let model = model()
        XCTAssertEqual(model.transferTargets(from: "1"), ["2", "3"])
        model.addCloneGroup(["2", "3"])
        XCTAssertEqual(model.transferTargets(from: "1"), [], "clone members aren't targets")
        XCTAssertEqual(model.transferTargets(from: "2"), ["1"], "a clone's wallpaper can be copied out")
        model.removeGroup(containing: "2")
        model.setLayout(.clone)
        XCTAssertEqual(model.transferTargets(from: "1"), [], "only under a wallpaper per display")
        model.setLayout(.perDisplay)
        model.wallpapers.removeValue(forKey: "1")
        XCTAssertEqual(model.transferTargets(from: "1"), [], "a display without a wallpaper has nothing to copy")
    }

    func testCopyToSetsTheWallpaperAndItsDisplayOptions() {
        let model = model()
        let zoomed = WallpaperDisplayOptions(offsetX: 0.25, zoom: 2)
        model.setDisplayOptions(zoomed, for: wallpaper("a"), on: ["1"])
        model.copyWallpaper(from: "1", to: "3")
        XCTAssertEqual(titles(model), ["a", "b", "a"])
        XCTAssertEqual(model.displayOptions(on: "3"), zoomed)
        XCTAssertEqual(model.displayOptions(on: "1"), zoomed, "the source keeps its own")
    }

    func testSwapWithExchangesTheWallpapersWithTheirOptions() {
        let model = model()
        let zoomed = WallpaperDisplayOptions(zoom: 2), flipped = WallpaperDisplayOptions(flipHorizontal: true)
        model.setDisplayOptions(zoomed, for: wallpaper("a"), on: ["1"])
        model.setDisplayOptions(flipped, for: wallpaper("b"), on: ["2"])
        model.swapWallpapers("1", "2")
        XCTAssertEqual(titles(model), ["b", "a", "c"])
        XCTAssertEqual(model.displayOptions(on: "1"), flipped)
        XCTAssertEqual(model.displayOptions(on: "2"), zoomed)
    }

    func testSwapOfOneWallpaperExchangesItsTwoSetsOfOptions() {
        let model = model()
        model.setWallpaper(wallpaper("a"), for: "2")
        let zoomed = WallpaperDisplayOptions(zoom: 2), flipped = WallpaperDisplayOptions(flipHorizontal: true)
        model.setDisplayOptions(zoomed, for: wallpaper("a"), on: ["1"])
        model.setDisplayOptions(flipped, for: wallpaper("a"), on: ["2"])
        model.swapWallpapers("1", "2")
        XCTAssertEqual(model.displayOptions(on: "1"), flipped)
        XCTAssertEqual(model.displayOptions(on: "2"), zoomed)
    }

    func testSwapWithADisplayWithoutAWallpaperMovesIt() {
        let model = model()
        model.wallpapers.removeValue(forKey: "3")
        model.swapWallpapers("1", "3")
        XCTAssertNil(model.wallpapers["1"], "the display swapped with one without a wallpaper has none")
        XCTAssertEqual(model.wallpapers["3"]?.project.title, "a")
    }
}
