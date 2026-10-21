import XCTest
@testable import OpenWallpaperEngine

/// WE's `assets/zcompat/scene/shaders`: fixed copies of broken Workshop shaders.
final class SceneShaderCompatTests: XCTestCase {
    private var compat: SceneShaderCompat { SceneShaderCompat(root: Fixtures.url("ZCompat/scene/shaders")) }

    func testReadsConfig() throws {
        let entry = try XCTUnwrap(compat.entry(for: "1234567890"))
        XCTAssertEqual(entry.maximumProjectId, 2_000_000_000)
        XCTAssertEqual(entry.files, ["bars.frag", "bars.vert"])
        XCTAssertNil(compat.entry(for: "999"))
        XCTAssertNil(compat.entry(for: "../web"))
    }

    func testReplacesAWorkshopItemsShaderForOlderProjects() {
        let frag = compat.replacement(forShaderPath: "shaders/workshop/1234567890/bars.frag", projectId: "1500000000")
        XCTAssertEqual(frag, Data("// fixed frag\n".utf8))
        let vert = compat.replacement(forShaderPath: "effects\\workshop\\1234567890\\fx\\shaders\\Bars.vert", projectId: nil)
        XCTAssertEqual(vert, Data("// fixed vert\n".utf8))
    }

    func testProjectsPastTheBoundKeepTheirShader() {
        XCTAssertNil(compat.replacement(forShaderPath: "shaders/workshop/1234567890/bars.frag", projectId: "2000000001"))
        XCTAssertNotNil(compat.replacement(forShaderPath: "shaders/workshop/1234567890/bars.frag", projectId: "2000000000"))
    }

    func testOnlyTheListedStagesAreReplaced() {
        XCTAssertNil(compat.replacement(forShaderPath: "shaders/workshop/1234567890/other.frag", projectId: nil))
        XCTAssertNil(compat.replacement(forShaderPath: "shaders/workshop/1234567890/bars.json", projectId: nil))
        XCTAssertNil(compat.replacement(forShaderPath: "shaders/workshop/5555555555/bars.frag", projectId: nil))
    }

    func testTheWallpapersOwnCustomShaderIsReplacedWhenItIsTheItem() {
        XCTAssertNotNil(compat.replacement(forShaderPath: "shaders/bars.frag", projectId: "1234567890"))
        XCTAssertNil(compat.replacement(forShaderPath: "shaders/bars.frag", projectId: "1111111111"))
        XCTAssertNil(compat.replacement(forShaderPath: "shaders/bars.frag", projectId: nil))
    }

    func testBundledZCompatConfigsParse() throws {
        let root = try Fixtures.assets().appending(path: "zcompat/scene/shaders")
        let bundled = SceneShaderCompat(root: root)
        let ids = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(ids.isEmpty)
        for id in ids {
            let entry = try XCTUnwrap(bundled.entry(for: id), id)
            XCTAssertEqual(entry.files.count, 2, id)
            for file in entry.files {
                XCTAssertTrue(FileManager.default.fileExists(atPath: entry.directory.appending(path: file).path), file)
            }
        }
    }

    func testWorkshopIdComesFromProjectThenFolder() {
        var project = WEProject(file: "scene.json", preview: "p.jpg", title: "t", type: "scene")
        let folder = URL(fileURLWithPath: "/tmp/owe/2084198056")
        XCTAssertEqual(SceneContentLoader.workshopId(of: WEWallpaper(using: project, where: folder)), "2084198056")
        project.workshopid = .int(42)
        XCTAssertEqual(SceneContentLoader.workshopId(of: WEWallpaper(using: project, where: folder)), "42")
        project.workshopid = nil
        XCTAssertNil(SceneContentLoader.workshopId(of: WEWallpaper(using: project, where: URL(fileURLWithPath: "/tmp/owe/mine"))))
    }
}
