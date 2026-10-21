import XCTest
@testable import OpenWallpaperEngine

/// A library whose wallpaper folders are symbolic links to folders elsewhere (a library made of
/// links into another one): the wallpapers run from the folders the links point to, so every
/// listing of their files works (Foundation's URL listings don't follow a link they start from),
/// and deleting one removes the link, never the folder it points to.
final class InstalledLibraryLinkTests: XCTestCase {
    private var root: URL!
    /// Where the wallpaper folders really are.
    private var storage: URL!
    /// The library: links to `storage`'s folders.
    private var library: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "owe-library-links-\(UUID().uuidString)")
        storage = root.appending(path: "storage", directoryHint: .isDirectory)
        library = root.appending(path: "library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    /// A scene wallpaper `id` in the storage folder with a sound file, linked into the library.
    @discardableResult
    private func linkedWallpaper(_ id: String) throws -> (folder: URL, link: URL) {
        let folder = storage.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "sounds"), withIntermediateDirectories: true)
        let project: [String: Any] = ["title": "Linked \(id)", "type": "scene", "file": "scene.json"]
        try JSONSerialization.data(withJSONObject: project).write(to: folder.appending(path: "project.json"))
        try Data("{}".utf8).write(to: folder.appending(path: "scene.json"))
        try Data([0]).write(to: folder.appending(path: "sounds/music.mp3"))
        let link = library.appending(path: id, directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        return (folder, link)
    }

    private func canonical(_ url: URL) throws -> String {
        try XCTUnwrap(ContainedPath.canonical(url))
    }

    func testALinkedWallpaperRunsFromTheFolderItPointsTo() throws {
        let (folder, _) = try linkedWallpaper("1001")
        let listed = try XCTUnwrap(InstalledLibrary.wallpapers(in: library, hiding: []).first)
        XCTAssertEqual(listed.project.title, "Linked 1001")
        XCTAssertEqual(listed.wallpaperDirectory.path, try canonical(folder))
        let cached = try XCTUnwrap(InstalledLibraryCache().wallpapers(in: library, hiding: []).first)
        XCTAssertEqual(cached.wallpaperDirectory, listed.wallpaperDirectory)
        // A selection saved with the link's path is followed too.
        let saved = WEWallpaper(using: listed.project, where: library.appending(path: "1001"))
        let decoded = try XCTUnwrap(WEWallpaper(rawValue: saved.rawValue))
        XCTAssertEqual(decoded.wallpaperDirectory, listed.wallpaperDirectory)
    }

    /// What the bug report saw: "Loading snapshot: can't read <id>" (Not a directory), so a linked
    /// scene never had a loading snapshot; its sounds weren't found and its size was 0 either.
    func testALinkedWallpapersFilesAreListed() async throws {
        let (folder, _) = try linkedWallpaper("1002")
        let wallpaper = try XCTUnwrap(InstalledLibrary.wallpapers(in: library, hiding: []).first)
        // File IO, off the main thread as the app does it.
        let found: (key: String?, real: String?, audio: Bool, size: Int) = await Task.detached {
            (SceneLoadingSnapshotStore.contentKey(for: wallpaper.wallpaperDirectory),
             SceneLoadingSnapshotStore.contentKey(for: folder),
             SceneAudioPresence.hasAudio(in: wallpaper.wallpaperDirectory), wallpaper.wallpaperSize)
        }.value
        XCTAssertNotNil(found.key, "the snapshot store reads the folder")
        XCTAssertEqual(found.key, found.real)
        XCTAssertTrue(found.audio, "its sound is found")
        XCTAssertGreaterThan(found.size, 0)
    }

    /// A library folder that is itself a link lists its wallpapers.
    func testALinkedLibraryIsListed() throws {
        try linkedWallpaper("1003")
        let linkedLibrary = root.appending(path: "linked-library", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: linkedLibrary, withDestinationURL: library)
        XCTAssertEqual(InstalledLibrary.wallpapers(in: linkedLibrary, hiding: []).map(\.project.title), ["Linked 1003"])
        XCTAssertEqual(InstalledLibraryCache().wallpapers(in: linkedLibrary, hiding: []).map(\.project.title), ["Linked 1003"])
    }

    /// A Workshop dependency linked into the library is found through the folder it points to.
    func testALinkedDependencyResolvesToItsFolder() throws {
        let (folder, _) = try linkedWallpaper("2084198056")
        let resolver = WorkshopAssetResolver(roots: [library])
        let item = try XCTUnwrap(resolver.itemDirectory(for: "2084198056"))
        XCTAssertEqual(item.path, try canonical(folder))
        XCTAssertNoThrow(try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil))
    }

    func testDeletingALinkedWallpaperRemovesOnlyTheLink() async throws {
        let (folder, link) = try linkedWallpaper("1004")
        let wallpaper = try XCTUnwrap(InstalledLibrary.wallpapers(in: library, hiding: []).first)
        let directory = wallpaper.wallpaperDirectory
        let libraries: [URL] = [library]
        let result: (deleted: [URL], failure: WallpaperDeletion.Failure?) = await Task.detached {
            WallpaperDeletion.delete([directory], toTrash: false, libraries: libraries)
        }.value
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.deleted, [directory])
        XCTAssertFalse(ContainedPath.isSymbolicLink(link), "the link is gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "project.json").path(percentEncoded: false)),
                      "the folder it pointed to is kept")
    }
}
