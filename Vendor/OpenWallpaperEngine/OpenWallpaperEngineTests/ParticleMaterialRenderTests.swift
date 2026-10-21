import XCTest
import Metal
import MetalKit
import AppKit
@testable import OpenWallpaperEngine

/// Particles drawn headlessly through WE's `genericparticle` / `genericropeparticle` materials,
/// with the emulated geometry stage and with WE's no-geometry-shader stream. The particles are
/// placed by a GPU step (`ParticleGPUSimulator`), which writes the records the draw reads.
final class ParticleMaterialRenderTests: XCTestCase {
    private static let size = 256
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var renderer: ParticleMaterialRenderer!
    private var simulator: ParticleGPUSimulator!
    private var builder: ParticleMaterialPlanBuilder!
    private var white: MTLTexture!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        renderer = try XCTUnwrap(ParticleMaterialRenderer(device: device))
        simulator = try ParticleGPUSimulator(device: device)
        let roots = [Fixtures.url("Particles"), ShaderVariantTests.weAssets]
        builder = ParticleMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil),
            readFile: { path in roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first },
            loadTexture: { _, _ in nil })
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        white = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        white.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0,
                      withBytes: [UInt8](repeating: 255, count: 64), bytesPerRow: 16)
    }

    // MARK: - Tests

    func testSpriteThroughEmulatedGeometryStage() throws {
        _ = try Fixtures.assets()
        let plan = try self.plan("materials/solid.json", renderer: "sprite", keeping: .emulated(vertexCount: 6))
        // One particle in the top-left quadrant (scene y is up). Its size is half the authored
        // one, and the shaders read it as the quad's width.
        let pixels = try render(plan, particles: [particle(at: SIMD2(64, 192), size: 80)])
        XCTAssertGreaterThan(pixels.red(x: 64, y: 64), 250, "the sprite covers its position")
        XCTAssertGreaterThan(pixels.red(x: 64 + 17, y: 64 - 17), 250, "a size-80 sprite is 40 wide: it reaches 17 out")
        XCTAssertLessThan(pixels.red(x: 64 + 24, y: 64), 5, "and no further than 20")
        XCTAssertLessThan(pixels.red(x: 64, y: 192), 5, "nothing is drawn mirrored")
        XCTAssertEqual(renderer.drawsEncoded, 1, "one instanced draw per system")
    }

    /// WE draws a system through its model matrix: a non-uniform scale squashes the sprite
    /// (`g_Orientation*` carry the emitter's transform).
    func testANonUniformEmitterScaleSquashesTheSprite() throws {
        _ = try Fixtures.assets()
        for geometry in [ParticleMaterialPlan.Stage.Geometry.emulated(vertexCount: 6), .expandedQuads] {
            let plan = try self.plan("materials/solid.json", renderer: "sprite", keeping: geometry)
            // Size 80 draws a 40-wide quad; scaled 2 across and 0.5 up it is 80 by 20.
            let pixels = try render(plan, particles: [particle(at: SIMD2(128, 128), size: 80)],
                                    drawLinear: simd_float2x2(diagonal: SIMD2(2, 0.5)))
            XCTAssertGreaterThan(pixels.red(x: 128 + 36, y: 128), 250, "\(geometry): twice as wide")
            XCTAssertLessThan(pixels.red(x: 128 + 44, y: 128), 5, "\(geometry)")
            XCTAssertGreaterThan(pixels.red(x: 128, y: 128 + 8), 250, "\(geometry)")
            XCTAssertLessThan(pixels.red(x: 128, y: 128 + 12), 5, "\(geometry): half as tall")
        }
    }

    func testSpriteThroughNoGeometryShaderStream() throws {
        _ = try Fixtures.assets()
        let plan = try self.plan("materials/solid.json", renderer: "sprite", keeping: .expandedQuads)
        let pixels = try render(plan, particles: [particle(at: SIMD2(64, 192), size: 80),
                                                  particle(at: SIMD2(192, 64), size: 40)])
        XCTAssertGreaterThan(pixels.red(x: 64, y: 64), 250)
        XCTAssertGreaterThan(pixels.red(x: 192, y: 192), 250, "every instance draws")
        XCTAssertLessThan(pixels.red(x: 192 + 14, y: 192), 5)
        XCTAssertLessThan(pixels.red(x: 128, y: 128), 5)
    }

    func testBothPathsDrawTheSameRotatedSprite() throws {
        _ = try Fixtures.assets()
        var rotated = particle(at: SIMD2(128, 128), size: 120)
        rotated.rotation = .pi / 4
        let emulated = try render(try plan("materials/solid.json", renderer: "sprite", keeping: .emulated(vertexCount: 6)),
                                  particles: [rotated])
        let expanded = try render(try plan("materials/solid.json", renderer: "sprite", keeping: .expandedQuads),
                                  particles: [rotated])
        let differing = zip(emulated.bytes, expanded.bytes).filter { abs(Int($0) - Int($1)) > 8 }.count
        XCTAssertLessThan(differing, 64, "the geometry stage and WE's stream agree (edge pixels aside)")
        // A 45° square reaches its corner along the axes (30·√2 ≈ 42) but not diagonally.
        XCTAssertGreaterThan(emulated.red(x: 128 + 38, y: 128), 250)
        XCTAssertLessThan(emulated.red(x: 128 + 26, y: 128 + 26), 5)
    }

    func testSpriteTrailStretchesAlongVelocity() throws {
        _ = try Fixtures.assets()
        let plan = try self.plan("materials/solid.json", renderer: "spritetrail", keeping: .emulated(vertexCount: 6))
        var moving = particle(at: SIMD2(128, 128), size: 20)
        moving.velocity = SIMD2(200, 0)
        // length 0.05 · speed 200 = 10 sizes long (the default maxlength).
        let pixels = try render(plan, particles: [moving])
        XCTAssertGreaterThan(pixels.red(x: 128 + 40, y: 128), 250, "stretched along the velocity")
        XCTAssertLessThan(pixels.red(x: 128, y: 128 + 12), 5, "not across it")
    }

    func testRopeThroughEmulatedGeometryStage() throws {
        _ = try Fixtures.assets()
        let plan = try self.plan("materials/solid.json", renderer: "rope", keeping: .emulated(vertexCount: 6))
        XCTAssertEqual(plan.shader, "genericropeparticle", "rope renderers swap in WE's rope shader")
        // A horizontal strand across the middle, as wide as the particles' size (the shader's
        // half width is half the size).
        let pixels = try render(plan, particles: [particle(at: SIMD2(32, 128), size: 20),
                                                  particle(at: SIMD2(128, 128), size: 20),
                                                  particle(at: SIMD2(224, 128), size: 20)])
        for x in [48, 128, 200] {
            XCTAssertGreaterThan(pixels.red(x: x, y: 128), 250, "strand at x \(x)")
            XCTAssertGreaterThan(pixels.red(x: x, y: 128 - 8), 250, "strand is 20 units wide at x \(x)")
            XCTAssertLessThan(pixels.red(x: x, y: 128 - 14), 5, "and no wider at x \(x)")
        }
    }

    func testSubdividedRopeCurvesThroughItsPoints() throws {
        _ = try Fixtures.assets()
        let renderer = try decodeRenderer(#"{"name":"rope","subdivision":3}"#)
        let plan = try builder.build(materialPath: "materials/solid.json", renderer: renderer, flags: 0,
                                     baseTexture: .image(NSImage()), spriteSheet: nil)
        XCTAssertEqual(plan.stages.first?.geometry, .emulated(vertexCount: 3 * (4 + 3 * 2 - 2)))
        let pixels = try render(plan, particles: [particle(at: SIMD2(32, 64), size: 12),
                                                  particle(at: SIMD2(128, 192), size: 12),
                                                  particle(at: SIMD2(224, 64), size: 12)])
        XCTAssertGreaterThan(pixels.red(x: 128, y: 64), 250, "passes through the apex")
        XCTAssertLessThan(pixels.red(x: 128, y: 160), 5)
    }

    func testRopeThroughNoGeometryShaderStream() throws {
        _ = try Fixtures.assets()
        let plan = try self.plan("materials/solid.json", renderer: "rope", keeping: .expandedQuads)
        let pixels = try render(plan, particles: [particle(at: SIMD2(32, 128), size: 20),
                                                  particle(at: SIMD2(224, 128), size: 20)])
        XCTAssertGreaterThan(pixels.red(x: 128, y: 128), 250)
        XCTAssertLessThan(pixels.red(x: 128, y: 64), 5)
    }

    func testRopeTrailFollowsEachParticlesHistory() throws {
        _ = try Fixtures.assets()
        let plan = try self.plan("materials/solid.json", renderer: "ropetrail", keeping: .emulated(vertexCount: 6))
        // A particle moving from x 0 to x 200 over a second: its trail's 4 samples a quarter of a
        // second apart reach back past x 50.
        var head = particle(at: SIMD2(0, 128), size: 16)
        head.velocity = SIMD2(200, 0)
        head.moves = true
        let pixels = try render(plan, particles: [head], frames: 60)
        for x in [60, 160] { XCTAssertGreaterThan(pixels.red(x: x, y: 128), 250, "trail at x \(x)") }
        XCTAssertLessThan(pixels.red(x: 230, y: 128), 5, "nothing past the particle")
    }

    func testRandomSpriteFramesShowOneFrameEvenWithFrameBlending() throws {
        _ = try Fixtures.assets()
        // Two frames side by side: red, then green.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 2, height: 1, mipmapped: false)
        let sheet = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        sheet.replace(region: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0,
                      withBytes: [UInt8]([255, 0, 0, 255, 0, 255, 0, 255]), bytesPerRow: 8)
        let frames = SpriteSheet(columns: 2, rows: 1, frames: 2, duration: 1)
        let built = try builder.build(materialPath: "materials/solid.json", renderer: try decodeRenderer(#"{"name":"sprite"}"#),
                                      flags: 0, baseTexture: .image(NSImage()), spriteSheet: frames)
        let stage = try XCTUnwrap(built.stages.first { $0.geometry == .emulated(vertexCount: 6) })
        XCTAssertEqual(stage.variant.combos["SPRITESHEET"], 1)
        XCTAssertEqual(stage.variant.combos["SPRITESHEETBLEND"], 1, "blending is on unless the system's flag 2 is set")
        XCTAssertEqual(stage.variant.combos["THICKFORMAT"], 1)
        var plan = ParticleMaterialPlan(materialPath: built.materialPath, shader: built.shader, format: built.format,
                                        blending: built.blending, stages: [stage], trailLengths: built.trailLengths,
                                        spriteSheet: frames)
        // Clamped, so the frames' outer edges don't pull in the opposite frame.
        plan.textureFlags[0] = .clampUVs
        let chosen = particle(at: SIMD2(128, 128), size: 80)
        for frame in 0..<2 {
            // WE picks a random frame per particle: a seed whose particle lands on `frame`.
            let seed = try self.seed(placing: chosen, onFrame: frame, plan: plan, texture: sheet)
            let pixels = try render(plan, particles: [chosen], seed: seed, texture: sheet, animationMode: "randomframe")
            let index = (128 * Self.size + 128) * 4
            let (own, other) = frame == 0 ? (pixels.bytes[index], pixels.bytes[index + 1])
                                          : (pixels.bytes[index + 1], pixels.bytes[index])
            XCTAssertGreaterThan(own, 250, "frame \(frame) shows")
            XCTAssertLessThan(other, 5, "without the other frame blended in (frame \(frame))")
        }
    }

    func testClampUVsKeepsTheOppositeEdgeOut() throws {
        _ = try Fixtures.assets()
        // A texture whose top row is transparent and bottom row opaque white: repeat would pull
        // the bottom row into the top edge under bilinear filtering.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 4, mipmapped: false)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 4), mipmapLevel: 0,
                        withBytes: [UInt8]([0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255]), bytesPerRow: 4)
        var plan = try self.plan("materials/solid.json", renderer: "sprite", keeping: .emulated(vertexCount: 6))
        // A 1×4 texture makes the quad 4× taller than wide: 20 × 80 around the centre.
        let topRow = 128 - 39
        plan.textureFlags[0] = .clampUVs
        let clamped = try render(plan, particles: [particle(at: SIMD2(128, 128), size: 40)], texture: texture)
        XCTAssertLessThan(clamped.red(x: 128, y: topRow), 5, "clamped: the top edge stays transparent")
        plan.textureFlags[0] = []
        let repeated = try render(plan, particles: [particle(at: SIMD2(128, 128), size: 40)], texture: texture)
        XCTAssertGreaterThan(repeated.red(x: 128, y: topRow), 20, "WE's default repeat wraps the bottom row in")
    }

    // MARK: Geometry stages beyond WE's own

    /// `stripquads.geom` emits `size / 20` separate 20-unit quads (one strip each, 20 units apart)
    /// under a bound of 16 vertices.
    private func stripQuads(size: Float, cull: (MTLCullMode, MTLWinding)? = nil) throws -> Pixels {
        let plan = try self.plan("materials/stripquads.json", renderer: "sprite", keeping: .emulated(vertexCount: 3 * 14, restartsStrips: true))
        return try render(plan, particles: [particle(at: SIMD2(48, 128), size: size)], cull: cull)
    }

    func testRestartedStripsLeaveTheGapsBetweenThem() throws {
        let pixels = try stripQuads(size: 60)
        for x in [48, 88, 128] { XCTAssertGreaterThan(pixels.red(x: x, y: 128), 250, "quad at x \(x)") }
        for x in [68, 108] { XCTAssertLessThan(pixels.red(x: x, y: 128), 5, "no triangle bridges the strips at x \(x)") }
    }

    func testEmittingFewerVerticesThanTheBoundDrawsOnlyThoseTriangles() throws {
        let one = try stripQuads(size: 20)
        XCTAssertGreaterThan(one.red(x: 48, y: 128), 250)
        let lit = stride(from: 0, to: one.bytes.count, by: 4).filter { one.bytes[$0] > 128 }.count
        XCTAssertEqual(Double(lit), 400, accuracy: 44, "one 20 × 20 quad and nothing else")
        let three = try stripQuads(size: 60)
        XCTAssertLessThan(three.red(x: 168, y: 128), 5, "a fourth quad the bound allows is not drawn")
    }

    func testStripTrianglesKeepOneWinding() throws {
        // With back faces culled, a quad whose two triangles wound differently would lose half.
        var counts: [Int] = []
        for winding in [MTLWinding.clockwise, .counterClockwise] {
            let pixels = try stripQuads(size: 60, cull: (.back, winding))
            counts.append(stride(from: 0, to: pixels.bytes.count, by: 4).filter { pixels.bytes[$0] > 128 }.count)
        }
        XCTAssertEqual(counts.min(), 0, "every triangle faces the same way: \(counts)")
        XCTAssertEqual(Double(counts.max() ?? 0), 1200, accuracy: 100, "three whole quads: \(counts)")
    }

    func testBuilderReadsTheTextureFlags() throws {
        _ = try Fixtures.assets()
        let plan = try builder.build(materialPath: "materials/particle/halo.json", renderer: nil, flags: 0,
                                     baseTexture: .image(NSImage()), spriteSheet: nil)
        XCTAssertEqual(plan.textureFlags[0], .clampUVs, "WE's halo.tex clamps")
        let data = try XCTUnwrap(FileManager.default.contents(
            atPath: ShaderVariantTests.weAssets.appending(path: "materials/particle/beam/hose_1.tex").path))
        XCTAssertEqual(TEXFlags(texData: data)?.contains(.clampUVs), false, "rope hoses repeat along the rope")
    }

    func testAdditiveBlendingAndMaterialConstants() throws {
        _ = try Fixtures.assets()
        let plan = try self.plan("materials/additive_overbright.json", renderer: "sprite", keeping: .emulated(vertexCount: 6))
        XCTAssertEqual(plan.blending, "additive")
        // Two overlapping sprites at half brightness (`g_Overbright` 0.5) add up.
        let pixels = try render(plan, particles: [particle(at: SIMD2(128, 128), size: 80),
                                                  particle(at: SIMD2(138, 128), size: 80)])
        XCTAssertEqual(Double(pixels.red(x: 110, y: 128)), 128, accuracy: 3, "one sprite: half")
        XCTAssertGreaterThan(pixels.red(x: 133, y: 128), 250, "overlap: both added")
    }

    // MARK: Refraction (`_rt_FullFrameBuffer`)

    func testRefractionMultipliesTheScenePixelBeneath() throws {
        _ = try Fixtures.assets()
        for geometry in [ParticleMaterialPlan.Stage.Geometry.emulated(vertexCount: 6), .expandedQuads] {
            let plan = try self.plan("materials/refract.json", renderer: "sprite", keeping: geometry)
            XCTAssertTrue(plan.stages.allSatisfy(\.readsSceneSnapshot))
            // Four quadrants. Without a normal map nothing is offset, so a white sprite shows the
            // scene exactly where it lies (not mirrored).
            let scene = Self.scene { x, y in [x < 128 ? 255 : 0, y < 128 ? 255 : 0, 64, 255] }
            let pixels = try render(plan, particles: [particle(at: SIMD2(64, 192), size: 160),
                                                      particle(at: SIMD2(192, 64), size: 160)], scene: scene)
            for (x, y) in [(40, 40), (88, 88), (168, 168), (216, 216)] {
                let index = (y * Self.size + x) * 4
                XCTAssertEqual(Array(pixels.bytes[index..<index + 3]), Array(scene[index..<index + 3]),
                               "\(geometry): the scene beneath at (\(x), \(y))")
            }
        }
    }

    func testRefractionNormalOffsetsAlongTheScreenAxes() throws {
        _ = try Fixtures.assets()
        let plan = try refractionPlan()
        XCTAssertEqual(plan.stages.first?.variant.combos["NORMALMAP"], 1, "a bound normal map switches NORMALMAP on")
        // Left half red, right half green. The normal map's x (alpha, `DecompressNormalWithMask`)
        // is +1 and its mask (red) 1: with the material's refract amount 0.5 the sprite samples
        // the scene half a screen to its right.
        let columns = Self.scene { x, _ in x < 128 ? [255, 0, 0, 255] : [0, 255, 0, 255] }
        let rightward = try solidTexture([255, 128, 128, 255])
        let right = try render(plan, particles: [particle(at: SIMD2(64, 128), size: 100)], scene: columns,
                               assetTexture: { _, _ in rightward })
        XCTAssertEqual(right.bytes[(128 * Self.size + 64) * 4 + 1], 255, "samples the green half to the right")
        XCTAssertEqual(right.bytes[(128 * Self.size + 64) * 4], 0)
        // Top half red, bottom half green, and the normal's y (green) +1: WE samples below it on
        // screen (GL: v up and the offset negated; D3D: v down and not negated).
        let rows = Self.scene { _, y in y < 128 ? [255, 0, 0, 255] : [0, 255, 0, 255] }
        let upward = try solidTexture([255, 255, 128, 128])
        let down = try render(plan, particles: [particle(at: SIMD2(128, 192), size: 100)], scene: rows,
                              assetTexture: { _, _ in upward })
        XCTAssertEqual(down.bytes[(64 * Self.size + 128) * 4 + 1], 255, "samples the green half below")
        XCTAssertEqual(down.bytes[(64 * Self.size + 128) * 4], 0)
    }

    func testCompilingPipelineDrawsNothingRatherThanTheBuiltInDraw() throws {
        _ = try Fixtures.assets()
        // A pixel format no other test compiles for, so the pipeline is new here.
        let format = MTLPixelFormat.bgra8Unorm_srgb
        let plan = try self.plan("materials/additive_overbright.json", renderer: "sprite", keeping: .expandedQuads)
        let system = ParticleSystemRuntime(texture: white, configuration: Self.configuration(
            plan: plan, placing: [particle(at: SIMD2(128, 128), size: 80)]))
        // The first frame starts the compile: the system stays on the material path, drawing nothing.
        XCTAssertNotNil(renderer.prepareSimulated(system, pixelFormat: format))
        XCTAssertFalse(renderer.readsSceneSnapshot(system))
        XCTAssertEqual(renderer.fallbacksReported, 0)
        XCTAssertTrue(renderer.waitUntilCompiled(plan, pixelFormat: format))
        XCTAssertNotNil(renderer.prepareSimulated(system, pixelFormat: format))
    }

    /// Uniform blocks over 4 KB come from the reused arena, not a new buffer per draw.
    func testLargeUniformBlocksComeFromTheArena() throws {
        _ = try Fixtures.assets()
        renderer.uniformArena.inlineLimit = 0
        let plan = try self.plan("materials/solid.json", renderer: "sprite", keeping: .emulated(vertexCount: 6))
        for _ in 0..<3 {
            let pixels = try render(plan, particles: [particle(at: SIMD2(128, 128), size: 80)])
            XCTAssertGreaterThan(pixels.red(x: 128, y: 128), 250, "the block reaches the shaders")
        }
        XCTAssertEqual(renderer.uniformArena.chunksCreated, 1, "one chunk, reused")
    }

    /// Memory pressure drops the pipelines not drawn with since the last critical trim.
    func testMemoryPressureDropsIdlePipelines() throws {
        _ = try Fixtures.assets()
        let plan = try self.plan("materials/solid.json", renderer: "sprite", keeping: .emulated(vertexCount: 6))
        _ = try render(plan, particles: [particle(at: SIMD2(128, 128), size: 80)])
        XCTAssertEqual(renderer.pipelineCount, 1)
        renderer.trimMemory(dropIdlePipelines: false)
        XCTAssertEqual(renderer.pipelineCount, 1, "a warning keeps pipelines")
        renderer.trimMemory(dropIdlePipelines: true)
        XCTAssertEqual(renderer.pipelineCount, 1, "drawn with since the last trim: kept")
        renderer.trimMemory(dropIdlePipelines: true)
        XCTAssertEqual(renderer.pipelineCount, 0, "idle since the last trim: dropped")
    }

    func testUserShaderValuesDriveTheMaterialLive() throws {
        _ = try Fixtures.assets()
        let plan = try self.plan("materials/user_overbright.json", renderer: "sprite", keeping: .emulated(vertexCount: 6))
        var dim = particle(at: SIMD2(128, 128), size: 80)
        dim.color = SIMD4(0.25, 0.25, 0.25, 1)
        let index = (128 * Self.size + 128) * 4
        let unset = try render(plan, particles: [dim])
        XCTAssertEqual(Double(unset.bytes[index]), 0.25 * 255, accuracy: 2, "the constant is the fallback")
        let doubled = try render(plan, particles: [dim], values: UserValues(values: ["glow": "2"]))
        XCTAssertEqual(Double(doubled.bytes[index]), 0.5 * 255, accuracy: 2, "`glow` drives g_Overbright")
        let tripled = try render(plan, particles: [dim], values: UserValues(values: ["glow": "3"]))
        XCTAssertEqual(Double(tripled.bytes[index]), 0.75 * 255, accuracy: 2, "and follows the property")
    }

    func testBlockCompressedTexturesAfterTheFirstSetTheirFormatCombo() {
        func header(format: UInt8) -> Data {
            Data("TEXV0005\u{0}TEXI0001\u{0}".utf8) + Data([format, 0, 0, 0, 2, 0, 0, 0])
        }
        XCTAssertEqual(TEXImageFormat(texData: header(format: 4)), TEXImageFormat(rawValue: 4))
        XCTAssertEqual(TEXFlags(texData: header(format: 4)), .clampUVs, "the flags follow the format word")
        let combos = ParticleMaterialPlanBuilder.textureFormatCombos([0: header(format: 4), 1: header(format: 4),
                                                                      2: header(format: 8), 3: header(format: 0)])
        XCTAssertEqual(combos, ["TEX1FORMAT": 4, "TEX2FORMAT": 8],
                       "a DXT5 normal map and an RG88 texture; RGBA and a block-compressed texture 0 stay unset")
    }

    /// An RG88 normal map (loaded as (r, g, 0, 1)) refracts by `DecompressNormalWithMask`'s RG88
    /// branch: x from green, y from red, the mask (alpha) 1.
    func testRG88NormalMapRefractsThroughItsFormatCombo() throws {
        _ = try Fixtures.assets()
        let built = try reducedFormatBuilder().build(materialPath: "materials/refract_rg88.json",
                                                     renderer: try decodeRenderer(#"{"name":"sprite"}"#), flags: 0,
                                                     baseTexture: .image(NSImage()), spriteSheet: nil)
        let plan = emulated(built)
        XCTAssertEqual(plan.stages.first?.variant.combos["TEX1FORMAT"], 8)
        let normal = try rg88Texture([128, 255])
        let columns = Self.scene { x, _ in x < 128 ? [255, 0, 0, 255] : [0, 255, 0, 255] }
        let pixels = try render(plan, particles: [particle(at: SIMD2(64, 128), size: 100)], scene: columns,
                                assetTexture: { _, _ in normal })
        XCTAssertEqual(pixels.bytes[(128 * Self.size + 64) * 4 + 1], 255, "green is x: it samples the half to the right")
        XCTAssertEqual(pixels.bytes[(128 * Self.size + 64) * 4], 0)
    }

    /// An RG88 albedo reads as luminance and alpha (`ConvertTexture0Format`'s `.rrrg`).
    func testRG88AlbedoReadsAsLuminanceAndAlpha() throws {
        _ = try Fixtures.assets()
        let built = try reducedFormatBuilder().build(materialPath: "materials/albedo_rg88.json",
                                                     renderer: try decodeRenderer(#"{"name":"sprite"}"#), flags: 0,
                                                     baseTexture: .image(NSImage()), spriteSheet: nil)
        let plan = emulated(built)
        XCTAssertEqual(plan.stages.first?.variant.combos["TEX0FORMAT"], 8)
        let pixels = try render(plan, particles: [particle(at: SIMD2(128, 128), size: 80)], texture: try rg88Texture([255, 128]))
        let index = (128 * Self.size + 128) * 4
        for channel in 0..<3 {
            XCTAssertEqual(Double(pixels.bytes[index + channel]), 128, accuracy: 2, "white at half alpha over black")
        }
    }

    func testFailedPipelineFallsBackToTheBuiltInDraw() throws {
        _ = try Fixtures.assets()
        let (plan, broken) = try brokenPlan()
        let system = ParticleSystemRuntime(texture: white, configuration: Self.configuration(plan: plan))
        XCTAssertTrue(renderer.waitUntilCompiled(plan, pixelFormat: .rgba8Unorm))
        XCTAssertNotNil(renderer.pipelineFailure(broken, plan: plan, pixelFormat: .rgba8Unorm))
        XCTAssertNil(renderer.prepareSimulated(system, pixelFormat: .rgba8Unorm))
    }

    func testSpriteSheetFrameVariables() {
        let info = BuiltinTextureInfo(allocatedSize: SIMD2(512, 512), contentSize: SIMD2(400, 300))
        let value = ParticleMaterialUniforms.spriteSheetRenderVar(SpriteSheet(columns: 4, rows: 3, frames: 12, duration: 1),
                                                                   texture: info)
        XCTAssertEqual(value.x, 100 / 512, accuracy: 1e-6)
        XCTAssertEqual(value.y, 100 / 512, accuracy: 1e-6)
        XCTAssertEqual(value.z, 12)
        XCTAssertEqual(value.w, 1, accuracy: 1e-6)
    }

    // MARK: - Risks (docs/test-risks.md)

    /// I3: every attribute a stage reads is fed from the record, for every renderer form.
    func testEveryAttributeTheStageReadsComesFromTheRecord() throws {
        _ = try Fixtures.assets()
        let sheet = SpriteSheet(columns: 2, rows: 2, frames: 4, duration: 1)
        for (name, spriteSheet) in [("sprite", nil), ("sprite", sheet), ("spritetrail", nil), ("spritetrail", sheet),
                                    ("rope", nil), ("ropetrail", nil)] as [(String, SpriteSheet?)] {
            let plan = try builder.build(materialPath: "materials/solid.json", renderer: try decodeRenderer(#"{"name":"\#(name)"}"#),
                                         flags: 0, baseTexture: .image(NSImage()), spriteSheet: spriteSheet)
            XCTAssertEqual(plan.stages.count, 2, name)
            for stage in plan.stages {
                let function = try XCTUnwrap(try device.makeLibrary(source: stage.variant.vertexMSL, options: nil)
                    .makeFunction(name: "main0"))
                for attribute in function.vertexAttributes ?? [] where attribute.isActive {
                    let names = stage.variant.attributes.filter { $0.value == attribute.attributeIndex }.keys
                    XCTAssertTrue(names.contains { plan.format.recordOffset(ofAttribute: $0) != nil },
                                  "\(name)\(spriteSheet == nil ? "" : " sheet") \(stage.geometry): \(names.sorted()) would read zero")
                }
            }
        }
    }

    /// I3: `a_Color` carries the particle's colour and alpha to the pixel.
    func testColourAndAlphaReachThePixel() throws {
        _ = try Fixtures.assets()
        let plan = try self.plan("materials/solid.json", renderer: "sprite", keeping: .emulated(vertexCount: 6))
        var red = particle(at: SIMD2(128, 128), size: 80)
        red.color = SIMD4<Float>(1, 0, 0, 0.5)
        let pixels = try render(plan, particles: [red])
        let index = (128 * Self.size + 128) * 4
        XCTAssertEqual(Double(pixels.bytes[index]), 128, accuracy: 2, "half-transparent red over black")
        XCTAssertLessThan(pixels.bytes[index + 1], 2)
        XCTAssertLessThan(pixels.bytes[index + 2], 2)
    }

    /// I7: a mid-grey texel stays mid-grey in the scene target's format (no sRGB conversion).
    func testGreyStaysGreyInTheSceneFormat() throws {
        _ = try Fixtures.assets()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        let grey = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        grey.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0,
                     withBytes: [UInt8](repeating: 0x80, count: 64).enumerated().map { $0.offset % 4 == 3 ? 255 : $0.element },
                     bytesPerRow: 16)
        let plan = try self.plan("materials/solid.json", renderer: "sprite", keeping: .emulated(vertexCount: 6))
        for format in [MTLPixelFormat.rgba8Unorm, .bgra8Unorm] {
            let pixels = try render(plan, particles: [particle(at: SIMD2(128, 128), size: 80)], texture: grey, pixelFormat: format)
            let index = (128 * Self.size + 128) * 4
            for channel in 0..<3 {
                XCTAssertEqual(Double(pixels.bytes[index + channel]), 128, accuracy: 1, "\(format.rawValue) channel \(channel)")
            }
        }
    }

    /// I10: a coverage-mask sprite (R8, loaded as (r, 0, 0, 1) like the GPU samples it) takes its
    /// colour from the particle and its alpha from the mask: `TEX0FORMAT` makes
    /// `ConvertTexture0Format` read it as (1, 1, 1, r).
    func testCoverageMaskSpriteTakesTheParticlesColour() throws {
        _ = try Fixtures.assets()
        let built = try reducedFormatBuilder().build(materialPath: "materials/albedo_r8.json",
                                                     renderer: try decodeRenderer(#"{"name":"sprite"}"#), flags: 0,
                                                     baseTexture: .image(NSImage()), spriteSheet: nil)
        let plan = emulated(built)
        XCTAssertEqual(plan.stages.first?.variant.combos["TEX0FORMAT"], 9)
        var tinted = particle(at: SIMD2(128, 128), size: 80)
        tinted.color = SIMD4(1, 0.5, 0, 1)
        let pixels = try render(plan, particles: [tinted], texture: try reducedTexture(format: 9, texel: [128]))
        let index = (128 * Self.size + 128) * 4
        XCTAssertEqual(Double(pixels.bytes[index]), 128, accuracy: 2)
        XCTAssertEqual(Double(pixels.bytes[index + 1]), 64, accuracy: 2)
        XCTAssertLessThan(pixels.bytes[index + 2], 2)
    }

    /// I16: a system that can't use its material is reported once, however many frames ask.
    func testAFallbackIsReportedOnce() throws {
        _ = try Fixtures.assets()
        let (plan, _) = try brokenPlan()
        XCTAssertTrue(renderer.waitUntilCompiled(plan, pixelFormat: .rgba8Unorm))
        let system = ParticleSystemRuntime(texture: white, configuration: Self.configuration(plan: plan))
        for _ in 0..<100 {
            XCTAssertNil(renderer.prepareSimulated(system, pixelFormat: .rgba8Unorm))
        }
        XCTAssertEqual(renderer.fallbacksReported, 1)
    }

    /// I21: every uniform a particle stage declares gets a value: a built-in, a material or
    /// annotation constant, or one of the particle uniforms `ParticleMaterialUniforms` writes.
    func testEveryParticleUniformHasASource() throws {
        _ = try Fixtures.assets()
        let particleUniforms: Set = ["g_OrientationRight", "g_OrientationUp", "g_OrientationForward", "g_EyePosition",
                                     "g_RenderVar0", "g_RenderVar1"]
        let sheet = SpriteSheet(columns: 2, rows: 2, frames: 4, duration: 1)
        for (name, spriteSheet) in [("sprite", nil), ("sprite", sheet), ("spritetrail", nil), ("rope", nil),
                                    ("ropetrail", nil)] as [(String, SpriteSheet?)] {
            for material in ["materials/solid.json", "materials/additive_overbright.json"] {
                let plan = try builder.build(materialPath: material, renderer: try decodeRenderer(#"{"name":"\#(name)"}"#),
                                             flags: 0, baseTexture: .image(NSImage()), spriteSheet: spriteSheet)
                for stage in plan.stages {
                    for member in (stage.variant.uniforms?.members ?? [:]).keys {
                        let sourced = BuiltinUniforms.isBuiltin(member) || particleUniforms.contains(member)
                            || stage.constants.staticValues[member] != nil
                            || stage.constants.dynamic.contains { $0.uniform == member }
                        XCTAssertTrue(sourced, "\(material) \(name) \(stage.geometry): \(member) is never set")
                    }
                }
            }
        }
    }

    /// I14: a rope joins its particles in their order; without a particle, its neighbours join.
    func testRopeJoinsParticlesInOrder() throws {
        _ = try Fixtures.assets()
        let plan = try self.plan("materials/solid.json", renderer: "rope", keeping: .emulated(vertexCount: 6))
        let zigzag = [SIMD2<Float>(32, 64), SIMD2(96, 192), SIMD2(160, 64), SIMD2(224, 192)]
            .map { particle(at: $0, size: 20) }
        // Scene y is up; pixel rows run down.
        func lit(_ pixels: Pixels, _ point: SIMD2<Float>) -> Bool { pixels.red(x: Int(point.x), y: Self.size - Int(point.y)) > 250 }
        let whole = try render(plan, particles: zigzag)
        for (a, b) in zip(zigzag, zigzag.dropFirst()) {
            XCTAssertTrue(lit(whole, (a.position + b.position) / 2), "segment \(a.position) → \(b.position)")
        }
        XCTAssertFalse(lit(whole, SIMD2(128, 128 + 40)), "no segment skips a particle")
        let gap = try render(plan, particles: [zigzag[0], zigzag[1], zigzag[3]])
        XCTAssertTrue(lit(gap, (zigzag[1].position + zigzag[3].position) / 2), "the neighbours join")
        XCTAssertFalse(lit(gap, (zigzag[1].position + zigzag[2].position) / 2), "nothing is drawn to the removed particle")
    }

    /// I14: `genericropeparticle` builds for every subdivision and trail combo through its
    /// geometry stage, and through WE's no-geometry-shader stream except where WE's own shader
    /// doesn't compile: with `TRAILSCROLLALPHA` and `TRAILFADESIZE` it writes `sizeStart.w` on a
    /// float.
    func testRopeShaderBuildsForEverySubdivisionAndTrailCombo() throws {
        _ = try Fixtures.assets()
        let comboSets: [[String: Int]] = [[:], ["TRAILSCROLLALPHA": 1], ["TRAILSCROLLALPHA": 1, "TRAILFADEALPHA": 1],
                                          ["TRAILSCROLLALPHA": 1, "TRAILFADESIZE": 1],
                                          ["TRAILSCROLLALPHA": 1, "TRAILFADEALPHA": 1, "TRAILFADESIZE": 1]]
        let roots = [Fixtures.url("Particles"), ShaderVariantTests.weAssets]
        var failures: [String] = []
        for combos in comboSets {
            let json = try JSONSerialization.data(withJSONObject: ["passes": [[
                "blending": "translucent", "shader": "genericparticle", "textures": ["particle/solid"], "combos": combos]]])
            let builder = ParticleMaterialPlanBuilder(
                translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil),
                readFile: { path in
                    path == "materials/rope.json" ? json
                        : roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first
                },
                loadTexture: { _, _ in nil })
            for name in ["rope", "ropetrail"] {
                for subdivision in 0...4 {
                    let label = "\(name) S=\(subdivision) \(combos.keys.sorted())"
                    let plan = try builder.build(materialPath: "materials/rope.json",
                                                 renderer: try decodeRenderer(#"{"name":"\#(name)","subdivision":\#(subdivision)}"#),
                                                 flags: 0, baseTexture: .image(NSImage()), spriteSheet: nil)
                    XCTAssertTrue(renderer.waitUntilCompiled(plan, pixelFormat: .bgra8Unorm), label)
                    let geometries = plan.stages.map(\.geometry)
                    let shippedBug = combos["TRAILSCROLLALPHA"] == 1 && combos["TRAILFADESIZE"] == 1
                    if geometries.contains(.expandedQuads) == shippedBug {
                        failures.append("\(label): vertex stage \(shippedBug ? "builds; drop the exception" : "missing")")
                    }
                    if !geometries.contains(where: { if case .emulated = $0 { return true } else { return false } }) {
                        failures.append("\(label): no geometry stage")
                    }
                    for stage in plan.stages {
                        if let failure = renderer.pipelineFailure(stage, plan: plan, pixelFormat: .bgra8Unorm) {
                            failures.append("\(label) \(stage.geometry): \(failure)")
                        }
                    }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// I24: additive particles with overbright above 1 saturate the 8-bit target.
    func testAdditiveOverbrightSaturates() throws {
        _ = try Fixtures.assets()
        let overbright = #"{"passes":[{"blending":"additive","shader":"genericparticle","textures":["particle/solid"],"#
            + #""constantshadervalues":{"ui_editor_properties_overbright":1.6}}]}"#
        let roots = [Fixtures.url("Particles"), ShaderVariantTests.weAssets]
        let builder = ParticleMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil),
            readFile: { path in
                path == "materials/overbright.json" ? Data(overbright.utf8)
                    : roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first
            },
            loadTexture: { _, _ in nil })
        let built = try builder.build(materialPath: "materials/overbright.json", renderer: try decodeRenderer(#"{"name":"sprite"}"#),
                                      flags: 0, baseTexture: .image(NSImage()), spriteSheet: nil)
        let plan = ParticleMaterialPlan(materialPath: built.materialPath, shader: built.shader, format: built.format,
                                        blending: built.blending, stages: built.stages.filter { $0.geometry == .emulated(vertexCount: 6) },
                                        trailLengths: built.trailLengths, spriteSheet: nil)
        var dim = particle(at: SIMD2(128, 128), size: 80)
        dim.color = SIMD4(0.8, 0.5, 0.25, 1)
        let pixels = try render(plan, particles: [dim])
        let index = (128 * Self.size + 128) * 4
        XCTAssertEqual(pixels.bytes[index], 255, "0.8 × 1.6 clamps at 1")
        XCTAssertEqual(Double(pixels.bytes[index + 1]), 0.5 * 1.6 * 255, accuracy: 2)
        XCTAssertEqual(Double(pixels.bytes[index + 2]), 0.25 * 1.6 * 255, accuracy: 2)
    }

    // MARK: - Helpers

    private func decodeRenderer(_ json: String) throws -> WEParticleRenderer {
        try JSONDecoder().decode(WEParticleRenderer.self, from: Data(json.utf8))
    }

    /// Builds the material for `renderer` and keeps only the stage of the path under test.
    private func plan(_ material: String, renderer name: String,
                      keeping geometry: ParticleMaterialPlan.Stage.Geometry) throws -> ParticleMaterialPlan {
        // Ropes without subdivision (`TRAILSUBDIVISION` 0), which these pixel checks assume.
        let json = name.hasPrefix("rope") ? #"{"name":"\#(name)","subdivision":0}"# : #"{"name":"\#(name)"}"#
        let plan = try builder.build(materialPath: material, renderer: try decodeRenderer(json),
                                     flags: 0, baseTexture: .image(NSImage()), spriteSheet: nil)
        let stages = plan.stages.filter { $0.geometry == geometry }
        XCTAssertEqual(stages.count, 1, "\(material) \(name): \(plan.stages.map(\.geometry))")
        return ParticleMaterialPlan(materialPath: plan.materialPath, shader: plan.shader, format: plan.format,
                                    blending: plan.blending, stages: stages, trailLengths: plan.trailLengths,
                                    spriteSheet: plan.spriteSheet)
    }

    /// A sprite plan whose only stage's vertex MSL is deliberately not Metal. It keeps a material
    /// path of its own, so its logged pipeline failure isn't mistaken for a real material's.
    private func brokenPlan() throws -> (plan: ParticleMaterialPlan, stage: ParticleMaterialPlan.Stage) {
        let good = try plan("materials/solid.json", renderer: "sprite", keeping: .emulated(vertexCount: 6))
        let stage = try XCTUnwrap(good.stages.first)
        let broken = ParticleMaterialPlan.Stage(
            geometry: stage.geometry,
            variant: TranslatedShaderVariant(vertexMSL: "not metal", fragmentMSL: stage.variant.fragmentMSL,
                                             uniforms: stage.variant.uniforms, textureSlots: stage.variant.textureSlots,
                                             attributes: stage.variant.attributes, combos: stage.variant.combos),
            variantKey: "broken", textures: stage.textures, constants: stage.constants)
        let plan = ParticleMaterialPlan(materialPath: "tests/deliberately-broken-vertex-stage.json", shader: good.shader,
                                        format: good.format, blending: good.blending, stages: [broken],
                                        trailLengths: good.trailLengths, spriteSheet: nil)
        return (plan, broken)
    }

    /// `refract_normal.json`'s emulated sprite stage, its normal map (`refractnormal`) found.
    private func refractionPlan() throws -> ParticleMaterialPlan {
        let roots = [Fixtures.url("Particles"), ShaderVariantTests.weAssets]
        let builder = ParticleMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil),
            readFile: { path in roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first },
            loadTexture: { name, _ in name == "refractnormal" ? .image(NSImage()) : nil })
        let built = try builder.build(materialPath: "materials/refract_normal.json", renderer: try decodeRenderer(#"{"name":"sprite"}"#),
                                      flags: 0, baseTexture: .image(NSImage()), spriteSheet: nil)
        return ParticleMaterialPlan(materialPath: built.materialPath, shader: built.shader, format: built.format,
                                    blending: built.blending, stages: built.stages.filter { $0.geometry == .emulated(vertexCount: 6) },
                                    trailLengths: built.trailLengths, spriteSheet: nil)
    }

    /// A builder that also finds the RG88 and R8 `.tex` files the `*_rg88.json` and `*_r8.json`
    /// fixtures name.
    private func reducedFormatBuilder() -> ParticleMaterialPlanBuilder {
        let roots = [Fixtures.url("Particles"), ShaderVariantTests.weAssets]
        let generated = ["materials/refractnormal_rg88.tex": TextureRG88Tests.tex(format: 8),
                         "materials/albedo_rg88.tex": TextureRG88Tests.tex(format: 8),
                         "materials/albedo_r8.tex": TextureRG88Tests.tex(format: 9)]
        return ParticleMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil),
            readFile: { path in
                generated[path] ?? roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first
            },
            loadTexture: { name, _ in name == "refractnormal_rg88" ? .image(NSImage()) : nil })
    }

    private func emulated(_ plan: ParticleMaterialPlan) -> ParticleMaterialPlan {
        ParticleMaterialPlan(materialPath: plan.materialPath, shader: plan.shader, format: plan.format,
                             blending: plan.blending, stages: plan.stages.filter { $0.geometry == .emulated(vertexCount: 6) },
                             trailLengths: plan.trailLengths, spriteSheet: nil)
    }

    /// A 4×4 RG88 texture of one texel value, loaded as the scene loader loads it.
    private func rg88Texture(_ texel: [UInt8]) throws -> MTLTexture {
        try reducedTexture(format: 8, texel: texel)
    }

    /// A 4×4 `.tex` of `format` (RG88 or R8) filled with `texel`, loaded and uploaded as the app does.
    private func reducedTexture(format: UInt32, texel: [UInt8]) throws -> MTLTexture {
        let data = TextureRG88Tests.tex(format: format, width: 4, height: 4, pixels: (0..<16).flatMap { _ in texel })
        let image = try XCTUnwrap(TEXParser(data: data).extractImage()?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return try SceneTextureUpload.texture(from: image, loader: MTKTextureLoader(device: device), device: device)
    }

    /// A 4×4 texture of one RGBA colour.
    private func solidTexture(_ rgba: [UInt8]) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let bytes = (0..<16).flatMap { _ in rgba }
        texture.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 16)
        return texture
    }

    /// RGBA bytes of a scene target, `color(x, y)` per pixel, row 0 at the top.
    private static func scene(_ color: (Int, Int) -> [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(size * size * 4)
        for y in 0..<size {
            for x in 0..<size { bytes += color(x, y) }
        }
        return bytes
    }

    /// A particle of authored `sizerandom` `size`: WE's particle size is half that (its base size
    /// 0.5 times the random, `wallpaper64.exe` 0x14023b340), which the shaders read as the quad's width.
    private func particle(at position: SIMD2<Float>, size: Float) -> Placed {
        Placed(position: position, size: size / 2)
    }

    /// A seed whose GPU step gives `placed` sprite-sheet frame `frame` (`randomframe`).
    private func seed(placing placed: Placed, onFrame frame: Int, plan: ParticleMaterialPlan,
                      texture: MTLTexture) throws -> UInt32 {
        XCTAssertTrue(renderer.waitUntilCompiled(plan, pixelFormat: .rgba8Unorm), "pipelines still compiling")
        let configuration = Self.configuration(plan: plan, placing: [placed], animationMode: "randomframe")
        for seed in UInt32(0)..<64 {
            let system = ParticleSystemRuntime(texture: texture, configuration: configuration, seed: seed)
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertTrue(Self.step(system, renderer: renderer, simulator: simulator, pixelFormat: .rgba8Unorm,
                                    sceneSize: SIMD2(Float(Self.size), Float(Self.size)), commandBuffer: buffer))
            buffer.commit()
            buffer.waitUntilCompleted()
            if simulator.snapshot(system, queue: queue).first?.spriteFrame == frame { return seed }
        }
        XCTFail("no seed in 64 puts the particle on frame \(frame)")
        return 0
    }

    struct Pixels {
        let bytes: [UInt8]
        let width: Int
        /// Row 0 is the top of the scene.
        func red(x: Int, y: Int) -> UInt8 { bytes[(y * width + x) * 4] }
    }

    struct NoValues: SceneValueContext {
        func userProperty(_ name: String) -> String? { nil }
        func evaluateScript(_ source: String, properties: SceneScriptProperties, current: ShaderValue) -> ShaderValue? { nil }
    }

    struct UserValues: SceneValueContext {
        let values: [String: String]
        func userProperty(_ name: String) -> String? { values[name] }
        func evaluateScript(_ source: String, properties: SceneScriptProperties, current: ShaderValue) -> ShaderValue? { nil }
    }

    /// Draws `particles` onto a target holding `scene` (black without one), which is also the
    /// snapshot a refracting stage reads. The particles are spawned by a GPU step of an emitter
    /// whose world transform is `drawLinear` at the first particle, and stepped `frames` times
    /// (the last one drawn). Particles that differ in more than their position are spawned by
    /// systems of their own, drawn in the order they first appear.
    private func render(_ plan: ParticleMaterialPlan, particles: [Placed], frames: Int = 1, seed: UInt32 = 0,
                        texture: MTLTexture? = nil,
                        animationMode: String = "sequence", cull: (MTLCullMode, MTLWinding)? = nil,
                        pixelFormat: MTLPixelFormat = .rgba8Unorm, scene: [UInt8]? = nil,
                        values: SceneValueContext = NoValues(), drawLinear: simd_float2x2 = matrix_identity_float2x2,
                        assetTexture: @escaping (String, SceneMetalTextureSource) -> MTLTexture? = { _, _ in nil }) throws -> Pixels {
        let size = Self.size
        let sceneSize = SIMD2<Float>(Float(size), Float(size))
        XCTAssertTrue(renderer.waitUntilCompiled(plan, pixelFormat: pixelFormat), "pipelines still compiling")
        for stage in plan.stages {
            XCTAssertNil(renderer.pipelineFailure(stage, plan: plan, pixelFormat: pixelFormat))
        }
        let anchor = particles.first?.position ?? .zero
        let emitter = SceneAffineTransform(linear: drawLinear, translation: anchor)
        var groups: [[Placed]] = []
        for var placed in particles {
            placed.position -= anchor
            if let index = groups.firstIndex(where: { $0[0].look == placed.look }) {
                groups[index].append(placed)
            } else {
                groups.append([placed])
            }
        }
        let systems = groups.map {
            ParticleSystemRuntime(texture: texture ?? white,
                                  configuration: Self.configuration(plan: plan, placing: $0, animationMode: animationMode),
                                  seed: seed)
        }
        for _ in 1..<max(frames, 1) {
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            for system in systems {
                XCTAssertTrue(Self.step(system, renderer: renderer, simulator: simulator, pixelFormat: pixelFormat,
                                        sceneSize: sceneSize, emitter: emitter, commandBuffer: buffer))
            }
            buffer.commit()
            buffer.waitUntilCompleted()
            XCTAssertNil(buffer.error)
        }
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        for system in systems {
            XCTAssertTrue(Self.step(system, renderer: renderer, simulator: simulator, pixelFormat: pixelFormat,
                                    sceneSize: sceneSize, emitter: emitter, commandBuffer: buffer), "draws through the material")
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: size, height: size, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var snapshot: MTLTexture?
        if let scene {
            let copy = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            for texture in [target, copy] {
                texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: scene, bytesPerRow: size * 4)
            }
            snapshot = copy
        }
        for system in systems {
            XCTAssertEqual(renderer.readsSceneSnapshot(system), plan.stages.first?.readsSceneSnapshot ?? false)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = scene == nil ? .clear : .load
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let encoder = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
        if let cull {
            encoder.setCullMode(cull.0)
            encoder.setFrontFacing(cull.1)
        }
        for system in systems {
            renderer.draw(system, encoder: encoder, commandBuffer: buffer, context: .init(
                sceneSize: sceneSize, frame: BuiltinFrameContext(), values: values,
                assetTexture: assetTexture, sceneSnapshot: snapshot))
        }
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        target.getBytes(&bytes, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        return Pixels(bytes: bytes, width: size)
    }

    /// A system with every simulation setting neutral; only the renderer fields matter here.
    static func configuration(plan: ParticleMaterialPlan, animationMode: String = "sequence") -> SceneMetalParticleSystem {
        let trail = plan.stages.first?.variant.combos["TRAILRENDERER"] == 1
        let rendererName = plan.format == .rope ? (trail ? "ropetrail" : "rope") : (trail ? "spritetrail" : "sprite")
        var system = SceneMetalParticleSystem(
            source: .image(NSImage()), origin: .zero, emissionRate: 0, maximumParticleCount: 100,
            rendererName: rendererName, trailLength: 1, trailSegments: 4, ropeSubdivision: 1, fadeTrailAlpha: false,
            fadeTrailSize: false, spriteSheet: plan.spriteSheet, animationMode: animationMode, sequenceMultiplier: 1,
            opacityMultiplier: 1, refractive: false, blending: plan.blending)
        system.material = plan
        return system
    }

    /// A particle a draw test places: where it spawns and what it spawns with.
    struct Placed {
        /// In the system's space (the scene, for a system at the origin).
        var position: SIMD2<Float>
        /// WE's particle size, which the shaders read as the quad's width (half the `sizerandom`).
        var size: Float
        var velocity = SIMD2<Float>.zero
        var rotation: Float = 0
        /// The colour, and the particle's alpha in `w`.
        var color = SIMD4<Float>(repeating: 1)
        /// Moves along its velocity (WE's `movement` operator); otherwise it holds still.
        var moves = false

        /// Everything but the position, which one system's initializers give all its particles.
        var look: [Float] {
            [size, velocity.x, velocity.y, rotation, color.x, color.y, color.z, color.w, moves ? 1 : 0]
        }
    }

    /// `configuration(plan:animationMode:)` spawning `particles` on its first step: a one-particle
    /// burst from a zero-extent box at each position, and initializers that give every particle the
    /// first's size, velocity, rotation, colour and alpha, and a lifetime of 10 seconds.
    static func configuration(plan: ParticleMaterialPlan, placing particles: [Placed],
                              animationMode: String = "sequence") -> SceneMetalParticleSystem {
        placing(particles, in: configuration(plan: plan, animationMode: animationMode))
    }

    /// `system` spawning `particles` on its first step (see `configuration(plan:placing:)`).
    static func placing(_ particles: [Placed], in system: SceneMetalParticleSystem) -> SceneMetalParticleSystem {
        var system = system
        guard let first = particles.first else { return system }
        let emitters = particles.map { placed -> ParticleEmitter in
            var shape = ParticleEmitterShape()
            shape.kind = .box
            shape.origin = SIMD3<Float>(placed.position.x, placed.position.y, 0)
            shape.directions = SIMD3<Float>(1, 1, 0)
            shape.distanceMaximum = .zero
            return ParticleEmitter(shape: shape, rate: 0, instantaneous: 1)
        }
        system.emitter = emitters[0].shape
        system.instantaneous = 1
        system.extraEmitters = Array(emitters.dropFirst())
        let size: Float = first.size * 2, color: SIMD4<Float> = first.color
        system.program = ParticleProgram(
            operators: first.moves ? [ParticleOperator(.movement)] : [],
            initializers: [
                ParticleInitializer(.lifetimeRandom, a: SIMD4<Float>(10, 10, 1, 0)),
                ParticleInitializer(.sizeRandom, a: SIMD4<Float>(size, size, 1, 0)),
                ParticleInitializer(.alphaRandom, a: SIMD4<Float>(color.w, color.w, 1, 0)),
                ParticleInitializer(.colorRandom, a: SIMD4<Float>(color.x, color.y, color.z, 1),
                                    b: SIMD4<Float>(color.x, color.y, color.z, 0)),
                ParticleInitializer(.velocityRandom, a: SIMD4<Float>(first.velocity.x, first.velocity.y, 0, 1),
                                    b: SIMD4<Float>(first.velocity.x, first.velocity.y, 0, 0)),
                ParticleInitializer(.rotationRandom, a: SIMD4<Float>(0, 0, first.rotation, 1),
                                    b: SIMD4<Float>(0, 0, first.rotation, 0)),
            ])
        return system
    }

    /// One frame of `system` on the GPU, encoded into `commandBuffer` as the renderer encodes it
    /// before the draw: `prepareSimulated`, then a step that writes the material's records. False
    /// when the system can't draw through its material.
    @discardableResult
    static func step(_ system: ParticleSystemRuntime, renderer: ParticleMaterialRenderer, simulator: ParticleGPUSimulator,
                     pixelFormat: MTLPixelFormat, depthFormat: MTLPixelFormat = .invalid, sceneSize: SIMD2<Float>,
                     emitter: SceneAffineTransform? = nil, commandBuffer: MTLCommandBuffer) -> Bool {
        guard let simulated = renderer.prepareSimulated(system, pixelFormat: pixelFormat, depthFormat: depthFormat) else {
            return false
        }
        let inputs = ParticleFrameInputs.advance(system, deltaTime: 1 / 60, cursor: .zero, emitter: emitter)
        let kind = ParticleGPUDrawKind.material(simulated.format, rendererName: system.configuration.rendererName)
        simulator.encode([ParticleGPUSimulator.Request(system: system, inputs: inputs, kind: kind,
                                                       materialVertexCount: simulated.vertexCount,
                                                       renderVar: simulated.renderVar)],
                         sceneSize: sceneSize, targetSize: sceneSize, commandBuffer: commandBuffer)
        return true
    }
}
