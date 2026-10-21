import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// WE's user colour correction: the image filter and colour options as WE derives them
/// (`wallpaper64.exe` 0x140182336…0x140182ea3), the LUT volumes, and WE's `ccsimple` pass run by the
/// effect graph against a CPU model of the shader.
final class SceneColorCorrectionTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var effects: EffectGraphRenderer!
    private var correction: SceneColorCorrection!
    private var cache: URL!
    private var frameIndex: UInt64 = 0

    private struct NoValues: SceneValueContext {
        func userProperty(_ name: String) -> String? { nil }
    }

    private static func assetData(_ path: String) -> Data? {
        FileManager.default.contents(atPath: ShaderVariantTests.weAssets.appending(path: path).path)
    }

    override func setUpWithError() throws {
        _ = try Fixtures.assets()
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-cc-\(UUID().uuidString)")
        effects = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: cache.appending(path: "archives")))
        let builder = SceneEffectPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: Self.assetData, loadTexture: { _, _ in nil })
        correction = try SceneColorCorrection.build(with: builder)
    }

    override func tearDownWithError() throws {
        effects?.pipelineArchive?.flush()
        if let cache { try? FileManager.default.removeItem(at: cache) }
    }

    // MARK: - Settings

    private func settings(_ values: [WEColorCorrectionProperty: String]) -> SceneColorCorrectionSettings {
        SceneColorCorrectionSettings { values[$0] }
    }

    /// WE's defaults are identity: no pass.
    func testWEsDefaultsMakeNoPass() throws {
        _ = try Fixtures.assets()
        let defaults = settings(Dictionary(uniqueKeysWithValues: WEColorCorrectionProperty.allCases.map { ($0, $0.defaultValue) }))
        XCTAssertEqual(defaults, SceneColorCorrectionSettings())
        XCTAssertTrue(defaults.isIdentity)
        XCTAssertEqual(defaults.params, SIMD4(1, 1, 1, 0))
        XCTAssertTrue(settings([:]).isIdentity, "a wallpaper that never set them")
    }

    /// The sliders go through WE's scales: brightness (v/50)², contrast and saturation √(v/50),
    /// hue v/100 − 0.5; the strength v/100.
    func testTheSlidersMapAsWEMapsThem() throws {
        _ = try Fixtures.assets()
        let edited = settings([.showColorOptions: "true", .brightness: "100", .contrast: "100", .saturation: "0",
                               .hueShift: "75", .filter: "tower", .filterStrength: "40"])
        XCTAssertEqual(edited.params.x, 4)
        XCTAssertEqual(edited.params.y, Float(2).squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(edited.params.z, 0)
        XCTAssertEqual(edited.params.w, 0.25, accuracy: 1e-6)
        XCTAssertEqual(edited.filterAmount, 0.4, accuracy: 1e-6)
        XCTAssertTrue(edited.appliesColor)
        XCTAssertTrue(edited.appliesFilter)
    }

    /// `COL` needs "Show color options" and a value away from identity; `LUT` a filter with strength.
    func testWhatWEMakesThePassWith() throws {
        _ = try Fixtures.assets()
        XCTAssertFalse(settings([.brightness: "80"]).appliesColor, "the options are hidden")
        XCTAssertFalse(settings([.showColorOptions: "true"]).appliesColor, "shown but at identity")
        XCTAssertTrue(settings([.showColorOptions: "true", .hueShift: "49"]).appliesColor)
        XCTAssertFalse(settings([.filter: "tower", .filterStrength: "0"]).appliesFilter)
        XCTAssertTrue(settings([.filter: "tower"]).appliesFilter, "strength defaults to 100")
        XCTAssertTrue(settings([.filter: "tower", .filterStrength: "0"]).isIdentity)
    }

    /// The menu is "None" and WE's 25 filters, numbered, each a LUT that ships with WE.
    func testTheFilterMenuIsWEs() throws {
        _ = try Fixtures.assets()
        let options = WEImageFilters.options { _ in nil }
        XCTAssertEqual(options.count, 26)
        XCTAssertEqual(options[0].title, "None")
        XCTAssertEqual(options[0].value, "")
        XCTAssertEqual(options[1].title, "1 Vibrant Contrast")
        XCTAssertEqual(options[25].title, "25 Retro Handheld")
        XCTAssertEqual(options.dropFirst().map(\.title), WEImageFilters.all.enumerated().map { "\($0 + 1) \($1.english)" })
        for filter in WEImageFilters.all {
            let data = try XCTUnwrap(Self.assetData("materials/lut/\(filter.name).tex"), filter.name)
            let volume = try TEXVolume(texData: data)
            XCTAssertEqual([volume.width, volume.height, volume.depth], [32, 32, 32], filter.name)
        }
    }

    /// Every colour property is applied live, without rebuilding the scene.
    func testThePropertiesAreLive() throws {
        _ = try Fixtures.assets()
        for key in WEColorCorrectionProperty.allCases {
            XCTAssertEqual(SceneChangeImpact.impact(of: key.rawValue), .none, key.rawValue)
        }
    }

    // MARK: - The LUT volumes

    /// `lut/neutral` is the identity: texel (r, g, b) holds (r, g, b) · 255/31, slices stacked by blue.
    func testTheNeutralLUTIsTheIdentity() throws {
        _ = try Fixtures.assets()
        let volume = try TEXVolume(texData: try XCTUnwrap(Self.assetData("materials/lut/neutral.tex")))
        XCTAssertEqual(volume.rgba.count, 32 * 32 * 32 * 4)
        for (x, y, z) in [(0, 0, 0), (31, 0, 0), (0, 31, 0), (0, 0, 31), (5, 7, 9), (31, 31, 31)] {
            let i = ((z * 32 + y) * 32 + x) * 4
            let expected: [UInt8] = [x, y, z].map { (value: Int) -> UInt8 in UInt8((Double(value) * 255 / 31).rounded()) }
            XCTAssertEqual(Array(volume.rgba[i..<i + 3]), expected, "(\(x), \(y), \(z))")
        }
    }

    /// A 2D `.tex` isn't a volume.
    func testAPlainTextureIsntAVolume() throws {
        _ = try Fixtures.assets()
        let data = try XCTUnwrap(Self.assetData("materials/util/noise.tex"))
        XCTAssertFalse(TEXVolume.isVolume(data))
        XCTAssertThrowsError(try TEXVolume(texData: data)) { XCTAssertEqual($0 as? TEXVolume.ParseError, .notVolume) }
    }

    // MARK: - The pass against the CPU model

    /// A gradient with a few saturated and grey patches.
    private static let width = 48, height = 32
    private static func pixel(_ x: Int, _ y: Int) -> [UInt8] {
        if y < 4 { return [[255, 0, 0, 255], [0, 200, 40, 255], [30, 60, 220, 255], [128, 128, 128, 255]][x % 4] }
        return [UInt8(x * 255 / (width - 1)), UInt8(y * 255 / (height - 1)), UInt8(255 - x * 5), 255]
    }

    private func run(_ settings: SceneColorCorrectionSettings) throws -> [UInt8]? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: Self.width,
                                                                  height: Self.height, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        let frame = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var bytes: [UInt8] = []
        for y in 0..<Self.height { for x in 0..<Self.width { bytes += Self.pixel(x, y) } }
        frame.replace(region: MTLRegionMake2D(0, 0, Self.width, Self.height), mipmapLevel: 0, withBytes: bytes,
                      bytesPerRow: Self.width * 4)
        if let plan = correction.plan(for: settings) {
            XCTAssertTrue(effects.waitUntilReady([plan], width: Self.width, height: Self.height))
        }
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        frameIndex += 1
        let output = correction.encode(on: frame, settings: settings, effects: effects, builtins: BuiltinFrameContext(),
                                       values: NoValues(), frameIndex: frameIndex, commandBuffer: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        return try output.map { try TextureUploadTests.read($0, device: device) }
    }

    private func check(_ settings: SceneColorCorrectionSettings, _ label: String) throws {
        let rendered = try XCTUnwrap(try run(settings), label)
        let lut = try settings.appliesFilter
            ? TEXVolume(texData: try XCTUnwrap(Self.assetData("materials/lut/\(settings.filter).tex"))) : nil
        var worst = 0
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let input = Self.pixel(x, y).map { Float($0) / 255 }
                let expected = CCSimpleReference.shade(SIMD4(input[0], input[1], input[2], input[3]), settings: settings, lut: lut)
                let i = (y * Self.width + x) * 4
                for c in 0..<4 {
                    let want = Int((min(max(expected[c], 0), 1) * 255).rounded())
                    worst = max(worst, abs(Int(rendered[i + c]) - want))
                }
            }
        }
        XCTAssertLessThanOrEqual(worst, 2, "\(label): off by \(worst)/255")
    }

    /// The colour options alone (`COL`), at a few settings.
    func testTheColourOptionsMatchTheCPUModel() throws {
        _ = try Fixtures.assets()
        try check(settings([.showColorOptions: "true", .brightness: "70"]), "brighter")
        try check(settings([.showColorOptions: "true", .contrast: "80", .saturation: "20"]), "contrast, desaturated")
        try check(settings([.showColorOptions: "true", .hueShift: "80", .brightness: "40"]), "hue shift")
    }

    /// A filter alone (`LUT`) and with the options, at full and partial strength.
    func testTheFiltersMatchTheCPUModel() throws {
        _ = try Fixtures.assets()
        try check(settings([.filter: "neutral"]), "neutral")
        try check(settings([.filter: "k23_b"]), "Vibrant Contrast")
        try check(settings([.filter: "lutx32_amber", .filterStrength: "35"]), "Amber at 35")
        try check(settings([.filter: "tower", .showColorOptions: "true", .saturation: "75"]), "Color Crush, saturated")
    }

    /// Identity makes no pass, as in WE; an unknown filter draws the frame as it is.
    func testIdentityAndAMissingFilterDrawTheFrameAsItIs() throws {
        _ = try Fixtures.assets()
        XCTAssertNil(try run(SceneColorCorrectionSettings()))
        XCTAssertNil(try run(settings([.filter: "no-such-filter"])))
    }
}

/// `ccsimple.frag` on the CPU: `COL` (contrast about 0.5, then HSV value, saturation and hue, with
/// `common.h`'s conversions) and `LUT` (a trilinear, edge-clamped read of the volume at the colour,
/// mixed in by `lutparams`), as the shader computes them in LDR.
enum CCSimpleReference {
    static func shade(_ albedo: SIMD4<Float>, settings: SceneColorCorrectionSettings, lut: TEXVolume?) -> SIMD4<Float> {
        var rgb = SIMD3(albedo.x, albedo.y, albedo.z)
        let params = settings.params
        if settings.appliesColor {
            rgb = SIMD3(repeating: 0.5) + (rgb - SIMD3(repeating: 0.5)) * params.y
            var hsv = rgb2hsv(rgb)
            hsv.z *= params.x
            hsv.y *= params.z
            hsv.x += params.w
            rgb = hsv2rgb(hsv)
        }
        if settings.appliesFilter, let lut {
            let filtered = sample(lut, rgb)
            rgb += (filtered - rgb) * settings.filterAmount
        }
        return SIMD4(rgb.x, rgb.y, rgb.z, albedo.w)
    }

    static func hsv2rgb(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let k = SIMD4<Float>(1, 2.0 / 3.0, 1.0 / 3.0, 3)
        func frac(_ v: Float) -> Float { v - v.rounded(.down) }
        func channel(_ offset: Float) -> Float {
            let p = abs(frac(c.x + offset) * 6 - k.w)
            let clamped = min(max(p - k.x, 0), 1)
            return c.z * (k.x + (clamped - k.x) * c.y)
        }
        return SIMD3(channel(k.x), channel(k.y), channel(k.z))
    }

    static func rgb2hsv(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let p: SIMD4<Float> = rgb.y < rgb.z ? SIMD4(rgb.z, rgb.y, -1, 2.0 / 3.0) : SIMD4(rgb.y, rgb.z, 0, -1.0 / 3.0)
        let q: SIMD4<Float> = rgb.x < p.x ? SIMD4(p.x, p.y, p.w, rgb.x) : SIMD4(rgb.x, p.y, p.z, p.x)
        let chroma = q.x - min(q.w, q.y)
        let hue = abs((q.w - q.y) / (6 * chroma + 1e-10) + q.z)
        return SIMD3(hue, chroma / (q.x + 1e-10), q.x)
    }

    /// Linear filtering with clamp-to-edge, as the GPU samples a 3D texture at `uvw`.
    static func sample(_ volume: TEXVolume, _ uvw: SIMD3<Float>) -> SIMD3<Float> {
        let size = SIMD3(Float(volume.width), Float(volume.height), Float(volume.depth))
        let texel = uvw * size - SIMD3(repeating: 0.5)
        let base = texel.rounded(.down)
        let t = texel - base
        func value(_ x: Int, _ y: Int, _ z: Int) -> SIMD3<Float> {
            let cx = min(max(x, 0), volume.width - 1), cy = min(max(y, 0), volume.height - 1)
            let cz = min(max(z, 0), volume.depth - 1)
            let i = ((cz * volume.height + cy) * volume.width + cx) * 4
            return SIMD3(Float(volume.rgba[i]), Float(volume.rgba[i + 1]), Float(volume.rgba[i + 2])) / 255
        }
        let x0 = Int(base.x), y0 = Int(base.y), z0 = Int(base.z)
        var result = SIMD3<Float>(repeating: 0)
        for dz in 0...1 {
            for dy in 0...1 {
                for dx in 0...1 {
                    let weight = (dx == 1 ? t.x : 1 - t.x) * (dy == 1 ? t.y : 1 - t.y) * (dz == 1 ? t.z : 1 - t.z)
                    result += value(x0 + dx, y0 + dy, z0 + dz) * weight
                }
            }
        }
        return result
    }
}
