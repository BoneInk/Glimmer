import XCTest
import Metal
@testable import OpenWallpaperEngine

/// WE's LDR bloom (`SceneBloomChain`): its four util passes, translated and run by the effect
/// graph, against the CPU model of the same passes (`BloomReference`) on synthetic frames.
final class SceneBloomChainTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var effects: EffectGraphRenderer!
    private var chain: SceneBloomChain!
    private var cache: URL!
    private var frameIndex: UInt64 = 0

    private struct NoValues: SceneValueContext {
        func userProperty(_ name: String) -> String? { nil }
    }

    override func setUpWithError() throws {
        _ = try Fixtures.assets()
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-bloom-\(UUID().uuidString)")
        effects = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: cache.appending(path: "archives")))
        let root = ShaderVariantTests.weAssets
        let builder = SceneEffectPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { FileManager.default.contents(atPath: root.appending(path: $0).path) },
            loadTexture: { _, _ in nil })
        chain = try SceneBloomChain.build(with: builder)
        XCTAssertTrue(effects.waitUntilReady([chain.plan], width: 64, height: 64))
        XCTAssertEqual(effects.failedPipelineCount, 0)
    }

    override func tearDownWithError() throws {
        effects?.pipelineArchive?.flush()
        if let cache { try? FileManager.default.removeItem(at: cache) }
    }

    // MARK: - The plan

    /// Four passes of WE's own materials, with WE's targets, inputs and constants' defaults.
    func testThePlanIsWEsFourUtilPasses() throws {
        _ = try Fixtures.assets()
        let plan = try XCTUnwrap(chain.plan)
        XCTAssertEqual(plan.passes.map(\.target), ["_rt_4FrameBuffer", "_rt_8FrameBuffer", "_rt_Bloom", nil])
        XCTAssertEqual(plan.fbos.map(\.name), ["_rt_4FrameBuffer", "_rt_8FrameBuffer", "_rt_Bloom"])
        XCTAssertEqual(plan.fbos.map(\.scale), [4, 8, 8])
        XCTAssertEqual(plan.fbos.map { EffectGraphRenderer.pixelFormat($0.format) }, [.rgba8Unorm, .rgba8Unorm, .rgba8Unorm])
        func input(_ pass: Int, _ slot: Int) -> String {
            switch plan.passes[pass].textures[slot] {
            case .sceneSnapshot?: return "_rt_FullFrameBuffer"
            case .fbo(let name)?: return name
            case let other: return "\(String(describing: other))"
            }
        }
        XCTAssertEqual(input(0, 0), "_rt_FullFrameBuffer")
        XCTAssertEqual(input(1, 0), "_rt_4FrameBuffer")
        XCTAssertEqual(input(2, 0), "_rt_8FrameBuffer")
        XCTAssertEqual([input(3, 0), input(3, 1)], ["_rt_FullFrameBuffer", "_rt_Bloom"])
        XCTAssertTrue(plan.passes.allSatisfy { $0.blending == "normal" })
        let constants = plan.passes[0].constants.staticValues
        XCTAssertEqual(constants["g_BloomStrength"]?.components, [2])
        XCTAssertEqual(constants["g_BloomThreshold"]?.components, [0.65])
        XCTAssertEqual(constants["g_BloomTint"]?.components, [1, 1, 1])
    }

    // MARK: - Against the CPU model

    /// Synthetic frames: an impulse, a step and a gradient, sized so the 1/4 and 1/8 targets are
    /// exact; and one that isn't a multiple of 8.
    private static let frames: [(name: String, image: BloomReference.Image)] = [
        ("impulse", BloomReference.Image(width: 64, height: 48) { x, y in
            (28..<36).contains(x) && (20..<28).contains(y) ? SIMD3(repeating: 1) : SIMD3(repeating: 0.05)
        }),
        ("step", BloomReference.Image(width: 64, height: 48) { x, _ in
            x < 32 ? SIMD3(0.2, 0.25, 0.3) : SIMD3(0.95, 0.8, 0.4)
        }),
        ("gradient", BloomReference.Image(width: 64, height: 48) { x, y in
            SIMD3(Float(x) / 63, Float(y) / 47, 1 - Float(x) / 63)
        }),
        ("odd size", BloomReference.Image(width: 70, height: 37) { x, y in
            (x / 5 + y / 5) % 3 == 0 ? SIMD3(1, 0.9, 0.7) : SIMD3(0.1, 0.2, 0.3)
        }),
    ]

    /// (strength, threshold, tint): WE's defaults, a tinted soft one, a hard one and none.
    private static let constants: [(Float, Float, SIMD3<Float>)] = [
        (2, 0.65, SIMD3(repeating: 1)),
        (1.3, 0.3, SIMD3(1, 0.5, 0.25)),
        (3.53, 0.94, SIMD3(repeating: 1)),
        (0, 0.65, SIMD3(repeating: 1)),
    ]

    /// The rendered chain equals the CPU model within 2/255 on every pixel and channel.
    func testTheChainMatchesTheCPUModel() throws {
        _ = try Fixtures.assets()
        for frame in Self.frames {
            for (strength, threshold, tint) in Self.constants {
                let rendered = try run(frame.image, strength: strength, threshold: threshold, tint: tint)
                let expected = BloomReference.run(frame.image, strength: strength, threshold: threshold, tint: tint).rgba
                let label = "\(frame.name), strength \(strength), threshold \(threshold), tint \(tint)"
                XCTAssertEqual(rendered.count, expected.count, label)
                let worst = zip(rendered, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
                XCTAssertLessThanOrEqual(worst, 2, "\(label): off by \(worst)/255")
                if strength == 0 {
                    XCTAssertEqual(rendered, frame.image.rgba, "\(label): no bloom leaves the frame as it is")
                }
            }
        }
    }

    /// Bloom adds only where the 4×4 box's brightest channel passes the threshold.
    func testBloomFollowsWEsThreshold() throws {
        _ = try Fixtures.assets()
        func patch(_ value: Float) -> BloomReference.Image {
            BloomReference.Image(width: 64, height: 48) { x, y in
                (24..<40).contains(x) && (16..<32).contains(y) ? SIMD3(value, value * 0.5, 0) : .zero
            }
        }
        let below = patch(0.6)
        XCTAssertEqual(try run(below, strength: 2, threshold: 0.65, tint: SIMD3(repeating: 1)), below.rgba,
                       "a patch below the threshold doesn't bloom")
        let above = patch(0.95)
        let rendered = try run(above, strength: 2, threshold: 0.65, tint: SIMD3(repeating: 1))
        let input = above.rgba
        // Right of the patch, in the dark: the glow.
        let outside = (24 * 64 + 42) * 4
        XCTAssertEqual(input[outside], 0)
        XCTAssertGreaterThan(rendered[outside], 10, "the glow spreads past the patch")
        XCTAssertTrue(zip(rendered, input).allSatisfy { $0 >= $1 }, "bloom only adds")
    }

    /// The same frame blooms the same way every time: no state leaks between frames.
    func testTheChainIsStable() throws {
        _ = try Fixtures.assets()
        let frame = Self.frames[0].image
        let first = try run(frame, strength: 2, threshold: 0.65, tint: SIMD3(repeating: 1))
        _ = try run(Self.frames[2].image, strength: 1, threshold: 0.2, tint: SIMD3(1, 0, 0))
        for _ in 0..<3 {
            XCTAssertEqual(try run(frame, strength: 2, threshold: 0.65, tint: SIMD3(repeating: 1)), first)
        }
    }

    // MARK: - Cost

    /// GPU time of the chain on a frame at 1080p and 5K: it has to be cheap. Each sample is one
    /// command buffer of `batch` chains back to back, as frames keep the GPU busy, over `batch`.
    func testTheChainIsCheap() throws {
        _ = try Fixtures.assets()
        let batch = 10
        var report = ""
        for (name, width, height, budget) in [("1080p", 1920, 1080, 2.0), ("5K", 5120, 2880, 8.0)] {
            let texture = try frameTexture(width: width, height: height) { x, y in
                let bright: UInt8 = (x / 64 + y / 64) % 5 == 0 ? 250 : 60
                return [bright, UInt8(x & 0xff), UInt8(y & 0xff), 255]
            }
            _ = try encode(texture, strength: 2, threshold: 0.65, tint: SIMD3(repeating: 1))
            var times: [Double] = []
            for _ in 0..<12 {
                let buffer = try XCTUnwrap(queue.makeCommandBuffer())
                for _ in 0..<batch {
                    frameIndex += 1
                    XCTAssertNotNil(chain.encode(on: texture, strength: 2, threshold: 0.65, tint: SIMD3(repeating: 1),
                                                 effects: effects, builtins: BuiltinFrameContext(), values: NoValues(),
                                                 frameIndex: frameIndex, commandBuffer: buffer))
                }
                buffer.commit()
                buffer.waitUntilCompleted()
                times.append((buffer.gpuEndTime - buffer.gpuStartTime) * 1000 / Double(batch))
            }
            let median = times.sorted()[times.count / 2]
            report += String(format: "%@ %dx%d: median %.3f ms, min %.3f ms per frame\n", name, width, height, median,
                             times.min() ?? 0)
            // The fastest sample: other work sharing the GPU (parallel tests, the desktop) only slows samples down.
            let fastest = times.min() ?? .infinity
            XCTAssertLessThan(fastest, budget, "\(name): the bloom chain costs \(fastest) ms")
        }
        print("LDR bloom chain GPU time:\n\(report)")
    }

    // MARK: - Helpers

    private func frameTexture(width: Int, height: Int, pixel: (Int, Int) -> [UInt8]) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = pixel(x, y)
                let i = (y * width + x) * 4
                bytes[i] = value[0]; bytes[i + 1] = value[1]; bytes[i + 2] = value[2]; bytes[i + 3] = value[3]
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes,
                        bytesPerRow: width * 4)
        return texture
    }

    /// Encodes the chain in a command buffer of its own and waits for it.
    private func encode(_ texture: MTLTexture, strength: Float, threshold: Float,
                        tint: SIMD3<Float>) throws -> (output: MTLTexture, buffer: MTLCommandBuffer) {
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        frameIndex += 1
        let output = try XCTUnwrap(chain.encode(on: texture, strength: strength, threshold: threshold, tint: tint,
                                                effects: effects, builtins: BuiltinFrameContext(), values: NoValues(),
                                                frameIndex: frameIndex, commandBuffer: buffer))
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        return (output, buffer)
    }

    private func run(_ image: BloomReference.Image, strength: Float, threshold: Float,
                     tint: SIMD3<Float>) throws -> [UInt8] {
        let bytes = image.rgba
        let texture = try frameTexture(width: image.width, height: image.height) { x, y in
            let i = (y * image.width + x) * 4
            return Array(bytes[i..<i + 4])
        }
        let output = try encode(texture, strength: strength, threshold: threshold, tint: tint).output
        XCTAssertEqual(output.width, image.width)
        XCTAssertEqual(output.height, image.height)
        XCTAssertEqual(output.pixelFormat, .rgba8Unorm)
        return try TextureUploadTests.read(output, device: device)
    }
}
