import XCTest
import Metal
import MetalKit
@testable import OpenWallpaperEngine

/// Runs real WE effects headlessly on a checkerboard and checks they actually change it.
final class EffectGraphTests: XCTestCase {
    private var device: MTLDevice!
    private var renderer: EffectGraphRenderer!
    private var builder: SceneEffectPlanBuilder!
    private var cache: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ShaderVariantTests.weAssets.path), "WE install not present")
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-graph-\(UUID().uuidString)")
        renderer = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: cache.appending(path: "archives")))
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache)
        let root = ShaderVariantTests.weAssets
        builder = SceneEffectPlanBuilder(
            translator: translator,
            readFile: { FileManager.default.contents(atPath: root.appending(path: $0).path) },
            loadTexture: { name, materialPath in
                let effectDirectory = materialPath.split(separator: "/").prefix(2).joined(separator: "/")
                for path in ["materials/\(name).tex", "\(name).tex", "\(effectDirectory)/materials/\(name).tex"] {
                    if let data = FileManager.default.contents(atPath: root.appending(path: path).path),
                       let image = TEXParser(data: data).extractImage() { return .image(image) }
                }
                return nil
            })
    }

    override func tearDownWithError() throws {
        // A pending archive write must not see its directory vanish mid-write.
        renderer?.pipelineArchive?.flush()
        if let cache { try? FileManager.default.removeItem(at: cache) }
    }

    private func effect(_ json: String) throws -> WEObjectEffect {
        try JSONDecoder().decode(WEObjectEffect.self, from: Data(json.utf8))
    }

    private func checkerboard(size: Int = 256) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size { for x in 0..<size where (x / 32 + y / 32) % 2 == 0 {
            let i = (y * size + x) * 4
            pixels[i] = 20; pixels[i + 1] = 40; pixels[i + 2] = 200
        } }
        texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: pixels, bytesPerRow: size * 4)
        return texture
    }

    private func read(_ texture: MTLTexture, queue: MTLCommandQueue) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width,
                                                                  height: texture.height, mipmapped: false)
        descriptor.storageMode = .shared
        let copy = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(buffer.makeBlitCommandEncoder())
        blit.copy(from: texture, to: copy)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        copy.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return bytes
    }

    struct FixedValues: SceneValueContext {
        func userProperty(_ name: String) -> String? { nil }
    }

    /// Plans, runs and reads back; returns (input, output) pixels.
    private func run(_ json: String) throws -> (input: [UInt8], output: [UInt8]) {
        let plan = try builder.build(try effect(json))
        XCTAssertFalse(plan.passes.isEmpty)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let input = try checkerboard()
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let loader = MTKTextureLoader(device: device)
        let context = EffectGraphRenderer.Context(
            frame: BuiltinFrameContext(time: 1.5), values: FixedValues(),
            assetTexture: { _, source in
                guard case .image(let image) = source, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                return try? loader.newTexture(cgImage: cg, options: [.SRGB: false])
            },
            sceneSnapshot: nil, layerColor: SIMD3(1, 1, 1), layerAlpha: 1)
        XCTAssertTrue(renderer.waitUntilReady([plan], width: input.width, height: input.height), "pipelines still compiling")
        let output = try XCTUnwrap(renderer.apply([plan], to: input, layerID: "test", context: context, commandBuffer: buffer),
                                   "no pass rendered")
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        return (try read(input, queue: queue), try read(output, queue: queue))
    }

    private func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
    }

    func testTintChangesTheImage() throws {
        let result = try run(#"{"file":"effects/tint/effect.json","passes":[{"constantshadervalues":{"color":"1 0 0","alpha":1}}]}"#)
        XCTAssertGreaterThan(difference(result.input, result.output), 1)
    }

    func testReleaseLayerFreesItsStateAndTargetsAreReused() throws {
        let json = #"{"file":"effects/tint/effect.json","passes":[{"constantshadervalues":{"color":"1 0 0","alpha":1}}]}"#
        _ = try run(json)
        XCTAssertEqual(renderer.layerStateCount, 1)
        let allocated = renderer.targetsAllocated
        renderer.releaseLayer("unknown")
        XCTAssertEqual(renderer.layerStateCount, 1, "unknown ids are ignored")
        renderer.releaseLayer("test")
        XCTAssertEqual(renderer.layerStateCount, 0)
        // The same chain on a new layer takes the released targets instead of allocating.
        _ = try run(json)
        XCTAssertEqual(renderer.targetsAllocated, allocated)
    }

    /// A layer released while its pipelines compile leaves no state behind; the compiles still
    /// land in the shared cache, and a later layer with the same chain uses them.
    func testReleaseLayerWhileItsPipelinesCompile() throws {
        let plan = try builder.build(try effect(#"{"file":"effects/blur/effect.json","passes":[{},{},{},{}]}"#))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let input = try checkerboard()
        let context = EffectGraphRenderer.Context(frame: BuiltinFrameContext(time: 1.5), values: FixedValues(),
                                                  assetTexture: { _, _ in nil }, sceneSnapshot: nil,
                                                  layerColor: SIMD3(1, 1, 1), layerAlpha: 1)
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertNil(renderer.apply([plan], to: input, layerID: "gone", context: context, commandBuffer: buffer),
                     "pipelines are compiling")
        renderer.releaseLayer("gone")
        XCTAssertEqual(renderer.layerStateCount, 0)
        XCTAssertTrue(renderer.waitUntilReady([plan], width: input.width, height: input.height))
        XCTAssertEqual(renderer.layerStateCount, 0, "a finished compile doesn't bring the layer back")
        let compiles = renderer.pipelineCompileCount
        XCTAssertGreaterThan(compiles, 0)
        XCTAssertNotNil(renderer.apply([plan], to: input, layerID: "next", context: context, commandBuffer: buffer))
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        XCTAssertEqual(renderer.pipelineCompileCount, compiles, "the released layer's pipelines are reused")
    }

    /// Many callers asking for the same pipelines at once start one compile per pipeline.
    func testConcurrentRequestsCompileEachPipelineOnce() throws {
        let plan = try builder.build(try effect(#"{"file":"effects/blur/effect.json","passes":[{},{},{},{}]}"#))
        let keys = Set(plan.passes.compactMap { pass -> String? in
            guard case .render = pass.command, pass.variant != nil else { return nil }
            return "\(pass.variantKey)|\(pass.target ?? "")|\(pass.blending)"
        })
        XCTAssertGreaterThan(keys.count, 1)
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            XCTAssertTrue(renderer.waitUntilReady([plan], width: 256, height: 256))
        }
        XCTAssertLessThanOrEqual(renderer.pipelineCompileCount, keys.count)
        XCTAssertEqual(renderer.failedPipelineCount, 0)
    }

    /// Motion blur accumulates into a unique buffer it reads before writing: each frame mixes the
    /// image into what earlier frames left (rate 0.8), so a still image shows through fully after
    /// a few frames, as in WE's effect gallery (no visible change at its defaults). The chain has no
    /// time input, but its output must not be kept after the first frame (`carriesFrames`).
    func testMotionBlurAccumulatesAcrossFrames() throws {
        let plan = try builder.build(try effect(#"{"file":"effects/motionblur/effect.json"}"#))
        XCTAssertTrue(plan.carriesFrames)
        XCTAssertFalse(try builder.build(try effect(#"{"file":"effects/tint/effect.json"}"#)).carriesFrames)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let input = try checkerboard()
        let context = EffectGraphRenderer.Context(frame: BuiltinFrameContext(time: 1.5), values: FixedValues(),
                                                  assetTexture: { _, _ in nil }, sceneSnapshot: nil,
                                                  layerColor: SIMD3(1, 1, 1), layerAlpha: 1)
        XCTAssertTrue(renderer.waitUntilReady([plan], width: input.width, height: input.height))
        var outputs: [[UInt8]] = []
        for _ in 0..<8 {
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            let output = try XCTUnwrap(renderer.apply([plan], to: input, layerID: "blur", context: context, commandBuffer: buffer))
            buffer.commit()
            buffer.waitUntilCompleted()
            outputs.append(try read(output, queue: queue))
        }
        let pixels = try read(input, queue: queue)
        XCTAssertGreaterThan(difference(pixels, outputs[0]), 10, "the first frame is 0.8 of the image")
        XCTAssertLessThan(difference(pixels, outputs[7]), 1, "after eight frames the image shows through")
    }

    /// `restartHistory` takes a chain that carries frames back to its first frame: motion blur's
    /// buffers go back to transparent black, so the next frame is again 0.8 of the image, not what
    /// the frames before it accumulated (a scene's frames before its first complete one).
    func testRestartedHistoryStartsFromTheNextFrame() throws {
        let plan = try builder.build(try effect(#"{"file":"effects/motionblur/effect.json"}"#))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let input = try checkerboard()
        let context = EffectGraphRenderer.Context(frame: BuiltinFrameContext(time: 1.5), values: FixedValues(),
                                                  assetTexture: { _, _ in nil }, sceneSnapshot: nil,
                                                  layerColor: SIMD3(1, 1, 1), layerAlpha: 1)
        XCTAssertTrue(renderer.waitUntilReady([plan], width: input.width, height: input.height))
        func frame() throws -> [UInt8] {
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            let output = try XCTUnwrap(renderer.apply([plan], to: input, layerID: "blur", context: context, commandBuffer: buffer))
            buffer.commit()
            buffer.waitUntilCompleted()
            return try read(output, queue: queue)
        }
        let firstFrame = try frame()
        for _ in 0..<4 { _ = try frame() }
        let accumulated = try frame()
        XCTAssertGreaterThan(difference(firstFrame, accumulated), 1, "the history built up")
        renderer.restartHistory()
        XCTAssertLessThan(difference(firstFrame, try frame()), 0.5, "the frame after the restart is a first frame again")
    }

    /// Glitter draws its sparkles into a fixed 256² tile (`"width"`, `"height"`) that repeats
    /// (`"uvs": "repeat"`): each tile texel covers a few screen pixels, WE's 3-4 px sparkles.
    func testFixedSizeFBOsDontFollowTheLayer() throws {
        let plan = try builder.build(try effect(#"{"file":"effects/glitter/effect.json"}"#))
        let tile = try XCTUnwrap(plan.fbos.first { $0.name == "_rt_GlitterTiles" })
        XCTAssertEqual(tile.uvs, "repeat")
        XCTAssertEqual(EffectGraphRenderer.fboSize(tile, width: 1024, height: 1024), SIMD2(256, 256))
        let blur = try builder.build(try effect(#"{"file":"effects/blur/effect.json"}"#))
        let quarter = try XCTUnwrap(blur.fbos.first)
        XCTAssertEqual(EffectGraphRenderer.fboSize(quarter, width: 1024, height: 1024), SIMD2(1024 / quarter.scale, 1024 / quarter.scale))
    }

    /// X-ray draws its sprite under the pointer: the pointer (y-down in WE's shaders) goes through
    /// `g_EffectTextureProjectionMatrixInverse` into the layer's image, so it lands where the
    /// cursor is over the layer, wherever the layer is on the screen.
    func testXRaySpriteFollowsThePointerOverTheLayer() throws {
        let plan = try builder.build(try effect(#"{"file":"effects/xray/effect.json"}"#))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let input = try checkerboard()
        let loader = MTKTextureLoader(device: device)
        XCTAssertTrue(renderer.waitUntilReady([plan], width: input.width, height: input.height))
        let scene = SIMD2<Float>(1000, 500)
        // The layer fills the left half of the scene; y up.
        let quad = SceneQuadGeometry(center: SIMD2(250, 250), axisX: SIMD2(500, 0), axisY: SIMD2(0, 500))
        /// The quadrant of the image (column, row from the top) the sprite brightens most.
        func brightest(pointer: SIMD2<Float>) throws -> SIMD2<Int> {
            var frame = BuiltinFrameContext(time: 1.5)
            frame.pointer = pointer
            frame.pointerLast = pointer
            var context = EffectGraphRenderer.Context(
                frame: frame, values: FixedValues(),
                assetTexture: { _, source in
                    guard case .image(let image) = source, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                    return try? loader.newTexture(cgImage: cg, options: [.SRGB: false])
                },
                sceneSnapshot: nil, layerColor: SIMD3(1, 1, 1), layerAlpha: 1)
            context.effectTextureProjection = EffectGraphRenderer.effectTextureProjection(quad: quad, sceneSize: scene)
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            let output = try XCTUnwrap(renderer.apply([plan], to: input, layerID: "xray", context: context, commandBuffer: buffer))
            buffer.commit()
            buffer.waitUntilCompleted()
            let before = try read(input, queue: queue), after = try read(output, queue: queue)
            var gain = [Double](repeating: 0, count: 4)
            for y in 0..<input.height {
                for x in 0..<input.width {
                    let i = (y * input.width + x) * 4
                    gain[(y * 2 / input.height) * 2 + x * 2 / input.width] += Double(after[i]) - Double(before[i])
                }
            }
            let best = gain.indices.max { gain[$0] < gain[$1] }!
            return SIMD2(best % 2, best / 2)
        }
        // Pointer (y up) over the layer's upper right, then its lower left.
        XCTAssertEqual(try brightest(pointer: SIMD2(0.375, 0.75)), SIMD2(1, 0))
        XCTAssertEqual(try brightest(pointer: SIMD2(0.125, 0.25)), SIMD2(0, 1))
    }

    func testFourPassBlurWithQuarterBuffersSoftensEdges() throws {
        let result = try run(#"{"file":"effects/blur/effect.json","passes":[{},{},{},{}]}"#)
        XCTAssertGreaterThan(difference(result.input, result.output), 0.5)
        // The checker's colours are still where they were (no flip, no shift).
        let center = (128 * 256 + 16) * 4
        XCTAssertLessThan(abs(Int(result.output[center + 2]) - Int(result.input[center + 2])), 60)
    }

    /// Shake moves pixels along its direction map (slot 1); the default `util/noflow` is zero flow,
    /// so give it a real one, plus an opacity mask in slot 3 (MASK combo).
    func testShakeFollowsItsDirectionMapThroughAMask() throws {
        let result = try run(#"{"file":"effects/shake/effect.json","passes":[{"textures":[null,"util/clouds_256",null,"util/white"],"constantshadervalues":{"strength":0.3,"speed":2}}]}"#)
        XCTAssertGreaterThan(difference(result.input, result.output), 0.1)
    }

    /// Shine casts rays only from what its R8 opacity mask lets through: the mask reads `.r`, so
    /// light never appears beyond the rays' reach from the masked area. A mid-grey image clears
    /// the threshold everywhere; only the left quarter is masked in.
    func testShineStaysInsideItsR8Mask() throws {
        let size = 256
        let maskSize = 128
        let maskPixels = (0..<(maskSize * maskSize)).map { UInt8($0 % maskSize < maskSize / 4 ? 255 : 0) }
        // As WE's editor writes a painted mask: R8, clamped.
        let mask = TextureRG88Tests.tex(format: 9, width: UInt32(maskSize), height: UInt32(maskSize), pixels: maskPixels,
                                        flags: .clampUVs)
        let root = ShaderVariantTests.weAssets
        let maskedBuilder = SceneEffectPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { path in
                path == "materials/masks/left_quarter.tex" ? mask : FileManager.default.contents(atPath: root.appending(path: path).path)
            },
            loadTexture: { name, materialPath in
                if name == "masks/left_quarter" { return TEXParser(data: mask).extractImage().map { .image($0) } }
                let effectDirectory = materialPath.split(separator: "/").prefix(2).joined(separator: "/")
                for path in ["materials/\(name).tex", "\(effectDirectory)/materials/\(name).tex"] {
                    if let data = FileManager.default.contents(atPath: root.appending(path: path).path),
                       let image = TEXParser(data: data).extractImage() { return .image(image) }
                }
                return nil
            })
        let json = #"{"file":"effects/shine/effect.json","passes":[{"textures":[null,"masks/left_quarter",null],"constantshadervalues":{"raythreshold":0.26,"noiseamount":0.01}},{"constantshadervalues":{"raylength":0.1}},{},{},{}]}"#
        let plan = try maskedBuilder.build(try effect(json))
        XCTAssertEqual(plan.passes.first?.variant?.combos["MASK"], 1)
        // Sampled as its `.tex` flags say: the mask clamps, the noise (`util/clouds_256`) repeats.
        XCTAssertEqual(plan.passes.first?.textureFlags[1], .clampUVs)
        XCTAssertEqual(plan.passes.first?.textureFlags[2], [])
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        let input = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let grey = [UInt8](repeating: 0, count: size * size * 4).enumerated().map { $0.offset % 4 == 3 ? UInt8(255) : UInt8(128) }
        input.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: grey, bytesPerRow: size * 4)
        let loader = MTKTextureLoader(device: device)
        let context = EffectGraphRenderer.Context(
            frame: BuiltinFrameContext(time: 1.5), values: FixedValues(),
            assetTexture: { _, source in
                guard case .image(let image) = source, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                return try? SceneTextureUpload.texture(from: cg, loader: loader, device: self.device) // test upload; nil fails below
            },
            sceneSnapshot: nil, layerColor: SIMD3(1, 1, 1), layerAlpha: 1)
        XCTAssertTrue(renderer.waitUntilReady([plan], width: size, height: size), "pipelines still compiling")
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let output = try XCTUnwrap(renderer.apply([plan], to: input, layerID: "shine", context: context, commandBuffer: buffer))
        buffer.commit()
        buffer.waitUntilCompleted()
        let pixels = try read(output, queue: queue)
        func red(_ x: Int) -> Double { Double(pixels[(size / 2 * size + x) * 4]) }
        XCTAssertGreaterThan(red(size / 8), 150, "the masked quarter shines")
        // Horizontal rays reach 5% of the width past the mask, and the blur about a dozen texels more.
        for x in stride(from: size / 2, to: size, by: 8) {
            XCTAssertEqual(red(x), 128, accuracy: 2, "no shine at x \(x), beyond the rays' reach from the mask")
        }
    }

    /// A sampler annotated `"formatcombo": true` gets `TEX<n>FORMAT` from its texture's format, as
    /// WE sets it: refraction decodes an RG88 normal map by it, lightshafts reads an R8 gradient
    /// map as `.rrr`. An RGBA texture (expanded on load) sets `FORMAT_RGBA8888` (0).
    func testFormatComboSamplersTakeTheirTexturesFormat() throws {
        let root = ShaderVariantTests.weAssets
        let generated = ["materials/normal_rg88.tex": TextureRG88Tests.tex(format: 8, pixels: [128, 255]),
                         "materials/gradient_r8.tex": TextureRG88Tests.tex(format: 9, pixels: [200]),
                         "materials/gradient_rgba.tex": TextureRG88Tests.tex(format: 0, pixels: [1, 2, 3, 4])]
        let formatBuilder = SceneEffectPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { path in generated[path] ?? FileManager.default.contents(atPath: root.appending(path: path).path) },
            loadTexture: { name, _ in
                generated["materials/\(name).tex"].flatMap { TEXParser(data: $0).extractImage() }.map { .image($0) }
            })
        let refraction = try formatBuilder.build(try effect(
            #"{"file":"effects/refraction/effect.json","passes":[{},{"textures":[null,"normal_rg88"]}]}"#))
        XCTAssertEqual(refraction.passes.last?.variant?.combos["TEX1FORMAT"], 8)
        let gradient = #"{"file":"effects/lightshafts/effect.json","passes":[{"combos":{"RENDERING":1},"textures":[null,null,"TEXTURE"]}]}"#
        let r8 = try formatBuilder.build(try effect(gradient.replacingOccurrences(of: "TEXTURE", with: "gradient_r8")))
        XCTAssertEqual(r8.passes.first?.variant?.combos["TEX2FORMAT"], 9)
        let rgba = try formatBuilder.build(try effect(gradient.replacingOccurrences(of: "TEXTURE", with: "gradient_rgba")))
        XCTAssertEqual(rgba.passes.first?.variant?.combos["TEX2FORMAT"], 0)
    }

    func testEveryBuiltinEffectRunsWithDefaults() throws {
        let effects = ShaderVariantTests.weAssets.appending(path: "effects")
        var failures: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: effects.path).sorted() where !name.hasPrefix(".") {
            do {
                _ = try run(#"{"file":"effects/\#(name)/effect.json"}"#)
            } catch {
                failures.append("\(name): \(String(describing: error).prefix(200))")
            }
        }
        XCTAssertEqual(failures, [], failures.joined(separator: "\n"))
        // Every built-in effect's pipelines go into the binary archive, which must serialize.
        let archive = try XCTUnwrap(renderer.pipelineArchive)
        archive.flush()
        XCTAssertGreaterThan(archive.additions, 0)
        XCTAssertEqual(archive.writeFailures, 0)
        let reopened = EffectPipelineArchive(device: device, directory: archive.url.deletingLastPathComponent(), metalScratchDirectory: nil)
        XCTAssertFalse(reopened.archives.isEmpty, "the written archive opens")
    }

    /// Chains that don't change over time are rendered once and reused while the input is the same.
    func testStaticChainIsReusedAndAnimatedChainIsNot() throws {
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let input = try checkerboard()
        let context = EffectGraphRenderer.Context(frame: BuiltinFrameContext(time: 1), values: FixedValues(),
                                                  assetTexture: { _, _ in nil }, sceneSnapshot: nil,
                                                  layerColor: SIMD3(1, 1, 1), layerAlpha: 1)
        func frames(_ json: String, layer: String) throws -> (encoded: Int, reused: Int) {
            let plan = try builder.build(try effect(json))
            XCTAssertTrue(renderer.waitUntilReady([plan], width: 256, height: 256))
            let encodedBefore = renderer.passesEncoded
            let reusedBefore = renderer.layersReused
            for _ in 0..<3 {
                let buffer = try XCTUnwrap(queue.makeCommandBuffer())
                XCTAssertNotNil(renderer.apply([plan], to: input, layerID: layer, context: context, commandBuffer: buffer))
                buffer.commit()
            }
            return (renderer.passesEncoded - encodedBefore, renderer.layersReused - reusedBefore)
        }
        let tint = try frames(#"{"file":"effects/tint/effect.json"}"#, layer: "static")
        XCTAssertEqual(tint.encoded, 1, "tint has no time input: one render, then reuse")
        XCTAssertEqual(tint.reused, 2)
        let shake = try frames(#"{"file":"effects/shake/effect.json","passes":[{"textures":[null,"util/clouds_256"]}]}"#, layer: "animated")
        XCTAssertEqual(shake.encoded, 3, "shake reads g_Time and must render every frame")
        XCTAssertEqual(shake.reused, 0)
    }

    func testParametersComeFromShaderAnnotations() throws {
        let root = ShaderVariantTests.weAssets
        let parameters = SceneEffectParameters.parameters(for: "effects/shake/effect.json") {
            FileManager.default.contents(atPath: root.appending(path: $0).path)
        }
        let strength = try XCTUnwrap(parameters.first { $0.materialKey == "strength" })
        XCTAssertEqual(strength.title, "Strength")
        XCTAssertEqual(strength.defaultValue, [0.1], accuracy: 1e-6)
        XCTAssertEqual(strength.minimum, 0.01, accuracy: 1e-6)
        XCTAssertEqual(strength.maximum, 0.5, accuracy: 1e-6)
        XCTAssertEqual(parameters.first { $0.materialKey == "friction" }?.defaultValue.count, 2, "vec2")
    }

    func testInspectorOverrideWinsOverAuthoredValue() throws {
        let effect = try effect(#"{"file":"effects/shake/effect.json","passes":[{"constantshadervalues":{"strength":0.2}}]}"#)
        let plan = try builder.build(effect, overrides: {
            $0 == "strength" ? SceneEffectOverride(property: "p", value: "0.4") : nil
        })
        let constants = try XCTUnwrap(plan.passes.first?.constants)
        XCTAssertEqual(constants.staticValues["g_Amp"]?.components.first ?? 0, 0.4, accuracy: 1e-6)
        XCTAssertTrue(constants.dynamic.isEmpty, "an override is a static literal")
    }
}

private func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}
