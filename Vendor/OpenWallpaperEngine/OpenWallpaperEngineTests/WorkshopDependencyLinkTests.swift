import XCTest
@testable import OpenWallpaperEngine

/// Dependency links and package extraction stay inside the wallpaper's folder and leave the
/// `workshop/<id>/` paths to the dependency resolver.
final class WorkshopDependencyLinkTests: XCTestCase {
    private var root: URL!
    private var wallpaper: URL!
    private var item: URL!
    private var outside: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appending(path: "owe-dependency-links-\(UUID().uuidString)")
        wallpaper = root.appending(path: "1000000001")
        item = root.appending(path: "2000000002")
        outside = root.appending(path: "outside")
        for folder in [wallpaper!, item.appending(path: "materials"), outside!] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data(#"{"file":"scene.json","title":"T","type":"scene"}"#.utf8).write(to: wallpaper.appending(path: "project.json"))
    }

    override func tearDownWithError() throws {
        try fm.removeItem(at: root)
    }

    /// A PKGV archive holding `files`.
    private func package(_ files: [(String, Data)]) -> Data {
        func u32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
        let magic = Data("PKGV0001".utf8)
        var header = u32(magic.count) + magic + u32(files.count)
        var body = Data()
        for (path, contents) in files {
            let name = Data(path.utf8)
            header += u32(name.count) + name + u32(body.count) + u32(contents.count)
            body += contents
        }
        return header + body
    }

    private var materialsSource: URL { item.appending(path: "materials") }
    private var linkPath: URL { wallpaper.appending(path: "materials/workshop/2000000002") }

    private func outsideContents() throws -> [String] {
        try fm.contentsOfDirectory(atPath: outside.path)
    }

    func testCreatesTheLinkAndIsIdempotent() throws {
        XCTAssertTrue(WorkshopDependencyResolver.linkDependency(id: "2000000002", category: "materials",
                                                                to: materialsSource, inItemAt: wallpaper))
        XCTAssertTrue(WorkshopDependencyResolver.linkDependency(id: "2000000002", category: "materials",
                                                                to: materialsSource, inItemAt: wallpaper))
        XCTAssertTrue(ContainedPath.isSymbolicLink(linkPath))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: linkPath.path), materialsSource.path)
    }

    func testLinksInstalledDependenciesNamedByTheProject() throws {
        try Data(#"{"file":"scene.json","title":"T","type":"scene","dependency":"2000000002"}"#.utf8)
            .write(to: wallpaper.appending(path: "project.json"))
        WorkshopDependencyResolver.linkInstalledDependencies(inItemAt: wallpaper, resolver: WorkshopAssetResolver(roots: [root]))
        XCTAssertTrue(ContainedPath.isSymbolicLink(linkPath))
    }

    func testRefusesALinkedCategoryFolder() throws {
        try fm.createSymbolicLink(at: wallpaper.appending(path: "materials"), withDestinationURL: outside)
        XCTAssertFalse(WorkshopDependencyResolver.linkDependency(id: "2000000002", category: "materials",
                                                                 to: materialsSource, inItemAt: wallpaper))
        XCTAssertEqual(try outsideContents(), [])
    }

    func testRefusesALinkedWorkshopFolder() throws {
        try fm.createDirectory(at: wallpaper.appending(path: "materials"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: wallpaper.appending(path: "materials/workshop"), withDestinationURL: outside)
        XCTAssertFalse(WorkshopDependencyResolver.linkDependency(id: "2000000002", category: "materials",
                                                                 to: materialsSource, inItemAt: wallpaper))
        XCTAssertEqual(try outsideContents(), [])
    }

    func testRefusesUnusableFolderNames() {
        for category in ["", ".", "..", "a/b"] {
            XCTAssertFalse(WorkshopDependencyResolver.linkDependency(id: "2000000002", category: category,
                                                                     to: materialsSource, inItemAt: wallpaper))
        }
        XCTAssertFalse(WorkshopDependencyResolver.linkDependency(id: "../x", category: "materials",
                                                                 to: materialsSource, inItemAt: wallpaper))
    }

    func testReplacesAStaleLinkWithoutTouchingItsTarget() throws {
        try Data("original".utf8).write(to: outside.appending(path: "keep.txt"))
        try fm.createDirectory(at: linkPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkPath, withDestinationURL: outside)
        XCTAssertTrue(WorkshopDependencyResolver.linkDependency(id: "2000000002", category: "materials",
                                                                to: materialsSource, inItemAt: wallpaper))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: linkPath.path), materialsSource.path)
        XCTAssertEqual(try outsideContents(), ["keep.txt"])
    }

    func testKeepsAFolderTheWallpaperShips() throws {
        try fm.createDirectory(at: linkPath, withIntermediateDirectories: true)
        XCTAssertTrue(WorkshopDependencyResolver.linkDependency(id: "2000000002", category: "materials",
                                                                to: materialsSource, inItemAt: wallpaper))
        XCTAssertFalse(ContainedPath.isSymbolicLink(linkPath))
    }

    func testConverterExtractsBundledWorkshopItemFiles() throws {
        try package([("scene.json", Data("{}".utf8)),
                     ("materials/a.json", Data("{}".utf8)),
                     ("materials/workshop/2000000002/b.json", Data("{}".utf8)),
                     ("effects\\workshop\\3000000003\\e\\effect.json", Data("{}".utf8))])
            .write(to: wallpaper.appending(path: "scene.pkg"))

        let manifest = try XCTUnwrap(WallpaperPackageConverter.convertIfNeeded(wallpaperDirectory: wallpaper))
        // Wallpaper Engine reads the asset-pack files the package bundles, so they are extracted.
        XCTAssertEqual(manifest.extractedFiles.sorted(),
                       ["effects/workshop/3000000003/e/effect.json", "materials/a.json",
                        "materials/workshop/2000000002/b.json", "scene.json"])
        XCTAssertEqual(manifest.warnings, [])
        XCTAssertEqual(manifest.dependencyEntries, [])
        XCTAssertTrue(fm.fileExists(atPath: wallpaper.appending(path: "materials/workshop/2000000002/b.json").path))
        XCTAssertTrue(fm.fileExists(atPath: wallpaper.appending(path: "effects/workshop/3000000003/e/effect.json").path))
        XCTAssertEqual(WorkshopDependencyResolver.referencedWorkshopIds(inItemAt: wallpaper), ["2000000002", "3000000003"])
    }
}
