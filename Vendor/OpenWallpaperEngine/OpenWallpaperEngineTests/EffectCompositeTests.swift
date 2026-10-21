import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// An effect's "Composite" option (WE 2.8's editor: Normal, Blend, Under, Cutout; Blend's Alpha
/// 0…2, default 1). WE has no engine-side compositing for it: it is the `COMPOSITE` combo of the
/// effect's own shader (`common_composite.h`'s `ApplyComposite`), stored in scene.json as the pass's
/// `combos` and `compositealpha`/`compositecolor`/`compositeoffset` constants. In WE 2.8.42's assets
/// only `effects/blur`'s combine includes it. These run WE's blur with each mode and check the
/// output against `ApplyComposite` computed from the Normal output and the layer's image.
final class EffectCompositeTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var renderer: EffectGraphRenderer!
    private var builder: SceneEffectPlanBuilder!
    private var cache: URL!

    private struct NoValues: SceneValueContext {
        func userProperty(_ name: String) -> String? { nil }
    }

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-composite-\(UUID().uuidString)")
        renderer = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: cache.appending(path: "archives")))
        let root = ShaderVariantTests.weAssets
        builder = SceneEffectPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { FileManager.default.contents(atPath: root.appending(path: $0).path) },
            loadTexture: { _, _ in nil })
    }

    override func tearDownWithError() throws {
        renderer?.pipelineArchive?.flush()
        if let cache { try? FileManager.default.removeItem(at: cache) }
    }

    private static let size = 64

    /// Opaque and half-transparent squares of two colours, so every mode differs from the others.
    private static func pixel(_ x: Int, _ y: Int) -> SIMD4<Float> {
        let colour: SIMD3<Float> = (x / 16 + y / 16) % 2 == 0 ? SIMD3(0.9, 0.3, 0.1) : SIMD3(0.1, 0.4, 0.8)
        let alpha: Float = y < size / 2 ? 1 : 0.5
        return SIMD4(colour, alpha)
    }

    private func input() throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: Self.size,
                                                                  height: Self.size, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var bytes: [UInt8] = []
        for y in 0..<Self.size {
            for x in 0..<Self.size { bytes += Self.bytes(Self.pixel(x, y)) }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, Self.size, Self.size), mipmapLevel: 0, withBytes: bytes,
                        bytesPerRow: Self.size * 4)
        return texture
    }

    private static func bytes(_ value: SIMD4<Float>) -> [UInt8] {
        let clamped = simd_clamp(value, SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 1)) * 255
        let rounded = clamped.rounded(.toNearestOrAwayFromZero)
        return [UInt8(rounded.x), UInt8(rounded.y), UInt8(rounded.z), UInt8(rounded.w)]
    }

    /// WE's blur with the combine pass's `combos` and constants (scene.json's fourth pass).
    private func run(combos: [String: Int], constants: [String: String] = [:]) throws -> [SIMD4<Float>] {
        let combine = try JSONSerialization.data(withJSONObject: ["combos": combos, "constantshadervalues": constants])
        let json = #"{"file":"effects/blur/effect.json","passes":[{},{},{},"# + String(decoding: combine, as: UTF8.self) + "]}"
        let plan = try builder.build(try JSONDecoder().decode(WEObjectEffect.self, from: Data(json.utf8)))
        XCTAssertEqual(plan.passes.last?.variant?.combos["COMPOSITE"], combos["COMPOSITE"] ?? 0)
        let image = try input()
        XCTAssertTrue(renderer.waitUntilReady([plan], width: Self.size, height: Self.size))
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let context = EffectGraphRenderer.Context(frame: BuiltinFrameContext(), values: NoValues(),
                                                  assetTexture: { _, _ in nil }, sceneSnapshot: nil,
                                                  layerColor: SIMD3(repeating: 1), layerAlpha: 1)
        let output = try XCTUnwrap(renderer.apply([plan], to: image, layerID: "composite-\(combos)-\(constants)",
                                                  context: context, commandBuffer: buffer))
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        let bytes = try TextureUploadTests.read(output, device: device)
        return stride(from: 0, to: bytes.count, by: 4).map { i in
            SIMD4(Float(bytes[i]), Float(bytes[i + 1]), Float(bytes[i + 2]), Float(bytes[i + 3])) / 255
        }
    }

    /// Each pixel of `rendered` against `expected(original, effect)` within `tolerance`/255. The
    /// effect is the Normal output, the blur divided by its alpha as `blur_combine` does; where
    /// that is above 1 the Normal output is clamped and doesn't give it, so those pixels are skipped.
    private func check(_ rendered: [SIMD4<Float>], normal: [SIMD4<Float>], _ label: String, tolerance: Float = 3,
                       expected: (SIMD4<Float>, SIMD4<Float>) -> SIMD4<Float>) {
        var worst: Float = 0
        var checked = 0
        for y in 0..<Self.size {
            for x in 0..<Self.size {
                let i = y * Self.size + x
                guard simd_reduce_max(Self.rgb(normal[i])) < 0.99 else { continue }
                checked += 1
                let want = simd_clamp(expected(Self.pixel(x, y), normal[i]), SIMD4(repeating: 0), SIMD4(repeating: 1))
                worst = max(worst, simd_reduce_max(abs(rendered[i] - want)) * 255)
            }
        }
        XCTAssertGreaterThan(checked, Self.size * Self.size / 2, "\(label): too few pixels to check")
        XCTAssertLessThanOrEqual(worst, tolerance, "\(label): off by \(worst)/255")
    }

    private static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
    private static func saturate(_ v: Float) -> Float { min(max(v, 0), 1) }
    private static func rgb(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }

    /// Blend: the effect over the layer by `BLENDMODE` (Normal) at the effect's alpha × Alpha, and
    /// alpha max(effect · saturate(Alpha), layer). Alpha above 1 pushes past the effect, as in WE.
    func testBlendMixesTheEffectOverTheLayer() throws {
        _ = try Fixtures.assets()
        let normal = try run(combos: [:])
        for alpha: Float in [0.35, 1, 1.6] {
            let blended = try run(combos: ["COMPOSITE": 1], constants: ["compositealpha": "\(alpha)"])
            check(blended, normal: normal, "Blend, alpha \(alpha)") { original, effect in
                SIMD4(Self.mix(Self.rgb(original), Self.rgb(effect), effect.w * alpha),
                      max(effect.w * Self.saturate(alpha), original.w))
            }
        }
    }

    /// Under: the effect below the layer, mix(effect, layer, layer's alpha).
    func testUnderPutsTheEffectBelowTheLayer() throws {
        _ = try Fixtures.assets()
        let normal = try run(combos: [:])
        let under = try run(combos: ["COMPOSITE": 2], constants: ["compositealpha": "0.8"])
        check(under, normal: normal, "Under") { original, effect in
            let below = SIMD4(Self.rgb(effect), effect.w * 0.8)
            return below + (original - below) * original.w
        }
    }

    /// Cutout: the effect only where the layer is transparent.
    func testCutoutKeepsTheEffectWhereTheLayerIsTransparent() throws {
        _ = try Fixtures.assets()
        let normal = try run(combos: [:])
        let cutout = try run(combos: ["COMPOSITE": 3])
        check(cutout, normal: normal, "Cutout") { original, effect in
            SIMD4(Self.rgb(effect), effect.w * (1 - original.w))
        }
    }

    /// Every mode multiplies the effect by `compositecolor`; `COMPOSITEMONO` greys it first.
    func testColourAndMonochromeApplyToTheEffect() throws {
        _ = try Fixtures.assets()
        let normal = try run(combos: [:])
        let tinted = try run(combos: [:], constants: ["compositecolor": "1 0.5 0.25"])
        check(tinted, normal: normal, "tinted") { _, effect in effect * SIMD4(1, 0.5, 0.25, 1) }
        let mono = try run(combos: ["COMPOSITEMONO": 1])
        check(mono, normal: normal, "monochrome") { _, effect in
            let grey = simd_dot(Self.rgb(effect), SIMD3(0.11, 0.59, 0.3))
            return SIMD4(SIMD3(repeating: grey), effect.w)
        }
    }
}
