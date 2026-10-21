import XCTest
import simd
@testable import OpenWallpaperEngine

/// A `shape` object (`"shape": "quad"`, the light-shaft presets) as WE builds it: an image object
/// without an image, a square the scene's orthographic height on each side (0x14025fac0), whose
/// effects load with `DIRECTDRAW` 1 in every pass (0x14025ff50). The light-shaft effect then draws
/// its gradient's colours on nothing; without the combo it added them to the layer's white
/// placeholder and drew white (test-risks PG3).
final class SceneShapeObjectTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "owe-shape-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch, FileManager.default.fileExists(atPath: scratch.path) {
            try FileManager.default.removeItem(at: scratch)
        }
    }

    func testAShapeIsASquareOfTheSceneHeight() {
        XCTAssertEqual(SceneContentLoader.shapeSize(sceneSize: SIMD2<Float>(1920, 1080)), SIMD2<Float>(1080, 1080))
        XCTAssertEqual(SceneContentLoader.shapeEffectCombos, ["DIRECTDRAW": 1])
    }

    /// The object's combos go over the authored ones of every pass.
    func testObjectCombosGoOverThePassCombos() throws {
        _ = try Fixtures.assets()
        let root = ShaderVariantTests.weAssets
        var builder = SceneEffectPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: scratch.appending(path: "cache")),
            readFile: { FileManager.default.contents(atPath: root.appending(path: $0).path) },
            loadTexture: { _, _ in nil })
        let json = #"{"file":"effects/lightshafts/effect.json","passes":[{"combos":{"RENDERING":1,"DIRECTDRAW":0}}]}"#
        let effect = try JSONDecoder().decode(WEObjectEffect.self, from: Data(json.utf8))
        XCTAssertEqual(try builder.build(effect).passes.first?.variant?.combos["DIRECTDRAW"], 0)
        builder.objectCombos = SceneContentLoader.shapeEffectCombos
        let plan = try builder.build(effect)
        XCTAssertEqual(plan.passes.first?.variant?.combos["DIRECTDRAW"], 1)
        XCTAssertEqual(plan.passes.first?.variant?.combos["RENDERING"], 1)
    }

    /// The preset "Light shafts - corner" (lightshafts_0) over black: coloured rays from the
    /// gradient map, all inside the 1080 × 1080 square at the screen's centre.
    func testTheLightShaftPresetDrawsTheGradientInsideItsSquare() throws {
        _ = try Fixtures.assets()
        let directory = try makeCornerPreset()
        let data = try Data(contentsOf: directory.appending(path: "project.json"))
        let project = try decodeTolerant(WEProject.self, from: data)
        var settings = SceneRenderSettings()
        settings.textureReduction = 1
        settings.renderResolution = .yourDisplay
        let renderer = WEReferenceRenderer(directory: directory, project: project, settings: settings,
                                           storage: scratch.appending(path: "storage"))
        defer { Fixtures.removeStoredSettings(for: directory) }
        let frame = try XCTUnwrap(renderer.render([.init(time: 5.5, cursor: SIMD2(-1920, -1080))]).first)
        var lit = 0, grey = 0, outside = 0
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let i = (y * frame.width + x) * 4
                let r = Int(frame.pixels[i]), g = Int(frame.pixels[i + 1]), b = Int(frame.pixels[i + 2])
                let high = max(r, g, b)
                guard high > 40 else { continue }
                lit += 1
                if high - min(r, g, b) < 8 { grey += 1 }
                if x < 420 - 4 || x > 1500 + 4 { outside += 1 }
            }
        }
        XCTAssertGreaterThan(lit, 2000, "the rays draw")
        XCTAssertLessThan(Double(grey), 0.1 * Double(lit), "the rays take the iridescent gradient's colours, not white")
        XCTAssertEqual(outside, 0, "the quad is the 1080 × 1080 square at the centre")
    }

    /// 3546971487's "Light shafts - linear" over a grey scene: a shape's last pass adds to the
    /// scene (its blend state is WE's `additive`, 0x140260790), so the rays never darken what is
    /// under them, and its `scale` (2 here) sizes its square like any object's. Blended over the
    /// grey, its dim rays of high alpha drew a dark box, and at scale 1 the box's edges showed.
    func testALightShaftShapeAddsToTheSceneAtItsScale() throws {
        _ = try Fixtures.assets()
        let directory = try makePreset(name: "linear", clearColor: "0.5 0.5 0.5", scale: "2 2 2", pass: #"""
            {"combos":{"RENDERING":0},
             "constantshadervalues":{"colorastart":"1 1 1","colorend":"0.435 0.886 1","colorwexponent":0.2,
               "colorwintensity":0.3,"noiseamount":0.33,"noisescale":1.17,"point0":"-0.21111 -0.10689",
               "point1":"1.31283 -0.03616","point2":"0.8 0.8","point3":"0.29208 0.78184","rayfeather":"0.5 0",
               "rayradius":0.14,"rayscale":"0.34 0.2","raysmoothness":1,"rayspeed":0.15}}
            """#)
        let frame = try render(directory)
        let background: Int = 128
        var darker = 0, lit = 0, outside = 0
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let i: Int = (y * frame.width + x) * 4
                let r = Int(frame.pixels[i]), g = Int(frame.pixels[i + 1]), b = Int(frame.pixels[i + 2])
                if min(r, g, b) < background - 2 { darker += 1 }
                guard max(r, g, b) > background + 8 else { continue }
                lit += 1
                if x < 420 - 4 || x > 1500 + 4 { outside += 1 }
            }
        }
        XCTAssertGreaterThan(lit, 2000, "the rays draw")
        XCTAssertEqual(darker, 0, "the rays add to the scene; they don't blend over it")
        XCTAssertGreaterThan(outside, 1000, "at scale 2 the square is 2160 on a side, wider than the screen")
    }

    private func render(_ directory: URL) throws -> WEReferenceImage {
        let data = try Data(contentsOf: directory.appending(path: "project.json"))
        let project = try decodeTolerant(WEProject.self, from: data)
        var settings = SceneRenderSettings()
        settings.textureReduction = 1
        settings.renderResolution = .yourDisplay
        let renderer = WEReferenceRenderer(directory: directory, project: project, settings: settings,
                                           storage: scratch.appending(path: "storage"))
        defer { Fixtures.removeStoredSettings(for: directory) }
        return try XCTUnwrap(renderer.render([.init(time: 5.5, cursor: SIMD2(-1920, -1080))]).first)
    }

    /// A light-shaft shape at the centre of an orthographic 1920 × 1080 scene cleared to
    /// `clearColor`, its pass as `pass` authors it, with the effect's files copied in.
    private func makePreset(name: String, clearColor: String, scale: String, pass: String) throws -> URL {
        let fm = FileManager.default
        let directory = scratch.appending(path: "lightshafts_\(name)", directoryHint: .isDirectory)
        let effect = ShaderVariantTests.weAssets.appending(path: "effects/lightshafts")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for folder in ["materials", "shaders"] {
            try fm.copyItem(at: effect.appending(path: folder), to: directory.appending(path: folder))
        }
        let scene = """
        {"camera":{"center":"0 0 -1","eye":"0 0 0","up":"0 1 0"},
         "general":{"clearcolor":"\(clearColor)","orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[{"id":10,"name":"Light shafts - \(name)","shape":"quad","origin":"960 540 0","scale":"\(scale)",
           "visible":true,"effects":[{"file":"effects/lightshafts/effect.json","name":"","visible":true,
           "passes":[\(pass)]}]}]}
        """
        try Data(scene.utf8).write(to: directory.appending(path: "scene.json"))
        let project = #"{"file":"scene.json","title":"lightshafts","type":"scene","general":{"properties":{}}}"#
        try Data(project.utf8).write(to: directory.appending(path: "project.json"))
        return directory
    }

    /// lightshafts_0 as the particle gallery builds it: the preset's object at the screen's centre
    /// of an orthographic 1920 × 1080 scene, with the effect's material and shaders copied in as
    /// the editor copies them.
    private func makeCornerPreset() throws -> URL {
        let fm = FileManager.default
        let directory = scratch.appending(path: "lightshafts_0", directoryHint: .isDirectory)
        let effect = ShaderVariantTests.weAssets.appending(path: "effects/lightshafts")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for folder in ["materials", "shaders"] {
            try fm.copyItem(at: effect.appending(path: folder), to: directory.appending(path: folder))
        }
        let scene = #"""
        {"camera":{"center":"0 0 -1","eye":"0 0 0","up":"0 1 0"},
         "general":{"clearcolor":"0 0 0","orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[{"id":10,"name":"Light shafts - corner","shape":"quad","origin":"960 540 0","visible":true,
           "effects":[{"file":"effects/lightshafts/effect.json","name":"","visible":true,"passes":[{
             "combos":{"RAYCORNER":1,"RAYMODE":2,"RENDERING":1},
             "constantshadervalues":{"colorastart":"1 1 1","colorend":"0.435 0.886 1","colorwexponent":1,
               "colorwintensity":1,"noiseamount":0.33,"noisescale":0.85,"point0":"0.24560 0.09457",
               "point1":"0.85704 0.06238","point2":"0.94690 0.66185","point3":"0.07415 0.95000",
               "rayfeather":"0.22 0.1","rayradius":0.15,"rayscale":"0.4 1.01","raysmoothness":0.54,"rayspeed":0.39}}]}]}]}
        """#
        try Data(scene.utf8).write(to: directory.appending(path: "scene.json"))
        let project = #"{"file":"scene.json","title":"lightshafts_0","type":"scene","general":{"properties":{}}}"#
        try Data(project.utf8).write(to: directory.appending(path: "project.json"))
        return directory
    }
}
