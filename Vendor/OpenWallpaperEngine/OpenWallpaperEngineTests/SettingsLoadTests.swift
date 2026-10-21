import XCTest
@testable import OpenWallpaperEngine

/// Stored settings that can't be read are backed up before the defaults replace them, and a bad
/// key only loses that one setting.
final class SettingsLoadTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "owe-settings-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    func testUnreadableSettingsAreBackedUpBeforeTheDefaultsAreUsed() throws {
        let stored = Data("not settings".utf8)
        let now = Date(timeIntervalSince1970: 0)
        let loaded: GlobalSettings = GlobalSettingsViewModel.loadSettings(from: stored, backupDirectory: folder, now: now)
        XCTAssertEqual(loaded, GlobalSettings())
        let backups: [URL] = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        let backup: URL = try XCTUnwrap(backups.first)
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("settings.corrupt-"), backup.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: backup), stored)
    }

    func testABadKeyKeepsTheOtherSettings() throws {
        let stored = Data(#"{"fps": "fast", "autoStart": true, "reflection": false}"#.utf8)
        let loaded: GlobalSettings = GlobalSettingsViewModel.loadSettings(from: stored, backupDirectory: folder)
        XCTAssertEqual(loaded.fps, GlobalSettings().fps)
        XCTAssertTrue(loaded.autoStart)
        XCTAssertFalse(loaded.reflections)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "nothing to back up")
    }

    func testNoStoredSettingsUseTheDefaults() {
        XCTAssertEqual(GlobalSettingsViewModel.loadSettings(from: nil, backupDirectory: folder), GlobalSettings())
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
}
