import XCTest
@testable import OpenWallpaperEngine

/// Only a display never connected before gets wallpapers turned on when the displays change; one
/// the user turned off stays off through wake, resolution and arrangement changes.
@MainActor
final class KnownDisplaysTests: XCTestCase {
    private var enabledBefore: Any?

    override func setUp() async throws {
        enabledBefore = UserDefaults.app.object(forKey: "EnabledScreens")
    }

    override func tearDown() async throws {
        UserDefaults.app.set(enabledBefore, forKey: "EnabledScreens")
    }

    func testOnlyDisplaysNeverSeenAreNew() {
        var known = KnownDisplays(["1"])
        XCTAssertEqual(known.recordConnected(["1", "2"]), ["2"])
        XCTAssertEqual(known.recordConnected(["1", "2"]), [])
        XCTAssertEqual(known.recordConnected(["3"]), ["3"], "a disconnected display stays known")
        XCTAssertEqual(known.screenIds, ["1", "2", "3"])
    }

    func testADisplayTurnedOffStaysOff() {
        let model = WallpaperViewModel(persistsWallpapers: false)
        model.enabledScreens = []
        XCTAssertEqual(model.enableNewDisplays(["1", "2"]), ["1", "2"])
        XCTAssertEqual(model.enabledScreens, ["1", "2"])
        model.toggleScreen("2")
        XCTAssertEqual(model.enableNewDisplays(["1", "2"]), [], "wake or a resolution change")
        XCTAssertEqual(model.enabledScreens, ["1"])
        XCTAssertEqual(model.enableNewDisplays(["1", "2", "3"]), ["3"])
        XCTAssertEqual(model.enabledScreens, ["1", "3"])
    }

    func testTogglingADisplayTellsOnlyThatDisplay() {
        let model = WallpaperViewModel(persistsWallpapers: false)
        model.enabledScreens = ["1", "2"]
        var told: [String] = []
        model.onScreenEnabledChange = { told.append($0) }
        model.toggleScreen("2")
        XCTAssertEqual(told, ["2"])
        XCTAssertEqual(model.enabledScreens, ["1"])
    }
}
