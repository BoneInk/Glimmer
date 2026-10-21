import XCTest
import Metal
@testable import OpenWallpaperEngine

/// WE's HDR bloom (`SceneHDRChain`): its util passes, translated and run by the effect graph on
/// float frames, against the CPU model of the same passes (`HDRReference`), and WE's arithmetic
/// for the levels, constants and `g_RenderVar0`.
final class SceneHDRChainTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var effects: EffectGraphRenderer!
    private var chain: SceneHDRChain!
    private var cache: URL!
    private var frameIndex: UInt64 = 0

    private struct NoValues: SceneValueContext {
        func userProperty(_ name: String) -> String? { nil }
    }

    private static let targetFormats = EffectGraphRenderer.TargetFormats(frameBuffer: .rgba16Float,
                                                                         output: SceneHDRChain.outputFormat)

    override func setUpWithError() throws {
        _ = try Fixtures.assets()
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-hdr-\(UUID().uuidString)")
        effects = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: cache.appending(path: "archives")))
        let root = ShaderVariantTests.weAssets
        let builder = SceneEffectPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { FileManager.default.contents(atPath: root.appending(path: $0).path) },
            loadTexture: { _, _ in nil },
            sceneEngineCombos: SceneEngineCombos(hdr: true))
        chain = try SceneHDRChain.build(with: builder)
        XCTAssertTrue(effects.waitUntilReady([chain.full], width: 64, height: 64, targetFormats: Self.targetFormats))
        XCTAssertEqual(effects.failedPipelineCount, 0)
    }

    override func tearDownWithError() throws {
        effects?.pipelineArchive?.flush()
        if let cache { try? FileManager.default.removeItem(at: cache) }
    }

    // MARK: - WE's arithmetic

    /// The levels: how many times the smaller side halves before 0, at most 8 (`0x14017f370`).
    func testLevelsFollowTheSmallerSide() throws {
        _ = try Fixtures.assets()
        XCTAssertEqual(SceneHDRChain.levels(width: 1920, height: 1080), 8)
        XCTAssertEqual(SceneHDRChain.levels(width: 5120, height: 2880), 8)
        XCTAssertEqual(SceneHDRChain.levels(width: 64, height: 48), 5, "48 → 24, 12, 6, 3, 1")
        XCTAssertEqual(SceneHDRChain.levels(width: 256, height: 256), 8)
        XCTAssertEqual(SceneHDRChain.levels(width: 255, height: 400), 7)
        XCTAssertEqual(SceneHDRChain.levels(width: 1, height: 1), 1, "WE takes the frame as 2×2 at least")
        XCTAssertEqual(SceneHDRChain.runLevels(width: 1920, height: 1080, iterations: 8), 8)
        XCTAssertEqual(SceneHDRChain.runLevels(width: 1920, height: 1080, iterations: 3), 3)
        XCTAssertEqual(SceneHDRChain.runLevels(width: 64, height: 48, iterations: 8), 5)
        XCTAssertEqual(SceneHDRChain.runLevels(width: 1920, height: 1080, iterations: 0), 1)
        XCTAssertEqual(SceneHDRChain.runLevels(width: 1920, height: 1080, iterations: -4), 1)
    }

    /// WE's defaults give strength 2 / (1 + 1.619^6) and blend (1, 0.9, 0.2, 2.5) (`0x140184020`).
    func testConstantsAreWEs() throws {
        _ = try Fixtures.assets()
        let defaults = SceneHDRChain.Constants(SceneHDRBloomSettings(), levels: 8, tint: SIMD3(repeating: 1))
        XCTAssertEqual(defaults.strength, 2 / (1 + powf(1.619, 6)), accuracy: 1e-6)
        XCTAssertEqual(defaults.strength, 0.1052, accuracy: 1e-4)
        XCTAssertEqual(defaults.blend.x, 1)
        XCTAssertEqual(defaults.blend.y, 0.9, accuracy: 1e-6)
        XCTAssertEqual(defaults.blend.z, 0.2, accuracy: 1e-6)
        XCTAssertEqual(defaults.blend.w, 0.25 / (0.1 + 1e-5), accuracy: 1e-4)
        XCTAssertEqual(defaults.scatter, 1.619, accuracy: 1e-6)
        // n ≤ 2 normalises by 1 + scatter^0 = 2.
        XCTAssertEqual(SceneHDRChain.Constants(SceneHDRBloomSettings(), levels: 1, tint: SIMD3(repeating: 1)).strength, 1)
        XCTAssertEqual(SceneHDRChain.Constants(SceneHDRBloomSettings(), levels: 2, tint: SIMD3(repeating: 1)).strength, 1)
        XCTAssertEqual(SceneHDRChain.Constants(SceneHDRBloomSettings(), levels: 3, tint: SIMD3(repeating: 1)).strength,
                       2 / 2.619, accuracy: 1e-6)
        // The app's bloom slider scales it; 1 is WE's.
        XCTAssertEqual(SceneHDRChain.Constants(SceneHDRBloomSettings(), levels: 8, tint: SIMD3(repeating: 1),
                                               strengthScale: 2).strength, defaults.strength * 2, accuracy: 1e-6)
    }

    /// `g_RenderVar0` per pass (`0x140183610`): D0 ±1 frame texel, then × 2^level; the combine
    /// gets the device's (1, 0) and keeps the last pass's zw.
    func testRenderVarsAreWEs() throws {
        _ = try Fixtures.assets()
        let size = SIMD2<Float>(1920, 1080)
        let base = SIMD4<Float>(1 / 1920, 1 / 1080, -1 / 1920, -1 / 1080)
        let vars = SceneHDRChain.renderVars(levels: 8, size: size)
        XCTAssertEqual(vars[SceneHDRChain.Pass.downsampleBloom], base)
        XCTAssertEqual(vars[SceneHDRChain.Pass.downsample(3)], base * 8)
        XCTAssertEqual(vars[SceneHDRChain.Pass.upsample(3)], base * 8)
        XCTAssertEqual(vars[SceneHDRChain.Pass.upsampleCubic(7)], base * 128)
        XCTAssertEqual(vars[SceneHDRChain.Pass.combine], SIMD4(1, 0, base.z * 2, base.w * 2))
        XCTAssertEqual(SceneHDRChain.renderVars(levels: 1, size: size)[SceneHDRChain.Pass.combine], SIMD4(1, 0, base.z, base.w))
    }

    // MARK: - The plan

    /// Every pass is WE's own material with WE's targets; a frame's plan picks its levels, bicubic
    /// for the two coarsest upsamples.
    func testThePlanIsWEsMipChain() throws {
        _ = try Fixtures.assets()
        let full = chain.full
        XCTAssertEqual(full.fbos.map(\.name), (0..<8).map(SceneHDRChain.target))
        XCTAssertEqual(full.fbos.map(\.name).first, "_rt_2FrameBuffer")
        XCTAssertEqual(full.fbos.map(\.name).last, "_rt_256FrameBuffer")
        XCTAssertEqual(full.fbos.map(\.scale), [2, 4, 8, 16, 32, 64, 128, 256])
        XCTAssertEqual(Set(full.fbos.map { EffectGraphRenderer.pixelFormat($0.format) }), [.rgba16Float])

        let plan = chain.plan(levels: 5)
        let indices = plan.passes.map(\.materialIndex)
        XCTAssertEqual(indices, [0, 1, 2, 3, 4, SceneHDRChain.Pass.upsampleCubic(4), SceneHDRChain.Pass.upsampleCubic(3),
                                 SceneHDRChain.Pass.upsample(2), SceneHDRChain.Pass.upsample(1), SceneHDRChain.Pass.combine])
        XCTAssertEqual(plan.passes.map(\.target), ["_rt_2FrameBuffer", "_rt_4FrameBuffer", "_rt_8FrameBuffer",
                                                   "_rt_16FrameBuffer", "_rt_32FrameBuffer", "_rt_16FrameBuffer",
                                                   "_rt_8FrameBuffer", "_rt_4FrameBuffer", "_rt_2FrameBuffer", nil])
        XCTAssertEqual(plan.fbos.count, 5)
        XCTAssertEqual(plan.passes.map(\.blending), ["normal", "normal", "normal", "normal", "normal",
                                                     "additive", "additive", "additive", "additive", "normal"])
        func input(_ pass: SceneEffectPassPlan, _ slot: Int) -> String {
            switch pass.textures[slot] {
            case .sceneSnapshot?: return "_rt_FullFrameBuffer"
            case .fbo(let name)?: return name
            case .current?: return "current"
            case let other: return "\(String(describing: other))"
            }
        }
        XCTAssertEqual(input(plan.passes[0], 0), "current")
        XCTAssertEqual(input(plan.passes[1], 0), "_rt_2FrameBuffer")
        XCTAssertEqual(input(plan.passes[5], 0), "_rt_32FrameBuffer")
        XCTAssertEqual([input(plan.passes[9], 0), input(plan.passes[9], 1)], ["_rt_FullFrameBuffer", "_rt_2FrameBuffer"])
        XCTAssertEqual(chain.plan(levels: 1).passes.map(\.materialIndex), [0, SceneHDRChain.Pass.combine])
        XCTAssertEqual(chain.plan(levels: 2).passes.map(\.materialIndex), [0, 1, SceneHDRChain.Pass.upsampleCubic(1),
                                                                           SceneHDRChain.Pass.combine])
        let srgb = chain.plan(levels: nil)
        XCTAssertEqual(srgb.passes.map(\.materialIndex), [SceneHDRChain.Pass.combineSRGB])
        XCTAssertEqual(input(srgb.passes[0], 0), "_rt_FullFrameBuffer")
        // The materials' own defaults (overwritten each frame with WE's values).
        let d0 = full.passes[0].constants.staticValues
        XCTAssertEqual(d0["g_BloomStrength"]?.components, [2])
        XCTAssertEqual(d0["g_BloomBlendParams"]?.components, [1, 1, 0, 1])
    }

    // MARK: - Against the CPU model

    /// Float frames with overbright values: an impulse, a step, a gradient, and odd sizes.
    private static let frames: [(name: String, image: HDRReference.Image)] = [
        ("impulse", HDRReference.Image(width: 64, height: 48) { x, y in
            (28..<36).contains(x) && (20..<28).contains(y) ? SIMD3(4, 3, 2.5) : SIMD3(repeating: 0.05)
        }),
        ("step", HDRReference.Image(width: 64, height: 48) { x, _ in
            x < 32 ? SIMD3(0.2, 0.25, 0.3) : SIMD3(1.6, 1.1, 0.4)
        }),
        ("gradient", HDRReference.Image(width: 64, height: 48) { x, y in
            SIMD3(Float(x) / 21, Float(y) / 47, 1 - Float(x) / 63)
        }),
        ("odd size", HDRReference.Image(width: 70, height: 37) { x, y in
            (x / 5 + y / 5) % 3 == 0 ? SIMD3(2, 1.8, 1.4) : SIMD3(0.1, 0.2, 0.3)
        }),
        ("tall", HDRReference.Image(width: 23, height: 90) { x, y in
            (x - 11) * (x - 11) + (y - 45) * (y - 45) < 30 ? SIMD3(repeating: 6) : .zero
        }),
    ].map { (name: $0.0, image: $0.1.halved) }

    /// (settings, tint): WE's defaults, the Cyberpunk Samurai's, a hard knee, a tinted soft one
    /// with a low threshold, and none.
    private static let settings: [(SceneHDRBloomSettings, SIMD3<Float>)] = {
        func make(_ strength: Float, _ threshold: Float, _ feather: Float, _ scatter: Float, _ iterations: Int) -> SceneHDRBloomSettings {
            var settings = SceneHDRBloomSettings()
            settings.enabled = true
            settings.strength = strength
            settings.threshold = threshold
            settings.feather = feather
            settings.scatter = scatter
            settings.iterations = iterations
            return settings
        }
        return [(make(2, 1, 0.1, 1.619, 8), SIMD3(repeating: 1)),
                (make(2.11, 1, 0.34, 1.33, 8), SIMD3(repeating: 1)),
                (make(3, 0.9, 0, 2, 3), SIMD3(repeating: 1)),
                (make(1.5, 0.4, 0.5, 1, 2), SIMD3(1, 0.5, 0.25)),
                (make(0, 1, 0.1, 1.619, 8), SIMD3(repeating: 1))]
    }()

    /// The rendered chain equals the CPU model within 2/255 on every pixel and channel.
    func testTheChainMatchesTheCPUModel() throws {
        _ = try Fixtures.assets()
        for frame in Self.frames {
            for (settings, tint) in Self.settings {
                let levels = SceneHDRChain.runLevels(width: frame.image.width, height: frame.image.height,
                                                     iterations: settings.iterations)
                let constants = SceneHDRChain.Constants(settings, levels: levels, tint: tint)
                let rendered = try run(frame.image, levels: levels, constants: constants)
                let expected = HDRReference.run(frame.image, levels: levels, constants: constants)
                let label = "\(frame.name), \(levels) levels, \(constants)"
                XCTAssertEqual(rendered.count, expected.count, label)
                let worst = zip(rendered, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
                XCTAssertLessThanOrEqual(worst, 2, "\(label): off by \(worst)/255")
                if settings.strength == 0 {
                    // The two combines round differently in the last bit.
                    let srgb = try run(frame.image, levels: nil, constants: constants)
                    let apart = zip(rendered, srgb).map { abs(Int($0) - Int($1)) }.max() ?? 0
                    XCTAssertLessThanOrEqual(apart, 1, "\(label): no bloom is combine_srgb")
                }
            }
        }
    }

    /// Without bloom a HDR frame goes through `combine_srgb`: the sRGB bytes of the frame, clamped.
    func testCombineSRGBIsTheFrameClamped() throws {
        _ = try Fixtures.assets()
        let frame = Self.frames[1].image
        let constants = SceneHDRChain.Constants(SceneHDRBloomSettings(), levels: 1, tint: SIMD3(repeating: 1))
        let rendered = try run(frame, levels: nil, constants: constants)
        XCTAssertEqual(rendered, HDRReference.run(frame, levels: nil, constants: constants))
        // In 0…1 the bytes are the frame's (an 8-bit frame would have held the same); overbright clamps.
        for (index, value) in [(0, Float(0.2)), (1, 0.25), (2, 0.3)] {
            XCTAssertLessThanOrEqual(abs(Int(rendered[index]) - Int((value * 255).rounded())), 1)
        }
        let right = (10 * 64 + 40) * 4
        XCTAssertEqual(Array(rendered[right..<right + 2]), [255, 255])
    }

    /// A HDR video's frame holds linear light: `combine_video_hdr` replaces `combine_srgb`, with no
    /// linearisation, clamped to [0, 2 · g_HDRParams.y]: 2 · (headroom − 1) on the EDR output, SDR
    /// white on a display without headroom (then encoded to sRGB like every combine).
    func testAHDRVideoCombinesWithCombineVideoHDR() throws {
        _ = try Fixtures.assets()
        let plan = chain.plan(levels: nil, videoHDR: true)
        XCTAssertEqual(plan.passes.map(\.materialIndex), [SceneHDRChain.Pass.combineVideoHDR])
        if case .sceneSnapshot? = plan.passes.first?.textures[0] {} else { XCTFail("combine_video_hdr reads _rt_FullFrameBuffer") }
        XCTAssertEqual(chain.plan(levels: 2, videoHDR: true).passes.last?.materialIndex, SceneHDRChain.Pass.combine,
                       "bloom keeps its own combine, as WE's does")

        let values: [Float] = [0.5, 3, 40, -1]
        let image = HDRReference.Image(width: 16, height: 4) { x, _ in SIMD3(repeating: values[x / 4]) }
        let texture = try HDRReference.texture(image, device: device)
        let constants = SceneHDRChain.Constants(SceneHDRBloomSettings(), levels: 1, tint: SIMD3(repeating: 1))
        XCTAssertTrue(effects.waitUntilReady([chain.full], width: 16, height: 4, targetFormats: EffectGraphRenderer.TargetFormats(
            frameBuffer: .rgba16Float, output: SceneHDRChain.displayHDROutputFormat)))
        let edr = try encode(texture, levels: nil, constants: constants, displayHDR: SIMD2(1, 3), videoHDR: true)
        XCTAssertEqual(edr.pixelFormat, SceneHDRChain.displayHDROutputFormat)
        let shown = try HDRReference.read(edr, device: device)
        for (band, expected) in [Float(0.5), 3, 6, 0].enumerated() {
            XCTAssertEqual(shown[band * 4 + 1, 1].x, expected, accuracy: 0.01, "band \(band)")
        }

        let standard = try encode(texture, levels: nil, constants: constants, videoHDR: true)
        XCTAssertEqual(standard.pixelFormat, SceneHDRChain.outputFormat)
        let bytes = try TextureUploadTests.read(standard, device: device)
        // sRGB(0.5) = 188; 3 and 40 clamp to SDR white; below 0 is black.
        XCTAssertEqual([bytes[4], bytes[16], bytes[32], bytes[48]].map(Int.init), [188, 255, 255, 0])
    }

    /// Only light above the threshold blooms: a patch at 1.0 stays (almost) dark around, one at 3 glows.
    func testBloomFollowsWEsKnee() throws {
        _ = try Fixtures.assets()
        func patch(_ value: Float) -> HDRReference.Image {
            HDRReference.Image(width: 64, height: 48) { x, y in
                (24..<40).contains(x) && (16..<32).contains(y) ? SIMD3(value, value, value) : .zero
            }
        }
        let constants = SceneHDRChain.Constants(SceneHDRBloomSettings(), levels: 5, tint: SIMD3(repeating: 1))
        let outside = (24 * 64 + 44) * 4
        let below = try run(patch(0.85), levels: 5, constants: constants)
        XCTAssertEqual(below[outside], 0, "below the knee (0.9) nothing blooms")
        let at = try run(patch(1), levels: 5, constants: constants)
        XCTAssertLessThan(at[outside], 12, "in the knee a little")
        let above = try run(patch(3), levels: 5, constants: constants)
        XCTAssertGreaterThan(above[outside], 60, "the glow spreads past the patch")
    }

    /// The same frame blooms the same way every time: no state leaks between frames or levels.
    func testTheChainIsStable() throws {
        _ = try Fixtures.assets()
        let frame = Self.frames[0].image
        let constants = SceneHDRChain.Constants(SceneHDRBloomSettings(), levels: 5, tint: SIMD3(repeating: 1))
        let first = try run(frame, levels: 5, constants: constants)
        _ = try run(Self.frames[2].image, levels: 2, constants: constants)
        _ = try run(frame, levels: nil, constants: constants)
        for _ in 0..<3 {
            XCTAssertEqual(try run(frame, levels: 5, constants: constants), first)
        }
    }

    // MARK: - Cost

    /// GPU time of the chain on a frame at 1080p and 5K, 8 levels: one command buffer of `batch`
    /// chains back to back, over `batch`.
    func testTheChainIsCheap() throws {
        _ = try Fixtures.assets()
        let batch = 10
        var report = ""
        let constants = SceneHDRChain.Constants(SceneHDRBloomSettings(), levels: 8, tint: SIMD3(repeating: 1))
        for (name, width, height, budget) in [("1080p", 1920, 1080, 4.0), ("5K", 5120, 2880, 20.0)] {
            let image = HDRReference.Image(width: width, height: height) { x, y in
                (x / 64 + y / 64) % 5 == 0 ? SIMD3(3, 2, 1) : SIMD3(Float(x & 0xff) / 255, Float(y & 0xff) / 255, 0.2)
            }
            let texture = try HDRReference.texture(image, device: device)
            _ = try encode(texture, levels: 8, constants: constants)
            var times: [Double] = []
            for _ in 0..<12 {
                let buffer = try XCTUnwrap(queue.makeCommandBuffer())
                for _ in 0..<batch {
                    frameIndex += 1
                    XCTAssertNotNil(chain.encode(on: texture, levels: 8, constants: constants, effects: effects,
                                                 builtins: BuiltinFrameContext(), values: NoValues(),
                                                 frameIndex: frameIndex, commandBuffer: buffer))
                }
                buffer.commit()
                buffer.waitUntilCompleted()
                times.append((buffer.gpuEndTime - buffer.gpuStartTime) * 1000 / Double(batch))
            }
            let median = times.sorted()[times.count / 2]
            report += String(format: "%@ %dx%d: median %.3f ms, min %.3f ms per frame\n", name, width, height, median,
                             times.min() ?? 0)
            // The fastest sample: other work sharing the GPU only slows samples down.
            let fastest = times.min() ?? .infinity
            // A regression guard, not a benchmark: the machine is often shared with other GPU work,
            // so only a several-fold blow-up fails (the measured costs are in the printed report).
            XCTAssertLessThan(fastest, budget * 5, "\(name): the HDR chain costs \(fastest) ms")
        }
        print("HDR bloom chain GPU time:\n\(report)")
    }

    // MARK: - Helpers

    /// Encodes the chain in a command buffer of its own and waits for it.
    private func encode(_ texture: MTLTexture, levels: Int?, constants: SceneHDRChain.Constants,
                        displayHDR: SIMD2<Float>? = nil, videoHDR: Bool = false) throws -> MTLTexture {
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        frameIndex += 1
        let output = try XCTUnwrap(chain.encode(on: texture, levels: levels, constants: constants, effects: effects,
                                                builtins: BuiltinFrameContext(), values: NoValues(),
                                                frameIndex: frameIndex, displayHDR: displayHDR, videoHDR: videoHDR,
                                                commandBuffer: buffer))
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        return output
    }

    private func run(_ image: HDRReference.Image, levels: Int?, constants: SceneHDRChain.Constants) throws -> [UInt8] {
        let texture = try HDRReference.texture(image, device: device)
        let output = try encode(texture, levels: levels, constants: constants)
        XCTAssertEqual(output.width, image.width)
        XCTAssertEqual(output.height, image.height)
        XCTAssertEqual(output.pixelFormat, SceneHDRChain.outputFormat)
        let view = try XCTUnwrap(SceneHDRChain.encodedView(of: output))
        XCTAssertEqual(view.pixelFormat, .rgba8Unorm)
        return try TextureUploadTests.read(output, device: device)
    }
}
