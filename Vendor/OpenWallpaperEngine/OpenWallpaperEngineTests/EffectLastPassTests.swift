import XCTest
import simd
@testable import OpenWallpaperEngine

/// A layer's last effect pass draws straight into the scene through the layer's quad, as WE's does
/// (`EffectGraphRenderer.lastScenePass`, `SceneMetalRenderer.runEffectsDrawingLastPass`;
/// docs/test-risks.md FX2): its shader runs once per pixel of the screen, not once per texel of
/// the layer's buffer resampled onto it.
final class EffectLastPassTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "owe-last-pass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch, FileManager.default.fileExists(atPath: scratch.path) {
            try FileManager.default.removeItem(at: scratch)
        }
    }

    // MARK: - Which pass

    /// The last visible effect's last pass, when it draws into the layer's buffers; a chain ending
    /// in a pass into one of its effect's FBOs has none (it composites through a buffer).
    func testTheLastPassIsTheLastVisibleEffectsLastBufferPass() {
        let blur = Self.effect([Self.pass(target: "a"), Self.pass(), Self.pass()])
        let tint = Self.effect([Self.pass()])
        let both = EffectGraphRenderer.lastScenePass([blur, tint], hidden: []).map { [$0.effect, $0.pass] }
        XCTAssertEqual(both, [1, 0])
        let blurOnly = EffectGraphRenderer.lastScenePass([blur, tint], hidden: [1]).map { [$0.effect, $0.pass] }
        XCTAssertEqual(blurOnly, [0, 2], "a hidden effect is skipped")
        XCTAssertNil(EffectGraphRenderer.lastScenePass([tint, Self.effect([Self.pass(), Self.pass(target: "a")])], hidden: []))
        XCTAssertNil(EffectGraphRenderer.lastScenePass([tint], hidden: [0]))
        XCTAssertNil(EffectGraphRenderer.lastScenePass([Self.effect([Self.pass(command: .copy(source: "previous", target: "a"))])],
                                                       hidden: []))
    }

    // MARK: - Film grain

    /// WE's film grain is evaluated at every screen pixel: over the gallery's gradient (drawn at 0.85)
    /// its grain is as strong as the shader makes it and uncorrelated between neighbours (WE's
    /// capture: spread 11.6, lag-1 0.07). Run in the 1024² buffer and resampled, it was 0.66 as
    /// strong (7.8) and correlated (0.27).
    func testFilmGrainIsEvaluatedAtEveryPixelOfTheScreen() throws {
        try XCTSkipUnless(Fixtures.hasWEShaderSources, "WE's effect shader sources aren't available")
        let assets = try XCTUnwrap(WallpaperEngineAssets.directory)
        let control = try render(WEEffectGallery.makeProject(effect: nil, assets: assets, in: scratch))
        let grain = try render(WEEffectGallery.makeProject(effect: "filmgrain", assets: assets, in: scratch))
        // Inside the gradient's quad: centre (1440, 540), 870 wide.
        let rows = 300..<780, columns = 1200..<1680
        var residual: [[Float]] = []
        for y in rows {
            residual.append(columns.map { x in Self.luma(grain, x, y) - Self.luma(control, x, y) })
        }
        let values = residual.flatMap { $0 }
        let mean = values.reduce(0, +) / Float(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
        var lagged: Float = 0
        var pairs = 0
        for row in residual {
            for index in 1..<row.count {
                lagged += (row[index] - mean) * (row[index - 1] - mean)
                pairs += 1
            }
        }
        let lag1 = lagged / Float(pairs) / max(variance, 1e-6)
        let spread = variance.squareRoot()
        print(String(format: "film grain over the gradient: spread %.2f, lag-1 %.3f", spread, lag1))
        XCTAssertGreaterThan(spread, 10, "the grain's spread (WE's 11.6; resampled from the buffer, 7.8)")
        XCTAssertLessThan(lag1, 0.15, "neighbouring pixels are drawn apart (WE's lag-1 0.07; resampled, 0.27)")
    }

    // MARK: - Helpers

    private func render(_ directory: URL) throws -> WEReferenceImage {
        let data = try Data(contentsOf: directory.appending(path: "project.json"))
        let project = try decodeTolerant(WEProject.self, from: data)
        var settings = SceneRenderSettings()
        settings.postProcessing = .enabled
        settings.textureReduction = 1
        settings.sceneDetail = .full
        settings.renderResolution = .yourDisplay
        settings.antiAliasing = .msaa_x2
        let renderer = WEReferenceRenderer(directory: directory, project: project, settings: settings,
                                           storage: scratch.appending(path: "storage-\(directory.lastPathComponent)"))
        defer { Fixtures.removeStoredSettings(for: directory) }
        let shot = WEReferenceRenderer.Shot(time: WEEffectGallery.stillTime, cursor: WEEffectGallery.cursor)
        return try XCTUnwrap(renderer.render([shot]).first)
    }

    private static func luma(_ image: WEReferenceImage, _ x: Int, _ y: Int) -> Float {
        let index = (y * image.width + x) * 4
        let r = Float(image.pixels[index]), g = Float(image.pixels[index + 1]), b = Float(image.pixels[index + 2])
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    private static func pass(target: String? = nil, command: SceneEffectPassCommand = .render) -> SceneEffectPassPlan {
        let variant = TranslatedShaderVariant(vertexMSL: "", fragmentMSL: "", uniforms: nil, textureSlots: [0],
                                              attributes: [:], combos: [:])
        return SceneEffectPassPlan(command: command, variantKey: "v", variant: variant,
                            blending: "normal", target: target, textures: [0: .current],
                            constants: ShaderConstantResolver.ResolvedConstants(staticValues: [:], dynamic: []))
    }

    private static func effect(_ passes: [SceneEffectPassPlan]) -> SceneEffectPlan {
        SceneEffectPlan(file: "effects/test/effect.json", fbos: [], passes: passes)
    }
}
