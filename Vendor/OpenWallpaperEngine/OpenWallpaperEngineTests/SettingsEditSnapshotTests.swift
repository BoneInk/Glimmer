import Combine
import XCTest
@testable import OpenWallpaperEngine

/// Settings' OK and Cancel: changes apply as they are made, Cancel (or closing the window) goes
/// back to the settings the window opened with, OK keeps them; a quality preset is one change.
@MainActor
final class SettingsEditSnapshotTests: XCTestCase {
    private var storedBefore: Data?

    override func setUp() async throws {
        storedBefore = UserDefaults.app.data(forKey: GlobalSettingsViewModel.defaultsKey)
    }

    override func tearDown() async throws {
        UserDefaults.app.set(storedBefore, forKey: GlobalSettingsViewModel.defaultsKey)
    }

    func testCancelRestoresTheSettingsTheWindowOpenedWith() {
        let model = GlobalSettingsViewModel(followsLaunch: false)
        let opened = model.settings
        model.beginEditing()
        XCTAssertFalse(model.hasUnconfirmedEdits)
        model.settings.fps = opened.fps == 30 ? 45 : 30
        XCTAssertTrue(model.hasUnconfirmedEdits, "the Edited badge shows")
        model.beginEditing() // refocusing the window keeps the first snapshot
        model.reset()
        XCTAssertEqual(model.settings, opened)
        XCTAssertNil(model.editSnapshot)
        XCTAssertEqual(GlobalSettingsViewModel.loadSettings(from: UserDefaults.app.data(forKey: GlobalSettingsViewModel.defaultsKey),
                                                            backupDirectory: FileManager.default.temporaryDirectory),
                       opened, "the restored settings are stored")
    }

    func testOKKeepsTheChanges() {
        let model = GlobalSettingsViewModel(followsLaunch: false)
        model.beginEditing()
        let fps: Double = model.settings.fps == 30 ? 45 : 30
        model.settings.fps = fps
        model.commitEdits()
        XCTAssertFalse(model.hasUnconfirmedEdits)
        model.reset() // the window closing after OK
        XCTAssertEqual(model.settings.fps, fps)
    }

    /// Without a snapshot, stored data that can't be read is never replaced by the defaults.
    func testResetKeepsTheSettingsWhenTheStoredOnesCantBeRead() {
        let model = GlobalSettingsViewModel(followsLaunch: false)
        model.settings.fps = model.settings.fps == 30 ? 45 : 30
        let inUse = model.settings
        let corrupt = Data("not settings".utf8)
        UserDefaults.app.set(corrupt, forKey: GlobalSettingsViewModel.defaultsKey)
        model.reset()
        XCTAssertEqual(model.settings, inUse)
        XCTAssertEqual(UserDefaults.app.data(forKey: GlobalSettingsViewModel.defaultsKey), corrupt)
    }

    func testAQualityPresetIsOneChange() {
        let model = GlobalSettingsViewModel(followsLaunch: false)
        model.settings = GlobalSettings()
        var changes = 0
        let watch = model.$settings.dropFirst().sink { _ in changes += 1 }
        model.setQuality(.low)
        watch.cancel()
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(model.settings, GlobalSettingsViewModel.applying(.low, to: GlobalSettings()))
        XCTAssertFalse(model.settings.reflections)
        XCTAssertEqual(model.settings.particleBudget, .low)
    }
}
