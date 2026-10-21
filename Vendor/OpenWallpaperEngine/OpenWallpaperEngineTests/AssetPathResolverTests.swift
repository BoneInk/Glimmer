import XCTest
@testable import OpenWallpaperEngine

/// Asset paths resolve to regular files inside the folder they are looked up in.
final class AssetPathResolverTests: XCTestCase {
    private var root: URL!
    private var wallpaper: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "owe-assetpath-\(UUID().uuidString)")
        wallpaper = root.appending(path: "123456")
        outside = root.appending(path: "outside")
        let fm = FileManager.default
        try fm.createDirectory(at: wallpaper.appending(path: "materials/sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("material".utf8).write(to: wallpaper.appending(path: "materials/sub/a.json"))
        try Data("other".utf8).write(to: outside.appending(path: "other.json"))
        try fm.createSymbolicLink(at: wallpaper.appending(path: "materials/linked.json"),
                                  withDestinationURL: outside.appending(path: "other.json"))
        try fm.createSymbolicLink(at: wallpaper.appending(path: "materials/inner.json"),
                                  withDestinationURL: wallpaper.appending(path: "materials/sub/a.json"))
        try fm.createSymbolicLink(at: wallpaper.appending(path: "linkeddir"), withDestinationURL: outside)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testSanitizesRelativePaths() {
        XCTAssertEqual(AssetPathResolver.sanitize("materials\\sub\\a.json"), "materials/sub/a.json")
        XCTAssertEqual(AssetPathResolver.sanitize("./materials//a.json"), "materials/a.json")
        XCTAssertEqual(AssetPathResolver.sanitize("scene.json"), "scene.json")
        XCTAssertNil(AssetPathResolver.sanitize(""))
        XCTAssertNil(AssetPathResolver.sanitize("."))
        XCTAssertNil(AssetPathResolver.sanitize("/etc/hosts"))
        XCTAssertNil(AssetPathResolver.sanitize("\\\\server\\share\\a.json"))
        XCTAssertNil(AssetPathResolver.sanitize("C:\\Windows\\a.json"))
        XCTAssertNil(AssetPathResolver.sanitize("c:a.json"))
        XCTAssertNil(AssetPathResolver.sanitize("materials/../../a.json"))
        XCTAssertNil(AssetPathResolver.sanitize("..\\a.json"))
        XCTAssertNil(AssetPathResolver.sanitize("a\0b"))
        XCTAssertEqual(AssetPathResolver.sanitize("materials/..a.json"), "materials/..a.json")
    }

    func testReadsAFileInsideTheFolder() throws {
        XCTAssertEqual(try AssetPathResolver.data("materials/sub/a.json", in: wallpaper), Data("material".utf8))
        XCTAssertEqual(try AssetPathResolver.data("materials\\sub\\a.json", in: wallpaper), Data("material".utf8))
        // A link that stays inside the folder is fine.
        XCTAssertEqual(try AssetPathResolver.data("materials/inner.json", in: wallpaper), Data("material".utf8))
    }

    func testRefusesPathsLeavingTheFolder() throws {
        XCTAssertNil(try AssetPathResolver.data("../outside/other.json", in: wallpaper))
        XCTAssertNil(try AssetPathResolver.data(outside.appending(path: "other.json").path, in: wallpaper))
        XCTAssertNil(try AssetPathResolver.data("materials/linked.json", in: wallpaper))
        XCTAssertNil(try AssetPathResolver.data("linkeddir/other.json", in: wallpaper))
    }

    func testRefusesFoldersAndMissingFiles() throws {
        XCTAssertNil(try AssetPathResolver.data("materials/sub", in: wallpaper))
        XCTAssertNil(try AssetPathResolver.data("materials/missing.json", in: wallpaper))
        XCTAssertNil(AssetPathResolver.fileURL("materials", in: wallpaper))
    }

    func testFolderThatIsItselfALinkIsJudgedByItsTarget() throws {
        let link = root.appending(path: "library-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: wallpaper)
        XCTAssertEqual(try AssetPathResolver.data("materials/sub/a.json", in: link), Data("material".utf8))
        XCTAssertNil(try AssetPathResolver.data("materials/linked.json", in: link))
    }

    func testReadRegularFileRefusesFolders() {
        XCTAssertThrowsError(try AssetPathResolver.readRegularFile(at: wallpaper.appending(path: "materials")))
    }

    func testWEAssetsLookupStaysInsideTheAssetsFolder() {
        XCTAssertNotNil(WallpaperEngineAssets.locate(["missing.json", "materials/sub/a.json"], in: [wallpaper]))
        XCTAssertNil(WallpaperEngineAssets.locate(["materials/linked.json", "../outside/other.json"], in: [wallpaper]))
    }

    func testWorkshopLookupStaysInsideTheItemFolder() throws {
        let library = root.appending(path: "library")
        let item = library.appending(path: "2981960200")
        try FileManager.default.createDirectory(at: item.appending(path: "fonts"), withIntermediateDirectories: true)
        try Data("font".utf8).write(to: item.appending(path: "fonts/x.ttf"))
        try FileManager.default.createSymbolicLink(at: item.appending(path: "fonts/y.ttf"),
                                                   withDestinationURL: outside.appending(path: "other.json"))
        let resolver = WorkshopAssetResolver(roots: [library])
        XCTAssertEqual(resolver.data(for: "fonts/workshop/2981960200/x.ttf"), Data("font".utf8))
        XCTAssertNil(resolver.url(for: "fonts/workshop/2981960200/y.ttf"))
        XCTAssertNil(resolver.url(for: "fonts/workshop/2981960200/../../outside/other.json"))
    }

    func testProjectFileMustBeARelativePath() throws {
        func decode(_ file: String) throws -> WEProject {
            let json = try JSONSerialization.data(withJSONObject: ["file": file, "title": "t", "type": "scene"])
            return try JSONDecoder().decode(WEProject.self, from: json)
        }
        XCTAssertEqual(try decode("scene.json").file, "scene.json")
        XCTAssertEqual(try decode(".\\web\\index.html").file, "web/index.html")
        XCTAssertEqual(try decode("https://example.com/v.mp4").file, "https://example.com/v.mp4")
        XCTAssertThrowsError(try decode("../other/scene.json"))
        XCTAssertThrowsError(try decode("/etc/scene.json"))
        XCTAssertThrowsError(try decode("C:\\scene.json"))
    }
}
