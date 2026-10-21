import XCTest
import MetalKit
import Metal
import simd
@testable import OpenWallpaperEngine

/// `_rt_MipMappedFrameBuffer` (`SceneMipMappedFrameBuffer`, docs/lighting-plan.md §2.4): WE's mip
/// count, when the target exists, the copy and its mips, `g_Texture3MipMapInfo`, and the
/// reflection setting. `ImageMaterialReflectionTests` draws a material that samples it.
final class SceneMipMappedFrameBufferTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!

    /// The scene target of these tests: 256×128 pixels for a 512×256 scene, so 4 mips.
    static let sceneSize = SIMD2<Float>(512, 256)
    static let width = 256
    static let height = 128

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
    }

    // MARK: - Mip count

    /// The render-target constructor at 0x1400d2dde: for each side, log2 of half the smallest
    /// power of two not below it; the smaller one, minus 2, at least 1.
    func testMipCountIsWEs() {
        XCTAssertEqual(SceneMipMappedFrameBuffer.mipCount(width: 1920, height: 1080), 8)
        XCTAssertEqual(SceneMipMappedFrameBuffer.mipCount(width: 2560, height: 1440), 8)
        XCTAssertEqual(SceneMipMappedFrameBuffer.mipCount(width: 3840, height: 2160), 9)
        XCTAssertEqual(SceneMipMappedFrameBuffer.mipCount(width: 2048, height: 2048), 8, "a power of two counts as half")
        XCTAssertEqual(SceneMipMappedFrameBuffer.mipCount(width: 2049, height: 2049), 9)
        XCTAssertEqual(SceneMipMappedFrameBuffer.mipCount(width: 256, height: 128), 4)
        XCTAssertEqual(SceneMipMappedFrameBuffer.mipCount(width: 8, height: 8), 1)
        XCTAssertEqual(SceneMipMappedFrameBuffer.mipCount(width: 1, height: 1), 1)
    }

    // MARK: - When it exists

    func testNothingIsMadeWhileNothingSamplesIt() throws {
        let stage = SceneMipMappedFrameBuffer(device: device)
        stage.setContent(Self.content(layers: [Self.layer("plain")]))
        let scene = try Self.sceneTexture(device: device)
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertNil(stage.target(matching: scene, commandBuffer: commands))
        stage.encode(Self.stageContext(scene, commands, reflection: true))
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertNil(stage.texture)
        XCTAssertEqual(stage.framesCopied, 0)
    }

    /// Effect passes and image materials that sample it are found; it isn't the scene drawn so
    /// far, so reading it doesn't pause the scene pass.
    func testEffectsAndMaterialsThatSampleItAreFound() {
        let pass = Self.samplingPass()
        XCTAssertTrue(pass.readsMipMappedFrameBuffer)
        XCTAssertFalse(pass.readsSceneSnapshot)
        XCTAssertTrue(SceneMipMappedFrameBuffer.samples(Self.content(layers: [Self.samplingLayer()])))
        var material = Self.layer("material")
        material.imageMaterial = ImageMaterialPlan(materialPath: "materials/test.json", pass: pass,
                                                   usesSpriteSheetUniforms: false, liveFactors: [:])
        XCTAssertTrue(SceneMipMappedFrameBuffer.samples(Self.content(layers: [material])))
        XCTAssertFalse(material.imageMaterial?.readsSceneSnapshot ?? true)
        XCTAssertFalse(SceneMipMappedFrameBuffer.samples(Self.content(layers: [Self.layer("plain")])))
    }

    // MARK: - The copy

    /// Level 0 is the scene; each level after it is the 2×2 box average of the one before; the
    /// count is WE's, and `g_Texture3MipMapInfo` is it. A new target reads as transparent black
    /// until the end of its first frame, so the draws of a frame see the previous one.
    func testCopyHoldsTheSceneAndItsMips() throws {
        let stage = SceneMipMappedFrameBuffer(device: device)
        stage.setContent(Self.content(layers: [Self.samplingLayer()]))
        let scene = try Self.sceneTexture(device: device)
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let target = try XCTUnwrap(stage.target(matching: scene, commandBuffer: commands))
        XCTAssertEqual(target.mipmapLevelCount, 4)
        XCTAssertEqual(target.width, Self.width)
        XCTAssertEqual(target.pixelFormat, scene.pixelFormat, "the frame buffer's format")
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertTrue(try Self.levels(of: target, queue: queue).allSatisfy { $0.allSatisfy { $0 == 0 } },
                      "a new target is transparent black")

        let copy = try XCTUnwrap(queue.makeCommandBuffer())
        stage.encode(Self.stageContext(scene, copy, reflection: true))
        copy.commit()
        copy.waitUntilCompleted()
        XCTAssertTrue(stage.texture === target, "the same target from frame to frame")
        XCTAssertEqual(stage.framesCopied, 1)
        let mips = try Self.levels(of: target, queue: queue)
        let scenePixels = Self.swappingRedAndBlue(Self.bytes(Self.stripes, width: Self.width, height: Self.height))
        XCTAssertEqual(mips[0], scenePixels.map(Float.init))
        for level in 1..<mips.count {
            XCTAssertLessThanOrEqual(Self.worstBoxDifference(mips[level], above: mips[level - 1],
                                                             width: Self.width >> level, height: Self.height >> level),
                                     1, "level \(level) is the box average of level \(level - 1)")
        }
        // 4-pixel stripes (red and blue): level 2 still alternates, level 3 is mid-grey.
        XCTAssertEqual(mips[2][0], 255, accuracy: 1)
        XCTAssertEqual(mips[2][4], 0, accuracy: 1)
        XCTAssertEqual(mips[3][0], 127.5, accuracy: 1)

        let info = EffectGraphRenderer.textureInfo(for: target, contentSize: nil)
        let value = BuiltinUniforms.value(named: "g_Texture3MipMapInfo", frame: BuiltinFrameContext(),
                                          pass: BuiltinPassContext(targetSize: SIMD2(256, 128), textures: [3: info]))
        XCTAssertEqual(value, [4], "the level count, not the count − 1")
    }

    /// LF9: WE makes the target with the scene it loads, so a new content's first frame reads
    /// transparent black, not the last content's frame, even at the same size.
    func testANewContentDoesntReflectTheLastOne() throws {
        let stage = SceneMipMappedFrameBuffer(device: device)
        stage.setContent(Self.content(layers: [Self.samplingLayer()]))
        let scene = try Self.sceneTexture(device: device)
        let copy = try XCTUnwrap(queue.makeCommandBuffer())
        stage.encode(Self.stageContext(scene, copy, reflection: true))
        copy.commit()
        copy.waitUntilCompleted()
        XCTAssertEqual(stage.framesCopied, 1)

        stage.setContent(Self.content(layers: [Self.samplingLayer()]))
        let next = try XCTUnwrap(queue.makeCommandBuffer())
        let target = try XCTUnwrap(stage.target(matching: scene, commandBuffer: next))
        next.commit()
        next.waitUntilCompleted()
        XCTAssertTrue(try Self.levels(of: target, queue: queue).allSatisfy { $0.allSatisfy { $0 == 0 } },
                      "the new content's first frame reads transparent black")
    }

    /// The scene snapshot may go into the target's level 0 (test-risks LR10) only while the copy
    /// runs this frame and nothing from the first scene-reading layer on samples the target in the
    /// scene pass. A layer whose effects sample it runs them before the scene pass.
    func testTheSnapshotSharesTheTargetOnlyWhereNothingLaterReadsIt() {
        var reader = Self.layer("reader")
        reader.weEffects = [SceneEffectPlan(file: "effects/test/effect.json", fbos: [], passes: [Self.snapshotPass()])]
        XCTAssertTrue(reader.readsScene)
        var direct = Self.layer("direct")
        direct.imageMaterial = ImageMaterialPlan(materialPath: "materials/test.json", pass: Self.samplingPass(),
                                                 usesSpriteSheetUniforms: false, liveFactors: [:])
        func share(_ layers: [SceneMetalLayer], reflection: Bool = true) -> Bool {
            SceneMipMappedFrameBuffer.snapshotCanShare(layers: layers, particleSystems: [], reflection: reflection)
        }
        XCTAssertTrue(share([Self.samplingLayer(), direct, reader]), "the target is read before the snapshot")
        XCTAssertFalse(share([reader, direct]), "a later draw reads the previous frame")
        XCTAssertFalse(share([Self.samplingLayer(), reader], reflection: false), "with the setting off it stays black")
        var both = Self.layer("both")
        both.weEffects = [SceneEffectPlan(file: "effects/test/effect.json", fbos: [],
                                          passes: [Self.snapshotPass(), Self.samplingPass()])]
        XCTAssertFalse(share([both]), "the scene reader's own effects read it")
    }

    /// Through the renderer: where the snapshot may share the target, the frame leases no
    /// full-size target for it (a material that reads the scene draws inside the scene pass, so it
    /// needs a copy); a layer whose effects alone read the scene needs no copy at all: they run
    /// while the scene pass is paused and read the scene target itself.
    func testASharedSnapshotLeasesNoTargetOfItsOwn() throws {
        var reader = Self.layer("reader")
        reader.imageMaterial = ImageMaterialPlan(materialPath: "materials/test.json", pass: Self.snapshotPass(),
                                                 usesSpriteSheetUniforms: false, liveFactors: [:])
        var effectReader = Self.layer("effects")
        effectReader.weEffects = [SceneEffectPlan(file: "effects/test/effect.json", fbos: [], passes: [Self.snapshotPass()])]
        var direct = Self.layer("direct")
        direct.imageMaterial = ImageMaterialPlan(materialPath: "materials/test.json", pass: Self.samplingPass(),
                                                 usesSpriteSheetUniforms: false, liveFactors: [:])
        func poolBytes(_ layers: [SceneMetalLayer]) throws -> Int {
            let size = 256
            let view = MTKView(frame: CGRect(x: 0, y: 0, width: size, height: size / 2), device: device)
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = false
            view.autoResizeDrawable = false
            view.drawableSize = CGSize(width: size, height: size / 2)
            let renderer = try XCTUnwrap(SceneMetalRenderer(view: view))
            defer { renderer.releaseContent() }
            view.isPaused = true
            renderer.setPlacement(.stretch)
            renderer.setContent(Self.content(layers: layers))
            let deadline = Date().addingTimeInterval(30)
            while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            for _ in 0..<3 {
                renderer.draw(in: view)
                renderer.lastCommandBuffer?.waitUntilCompleted()
            }
            return renderer.frameTargetBytes["target pool (snapshots, regions)"] ?? 0
        }
        XCTAssertEqual(try poolBytes([effectReader]), 0, "effects read the paused scene target")
        let target = 256 * 128 * 4
        let shared = try poolBytes([direct, reader]), separate = try poolBytes([reader, direct])
        XCTAssertGreaterThanOrEqual(separate - shared, target, "one full-size target fewer: \(shared) vs \(separate)")
    }

    /// Render flag 0x80 off: the target is cleared to (0, 0, 0, 1) once and never filled.
    func testReflectionOffClearsItToOpaqueBlack() throws {
        let stage = SceneMipMappedFrameBuffer(device: device)
        stage.setContent(Self.content(layers: [Self.samplingLayer()]))
        let scene = try Self.sceneTexture(device: device)
        for _ in 0..<2 {
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            stage.encode(Self.stageContext(scene, commands, reflection: false))
            commands.commit()
            commands.waitUntilCompleted()
        }
        XCTAssertEqual(stage.framesCopied, 0)
        let target = try XCTUnwrap(stage.texture)
        for (level, texels) in try Self.levels(of: target, queue: queue).enumerated() {
            let black = [Float](repeating: 0, count: texels.count).enumerated().map { $0.offset % 4 == 3 ? Float(255) : 0 }
            XCTAssertEqual(texels, black, "level \(level)")
        }
    }

    // MARK: - Helpers (also used by `ImageMaterialReflectionTests`)

    /// Vertical 4-pixel stripes, white then black, with a green ramp down the rows (RGBA).
    static func stripes(_ x: Int, _ y: Int) -> [UInt8] {
        let white: UInt8 = (x / 4) % 2 == 0 ? 255 : 0
        return [white, UInt8(y * 2), white, 255]
    }

    static func bytes(_ texel: (Int, Int) -> [UInt8], width: Int, height: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width { bytes += texel(x, y) }
        }
        return bytes
    }

    /// RGBA ↔ BGRA.
    static func swappingRedAndBlue<T>(_ texels: [T]) -> [T] {
        var swapped = texels
        for index in stride(from: 0, to: swapped.count, by: 4) { swapped.swapAt(index, index + 2) }
        return swapped
    }

    /// The largest difference between `level` and the 2×2 box average of `above`, over every channel.
    static func worstBoxDifference(_ level: [Float], above: [Float], width: Int, height: Int) -> Float {
        var worst: Float = 0
        for y in 0..<height {
            for x in 0..<width {
                for channel in 0..<4 {
                    let topLeft = ((2 * y) * (2 * width) + 2 * x) * 4 + channel
                    let bottomLeft = topLeft + 2 * width * 4
                    let box = (above[topLeft] + above[topLeft + 4] + above[bottomLeft] + above[bottomLeft + 4]) / 4
                    worst = max(worst, abs(level[(y * width + x) * 4 + channel] - box))
                }
            }
        }
        return worst
    }

    static func stageContext(_ scene: MTLTexture, _ commands: MTLCommandBuffer, reflection: Bool) -> SceneFrameStageContext {
        var settings = SceneRenderSettings()
        settings.reflection = reflection
        return SceneFrameStageContext(scene: scene, commandBuffer: commands, sceneSize: sceneSize,
                                      frame: BuiltinFrameContext(), settings: settings)
    }

    /// A 256×128 bgra8 scene target (the renderer's format) holding `stripes`.
    static func sceneTexture(device: MTLDevice) throws -> MTLTexture {
        let rgba = bytes(stripes, width: width, height: height)
        return try texture(device: device, width: width, height: height, pixels: swappingRedAndBlue(rgba), format: .bgra8Unorm)
    }

    static func texture(device: MTLDevice, width: Int, height: Int, pixels: [UInt8],
                        format: MTLPixelFormat) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels,
                        bytesPerRow: width * 4)
        return texture
    }

    /// Every level of `texture` (4 bytes per texel, in its own channel order), as floats 0…255.
    static func levels(of texture: MTLTexture, queue: MTLCommandQueue) throws -> [[Float]] {
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(commands.makeBlitCommandEncoder())
        var buffers: [MTLBuffer] = []
        for level in 0..<texture.mipmapLevelCount {
            let width = max(1, texture.width >> level), height = max(1, texture.height >> level)
            let buffer = try XCTUnwrap(queue.device.makeBuffer(length: width * height * 4, options: .storageModeShared))
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
                      destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4)
            buffers.append(buffer)
        }
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return buffers.map { buffer in
            UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: buffer.length).map(Float.init)
        }
    }

    /// An effect pass that samples the target in slot 1.
    static func samplingPass() -> SceneEffectPassPlan {
        SceneEffectPassPlan(command: .render, variantKey: "", variant: nil, blending: "normal", target: nil,
                            textures: [0: .current, 1: .mipMappedFrameBuffer],
                            constants: ShaderConstantResolver.ResolvedConstants(staticValues: [:], dynamic: []))
    }

    /// A pass that samples the scene drawn so far (`_rt_FullFrameBuffer`).
    static func snapshotPass() -> SceneEffectPassPlan {
        SceneEffectPassPlan(command: .render, variantKey: "", variant: nil, blending: "normal", target: nil,
                            textures: [0: .current, 1: .sceneSnapshot],
                            constants: ShaderConstantResolver.ResolvedConstants(staticValues: [:], dynamic: []))
    }

    static func samplingLayer() -> SceneMetalLayer {
        var layer = layer("effect")
        layer.weEffects = [SceneEffectPlan(file: "effects/test/effect.json", fbos: [], passes: [samplingPass()])]
        return layer
    }

    static func layer(_ id: String, image: NSImage? = nil, size: SIMD2<Float> = sceneSize) -> SceneMetalLayer {
        SceneMetalLayer(
            id: id, name: id, source: .image(image ?? SceneContentLoader.pixelImage([0.5, 0.5, 0.5, 1])),
            position: size / 2, size: size, scale: SIMD2(1, 1), opacity: 1, brightness: 1, color: SIMD4(repeating: 1),
            text: nil, parallaxDepth: .zero, perspective: false, rotation: 0)
    }

    static func content(layers: [SceneMetalLayer], size: SIMD2<Float> = sceneSize) -> SceneMetalContent {
        SceneMetalContent(size: size, layers: layers, particleSystems: [],
                          bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7, tint: SIMD3(repeating: 1)))
    }
}
