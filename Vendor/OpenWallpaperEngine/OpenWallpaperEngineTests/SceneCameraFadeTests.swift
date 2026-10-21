import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// WE's camera fade (`SceneCameraFade`): `materials/util/fade.json` translated and drawn over the
/// finished frame, `color · 0.7` at `g_Alpha`, blended translucent; `color` is the `tint` key that
/// `usershadervalues` binds to the wallpaper's `schemecolor`.
final class SceneCameraFadeTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var cache: URL!
    private var builder: SceneEffectPlanBuilder!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-camerafade-\(UUID().uuidString)")
        let root = ShaderVariantTests.weAssets
        builder = SceneEffectPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { FileManager.default.contents(atPath: root.appending(path: $0).path) },
            loadTexture: { _, _ in nil })
    }

    override func tearDownWithError() throws {
        if let cache { try? FileManager.default.removeItem(at: cache) }
    }

    private struct Properties: SceneValueContext {
        var values: [String: String] = [:]
        func userProperty(_ name: String) -> String? { values[name] }
    }

    /// The pass is WE's: its shader, translucent blending, and `color` bound to `schemecolor`.
    func testThePassIsWEsFadeMaterial() throws {
        _ = try Fixtures.assets()
        let fade = try SceneCameraFade.build(with: builder)
        XCTAssertEqual(fade.pass.blending, "translucent")
        let color = try XCTUnwrap(fade.pass.constants.dynamic.first { $0.uniform == "color" }, "color follows a user property")
        guard case .user(let name, _, _) = color.source else { return XCTFail("\(color.source)") }
        XCTAssertEqual(name, "schemecolor")
    }

    /// Drawn over a frame: `frame·(1 − a) + color·0.7·a`, with the shader's default colour without
    /// a `schemecolor` and the property's with one; nothing at alpha 0.
    func testTheFadeBlendsTheTintOverTheFrame() throws {
        _ = try Fixtures.assets()
        let fade = try SceneCameraFade.build(with: builder)
        let cases: [(Properties, SIMD3<Float>, Float)] = [
            (Properties(), SIMD3(0.315, 0.135, 0.1125), 0.5),
            (Properties(values: ["schemecolor": "0 0 1"]), SIMD3(0, 0, 1), 0.8),
            (Properties(), SIMD3(0.315, 0.135, 0.1125), 0),
        ]
        for (properties, color, alpha) in cases {
            let frame = try target(filledWith: SIMD4(200, 100, 50, 255))
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            fade.encode(on: frame, alpha: alpha, builtins: BuiltinFrameContext(), values: properties, commandBuffer: commands)
            commands.commit()
            commands.waitUntilCompleted()
            XCTAssertEqual(fade.lastFade != nil, alpha > 0)
            let bytes = try TextureUploadTests.read(frame, device: device)
            let base = SIMD3<Float>(200, 100, 50) / 255
            let expected = base * (1 - alpha) + color * 0.7 * alpha
            // Every pixel of the target: the fade covers it whole.
            var wrong = 0
            for pixel in 0..<(bytes.count / 4) {
                for channel in 0..<3 where abs(Float(bytes[4 * pixel + channel]) / 255 - expected[channel]) > 1.5 / 255 {
                    wrong += 1
                }
            }
            XCTAssertEqual(wrong, 0, "alpha \(alpha): components off the expected fade")
        }
    }

    /// The fade runs after the colour correction, on the frame's own targets, drawn by the same
    /// renderer after other passes: it still covers the whole target (it drew a trapezoid over part
    /// of the default projects arsenal and fantasticcar).
    func testTheFadeCoversAWideTargetAfterOtherDraws() throws {
        _ = try Fixtures.assets()
        let fade = try SceneCameraFade.build(with: builder)
        for _ in 0..<2 {
            let frame = try target(filledWith: SIMD4(0, 0, 0, 255), width: 192, height: 108)
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            fade.encode(on: frame, alpha: 1, builtins: BuiltinFrameContext(), values: Properties(), commandBuffer: commands)
            commands.commit()
            commands.waitUntilCompleted()
            let bytes = try TextureUploadTests.read(frame, device: device)
            let covered = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 0 }.count
            XCTAssertEqual(covered, 192 * 108, "every pixel faded")
        }
    }

    private func target(filledWith value: SIMD4<UInt8>, width: Int = 8, height: Int = 8) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let bytes = [UInt8](repeating: 0, count: width * height * 4).enumerated().map { value[$0.offset % 4] }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        return texture
    }
}
