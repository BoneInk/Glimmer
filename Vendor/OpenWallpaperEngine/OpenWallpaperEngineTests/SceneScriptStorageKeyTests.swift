import XCTest
@testable import OpenWallpaperEngine

/// SceneScript `localStorage` is keyed on the install folder, not project.json's `workshopid`, and
/// a store an earlier version kept under the `workshopid` is adopted only when it is this
/// wallpaper's (`SceneScriptStorageKey`, `SceneScriptStorage.adoptLegacyStore`).
final class SceneScriptStorageKeyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appending(path: "owe-storage-key-\(UUID().uuidString)",
                                                                  directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    private func folder(_ name: String, create: Bool = true) throws -> URL {
        let url = root.appending(path: "library/\(name)", directoryHint: .isDirectory)
        if create { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return url
    }

    // MARK: - Key

    func testNumericFolderIsTheKey() throws {
        XCTAssertEqual(SceneScriptStorageKey.key(forWallpaperDirectory: try folder("123456")), "123456")
    }

    func testOtherFoldersAreKeyedOnTheirPath() throws {
        let named = try folder("My Wallpaper")
        let key = SceneScriptStorageKey.key(forWallpaperDirectory: named)
        XCTAssertTrue(key.hasPrefix("local-"))
        XCTAssertEqual(key, SceneScriptStorageKey.key(forWallpaperDirectory: named.appending(path: "x/..")),
                       "the path is standardized")
        XCTAssertNotEqual(key, SceneScriptStorageKey.key(forWallpaperDirectory: try folder("Other")))
        // Non-ASCII digits are not a Steam id.
        XCTAssertTrue(SceneScriptStorageKey.key(forWallpaperDirectory: try folder("١٢٣")).hasPrefix("local-"))
        XCTAssertEqual(SceneContentLoader.localWallpaperID(named), key)
    }

    // MARK: - Which legacy store to adopt

    func testMatchingSteamFolderHasNothingToMove() throws {
        XCTAssertNil(SceneScriptStorageKey.legacyKeyToAdopt(previousKey: "123456", wallpaperDirectory: try folder("123456")))
    }

    func testSteamFolderDoesNotAdoptAnotherIdsStore() throws {
        XCTAssertNil(SceneScriptStorageKey.legacyKeyToAdopt(previousKey: "999", wallpaperDirectory: try folder("123456")))
    }

    func testNamedFolderAdoptsUnclaimedWorkshopStore() throws {
        XCTAssertEqual(SceneScriptStorageKey.legacyKeyToAdopt(previousKey: "999", wallpaperDirectory: try folder("Copy")), "999")
    }

    func testNamedFolderDoesNotAdoptAStoreItsWorkshopItemCanClaim() throws {
        _ = try folder("999")
        XCTAssertNil(SceneScriptStorageKey.legacyKeyToAdopt(previousKey: "999", wallpaperDirectory: try folder("Copy")))
    }

    func testLocalPreviousKeyHasNothingToAdopt() throws {
        let named = try folder("Copy")
        let local = SceneScriptStorageKey.localKey(forWallpaperDirectory: named)
        XCTAssertNil(SceneScriptStorageKey.legacyKeyToAdopt(previousKey: local, wallpaperDirectory: named))
        XCTAssertNil(SceneScriptStorageKey.legacyKeyToAdopt(previousKey: "../x", wallpaperDirectory: named))
    }

    // MARK: - Adopting

    private func store(_ wallpaperID: String) -> SceneScriptIdentity {
        SceneScriptIdentity(wallpaperID: wallpaperID, screenID: "screen-1")
    }

    func testLegacyStoreIsCopiedOnceAndKept() throws {
        let directory = root.appending(path: "scenestorage", directoryHint: .isDirectory)
        let writer = SceneScriptStorage(directory: directory, notificationCenter: NotificationCenter())
        XCTAssertTrue(writer.setValue("1", forKey: "g", in: .global, of: store("999")))
        XCTAssertTrue(writer.setValue("2", forKey: "s", in: .screen, of: store("999")))
        writer.flush()

        let storage = SceneScriptStorage(directory: directory, notificationCenter: NotificationCenter())
        XCTAssertTrue(storage.adoptLegacyStore(from: "999", to: "local-abc"))
        XCTAssertEqual(storage.value(forKey: "g", in: .global, of: store("local-abc")), "1")
        XCTAssertEqual(storage.value(forKey: "s", in: .screen, of: store("local-abc")), "2")
        XCTAssertEqual(storage.value(forKey: "g", in: .global, of: store("999")), "1", "the legacy store stays")

        // Once the new key has a store, later launches keep it.
        XCTAssertTrue(storage.setValue("3", forKey: "g", in: .global, of: store("local-abc")))
        storage.flush()
        XCTAssertFalse(storage.adoptLegacyStore(from: "999", to: "local-abc"))
        XCTAssertEqual(storage.value(forKey: "g", in: .global, of: store("local-abc")), "3")
    }

    func testNothingIsAdoptedWithoutALegacyStoreOrOverAnExistingOne() throws {
        let directory = root.appending(path: "scenestorage", directoryHint: .isDirectory)
        let storage = SceneScriptStorage(directory: directory, notificationCenter: NotificationCenter())
        XCTAssertFalse(storage.adoptLegacyStore(from: "999", to: "local-abc"))
        XCTAssertFalse(storage.adoptLegacyStore(from: "999", to: "999"))

        XCTAssertTrue(storage.setValue("old", forKey: "k", in: .global, of: store("999")))
        XCTAssertTrue(storage.setValue("new", forKey: "k", in: .global, of: store("local-abc")))
        XCTAssertFalse(storage.adoptLegacyStore(from: "999", to: "local-abc"), "a store in memory counts")
        XCTAssertEqual(storage.value(forKey: "k", in: .global, of: store("local-abc")), "new")
    }
}
