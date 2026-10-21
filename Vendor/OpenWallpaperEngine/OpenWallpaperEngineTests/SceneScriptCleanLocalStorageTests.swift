import XCTest
@testable import OpenWallpaperEngine

/// The Wallpaper Editor's Clean Local Storage (WE's command): every store of one wallpaper is
/// forgotten, in memory and on disk, and the other wallpapers' stay.
final class SceneScriptCleanLocalStorageTests: XCTestCase {
    func testRemovingAWallpapersStoresLeavesTheOthers() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "CleanLocalStorage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SceneScriptStorage(directory: directory, notificationCenter: NotificationCenter())
        let a = SceneScriptIdentity(wallpaperID: "a", screenID: "1"), b = SceneScriptIdentity(wallpaperID: "b", screenID: "1")
        XCTAssertFalse(storage.hasStores(of: "a"))
        XCTAssertTrue(storage.setValue("1", forKey: "k", in: .global, of: a))
        XCTAssertTrue(storage.setValue("2", forKey: "k", in: .screen, of: a))
        XCTAssertTrue(storage.setValue("3", forKey: "k", in: .global, of: b))
        XCTAssertTrue(storage.hasStores(of: "a"), "in memory before a flush")
        storage.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.storeFolder(for: "a").path))
        try storage.removeStores(of: "a")
        XCTAssertFalse(storage.hasStores(of: "a"))
        XCTAssertNil(storage.value(forKey: "k", in: .global, of: a))
        XCTAssertNil(storage.value(forKey: "k", in: .screen, of: a))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.storeFolder(for: "a").path))
        XCTAssertEqual(storage.value(forKey: "k", in: .global, of: b), "3")
        storage.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.storeFolder(for: "a").path), "nothing writes it back")
    }
}
