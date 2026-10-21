import XCTest
@testable import OWESceneEditing

/// Clean Project (the editor's files nothing names, transitively), New Material, and WE's asset
/// folders.
final class ProjectToolsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(_ files: [String: String]) throws -> EditorAssetStore {
        let store = EditorAssetStore(directory: directory.appending(path: "store"))
        for (path, text) in files { try store.store(Data(text.utf8), at: path) }
        return store
    }

    func testCleanProjectFindsWhatNothingNamesTransitively() throws {
        let store = try store([
            "models/editor/used-1.json": #"{"material": "materials/editor/used-1.json"}"#,
            "materials/editor/used-1.json": #"{"passes": [{"shader": "effects/mine", "textures": ["editor/used-1", "editor/used-1_normal"]}]}"#,
            "materials/editor/used-1.png": "png",
            "materials/editor/used-1_normal.tex": "tex",
            "materials/editor/used-1_normal.tex-json": "{}",
            "shaders/effects/mine.frag": "frag",
            "materials/masks/editor_mask-2.png": "mask",
            "particles/editor/particle_system.json": #"{"material": "materials/presets/rain.json"}"#,
            "materials/presets/rain.json": #"{"passes": []}"#,
            "models/editor/old-3.json": #"{"material": "materials/editor/old-3.json"}"#,
            "materials/editor/old-3.json": #"{"passes": [{"textures": ["editor/old-3"]}]}"#,
            "materials/editor/old-3.png": "png",
            "sounds/editor/rain-4.mp3": "mp3",
        ])
        // The draft names the image and a particle document (by its key); the saved edits a mask.
        let draft = Data((#"{"added": [{"id": 9, "object": {"image": "models/editor/used-1.json"}}],"#
            + #""particles": {"assets": {"particles/editor/particle_system.json": {}}}}"#).utf8)
        let saved = Data(#"{"objects": {"1": {"effects": {"0": {"textures": {"1": "masks/editor_mask-2"}}}}}}"#.utf8)
        let unused = ProjectCleaner.unusedAssets(in: store, roots: [draft, saved]).map(\.path)
        XCTAssertEqual(unused, ["materials/editor/old-3.json", "materials/editor/old-3.png", "models/editor/old-3.json",
                                "sounds/editor/rain-4.mp3"])
        XCTAssertEqual(ProjectCleaner.unusedAssets(in: store, roots: []).count, store.assets().count, "nothing named, nothing used")
    }

    func testNamesMatchAsWENamesFiles() {
        XCTAssertTrue(ProjectCleaner.isNamed("materials/editor/a.png", by: ["editor/a"]), "a texture by its name")
        XCTAssertTrue(ProjectCleaner.isNamed("shaders/effects/x.vert", by: ["effects/x"]), "a shader by its name")
        XCTAssertTrue(ProjectCleaner.isNamed("materials/a.tex-json", by: ["a"]), "a .tex-json goes with its .tex")
        XCTAssertFalse(ProjectCleaner.isNamed("materials/editor/ab.png", by: ["editor/a"]))
    }

    func testNewMaterialIsNamedByTheAuthorAndNeverOverwrites() throws {
        let store = try store([:])
        XCTAssertEqual(EditorAssetStore.materialFileName(" glass:blue./x "), "glassbluex")
        XCTAssertNil(try store.createMaterial(named: "..."))
        XCTAssertEqual(try store.createMaterial(named: "Glass"), "materials/Glass.json")
        XCTAssertEqual(try store.createMaterial(named: "Glass"), "materials/Glass 2.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: try XCTUnwrap(store.url(for: "materials/Glass.json"))))
        XCTAssertEqual(((json as? [String: Any])?["passes"] as? [[String: Any]])?.first?["shader"] as? String, "generic")
    }
}
