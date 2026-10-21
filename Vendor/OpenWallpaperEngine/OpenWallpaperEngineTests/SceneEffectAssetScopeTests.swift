import XCTest
@testable import OpenWallpaperEngine

/// Where an effect's materials and shaders are found (`SceneEffectPlanBuilder.readWallpaperFile`).
/// WE resolves them at the project root, then the assets root; a project that lacks its copy of a
/// built-in effect's `materials/effects/<x>.json` logs "Failed opening" and drops the effect (WE
/// 2.8.0.42, the effect gallery's capture log), because WE never looks inside
/// `assets/effects/<x>/`. A Workshop effect's item keeps its files in the effect's folder, and
/// that folder is searched.
final class SceneEffectAssetScopeTests: XCTestCase {
    private var cache: URL!
    private var translator: ShaderVariantTranslator!
    private let assets = ShaderVariantTests.weAssets

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: assets.appending(path: "effects/tint/effect.json").path),
                          "WE assets not present")
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-effect-scope-\(UUID().uuidString)")
        translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache)
    }

    override func tearDownWithError() throws {
        if let cache { try? FileManager.default.removeItem(at: cache) } // scratch cleanup
    }

    private func asset(_ path: String) throws -> Data {
        try Data(contentsOf: assets.appending(path: path))
    }

    /// A builder over a wallpaper made of `files`, falling back to the WE assets root.
    private func builder(_ files: [String: Data], scoped: Bool = true) -> SceneEffectPlanBuilder {
        let root = assets
        var builder = SceneEffectPlanBuilder(
            translator: translator,
            readFile: { files[$0] ?? FileManager.default.contents(atPath: root.appending(path: $0).path) },
            loadTexture: { _, _ in nil })
        if scoped { builder.readWallpaperFile = { files[$0] } }
        return builder
    }

    private func effect(_ file: String) throws -> WEObjectEffect {
        try JSONDecoder().decode(WEObjectEffect.self, from: Data(#"{"file": "\#(file)"}"#.utf8))
    }

    private func tintCopy(under prefix: String = "") throws -> [String: Data] {
        [prefix + "materials/effects/tint.json": try asset("effects/tint/materials/effects/tint.json"),
         prefix + "shaders/effects/tint.frag": try asset("effects/tint/shaders/effects/tint.frag"),
         prefix + "shaders/effects/tint.vert": try asset("effects/tint/shaders/effects/tint.vert")]
    }

    func testBuiltInEffectWithoutTheProjectsMaterialCopyIsDropped() throws {
        let files = ["effects/tint/effect.json": try asset("effects/tint/effect.json")]
        XCTAssertThrowsError(try builder(files).build(effect("effects/tint/effect.json"))) { error in
            XCTAssertEqual("\(error)", "missing materials/effects/tint.json")
        }
    }

    func testBuiltInEffectTheProjectDoesntHaveIsDropped() throws {
        XCTAssertThrowsError(try builder([:]).build(effect("effects/tint/effect.json"))) { error in
            XCTAssertEqual("\(error)", "missing materials/effects/tint.json")
        }
    }

    func testBuiltInEffectCopiedIntoTheProjectBuilds() throws {
        var files = try tintCopy()
        files["effects/tint/effect.json"] = try asset("effects/tint/effect.json")
        let plan = try builder(files).build(effect("effects/tint/effect.json"))
        XCTAssertEqual(plan.passes.count, 1)
        XCTAssertNotNil(plan.passes.first?.variant)
    }

    func testWorkshopEffectResolvesInsideItsOwnFolder() throws {
        let folder = "effects/workshop/2084198056/tinted/"
        var files = try tintCopy(under: folder)
        files[folder + "effect.json"] = try asset("effects/tint/effect.json")
        let plan = try builder(files).build(effect(folder + "effect.json"))
        XCTAssertEqual(plan.passes.count, 1)
    }

    /// The engine's own chains (bloom, HDR, colour correction) read WE's assets directly and keep
    /// the effect-folder lookup.
    func testBuilderWithoutWallpaperFilesStillSearchesTheEffectFolder() throws {
        let plan = try builder([:], scoped: false).build(effect("effects/tint/effect.json"))
        XCTAssertEqual(plan.passes.count, 1)
    }
}
