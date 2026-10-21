import XCTest
@testable import OpenWallpaperEngine

/// The Installed tab's cached library lists what `InstalledLibrary` lists and follows changes on disk.
final class InstalledLibraryCacheTests: XCTestCase {
    private var library: URL!

    override func setUpWithError() throws {
        library = FileManager.default.temporaryDirectory.appending(path: "owe-library-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: library)
    }

    private func writeProject(_ id: String, title: String, type: String? = "scene",
                              properties: [String: Any] = [:], modified: Date = Date()) throws {
        let folder = library.appending(path: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var project: [String: Any] = ["title": title, "file": "scene.json"]
        if let type { project["type"] = type }
        if !properties.isEmpty { project["general"] = ["properties": properties] }
        let file = folder.appending(path: "project.json")
        try JSONSerialization.data(withJSONObject: project).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }

    private func titles(_ wallpapers: [WEWallpaper]) -> Set<String> {
        Set(wallpapers.map(\.project.title))
    }

    func testListsWhatTheLibraryLists() throws {
        try writeProject("1", title: "Scene")
        try writeProject("2", title: "Asset", type: nil)
        try writeProject("3", title: "Dependency")
        let cache = InstalledLibraryCache()
        let cached = cache.wallpapers(in: library, hiding: ["3"])
        let listed = InstalledLibrary.wallpapers(in: library, hiding: ["3"])
        XCTAssertEqual(titles(cached), titles(listed))
        XCTAssertEqual(titles(cached), ["Scene"])
    }

    func testReportsOnlyWallpapersThatArriveAfterTheFirstPass() throws {
        try writeProject("1", title: "Existing")
        let cache = InstalledLibraryCache()
        var arrived: [String] = []
        cache.onArrival = { arrived.append($0.project.title) }
        _ = cache.wallpapers(in: library, hiding: [])
        try writeProject("2", title: "Downloaded")
        _ = cache.wallpapers(in: library, hiding: [])
        _ = cache.wallpapers(in: library, hiding: [])
        XCTAssertEqual(arrived, ["Downloaded"])
    }

    func testFollowsAddedRewrittenAndRemovedWallpapers() throws {
        let cache = InstalledLibraryCache()
        try writeProject("1", title: "Before", modified: Date(timeIntervalSinceNow: -60))
        XCTAssertEqual(titles(cache.wallpapers(in: library, hiding: [])), ["Before"])

        try writeProject("1", title: "After", modified: Date())
        try writeProject("2", title: "New")
        XCTAssertEqual(titles(cache.wallpapers(in: library, hiding: [])), ["After", "New"])

        try FileManager.default.removeItem(at: library.appending(path: "1"))
        XCTAssertEqual(titles(cache.wallpapers(in: library, hiding: [])), ["New"])
    }

    func testCustomizablePropertiesFollowTheProject() throws {
        let cache = InstalledLibraryCache()
        try writeProject("1", title: "Plain", properties: ["schemecolor": ["value": "0 0 0"]],
                         modified: Date(timeIntervalSinceNow: -60))
        var wallpaper = try XCTUnwrap(cache.wallpapers(in: library, hiding: []).first)
        XCTAssertFalse(cache.hasCustomizableProperties(wallpaper))

        try writeProject("1", title: "Plain", properties: ["speed": ["value": 1]], modified: Date())
        wallpaper = try XCTUnwrap(cache.wallpapers(in: library, hiding: []).first)
        XCTAssertTrue(cache.hasCustomizableProperties(wallpaper))
    }

    func testSizeIsMeasuredAgainWhenFilesComeOrGo() throws {
        let cache = InstalledLibraryCache()
        try writeProject("1", title: "Sized")
        let folder = library.appending(path: "1")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
                                              ofItemAtPath: folder.path)
        var wallpaper = try XCTUnwrap(cache.wallpapers(in: library, hiding: []).first)
        let before = cache.size(of: wallpaper)

        try Data(count: 256 * 1024).write(to: folder.appending(path: "scene.pkg"))
        wallpaper = try XCTUnwrap(cache.wallpapers(in: library, hiding: []).first)
        XCTAssertGreaterThan(cache.size(of: wallpaper), before)
    }
}
