import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// A particle texture's sprite-sheet grid, from its `.tex-json` sequence and the texture's pixels,
/// and a refracting drop of WE's rain sheet (`particle/water/rain_drops_sheet`, 16 frames of 64 on
/// 256 × 256, RG88 albedo and an RGBA normal map) drawn through the real loader and renderer; and a
/// sheet from a `.tex`'s own `TEXS` frames, with no `.tex-json` (`Scenes/particle-texs-sheet`).
final class ParticleSpriteSheetTests: XCTestCase {
    // MARK: - Playback

    /// WE writes a sprite-sheet particle's life value as its life fraction times the system's
    /// `sequencemultiplier` (0x14023703b…0x140237075) and the shader takes its fraction's frame
    /// (`ComputeSpriteFrame`): a sequence plays over the particle's life, `sequencemultiplier` times,
    /// whatever the sheet's `duration`.
    func testASequencePlaysOverTheParticlesLife() throws {
        var configuration = SceneMetalParticleSystem(
            source: .image(NSImage()), origin: .zero, emissionRate: 0, maximumParticleCount: 1, rendererName: "sprite",
            trailLength: 0, trailSegments: 1, ropeSubdivision: 0, fadeTrailAlpha: false, fadeTrailSize: false,
            spriteSheet: SpriteSheet(columns: 8, rows: 8, frames: 64, duration: 1), animationMode: "sequence",
            sequenceMultiplier: 3, opacityMultiplier: 1, refractive: false, blending: "translucent")
        configuration.instantaneous = 1
        configuration.program = ParticleProgram(operators: [], initializers: [
            ParticleInitializer(.lifetimeRandom, a: SIMD4<Float>(2.5, 2.5, 1, 0)),
        ])
        let gpu = try ParticleGPUStepper()
        let runtime = ParticleSystemRuntime(texture: try gpu.texture(), configuration: configuration)
        for _ in 0..<75 {
            gpu.step(runtime, inputs: ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero))
        }
        let particle = try XCTUnwrap(gpu.particles(runtime).first)
        let record = try XCTUnwrap(gpu.simulator.records(runtime, as: ParticleSpriteInstance.self, queue: gpu.queue).records.first)
        let life: Float = particle.age / particle.lifetime
        XCTAssertEqual(life, 0.5, accuracy: 0.02, "about halfway through its life")
        let plays: Float = life * 3
        XCTAssertEqual(record.velocityLifetime.w, plays - plays.rounded(.down), accuracy: 1e-4,
                       "3 plays over its life: halfway is 1.5, frame 32 of 64")
    }

    // MARK: - The grid

    /// The grid counts the image's pixels, not its points: an `NSImage` made from a `CGImage`
    /// reports its representation's `pixelsWide` at the screen's backing scale, which made WE's
    /// rain sheet an 8 × 8 grid on a Retina display and drew a quarter of each frame.
    func testTheSheetCountsTheImagesPixels() throws {
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        for points in [256.0, 128, 512] {
            let image = NSImage(cgImage: bitmap, size: NSSize(width: points, height: points))
            for source in [SceneMetalTextureSource.image(image),
                           .animated(TEXAnimatedImages(images: [image], frames: []))] {
                XCTAssertEqual(source.sheetPixelSize, SIMD2(256, 256), "\(points) points")
            }
        }
        XCTAssertNil(SceneMetalTextureSource.animated(TEXAnimatedImages(images: [], frames: [])).sheetPixelSize)
    }

    func testTheGridFollowsTheSequencesFrameSize() {
        let sheet = SpriteSheet(frames: 16, frameSize: SIMD2(64, 64), duration: 1, textureSize: SIMD2(256, 256))
        XCTAssertEqual([sheet.columns, sheet.rows, sheet.frames], [4, 4, 16])
        // Frames fill the rows first; a short last row still counts.
        let short = SpriteSheet(frames: 7, frameSize: SIMD2(64, 32), duration: 1, textureSize: SIMD2(256, 32))
        XCTAssertEqual([short.columns, short.rows], [4, 2])
    }

    /// WE's rain sheet, loaded for a scene: 4 × 4 frames, a quarter of the texture each.
    func testTheRainSheetLoadsAsFourByFour() throws {
        _ = try Fixtures.assets()
        let content = try content(.enabled)
        let system = try XCTUnwrap(content.particleSystems.first)
        let sheet = try XCTUnwrap(system.spriteSheet)
        XCTAssertEqual([sheet.columns, sheet.rows, sheet.frames], [4, 4, 16])
        XCTAssertEqual(system.material?.spriteSheet?.columns, 4, "the material draws the same grid")
    }

    // MARK: - A sheet from the .tex's frames

    /// A compiled `.tex` carries its sheet in `TEXS` (WE's runtime never reads a `.tex-json`):
    /// the Tanjiro wallpaper's glass shards (3245833232) are 16 frames of 64 in a 1024 × 64 strip.
    func testTheTexFramesLayOutTheGrid() throws {
        let strip = (0..<16).map { frame(x: Float($0) * 64, size: 64, duration: 0.0625) }
        let sheet = try XCTUnwrap(SpriteSheet(texFrames: strip, textureSize: SIMD2(1024, 64)))
        XCTAssertEqual([sheet.columns, sheet.rows, sheet.frames], [16, 1, 16])
        XCTAssertEqual(sheet.duration, 1, accuracy: 1e-6, "the frames' times")
        // `TEXS0002` frames carry no time: the `.tex-json` default of a second.
        let untimed = (0..<4).map { frame(x: Float($0) * 16, size: 16, duration: 0) }
        XCTAssertEqual(SpriteSheet(texFrames: untimed, textureSize: SIMD2(64, 16))?.duration, 1)
        // A GIF's frames on several atlases aren't one sheet.
        XCTAssertNil(SpriteSheet(texFrames: [frame(x: 0, size: 16, duration: 0.1), frame(x: 0, size: 16, duration: 0.1, image: 1)],
                                 textureSize: SIMD2(16, 16)))
        XCTAssertNil(SpriteSheet(texFrames: [], textureSize: SIMD2(16, 16)))
    }

    /// `Scenes/particle-texs-sheet`: a 64 × 16 strip of four 16-pixel frames, each an opaque white
    /// square over its middle 8 pixels, with `TEXS` frames and no `.tex-json`.
    func testASheetWithoutTexJSONComesFromTheTexFrames() throws {
        _ = try Fixtures.assets()
        let content = try content(.enabled, directory: texsDirectory)
        let system = try XCTUnwrap(content.particleSystems.first)
        let sheet = try XCTUnwrap(system.spriteSheet, "the .tex's TEXS frames are the sheet")
        XCTAssertEqual([sheet.columns, sheet.rows, sheet.frames], [4, 1, 4])
        XCTAssertEqual(system.material?.spriteSheet?.columns, 4, "the material draws the same grid")
    }

    /// One particle of that strip (size 256: a 128-unit quad around (128, 128)) draws one frame,
    /// square, its white square over the middle half: x and y 96…160. Without the sheet the whole
    /// strip drew on a quad of its 4 : 1 aspect, a dotted line of four squares.
    func testASheetFromTheTexFramesDrawsOneSquareFrame() throws {
        let pixels = try render(.enabled, directory: texsDirectory, until: { $0.x > 128 })
        let lit = pixels.points { $0.x > 128 }
        XCTAssertFalse(lit.isEmpty, "the shard is drawn")
        guard !lit.isEmpty else { return }
        let low = lit.reduce(SIMD2(Int.max, Int.max)) { simd_min($0, $1.point) }
        let high = lit.reduce(SIMD2(Int.min, Int.min)) { simd_max($0, $1.point) }
        XCTAssertEqual(Double(low.x), 96, accuracy: 3, "the square's left edge")
        XCTAssertEqual(Double(high.x), 159, accuracy: 3, "its right edge")
        XCTAssertEqual(Double(low.y), 96, accuracy: 3, "its top edge, not a thin line's")
        XCTAssertEqual(Double(high.y), 159, accuracy: 3, "its bottom edge")
        // One solid square, not four in a row.
        XCTAssertGreaterThan(Double(lit.count) / Double((high.x - low.x + 1) * (high.y - low.y + 1)), 0.9, "filled")
    }

    private func frame(x: Float, size: Float, duration: Float, image: Int = 0) -> TEXAnimationFrame {
        TEXAnimationFrame(imageIndex: image, duration: duration, x: x, y: 0, width: size, widthY: 0, heightX: 0, height: size)
    }

    // MARK: - The drawn drop

    /// One drop (frame 0, a 100-unit sprite tinted red) over a 0.6 grey layer. WE draws the
    /// albedo's luminance (white) times the colour times the refracted scene, with the albedo's
    /// alpha: a red-tinted copy of the grey, the frame's whole blob and nothing else of its quad.
    func testARefractingDropShowsItsWholeFrameOfTheRefractedScene() throws {
        _ = try Fixtures.assets()
        for quality in [GSPostProcessingQuality.enabled, .ultra] {
            let pixels = try render(quality)
            let drop = pixels.points { $0.x > $0.y + 60 }
            XCTAssertFalse(drop.isEmpty, "\(quality): the drop is drawn")
            guard !drop.isEmpty else { continue }
            // Frame 0's blob spans x 10…52 and y 16…48 of its 64 pixels: on the 100-unit quad
            // around (128, 128), x 94…159 and y 103…153, with a clear margin on every side.
            let low = drop.reduce(SIMD2(Int.max, Int.max)) { simd_min($0, $1.point) }
            let high = drop.reduce(SIMD2(Int.min, Int.min)) { simd_max($0, $1.point) }
            XCTAssertEqual(Double(low.x), 94, accuracy: 4, "\(quality): the blob's left edge")
            XCTAssertEqual(Double(high.x), 159, accuracy: 4, "\(quality): its right edge, not the quad's")
            XCTAssertEqual(Double(low.y), 103, accuracy: 4, "\(quality): its top edge")
            XCTAssertEqual(Double(high.y), 153, accuracy: 4, "\(quality): its bottom edge, not the quad's")
            XCTAssertTrue(drop.contains { $0.point == SIMD2(128, 128) }, "\(quality): the blob covers the centre")
            // Inside the blob (its edge pixels aside, which blend with the layer) the refracted
            // grey shows at full strength through the red tint: the drop is the scene seen
            // through water, not a dark shape.
            let inside = drop.filter { $0.color.y < 20 }
            XCTAssertGreaterThan(Double(inside.count) / Double(drop.count), 0.85, "\(quality): mostly covered")
            let reds = inside.map { Int($0.color.x) }
            XCTAssertEqual(reds.min() ?? 0, 153, accuracy: 6, "\(quality): the refracted grey, at its darkest")
            XCTAssertEqual(reds.max() ?? 0, 153, accuracy: 6, "\(quality): and its brightest")
        }
    }

    // MARK: - Helpers

    private static let size = 256
    private let directory = Fixtures.url("Scenes/particle-rain-sheet")
    private let texsDirectory = Fixtures.url("Scenes/particle-texs-sheet")

    override func tearDownWithError() throws {
        Fixtures.removeStoredSettings(for: directory)
        Fixtures.removeStoredSettings(for: texsDirectory)
    }

    private struct Pixels {
        struct Sample {
            let point: SIMD2<Int>
            let color: SIMD3<UInt8>
        }

        let bytes: [UInt8]

        /// Every pixel (y down) whose (r, g, b) passes `test`.
        func points(where test: (SIMD3<Int>) -> Bool) -> [Sample] {
            var result: [Sample] = []
            for y in 0..<ParticleSpriteSheetTests.size {
                for x in 0..<ParticleSpriteSheetTests.size {
                    let i = (y * ParticleSpriteSheetTests.size + x) * 4
                    let color = SIMD3(bytes[i + 2], bytes[i + 1], bytes[i])
                    if test(SIMD3<Int>(truncatingIfNeeded: color)) { result.append(Sample(point: SIMD2(x, y), color: color)) }
                }
            }
            return result
        }
    }

    private func content(_ postProcessing: GSPostProcessingQuality, directory: URL? = nil) throws -> SceneMetalContent {
        let directory = directory ?? self.directory
        let project = try JSONDecoder().decode(WEProject.self, from: Data(contentsOf: directory.appending(path: "project.json")))
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        var settings = SceneRenderSettings()
        settings.postProcessing = postProcessing
        model.setRenderSettings(settings)
        return try XCTUnwrap(model.metalContent())
    }

    /// The fixture (the rain sheet's by default) drawn under `postProcessing` until a pixel passes
    /// `until` (the drop, by default; its pipelines compile off the render thread); the last
    /// frame's drawable.
    private func render(_ postProcessing: GSPostProcessingQuality, directory: URL? = nil,
                        until shown: @escaping (SIMD3<Int>) -> Bool = { $0.x > $0.y + 60 }) throws -> Pixels {
        let content = try content(postProcessing, directory: directory)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: Self.size, height: Self.size)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "rain-sheet"))
        defer { renderer.releaseContent() }
        view.isPaused = true
        renderer.renderSettings.postProcessing = postProcessing
        renderer.setPlacement(.stretch)
        renderer.setContent(content)
        var pixels = Pixels(bytes: [])
        let deadline = Date().addingTimeInterval(30)
        var drawn = 0
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            guard renderer.hasContent, let texture = view.currentDrawable?.texture else { continue }
            drawn += 1
            var bytes = [UInt8](repeating: 0, count: Self.size * Self.size * 4)
            texture.getBytes(&bytes, bytesPerRow: Self.size * 4, from: MTLRegionMake2D(0, 0, Self.size, Self.size), mipmapLevel: 0)
            pixels = Pixels(bytes: bytes)
        } while (drawn < 3 || pixels.points(where: shown).isEmpty) && Date() < deadline
        return pixels
    }
}
