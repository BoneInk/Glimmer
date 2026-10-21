import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// `HDR=1` on WE's materials (docs/lighting-plan.md §2.6, 0x1401a6721): the shaders that test it
/// translate and build, and CombineLighting's overbright path computes WE's values on a float target.
final class SceneHDRMaterialTests: XCTestCase {
    /// The shipped shaders with an `HDR` branch, and the combos that reach it.
    private static let shaders: [(String, [String: Int])] = [
        ("genericimage2", ["REFLECTION": 1, "EMISSIVE_MAP": 1, "PBRMASKS": 1]),
        ("genericimage3", [:]),
        ("genericimage4", ["LIGHTING": 1, "EMISSIVE_MAP": 1, "PBRMASKS": 1]),
        ("generic2", [:]),
        ("generic4", ["LIGHTING": 1]),
        ("ccsimple", [:]),
    ]

    /// Every shipped shader with an `HDR` branch translates and builds a pipeline with `HDR=1`.
    func testHDRShadersTranslate() throws {
        _ = try Fixtures.assets()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil, failureDirectory: nil)
        let loader = ShaderSourceLoader(roots: [ShaderVariantTests.weAssets])
        let engine = SceneEngineCombos(hdr: true, sceneOrtho: true)
        var failures: [String] = []
        for (path, overrides) in Self.shaders {
            let vertex = try loader.load(path, stage: .vertex), fragment = try loader.load(path, stage: .fragment)
            let combos = engine.applied(to: ShaderVariantTranslator.resolveCombos(
                vertex: vertex, fragment: fragment, overrides: [overrides], boundTextureSlots: [0]))
            XCTAssertEqual(combos["HDR"], 1, path)
            do {
                let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: combos)
                _ = try ShaderVariantTests.makePipeline(variant, device: device)
            } catch {
                failures.append("\(path): \(error)")
            }
        }
        XCTAssertEqual(failures, [])
    }

    /// A probe effect whose pass returns `CombineLighting(light, 0.25)` for the light in its input:
    /// with `HDR=1` it is `saturate(ambient + light) + light · overbright`, where overbright is
    /// `saturate(|light| − 2) · 0.5 / max(0.01, |light|)`; without, `ambient + light`.
    func testCombineLightingOverbrightsInHDR() throws {
        _ = try Fixtures.assets()
        let lights: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(0.5, 0.25, 0), SIMD3(1, 1, 1), SIMD3(1.5, 1.5, 1),
                                      SIMD3(3, 2, 1), SIMD3(6, 0, 0), SIMD3(10, 8, 6), SIMD3(0.9, 0.9, 0.9)]
        let ambient = SIMD3<Float>(repeating: 0.25)
        for hdr in [true, false] {
            let rendered = try probe(lights, hdr: hdr)
            for (index, light) in lights.enumerated() {
                let expected: SIMD3<Float>
                if hdr {
                    let length = simd_length(light)
                    let overbright = min(max(length - 2, 0), 1) * 0.5 / max(0.01, length)
                    expected = simd_clamp(ambient + light, .zero, SIMD3(repeating: 1)) + light * overbright
                } else {
                    expected = ambient + light
                }
                let drawn = rendered[index]
                XCTAssertLessThan(simd_length(drawn - expected), 0.01 * max(1, simd_length(expected)),
                                  "HDR \(hdr), light \(light): \(drawn) is not \(expected)")
            }
        }
    }

    // MARK: - Helpers

    private static let probeFiles: [String: String] = [
        "effects/hdrprobe/effect.json": #"{"passes": [{"material": "materials/hdrprobe.json"}]}"#,
        "materials/hdrprobe.json": #"{"passes": [{"shader": "hdrprobe", "blending": "normal"}]}"#,
        "shaders/hdrprobe.vert": """
            attribute vec3 a_Position;
            attribute vec2 a_TexCoord;
            varying vec2 v_TexCoord;
            void main() {
                gl_Position = vec4(a_Position, 1.0);
                v_TexCoord = a_TexCoord;
            }
            """,
        "shaders/hdrprobe.frag": """
            #include "common_pbr.h"
            varying vec2 v_TexCoord;
            uniform sampler2D g_Texture0;
            void main() {
                vec3 light = texSample2D(g_Texture0, v_TexCoord).rgb;
                gl_FragColor = vec4(CombineLighting(light, CAST3(0.25)), 1.0);
            }
            """,
    ]

    /// The probe on a row of `lights`, drawn into RGBA16F; the output per light.
    private func probe(_ lights: [SIMD3<Float>], hdr: Bool) throws -> [SIMD3<Float>] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cache = FileManager.default.temporaryDirectory.appending(path: "owe-hdr-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let effects = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: nil))
        let root = ShaderVariantTests.weAssets
        let builder = SceneEffectPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { Self.probeFiles[$0].map { Data($0.utf8) } ?? FileManager.default.contents(atPath: root.appending(path: $0).path) },
            loadTexture: { _, _ in nil },
            sceneEngineCombos: SceneEngineCombos(hdr: hdr))
        let effect = try JSONDecoder().decode(WEObjectEffect.self, from: Data(#"{"file": "effects/hdrprobe/effect.json"}"#.utf8))
        let plan = try builder.build(effect)
        let formats = EffectGraphRenderer.TargetFormats(frameBuffer: .rgba16Float, output: .rgba16Float)
        XCTAssertTrue(effects.waitUntilReady([plan], width: lights.count, height: 1, targetFormats: formats))
        XCTAssertEqual(effects.failedPipelineCount, 0)
        let input = try HDRReference.texture(HDRReference.Image(width: lights.count, height: 1) { x, _ in lights[x] },
                                             device: device)
        var context = EffectGraphRenderer.Context(frame: BuiltinFrameContext(), values: LiveSceneValueContext(),
                                                  assetTexture: { _, _ in nil }, sceneSnapshot: nil,
                                                  layerColor: SIMD3(repeating: 1), layerAlpha: 1)
        context.frameBufferFormat = .rgba16Float
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let output = try XCTUnwrap(effects.apply([plan], to: input, layerID: "probe", context: context, commandBuffer: buffer))
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertEqual(output.pixelFormat, .rgba16Float, "a layer's buffers are RGBA16F in HDR")
        return try HDRReference.read(output, device: device).pixels
    }
}
