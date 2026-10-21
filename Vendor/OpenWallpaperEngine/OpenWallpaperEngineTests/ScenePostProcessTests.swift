import XCTest
import Metal
import MetalKit
@testable import OpenWallpaperEngine

/// `ScenePostProcess`, the stage after the scene pass: WE's bloom gate and strength, and the
/// composite that carries the app's own adjustments.
final class ScenePostProcessTests: XCTestCase {
    private let placement = LayerUniform(position: SIMD2(960, 540), size: SIMD2(1920, 1080), sceneSize: SIMD2(1920, 1080),
                                         opacity: 1, particleShape: 0, rotation: 0, color: SIMD4(repeating: 1),
                                         uvOrigin: .zero, uvAxisX: SIMD2(1, 0), uvAxisY: SIMD2(0, 1),
                                         effects: SIMD4(1, 1, 1, 0), blur: 0, colorEffects: SIMD4(0, 1, 0, 0.7),
                                         transform: SIMD4(0, 0, 0, 1), transformScaleY: 1)

    /// The composite adds only the app's saturation, hue and blur; bloom is WE's chain, not the composite's.
    func testCompositeUniformCarriesTheAppExtrasOnly() {
        let extras = ScenePostProcess.AppExtras(bloom: 1.5, saturation: 0.8, hue: 0.25, blur: 1.5)
        let uniform = ScenePostProcess.compositeUniform(placement, extras: extras)
        XCTAssertEqual(uniform.effects, SIMD4(1, 1, 0.8, 0), "no native bloom")
        XCTAssertEqual(uniform.colorEffects.z, 0.25)
        XCTAssertEqual(uniform.blur, 2)
        XCTAssertEqual(uniform.position, placement.position)
        let identity = ScenePostProcess.compositeUniform(placement, extras: .init())
        XCTAssertEqual(identity.effects, SIMD4(1, 1, 1, 0))
        XCTAssertEqual(identity.colorEffects.z, 0)
        XCTAssertEqual(identity.blur, 0)
    }

    /// WE blooms when post-processing isn't "disabled" and the scene's live `bloom` is on (0x140180a41).
    func testBloomRunsWhenTheSceneAndTheSettingAllowIt() {
        let on = ScenePostProcess.Bloom(enabled: true, strength: 2, threshold: 0.65, tint: SIMD3(repeating: 1))
        var off = on
        off.enabled = false
        var settings = SceneRenderSettings()
        for quality in [GSPostProcessingQuality.enabled, .ultra, .displayhdr] {
            settings.postProcessing = quality
            XCTAssertTrue(ScenePostProcess.runsBloom(on, settings: settings), "\(quality)")
            XCTAssertFalse(ScenePostProcess.runsBloom(off, settings: settings), "\(quality): the scene's bloom is off")
        }
        settings.postProcessing = .disabled
        XCTAssertFalse(ScenePostProcess.runsBloom(on, settings: settings), "post-processing disabled")
    }

    /// In HDR the chain runs where bloom does, over WE's levels capped by `bloomhdriterations`;
    /// elsewhere the frame takes `combine_srgb` (nil).
    func testHDRLevelsFollowTheBloomGateAndIterations() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 64, height: 48,
                                                                  mipmapped: false)
        let scene = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var hdr = SceneHDRBloomSettings()
        hdr.enabled = true
        var frame = ScenePostProcess.Frame(
            scene: scene, output: MTLRenderPassDescriptor(), commandBuffer: try XCTUnwrap(queue.makeCommandBuffer()),
            placement: placement,
            bloom: ScenePostProcess.Bloom(enabled: true, strength: 2, threshold: 0.65, tint: SIMD3(repeating: 1), hdr: hdr),
            extras: .init(), settings: SceneRenderSettings())
        frame.settings.postProcessing = .ultra
        XCTAssertEqual(ScenePostProcess.hdrLevels(frame), 5, "48 halves 5 times")
        frame.bloom.hdr.iterations = 3
        XCTAssertEqual(ScenePostProcess.hdrLevels(frame), 3)
        frame.bloom.enabled = false
        XCTAssertNil(ScenePostProcess.hdrLevels(frame), "a script turned bloom off: combine_srgb")
    }

    /// The app's bloom slider scales WE's strength; 1 is WE's own.
    func testTheAppsBloomSliderScalesWEsStrength() {
        let bloom = ScenePostProcess.Bloom(enabled: true, strength: 2, threshold: 0.65, tint: SIMD3(repeating: 1))
        XCTAssertEqual(ScenePostProcess.bloomStrength(bloom, extras: .init()), 2)
        XCTAssertEqual(ScenePostProcess.bloomStrength(bloom, extras: .init(bloom: 1.5)), 3)
        XCTAssertEqual(ScenePostProcess.bloomStrength(bloom, extras: .init(bloom: 0)), 0)
        XCTAssertEqual(ScenePostProcess.bloomStrength(bloom, extras: .init(bloom: -1)), 0)
    }

    // MARK: - Composite skip (efficiency-plan-2d notes WP3-A, S2)

    /// The composite is a copy only for a quad exactly covering the output with every adjustment at identity.
    func testTheCompositeCopiesOnlyAnExactIdentityPlacement() {
        let size = SIMD2(1920, 1080)
        XCTAssertTrue(ScenePostProcess.compositeCopies(placement, size: size))
        var shifted = placement
        shifted.position.x += 0.5
        XCTAssertFalse(ScenePostProcess.compositeCopies(shifted, size: size))
        XCTAssertFalse(ScenePostProcess.compositeCopies(placement, size: SIMD2(1920, 1200)))
        XCTAssertFalse(ScenePostProcess.compositeCopies(
            ScenePostProcess.compositeUniform(placement, extras: .init(saturation: 0.9)), size: size))
        XCTAssertFalse(ScenePostProcess.compositeCopies(
            ScenePostProcess.compositeUniform(placement, extras: .init(blur: 1.5)), size: size))
        XCTAssertTrue(ScenePostProcess.compositeCopies(
            ScenePostProcess.compositeUniform(placement, extras: .init(bloom: 2)), size: size), "no bloom to scale")
    }

    /// Every CI scene drawn at its own size with the composite skipped equals, byte for byte (colour;
    /// the desktop ignores alpha), the frame drawn through the composite, wherever two composited
    /// renders agree with each other (random particles don't); through a view and a shared frame.
    /// About 10 min in Debug, so it runs nightly and locally (`OWE_SLOW_TESTS=1`), not on every PR.
    func testTheCompositeSkipEqualsTheCompositeOnCIScenes() throws {
        try SlowTests.require()
        let root = Fixtures.url("Scenes")
        var skipped = 0, compared = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() where !Fixtures.unrenderableScenes.contains(name) {
            let directory = root.appending(path: name)
            guard let data = FileManager.default.contents(atPath: directory.appending(path: "scene.json").path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let general = json["general"] as? [String: Any],
                  let projection = general["orthogonalprojection"] as? [String: Any],
                  let width = projection["width"] as? Int, let height = projection["height"] as? Int,
                  width * height <= 1920 * 1080 else { continue }
            let size = SIMD2(width, height)
            // Set before each load: a draw while a later harness loads would otherwise count.
            func harness(_ screen: String, skips: Bool) throws -> SceneFrameHarness {
                try SceneFrameHarness(directory: directory, size: size, screenID: screen) {
                    $0.skipsIdleFrames = false
                    $0.skipsIdentityComposite = skips
                }
            }
            let skip = try harness("skip", skips: true)
            let plain = try harness("plain", skips: false)
            let control = try harness("control", skips: false)
            defer { skip.close(); plain.close(); control.close() }
            for frame in 0..<24 {
                let shared = frame % 2 == 1
                for harness in [skip, plain, control] {
                    if shared {
                        harness.now += 1.0 / 30
                        let drawable = SIMD2<Float>(Float(size.x), Float(size.y))
                        harness.renderer.renderShared([SceneViewport(drawableSize: drawable, pointSize: drawable, cursor: nil,
                                                                     frameRateLimit: 60)])
                        harness.renderer.lastCommandBuffer?.waitUntilCompleted()
                        harness.renderer.scripts.wallpaper?.waitUntilIdle()
                    } else {
                        harness.draw(frames: 1, step: 1.0 / 30)
                    }
                }
                let reference = Self.rgb(plain, shared: shared)
                guard frame > 2, !reference.isEmpty, reference == Self.rgb(control, shared: shared) else { continue }
                XCTAssertTrue(reference == Self.rgb(skip, shared: shared), "\(name) frame \(frame) (shared \(shared)) differs")
                compared += 1
            }
            skipped += skip.renderer.compositesSkipped
            XCTAssertEqual(plain.renderer.compositesSkipped, 0)
        }
        print("Composite skip CI: \(compared) frames compared, \(skipped) composites skipped")
        XCTAssertGreaterThan(compared, 20)
        XCTAssertGreaterThan(skipped, 20)
    }

    /// The last frame's colour bytes: the view's drawable, or the shared frame.
    private static func rgb(_ harness: SceneFrameHarness, shared: Bool) -> [UInt8] {
        guard let texture = shared ? harness.renderer.sharedFrame : harness.view.currentDrawable?.texture,
              texture.width == harness.size.x, texture.height == harness.size.y,
              let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return [] }
        let bytesPerRow = texture.width * 4
        guard let buffer = device.makeBuffer(length: bytesPerRow * texture.height, options: .storageModeShared),
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else { return [] }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * texture.height)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let bytes = UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: buffer.length)
        return bytes.enumerated().compactMap { $0.offset % 4 == 3 ? nil : $0.element }
    }
}
