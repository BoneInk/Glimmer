import XCTest
@testable import OpenWallpaperEngine

/// Settings › General › Show in Dock and Show in Menu Bar.
final class AppPresenceSettingsTests: XCTestCase {
    func testDefaultsKeepTheMenuBarItemAndADockIconOnlyWithAWindow() throws {
        XCTAssertFalse(GlobalSettings().showInDock)
        XCTAssertTrue(GlobalSettings().showInMenuBar)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.showInDock)
        XCTAssertTrue(decoded.showInMenuBar)
    }

    func testBothOffRoundTrips() throws {
        var settings = GlobalSettings()
        settings.showInDock = false
        settings.showInMenuBar = false
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(decoded.showInDock)
        XCTAssertFalse(decoded.showInMenuBar)
    }

    func testRestoreDefaultsOnGeneralCoversThem() {
        var settings = GlobalSettings()
        settings.showInDock = true
        settings.showInMenuBar = false
        let changed = SettingsTab.general.fields.filter { $0.isChanged(settings) }
        XCTAssertEqual(changed.count, 2)
    }
}
