import XCTest
@testable import OpenWallpaperEngine

/// Settings › Library Folders: the folders are kept, and the Installed list scans them beside the
/// storage folder and follows their changes.
@MainActor
final class LibraryFoldersTests: XCTestCase {
    private var root: URL!
    private var storage: URL!
    private var extra: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "owe-library-folders-\(UUID().uuidString)")
        storage = root.appending(path: "storage")
        extra = root.appending(path: "extra")
        for folder in [storage!, extra!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        suiteName = "owe-library-folders-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try FileManager.default.removeItem(at: root)
    }

    private func writeProject(in folder: URL, _ name: String, title: String) throws {
        let item = folder.appending(path: name)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        let project: [String: Any] = ["title": title, "type": "scene", "file": "scene.json"]
        try JSONSerialization.data(withJSONObject: project).write(to: item.appending(path: "project.json"))
    }

    func testAddsRemovesAndRejectsTheStorageFolderAndDuplicates() throws {
        let folders = LibraryFolders(defaults: defaults)
        try folders.add(extra, storage: storage)
        XCTAssertEqual(folders.folders, [extra.standardizedFileURL])
        XCTAssertThrowsError(try folders.add(extra.appending(path: "/"), storage: storage)) {
            XCTAssertEqual($0 as? LibraryFolders.AddFailure, .alreadyAdded)
        }
        XCTAssertThrowsError(try folders.add(storage, storage: storage)) {
            XCTAssertEqual($0 as? LibraryFolders.AddFailure, .isStorage)
        }
        folders.remove(extra)
        XCTAssertEqual(folders.folders, [])
    }

    func testNamesTheLibraryFolderAWallpaperComesFrom() throws {
        let folders = LibraryFolders(defaults: defaults)
        try folders.add(extra, storage: storage)
        XCTAssertEqual(folders.folder(containing: extra.appending(path: "123")), extra.standardizedFileURL)
        XCTAssertNil(folders.folder(containing: storage.appending(path: "123")))
    }

    func testListsTheLibraryFoldersWallpapersAfterTheStorageFolders() throws {
        try writeProject(in: storage, "100", title: "Stored")
        try writeProject(in: extra, "200", title: "Extra")
        try writeProject(in: extra, "My Scene", title: "Local")
        // Not a wallpaper folder: a library folder may hold anything, so it isn't listed as invalid.
        try FileManager.default.createDirectory(at: extra.appending(path: "Notes"), withIntermediateDirectories: true)

        let wallpapers = InstalledLibraryCache().wallpapers(in: storage, libraryFolders: [extra], hiding: [])
        XCTAssertEqual(wallpapers.first?.project.title, "Stored")
        XCTAssertEqual(Set(wallpapers.map(\.project.title)), ["Stored", "Extra", "Local"])
    }

    func testAWorkshopItemInBothFoldersIsListedOnceFromStorage() throws {
        try writeProject(in: storage, "300", title: "Stored copy")
        try writeProject(in: extra, "300", title: "Other copy")
        let wallpapers = InstalledLibraryCache().wallpapers(in: storage, libraryFolders: [extra], hiding: [])
        XCTAssertEqual(wallpapers.map(\.project.title), ["Stored copy"])
    }

    func testAMissingLibraryFolderIsSkipped() throws {
        try writeProject(in: storage, "100", title: "Stored")
        let wallpapers = InstalledLibraryCache().wallpapers(in: storage, libraryFolders: [root.appending(path: "gone")],
                                                            hiding: [])
        XCTAssertEqual(wallpapers.map(\.project.title), ["Stored"])
    }

    func testWallpapersAddedToALibraryFolderArriveAndRemovedOnesLeave() throws {
        let cache = InstalledLibraryCache()
        var arrived: [String] = []
        cache.onArrival = { arrived.append($0.project.title) }
        XCTAssertTrue(cache.wallpapers(in: storage, libraryFolders: [extra], hiding: []).isEmpty)
        try writeProject(in: extra, "400", title: "New")
        XCTAssertEqual(cache.wallpapers(in: storage, libraryFolders: [extra], hiding: []).map(\.project.title), ["New"])
        XCTAssertEqual(arrived, ["New"])
        try FileManager.default.removeItem(at: extra.appending(path: "400"))
        XCTAssertTrue(cache.wallpapers(in: storage, libraryFolders: [extra], hiding: []).isEmpty)
    }

    func testTheWatcherReportsAWallpaperAddedToALibraryFolder() throws {
        let watcher = LibraryFolderWatcher()
        let changed = expectation(description: "library folder changed")
        changed.assertForOverFulfill = false
        watcher.onChange = { changed.fulfill() }
        watcher.watch([extra])
        defer { watcher.stop() }
        XCTAssertEqual(watcher.watchedFolders, [extra.standardizedFileURL])
        try writeProject(in: extra, "500", title: "Dropped in")
        wait(for: [changed], timeout: 5)
    }

    func testTheWatcherDoesNotCreateAMissingFolder() {
        let watcher = LibraryFolderWatcher()
        let missing = root.appending(path: "unmounted")
        watcher.watch([missing])
        XCTAssertTrue(watcher.watchedFolders.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path(percentEncoded: false)))
    }
}
