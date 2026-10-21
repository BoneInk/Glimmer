import XCTest
import Metal
@testable import OpenWallpaperEngine

/// An effect's `swap` command persists: the next frame starts from the buffers this one left, as
/// WE's fluid simulation (`effects/fluidsimulation`) needs for its velocity and dye ping-pong.
/// The fixture adds a quarter to red in `_rt_B` over `_rt_A`, shows `_rt_B`, then swaps them.
final class EffectGraphSwapTests: XCTestCase {
    private var cache: URL!

    override func tearDownWithError() throws {
        if let cache { try? FileManager.default.removeItem(at: cache) }
    }

    struct NoValues: SceneValueContext {
        func userProperty(_ name: String) -> String? { nil }
    }

    func testSwappedBuffersCarryIntoTheNextFrame() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ShaderVariantTests.weAssets.path), "WE install not present")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-swap-\(UUID().uuidString)")
        let renderer = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: cache.appending(path: "archives")))
        defer { renderer.pipelineArchive?.flush() }
        let reds = try pingpongReds(try pingpongPlan(), renderer: renderer, device: device, frames: 3)
        // 0.25, 0.5, 0.75: each frame adds to the last one's buffer. Without the swap carrying
        // over, every frame read the cleared `_rt_A` and showed 0.25.
        XCTAssertEqual(reds.count, 3)
        for (frame, red) in reds.enumerated() {
            XCTAssertEqual(red, 64 * (frame + 1), accuracy: 2, "frame \(frame): \(reds)")
        }
    }

    /// `IEffect.executeMaterialFunction`: the fixture's `reset` function (`"action": "clear"` on
    /// both buffers) starts the accumulation over from the FBOs' clear colour; a name the effect
    /// doesn't have changes nothing.
    func testClearFunctionStartsTheBuffersOver() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ShaderVariantTests.weAssets.path), "WE install not present")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-reset-\(UUID().uuidString)")
        let renderer = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: cache.appending(path: "archives")))
        defer { renderer.pipelineArchive?.flush() }
        var plan = try pingpongPlan()
        plan.effectIndex = 2
        XCTAssertEqual(plan.functions["reset"], EffectFunction(action: "clear", fbos: ["_rt_A", "_rt_B"]))
        var reds = try pingpongReds(plan, renderer: renderer, device: device, frames: 2)
        renderer.executeFunction(named: "noSuchFunction", effectIndex: 2, of: [plan], layer: "pingpong")
        reds += try pingpongReds(plan, renderer: renderer, device: device, frames: 1)
        renderer.executeFunction(named: "reset", effectIndex: 2, of: [plan], layer: "pingpong")
        reds += try pingpongReds(plan, renderer: renderer, device: device, frames: 2)
        let expected = [1, 2, 3, 1, 2].map { 64 * $0 }
        for (red, want) in zip(reds, expected) { XCTAssertEqual(red, want, accuracy: 2, "\(reds)") }
        XCTAssertEqual(reds.count, expected.count)
    }

    private func pingpongPlan() throws -> SceneEffectPlan {
        let fixture = Fixtures.url("Effects/pingpong")
        let assets = ShaderVariantTests.weAssets
        let builder = SceneEffectPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { path in
                FileManager.default.contents(atPath: fixture.appending(path: path).path)
                    ?? FileManager.default.contents(atPath: assets.appending(path: path).path)
            },
            loadTexture: { _, _ in nil })
        let effect = try JSONDecoder().decode(WEObjectEffect.self, from: Data(#"{"file": "effects/pingpong/effect.json"}"#.utf8))
        return try builder.build(effect)
    }

    /// The red of the middle pixel the pingpong fixture shows in each of `frames` frames.
    private func pingpongReds(_ plan: SceneEffectPlan, renderer: EffectGraphRenderer, device: MTLDevice,
                              frames: Int) throws -> [Int] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 8, height: 8, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let input = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let context = EffectGraphRenderer.Context(frame: BuiltinFrameContext(time: 0), values: NoValues(),
                                                  assetTexture: { _, _ in nil }, sceneSnapshot: nil,
                                                  layerColor: SIMD3(1, 1, 1), layerAlpha: 1)
        XCTAssertTrue(renderer.waitUntilReady([plan], width: 8, height: 8), "pipelines still compiling")
        var reds: [Int] = []
        for _ in 0..<frames {
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            let output = try XCTUnwrap(renderer.apply([plan], to: input, layerID: "pingpong", context: context,
                                                      commandBuffer: buffer))
            let shared = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: output.pixelFormat, width: output.width,
                                                                  height: output.height, mipmapped: false)
            shared.storageMode = .shared
            let copy = try XCTUnwrap(device.makeTexture(descriptor: shared))
            let blit = try XCTUnwrap(buffer.makeBlitCommandEncoder())
            blit.copy(from: output, to: copy)
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            var pixel = [UInt8](repeating: 0, count: 4)
            copy.getBytes(&pixel, bytesPerRow: output.width * 4, from: MTLRegionMake2D(4, 4, 1, 1), mipmapLevel: 0)
            reds.append(Int(pixel[0]))
        }
        return reds
    }

    /// A blended pass draws over what its target holds, and WE's targets start as transparent
    /// black. A ping target taken back from the spares (another layer's, released) still holds that
    /// layer's image, and a new one whatever its memory held: the first pass into it clears it. The
    /// fixture blends the input at half alpha (`translucent`) over its target.
    func testBlendedPassOverAReusedTargetStartsFromTransparentBlack() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ShaderVariantTests.weAssets.path), "WE install not present")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-reuse-\(UUID().uuidString)")
        let renderer = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: cache.appending(path: "archives")))
        defer { renderer.pipelineArchive?.flush() }
        let fixture = Fixtures.url("Effects/halfcover")
        let assets = ShaderVariantTests.weAssets
        let builder = SceneEffectPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { path in
                FileManager.default.contents(atPath: fixture.appending(path: path).path)
                    ?? FileManager.default.contents(atPath: assets.appending(path: path).path)
            },
            loadTexture: { _, _ in nil })
        func plan(_ json: String) throws -> SceneEffectPlan {
            try builder.build(try JSONDecoder().decode(WEObjectEffect.self, from: Data(json.utf8)))
        }
        let tint = try plan(#"{"file":"effects/tint/effect.json","passes":[{"constantshadervalues":{"color":"1 0 0","alpha":1}}]}"#)
        let halfcover = try plan(#"{"file":"effects/halfcover/effect.json"}"#)
        XCTAssertNotNil(EffectGraphRenderer.blendMode(try XCTUnwrap(halfcover.passes.first).blending))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 8, height: 8, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let input = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        // Opaque blue.
        let blue = [UInt8]((0..<64).flatMap { _ in [UInt8(0), 0, 255, 255] })
        blue.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0, withBytes: $0.baseAddress!,
                                             bytesPerRow: 8 * 4) }
        XCTAssertEqual(try TextureUploadTests.read(input, device: device), blue)
        let context = EffectGraphRenderer.Context(frame: BuiltinFrameContext(time: 0), values: NoValues(),
                                                  assetTexture: { _, _ in nil }, sceneSnapshot: nil,
                                                  layerColor: SIMD3(1, 1, 1), layerAlpha: 1)
        XCTAssertTrue(renderer.waitUntilReady([tint, halfcover], width: 8, height: 8), "pipelines still compiling")
        func run(_ effect: SceneEffectPlan, layer: String) throws -> [UInt8] {
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            let output = try XCTUnwrap(renderer.apply([effect], to: input, layerID: layer, context: context, commandBuffer: buffer))
            buffer.commit()
            buffer.waitUntilCompleted()
            return try TextureUploadTests.read(output, device: device)
        }
        // A red image left in a target that goes back to the spares.
        let red = try run(tint, layer: "tinted")
        XCTAssertGreaterThan(red[0], 200)
        renderer.releaseLayer("tinted")
        let allocated = renderer.targetsAllocated
        let pixel = Array(try run(halfcover, layer: "covered").prefix(4))
        XCTAssertEqual(renderer.targetsAllocated, allocated, "the released target is taken back")
        XCTAssertEqual(Int(pixel[0]), 0, accuracy: 1, "nothing of the red image shows: \(pixel)")
        XCTAssertEqual(Int(pixel[2]), 128, accuracy: 2, "half the blue over transparent black: \(pixel)")
    }

    /// FBOs start as their `clear` colour: pooled targets hold whatever they last held, and a
    /// simulation that reads its own last frame keeps garbage (a NaN) for good.
    func testFBOsStartAsTheirClearColour() {
        let authored = EffectGraphRenderer.clearColor("0.25 0.5 1 0")
        XCTAssertEqual([authored.red, authored.green, authored.blue, authored.alpha], [0.25, 0.5, 1, 0])
        let none = EffectGraphRenderer.clearColor(nil)
        XCTAssertEqual([none.red, none.green, none.blue, none.alpha], [0, 0, 0, 0])
    }
}
