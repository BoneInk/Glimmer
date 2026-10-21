import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// Puppet Warp meshes (docs/models-plan.md §2.13, §4.3 P1): the combos WE lays over the image's
/// material for its mesh, and the mesh drawn into the layer's albedo target by
/// `ScenePuppetRenderer` through the bundled WE shaders, against hand-built rigs whose pictures
/// are known.
final class ScenePuppetTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var builder: ImageMaterialPlanBuilder!
    private var renderer: ScenePuppetRenderer!
    private var cache: URL!

    override func setUpWithError() throws {
        let assets = ShaderVariantTests.weAssets
        try XCTSkipUnless(FileManager.default.fileExists(atPath: assets.appending(path: "shaders/genericimage2.vert").path),
                          "bundled WE shaders missing")
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-puppet-\(UUID().uuidString)")
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache)
        let roots = [Fixtures.url("ImageMaterials"), assets]
        builder = ImageMaterialPlanBuilder(
            translator: translator,
            readFile: { path in
                for root in roots {
                    if let data = FileManager.default.contents(atPath: root.appending(path: path).path) { return data }
                }
                return nil
            },
            loadTexture: { _, _ in nil })
        renderer = try XCTUnwrap(ScenePuppetRenderer(device: device, archive: nil))
    }

    override func tearDownWithError() throws {
        if let cache { try? FileManager.default.removeItem(at: cache) } // scratch cleanup
    }

    // MARK: - Combos

    /// 0x140207100: `SKINNING` always, `BONECOUNT` exactly the skeleton's (a model's is rounded to
    /// 16…128), `SKINNING_ALPHA` from mesh flag 0x4, `MORPHING` from `a_PositionVec4` and
    /// `MORPHING_MODIFIERS` from flag 0x2000 only with it.
    func testCombosFollowTheMeshAndTheExactBoneCount() {
        let plain = Self.mesh(format: 0x1800009, flags: 0)
        XCTAssertEqual(ImagePuppetCombos(mesh: plain, boneCount: 17).combos, ["SKINNING": 1, "BONECOUNT": 17])
        let alpha = Self.mesh(format: 0x1800009, flags: 0x4)
        XCTAssertEqual(ImagePuppetCombos(mesh: alpha, boneCount: 65).combos, ["SKINNING": 1, "BONECOUNT": 65, "SKINNING_ALPHA": 1])
        let modifiersOnly = Self.mesh(format: 0x1800009, flags: 0x2000)
        XCTAssertNil(ImagePuppetCombos(mesh: modifiersOnly, boneCount: 2).combos["MORPHING_MODIFIERS"],
                     "MORPHING_MODIFIERS needs a morphing mesh (0x1402073cf)")
        let morphing = Self.mesh(format: 0x1810008, flags: 0x2000)
        XCTAssertEqual(ImagePuppetCombos(mesh: morphing, boneCount: 3).combos,
                       ["SKINNING": 1, "BONECOUNT": 3, "MORPHING": 1, "MORPHING_MODIFIERS": 1])
    }

    /// The mesh pass is the layer's material with the puppet combos, unlit and without the
    /// object's blend mode: the layer's own pass lights and blends the image it draws.
    func testTheMeshPassIsTheMaterialUnlitWithThePuppetCombos() throws {
        let combos = ImagePuppetCombos(boneCount: 10)
        for material in ["litpbr", "image2version", "image4"] {
            let plan = try XCTUnwrap(try builder.buildPuppetMesh(materialPath: "materials/\(material).json", puppet: combos))
            let variant = try XCTUnwrap(plan.pass.variant, material)
            XCTAssertEqual(variant.combos["SKINNING"], 1, material)
            XCTAssertEqual(variant.combos["BONECOUNT"], 10, material)
            XCTAssertEqual(variant.combos["LIGHTING"] ?? 0, 0, material)
            XCTAssertEqual(variant.combos["REFLECTION"] ?? 0, 0, material)
            XCTAssertNil(variant.combos["BLENDMODE"], material)
            XCTAssertNil(plan.prelighting, material)
            XCTAssertEqual(variant.uniforms?.members["g_Bones"]?.count, 10, "\(material): g_Bones[BONECOUNT]")
            XCTAssertEqual(variant.uniforms?.members["g_Bones"]?.type, "mat4x3", material)
            guard case .current? = plan.pass.textures[0] else { return XCTFail("\(material): slot 0 is not the image") }
        }
    }

    /// WE draws the mesh two-sided when the material says `nocull`, else it culls back faces
    /// (0x1402071b5).
    func testTheMaterialsCullModeCullsTheMesh() throws {
        let combos = ImagePuppetCombos(boneCount: 1)
        XCTAssertFalse(try XCTUnwrap(try builder.buildPuppetMesh(materialPath: "materials/image4.json", puppet: combos)).cullsBackFaces)
        XCTAssertTrue(try XCTUnwrap(try builder.buildPuppetMesh(materialPath: "materials/depthcull.json", puppet: combos)).cullsBackFaces)
        XCTAssertTrue(try XCTUnwrap(try builder.buildPuppetMesh(materialPath: "materials/lit.json", puppet: combos)).cullsBackFaces,
                      "no cullmode: WE's default, back faces culled")
    }

    /// `MORPHING` declares `g_Texture5`, WE's morph texture, which the material doesn't list: the
    /// engine binds it, so the plan doesn't fail on it, and the modifiers' uniforms are declared.
    func testMorphingLeavesTheMorphTextureToTheEngine() throws {
        let combos = ImagePuppetCombos(boneCount: 4, morphing: true, morphingModifiers: true)
        let plan = try XCTUnwrap(try builder.buildPuppetMesh(materialPath: "materials/image4.json", puppet: combos))
        let variant = try XCTUnwrap(plan.pass.variant)
        XCTAssertEqual(variant.combos["MORPHING"], 1)
        XCTAssertEqual(variant.combos["MORPHING_MODIFIERS"], 1)
        XCTAssertNil(plan.pass.textures[ImagePuppetCombos.morphSlot])
        XCTAssertNotNil(variant.uniforms?.members["g_MorphBoneTransform"])
        XCTAssertEqual(variant.attributes["a_PositionVec4"], 0)
    }

    /// WE scales the first texture coordinate by the image's share of a padded texture
    /// (0x14020b040) and nothing else.
    func testTextureCoordinatesAreScaledToThePaddedTexture() throws {
        let mesh = Self.gridMesh(size: SIMD2(8, 4), columns: 1, rows: 1)
        let scaled = ScenePuppetPlan.scaledTexCoords(mesh, by: SIMD2(0.5, 0.25))
        let original = MDLMesh(materials: mesh.materials, flags: mesh.flags, format: mesh.format, vertexData: scaled,
                               indexData: mesh.indexData)
        XCTAssertEqual(original.floatValues(.texCoord), mesh.floatValues(.texCoord)!.enumerated().map {
            $0.element * ($0.offset % 2 == 0 ? 0.5 : 0.25)
        })
        XCTAssertEqual(original.floatValues(.position), mesh.floatValues(.position))
        XCTAssertEqual(original.floatValues(.blendWeights), mesh.floatValues(.blendWeights))
    }

    /// A particle `collisionmodel` can take a Puppet Warp image: WE reads its rig's `.mdl` as a
    /// model's (0x1401d4a69), so a rig without per-bone boxes collides through its box, which the
    /// plan keeps.
    func testThePlanKeepsTheRigsBoxForParticleCollisions() throws {
        var mesh = Self.gridMesh(size: SIMD2(8, 4), columns: 1, rows: 1)
        mesh.bounds = MDLBounds(min: SIMD3(-4, -2, 0), max: SIMD3(4, 2, 0))
        let plan = try plan(mesh, bones: 1, size: SIMD2(8, 4))
        let bounds = try XCTUnwrap(plan.bounds)
        XCTAssertEqual(bounds, MDLBounds(min: SIMD3(-4, -2, 0), max: SIMD3(4, 2, 0)))
        let capsules = ParticleCapsule.capsules(boneVectors: plan.skeleton.boneVectors, boneWorlds: [], bounds: bounds,
                                                world: matrix_identity_float4x4)
        XCTAssertEqual(capsules.count, 1)
        XCTAssertEqual(capsules.first?.length ?? 0, 4, accuracy: 1e-5)
        XCTAssertEqual(capsules.first?.radius ?? 0, 2, accuracy: 1e-5)
    }

    // MARK: - Pixels

    /// The bind pose (every bone the identity) of a rig laid over its image reproduces the image,
    /// texel for texel, straight alpha included.
    func testTheBindPoseReproducesTheImage() throws {
        let image = Self.picture(width: 64, height: 48)
        let plan = try plan(Self.gridMesh(size: SIMD2(64, 48), columns: 8, rows: 6), bones: 1, size: SIMD2(64, 48))
        let pixels = try draw(plan, source: image, pose: .bind(boneCount: 1))
        assertEqual(pixels, image.pixels, tolerance: 1)
    }

    /// A `cullmode` "normal" puppet (WE 2.8's capture, docs/models-plan.md §5.17): the editor's
    /// rig, wound counter-clockwise, faces the viewer and draws, and a layer that mirrors it culls
    /// every triangle, as WE culls the rope scaled −1 1 1. With clockwise in front the rig was
    /// culled upright: Empress of Grace's (3810943704) girl and eyes never showed.
    func testAMirroredLayerCullsANormalCullMesh() throws {
        let image = Self.picture(width: 64, height: 48, opaque: true)
        let plan = try plan(Self.gridMesh(size: SIMD2(64, 48), columns: 8, rows: 6), bones: 1, size: SIMD2(64, 48),
                            material: "depthcull")
        XCTAssertTrue(plan.material.cullsBackFaces)
        XCTAssertTrue(renderer.waitUntilReady(plan), "the mesh pipeline compiles")
        let texture = try Self.texture(image, device: device)
        func alphas(mirrored: Bool) throws -> [UInt8] {
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            let target = try XCTUnwrap(renderer.albedo(plan, ScenePuppetRenderer.Draw(
                layerID: "puppet", source: texture, pose: .bind(boneCount: 1), frame: BuiltinFrameContext(),
                values: EmptySceneValues(), assetTexture: { _, _ in nil }, mirrored: mirrored), commandBuffer: commands))
            commands.commit()
            commands.waitUntilCompleted()
            let pixels = try ScenePuppetTestSupport.rgba8(target, device: device)
            return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
        }
        XCTAssertTrue(try alphas(mirrored: false).allSatisfy { $0 == 255 }, "the rig's triangles face the viewer")
        XCTAssertTrue(try alphas(mirrored: true).allSatisfy { $0 == 0 }, "mirrored, they are culled")
    }

    /// An atlas: the rig takes the image's halves from the other side of the texture, as the
    /// witcher's (3803167460) takes its parts from a sheet. The bind pose assembles the picture.
    func testTheBindPoseAssemblesAnAtlas() throws {
        let image = Self.picture(width: 32, height: 16)
        // Left half of the picture from the texture's right half, and the other way round.
        let mesh = Self.mesh(quads: [(SIMD4(-16, 8, 0, -8), SIMD4(0.5, 0, 1, 1)), (SIMD4(0, 8, 16, -8), SIMD4(0, 0, 0.5, 1))])
        let plan = try plan(mesh, bones: 1, size: SIMD2(32, 16))
        let pixels = try draw(plan, source: image, pose: .bind(boneCount: 1))
        var expected = [UInt8](repeating: 0, count: image.pixels.count)
        for y in 0..<16 {
            for x in 0..<32 {
                let from = ((y * 32) + (x + 16) % 32) * 4
                for c in 0..<4 { expected[(y * 32 + x) * 4 + c] = image.pixels[from + c] }
            }
        }
        assertEqual(pixels, expected, tolerance: 1)
    }

    /// `g_Bones` maps bind-pose positions to posed ones (`p′ = bone · p`, WE's
    /// `boneWorld · inverseBind` transposed), in the image's pixels, y up: a bone moving +6 in x
    /// and +4 in y moves its vertices 6 texels right and 4 rows up; the other bone's stay.
    func testBonesMoveTheirVerticesInImagePixels() throws {
        let image = Self.picture(width: 32, height: 16)
        // The left half hangs on bone 0, the right half on bone 1.
        let mesh = Self.mesh(quads: [(SIMD4(-16, 8, 0, -8), SIMD4(0, 0, 0.5, 1)), (SIMD4(0, 8, 16, -8), SIMD4(0.5, 0, 1, 1))],
                             bones: [0, 1])
        let plan = try plan(mesh, bones: 2, size: SIMD2(32, 16))
        var pose = ScenePuppetPose.bind(boneCount: 2)
        pose.bones[1] = Self.translation(SIMD3(6, 4, 0))
        let pixels = try draw(plan, source: image, pose: pose)
        func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int) -> ArraySlice<UInt8> { bytes[((y * 32) + x) * 4..<((y * 32) + x) * 4 + 4] }
        // Bone 0's half is where it was.
        XCTAssertEqual(Array(pixel(pixels, 5, 10)), Array(pixel(image.pixels, 5, 10)))
        // Bone 1's texel (20, 10) now shows at (26, 6); the right edge fell off the image.
        XCTAssertEqual(Array(pixel(pixels, 26, 6)), Array(pixel(image.pixels, 20, 10)))
        XCTAssertEqual(Array(pixel(pixels, 17, 14)), [0, 0, 0, 0], "uncovered after the move")
        XCTAssertEqual(ScenePuppetPose.bind(boneCount: 1).boneComponents, [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0])
    }

    /// A layer without effects is drawn by WE through its mesh in the scene, so a part a bone moves
    /// past the image's rect still shows: its canvas grows (in eighths of the image) to the posed
    /// mesh, never shrinks, and the target lays that canvas over the image's texels.
    func testTheCanvasCoversAMeshPosedPastTheImage() throws {
        let image = Self.picture(width: 32, height: 16, opaque: true)
        let mesh = Self.mesh(quads: [(SIMD4(-16, 8, 0, -8), SIMD4(0, 0, 0.5, 1)), (SIMD4(0, 8, 16, -8), SIMD4(0.5, 0, 1, 1))],
                             bones: [0, 1])
        let plan = try plan(mesh, bones: 2, size: SIMD2(32, 16))
        let bind = renderer.canvas(plan, layerID: "puppet", pose: .bind(boneCount: 2))
        XCTAssertEqual(bind, ScenePuppetCanvas.image(SIMD2(32, 16)), "the bind pose stays on the image")
        var pose = ScenePuppetPose.bind(boneCount: 2)
        pose.bones[1] = Self.translation(SIMD3(15, 0, 0))
        let bounds = try XCTUnwrap(plan.posedBounds(pose))
        XCTAssertEqual(bounds.max, SIMD2<Float>(31, 8))
        let canvas = renderer.canvas(plan, layerID: "puppet", pose: pose)
        // 15 past the right edge, in steps of 32 / 8 = 4: 16.
        XCTAssertEqual(canvas, ScenePuppetCanvas(min: SIMD2(-16, -8), max: SIMD2(32, 8)))
        XCTAssertEqual(renderer.canvas(plan, layerID: "puppet", pose: .bind(boneCount: 2)), canvas, "never shrinks")

        XCTAssertTrue(renderer.waitUntilReady(plan))
        let texture = try Self.texture(image, device: device)
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let target = try XCTUnwrap(renderer.albedo(plan, ScenePuppetRenderer.Draw(
            layerID: "puppet", source: texture, pose: pose, frame: BuiltinFrameContext(), values: EmptySceneValues(),
            assetTexture: { _, _ in nil }, canvas: canvas), commandBuffer: commands))
        commands.commit()
        commands.waitUntilCompleted()
        let pixels = try ScenePuppetTestSupport.rgba8(target, device: device)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * 32 + x) * 4 + 3] }
        // Canvas x −16…32 over 32 texels: the moved half (15…31) lands on texels 21…31, the gap
        // it left (0…15) on 11…20, the unmoved half on 0…10.
        let moved: UInt8 = alpha(30, 8), gap: UInt8 = alpha(15, 8), kept: UInt8 = alpha(3, 8)
        XCTAssertEqual(moved, 255, "the part past the image draws")
        XCTAssertEqual(gap, 0)
        XCTAssertEqual(kept, 255)
    }

    /// With effects, the effects run on the bind-pose image and the posed mesh lays their output
    /// out (`posedEffectOutput`) over the same canvas a layer without effects grows to: a part
    /// posed past the image's rect still draws, and the effects keep the image's density.
    func testEffectOutputPosedPastTheImageIsNotClipped() throws {
        let output = Self.picture(width: 32, height: 16, opaque: true)
        let mesh = Self.mesh(quads: [(SIMD4(-16, 8, 0, -8), SIMD4(0, 0, 0.5, 1)), (SIMD4(0, 8, 16, -8), SIMD4(0.5, 0, 1, 1))],
                             bones: [0, 1])
        let plan = try plan(mesh, bones: 2, size: SIMD2(32, 16))
        var pose = ScenePuppetPose.bind(boneCount: 2)
        pose.bones[1] = Self.translation(SIMD3(15, 0, 0))
        let canvas = renderer.canvas(plan, layerID: "puppet", pose: pose)
        XCTAssertEqual(canvas, ScenePuppetCanvas(min: SIMD2(-16, -8), max: SIMD2(32, 8)))
        XCTAssertEqual(ScenePuppetCanvas.imageShare(imageSize: SIMD2(32, 16), canvas: canvas), SIMD2(32.0 / 48, 1))
        XCTAssertEqual(ScenePuppetCanvas.imageShare(imageSize: SIMD2(32, 16), canvas: .image(SIMD2(32, 16))), SIMD2(1, 1))

        let texture = try Self.texture(output, device: device)
        func alphas(_ canvas: ScenePuppetCanvas?) throws -> (moved: UInt8, gap: UInt8, kept: UInt8) {
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            let warped = try XCTUnwrap(renderer.warp(plan, layerID: "puppet", key: "_effects", texture: texture,
                                                     contentSize: nil, pose: pose, canvas: canvas, redraw: true,
                                                     commandBuffer: commands))
            commands.commit()
            commands.waitUntilCompleted()
            let pixels = try ScenePuppetTestSupport.rgba8(warped, device: device)
            func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * 32 + x) * 4 + 3] }
            return (alpha(30, 8), alpha(15, 8), alpha(3, 8))
        }
        // Canvas x −16…32 over 32 texels: the moved half (15…31) lands on texels 21…31.
        let posed = try alphas(canvas)
        XCTAssertEqual(posed.moved, 255, "the part posed past the image draws")
        XCTAssertEqual(posed.gap, 0)
        XCTAssertEqual(posed.kept, 255)
    }

    /// Two parts of an atlas, a transparent gutter between them in the texture, meeting edge to
    /// edge in the mesh and posed together: their shared edge stays opaque. Sampling the effect
    /// output bilinearly faded both parts' edge texels against the gutter, and the background
    /// showed through the seam.
    func testPartsSharingAnEdgeLeaveNoGapWhenPosed() throws {
        // Texels 0…13 part A (red), 14…17 the gutter, 18…31 part B (blue).
        var bytes = [UInt8](repeating: 0, count: 32 * 16 * 4)
        for y in 0..<16 {
            for x in 0..<32 where x < 14 || x >= 18 {
                bytes.replaceSubrange((y * 32 + x) * 4..<(y * 32 + x) * 4 + 4, with: x < 14 ? [255, 0, 0, 255] : [0, 0, 255, 255])
            }
        }
        let atlas = Picture(width: 32, height: 16, pixels: bytes)
        let quads: [(position: SIMD4<Float>, uv: SIMD4<Float>)] = [
            (position: SIMD4<Float>(-16, 8, 0, -8), uv: SIMD4<Float>(0, 0, 14.0 / 32, 1)),
            (position: SIMD4<Float>(0, 8, 16, -8), uv: SIMD4<Float>(18.0 / 32, 0, 1, 1)),
        ]
        let mesh = Self.mesh(quads: quads, bones: [0, 1])
        let plan = try plan(mesh, bones: 2, size: SIMD2(32, 16))
        var pose = ScenePuppetPose.bind(boneCount: 2)
        let move = Self.translation(SIMD3(3.5, 1.25, 0))
        pose.bones = [move, move]
        let canvas = renderer.canvas(plan, layerID: "puppet", pose: pose)
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let warped = try XCTUnwrap(renderer.warp(plan, layerID: "puppet", key: "_effects",
                                                 texture: try Self.texture(atlas, device: device), contentSize: nil,
                                                 pose: pose, canvas: canvas, redraw: true, commandBuffer: commands))
        commands.commit()
        commands.waitUntilCompleted()
        let pixels = try ScenePuppetTestSupport.rgba8(warped, device: device)
        // The seam, mesh x = 3.5, in the canvas's texels; every row the parts cover.
        let size: SIMD2<Float> = canvas.size
        let seamX: Float = (3.5 - canvas.min.x) / size.x * 32
        let topY: Float = (canvas.max.y - Float(8 + 1.25)) / size.y * 16
        let bottomY: Float = (canvas.max.y - Float(-8 + 1.25)) / size.y * 16
        let seam = Int(seamX.rounded(.down))
        let top = Int(topY.rounded(.up))
        let bottom = Int(bottomY.rounded(.down))
        XCTAssertLessThan(top, bottom)
        for y in top..<bottom {
            for x in seam - 1...seam + 1 {
                XCTAssertEqual(pixels[(y * 32 + x) * 4 + 3], 255, "seam open at (\(x), \(y))")
            }
        }
    }

    /// Skinning renormalises the weights over the bones the pose holds, so a vertex shared by two
    /// parts, whatever its weights' sum, lands where its neighbour's copy does; no usable weight
    /// leaves it at rest.
    func testSkinningRenormalisesWeights() {
        var pose = ScenePuppetPose.bind(boneCount: 2)
        pose.bones[1] = Self.translation(SIMD3(10, 0, 0))
        let p = SIMD4<Float>(2, 3, 0, 1)
        let full = ScenePuppetPlan.skin(p, weights: SIMD4(1, 0, 0, 0), bones: SIMD4(1, 0, 0, 0), pose: pose)
        let partial = ScenePuppetPlan.skin(p, weights: SIMD4(0.6, 0, 0, 0), bones: SIMD4(1, 0, 0, 0), pose: pose)
        XCTAssertEqual(full, SIMD4(12, 3, 0, 1))
        XCTAssertEqual(partial, full)
        // A bone the pose lacks drops out; the rest renormalise.
        let missing = ScenePuppetPlan.skin(p, weights: SIMD4(0.5, 0.5, 0, 0), bones: SIMD4(1, 7, 0, 0), pose: pose)
        XCTAssertEqual(missing, full)
        XCTAssertEqual(ScenePuppetPlan.skin(p, weights: .zero, bones: .zero, pose: pose), p)
    }

    /// `SKINNING_ALPHA` (mesh flag 0x4) multiplies the texel's alpha by the weighted `g_BonesAlpha`.
    func testSkinningAlphaFadesByTheBonesAlpha() throws {
        let image = Self.picture(width: 16, height: 16, opaque: true)
        let plan = try plan(Self.gridMesh(size: SIMD2(16, 16), columns: 2, rows: 2, flags: 0x4), bones: 1,
                            size: SIMD2(16, 16), material: "image2version")
        XCTAssertEqual(plan.combos.skinningAlpha, true)
        var pose = ScenePuppetPose.bind(boneCount: 1)
        pose.bonesAlpha = [0.5]
        let pixels = try draw(plan, source: image, pose: pose)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            XCTAssertEqual(Int(pixels[index + 3]), 128, accuracy: 1)
            XCTAssertEqual(Int(pixels[index]), Int(image.pixels[index]), accuracy: 1, "straight colour stays")
        }
    }

    /// The pose's `drawRanges` draw the index ranges in their order, later over earlier: the blue
    /// part (drawn second in the buffer) goes under the red one when its range comes first.
    func testDrawRangesDrawThePartsInTheirOrder() throws {
        var bytes = [UInt8](repeating: 0, count: 8 * 4 * 4)
        for y in 0..<4 {
            for x in 0..<8 { bytes.replaceSubrange((y * 8 + x) * 4..<(y * 8 + x) * 4 + 4, with: x < 4 ? [255, 0, 0, 255] : [0, 0, 255, 255]) }
        }
        let image = Picture(width: 8, height: 4, pixels: bytes)
        let mesh = Self.mesh(quads: [(SIMD4(-4, 2, 4, -2), SIMD4(0.1, 0.1, 0.4, 0.9)), (SIMD4(-4, 2, 4, -2), SIMD4(0.6, 0.1, 0.9, 0.9))])
        let plan = try plan(mesh, bones: 1, size: SIMD2(8, 4))
        var pose = ScenePuppetPose.bind(boneCount: 1)
        XCTAssertEqual(Array(try draw(plan, source: image, pose: pose)[0..<4]), [0, 0, 255, 255], "the buffer's order: blue last")
        pose.drawRanges = [.init(firstIndex: 6, indexCount: 6), .init(firstIndex: 0, indexCount: 6)]
        let pixels = try draw(plan, source: image, pose: pose)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            XCTAssertEqual(Array(pixels[index..<index + 4]), [255, 0, 0, 255], "texel \(index / 4): red last")
        }
    }

    /// A rig whose effects ran on its texture has its parts faded where the posed mesh lays the
    /// output out (`warp`, `fades`), by `g_BonesAlpha` weighted as `SKINNING_ALPHA` weights it.
    func testAFadingWarpFadesByTheBonesAlpha() throws {
        let image = Self.picture(width: 16, height: 16, opaque: true)
        let plan = try plan(Self.gridMesh(size: SIMD2(16, 16), columns: 2, rows: 2, flags: 0x4), bones: 1,
                            size: SIMD2(16, 16), material: "image2version")
        let texture = try Self.texture(image, device: device)
        _ = try draw(plan, texture: texture, pose: .bind(boneCount: 1))
        var pose = ScenePuppetPose.bind(boneCount: 1)
        pose.bonesAlpha = [0.5]
        func warped(fades: Bool) throws -> [UInt8] {
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            let output = try XCTUnwrap(renderer.warp(plan, layerID: "puppet", key: "_effects", texture: texture, contentSize: nil,
                                                     pose: pose, redraw: true, blended: true, fades: fades,
                                                     commandBuffer: commands))
            commands.commit()
            commands.waitUntilCompleted()
            return try ScenePuppetTestSupport.rgba8(output, device: device)
        }
        let faded = try warped(fades: true), kept = try warped(fades: false)
        for index in stride(from: 0, to: faded.count, by: 4) {
            XCTAssertEqual(Int(faded[index + 3]), 128, accuracy: 1, "texel \(index / 4)")
            XCTAssertEqual(Int(kept[index + 3]), 255, accuracy: 1, "texel \(index / 4)")
        }
    }

    /// Triangles over each other composite like WE's straight-alpha draws over each other: a
    /// half-transparent blue part over an opaque red one is half of each, opaque.
    func testOverlappingPartsCompositeOver() throws {
        // Texture: left half opaque red, right half blue at alpha 0.5.
        var bytes = [UInt8](repeating: 0, count: 8 * 4 * 4)
        for y in 0..<4 {
            for x in 0..<8 { bytes.replaceSubrange((y * 8 + x) * 4..<(y * 8 + x) * 4 + 4, with: x < 4 ? [255, 0, 0, 255] : [0, 0, 255, 128]) }
        }
        let image = Picture(width: 8, height: 4, pixels: bytes)
        // Both parts cover the whole image; the blue one is drawn second.
        let mesh = Self.mesh(quads: [(SIMD4(-4, 2, 4, -2), SIMD4(0.1, 0.1, 0.4, 0.9)), (SIMD4(-4, 2, 4, -2), SIMD4(0.6, 0.1, 0.9, 0.9))])
        let pixels = try draw(try plan(mesh, bones: 1, size: SIMD2(8, 4)), source: image, pose: .bind(boneCount: 1))
        let a = 128.0 / 255
        for index in stride(from: 0, to: pixels.count, by: 4) {
            XCTAssertEqual(Double(pixels[index]), 255 * (1 - a), accuracy: 1.5)
            XCTAssertEqual(Double(pixels[index + 1]), 0, accuracy: 1)
            XCTAssertEqual(Double(pixels[index + 2]), 255 * a, accuracy: 1.5)
            XCTAssertEqual(Double(pixels[index + 3]), 255, accuracy: 1)
        }
    }

    /// A puppet with effects: their output, laid out by the posed mesh (`warp`, `blended`), keeps
    /// the material's "over" where parts overlap. A part transparent where another lies over it
    /// (the Katana rig's face under its hair strands, 3238423642) must not erase the part drawn
    /// before it; unblended, the clear half replaced the red one.
    func testABlendedWarpCompositesOverlappingPartsOver() throws {
        // Texture: left half opaque red, right half clear. The clear part is drawn second.
        var bytes = [UInt8](repeating: 0, count: 8 * 4 * 4)
        for y in 0..<4 {
            for x in 0..<4 { bytes.replaceSubrange((y * 8 + x) * 4..<(y * 8 + x) * 4 + 4, with: [255, 0, 0, 255]) }
        }
        let texture = try Self.texture(Picture(width: 8, height: 4, pixels: bytes), device: device)
        let mesh = Self.mesh(quads: [(SIMD4(-4, 2, 4, -2), SIMD4(0.1, 0.1, 0.4, 0.9)), (SIMD4(-4, 2, 4, -2), SIMD4(0.6, 0.1, 0.9, 0.9))])
        let plan = try plan(mesh, bones: 1, size: SIMD2(8, 4))
        _ = try draw(plan, texture: texture, pose: .bind(boneCount: 1))
        func warped(blended: Bool) throws -> [UInt8] {
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            let output = try XCTUnwrap(renderer.warp(plan, layerID: "puppet", key: "_effects", texture: texture, contentSize: nil,
                                                     pose: .bind(boneCount: 1), redraw: true, blended: blended,
                                                     commandBuffer: commands))
            commands.commit()
            commands.waitUntilCompleted()
            return try ScenePuppetTestSupport.rgba8(output, device: device)
        }
        let over = try warped(blended: true)
        for index in stride(from: 0, to: over.count, by: 4) {
            XCTAssertEqual(Array(over[index..<index + 4]), [255, 0, 0, 255], "texel \(index / 4)")
        }
        XCTAssertEqual(try warped(blended: false)[3], 0, "unblended, the later part replaces")
    }

    /// A padded texture (a `.tex` whose image sits in a larger allocation): the target keeps the
    /// texture's layout, the image drawn into its top-left content texels and the padding clear.
    func testAPaddedImageKeepsItsTextureLayout() throws {
        var image = Self.picture(width: 64, height: 64)
        // The padding holds junk that must not show.
        for y in 0..<64 {
            for x in 0..<64 where x >= 48 || y >= 40 { image.pixels.replaceSubrange((y * 64 + x) * 4..<(y * 64 + x) * 4 + 4, with: [255, 0, 255, 255]) }
        }
        let source = SceneMetalTextureSource.dxt(TEXCompressedTexture(format: 0, width: 64, height: 64, data: [],
                                                                      contentWidth: 48, contentHeight: 40))
        let plan = try ScenePuppetPlan.make(model: Self.model(Self.gridMesh(size: SIMD2(48, 40), columns: 4, rows: 4), bones: 1),
                                            rigPath: "rig.mdl", materialPath: "materials/image4.json", source: source,
                                            imageSize: SIMD2(48, 40), builder: builder)
        XCTAssertEqual(plan.contentPixels, SIMD2(48, 40))
        let pixels = try draw(plan, source: image, pose: .bind(boneCount: 1))
        for y in 0..<64 {
            for x in 0..<64 {
                let index = (y * 64 + x) * 4
                if x < 48, y < 40 {
                    XCTAssertEqual(Array(pixels[index..<index + 4]), Array(image.pixels[index..<index + 4]), "(\(x), \(y))")
                } else {
                    XCTAssertEqual(pixels[index + 3], 0, "padding (\(x), \(y))")
                }
            }
        }
    }

    /// A rig WE can't draw is rejected with a reason, so the layer shows its image unwarped.
    func testRigsWithoutMeshOrSkeletonAreRejected() throws {
        let source = SceneMetalTextureSource.dxt(TEXCompressedTexture(format: 0, width: 8, height: 8, data: [],
                                                                      contentWidth: 8, contentHeight: 8))
        var model = Self.model(Self.gridMesh(size: SIMD2(8, 8), columns: 1, rows: 1), bones: 1)
        model.skeleton = nil
        XCTAssertThrowsError(try ScenePuppetPlan.make(model: model, rigPath: "a.mdl", materialPath: "materials/image4.json",
                                                      source: source, imageSize: SIMD2(8, 8), builder: builder))
        model.meshes = []
        XCTAssertThrowsError(try ScenePuppetPlan.make(model: model, rigPath: "a.mdl", materialPath: "materials/image4.json",
                                                      source: source, imageSize: SIMD2(8, 8), builder: builder))
    }

    /// A rig whose indices name a vertex past its mesh is rejected before anything is uploaded.
    func testRigIndexingPastItsVerticesIsRejected() throws {
        let source = SceneMetalTextureSource.dxt(TEXCompressedTexture(format: 0, width: 8, height: 8, data: [],
                                                                      contentWidth: 8, contentHeight: 8))
        var mesh = Self.gridMesh(size: SIMD2(8, 8), columns: 1, rows: 1)
        mesh.indexData += [UInt16(0), 1, 60_000].withUnsafeBytes { Data($0) }
        XCTAssertThrowsError(try ScenePuppetPlan.make(model: Self.model(mesh, bones: 1), rigPath: "a.mdl",
                                                      materialPath: "materials/image4.json", source: source,
                                                      imageSize: SIMD2(8, 8), builder: builder)) { error in
            XCTAssertTrue("\(error)".contains("indexes vertex 60000"), "\(error)")
        }
    }

    /// A redraw happens only when what the image is drawn from changes (the pose here).
    func testTheImageIsRedrawnOnlyWhenThePoseChanges() throws {
        let image = Self.picture(width: 16, height: 16)
        let plan = try plan(Self.gridMesh(size: SIMD2(16, 16), columns: 2, rows: 2), bones: 1, size: SIMD2(16, 16))
        let texture = try Self.texture(image, device: device)
        XCTAssertTrue(renderer.waitUntilReady(plan))
        for _ in 0..<3 { _ = try draw(plan, texture: texture, pose: .bind(boneCount: 1)) }
        XCTAssertEqual(renderer.drawsEncoded, 1)
        var pose = ScenePuppetPose.bind(boneCount: 1)
        pose.bones[0] = Self.translation(SIMD3(1, 0, 0))
        _ = try draw(plan, texture: texture, pose: pose)
        XCTAssertEqual(renderer.drawsEncoded, 2)
    }

    /// The image is redrawn into the same texture, so its version is what tells a cache keyed by
    /// that texture (a layer's kept effect output, its base pass) that the pose moved: a new one
    /// with every redraw, the same while the pose holds. The Cyberpunk Samurai (2321732083), a
    /// puppet with effects, stood in its first pose while that cache kept its effects' output.
    func testTheImageVersionChangesWithEveryRedraw() throws {
        let image = Self.picture(width: 16, height: 16)
        let plan = try plan(Self.gridMesh(size: SIMD2(16, 16), columns: 2, rows: 2), bones: 1, size: SIMD2(16, 16))
        let texture = try Self.texture(image, device: device)
        XCTAssertTrue(renderer.waitUntilReady(plan))
        XCTAssertEqual(renderer.albedoVersion("puppet"), 0, "no image yet")
        _ = try draw(plan, texture: texture, pose: .bind(boneCount: 1))
        let first = renderer.albedoVersion("puppet")
        XCTAssertNotEqual(first, 0)
        _ = try draw(plan, texture: texture, pose: .bind(boneCount: 1))
        XCTAssertEqual(renderer.albedoVersion("puppet"), first, "the same pose keeps the image and its version")
        var pose = ScenePuppetPose.bind(boneCount: 1)
        pose.bones[0] = Self.translation(SIMD3(1, 0, 0))
        _ = try draw(plan, texture: texture, pose: pose)
        let moved = renderer.albedoVersion("puppet")
        XCTAssertNotEqual(moved, first, "a new pose is a new drawing")
        _ = try draw(plan, texture: texture, pose: .bind(boneCount: 1))
        XCTAssertNotEqual(renderer.albedoVersion("puppet"), moved, "going back is a new drawing too")
    }

    // MARK: - Helpers

    struct Picture {
        var width: Int
        var height: Int
        /// RGBA8, straight alpha, rows from the top.
        var pixels: [UInt8]
    }

    /// A picture where every texel differs, with an alpha ramp (opaque when asked).
    static func picture(width: Int, height: Int, opaque: Bool = false) -> Picture {
        var pixels: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                let alpha = opaque ? 255 : (x * 7 + y * 13) % 200 + 56
                pixels += [UInt8((x * 255) / max(width - 1, 1)), UInt8((y * 255) / max(height - 1, 1)), UInt8((x * y) % 256),
                           UInt8(alpha)]
            }
        }
        return Picture(width: width, height: height, pixels: pixels)
    }

    static func texture(_ picture: Picture, device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: picture.width,
                                                                  height: picture.height, mipmapped: false)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        texture.replace(region: MTLRegionMake2D(0, 0, picture.width, picture.height), mipmapLevel: 0,
                        withBytes: picture.pixels, bytesPerRow: picture.width * 4)
        return texture
    }

    private func plan(_ mesh: MDLMesh, bones: Int, size: SIMD2<Float>, material: String = "image4") throws -> ScenePuppetPlan {
        let source = SceneMetalTextureSource.dxt(TEXCompressedTexture(format: 0, width: Int(size.x), height: Int(size.y),
                                                                      data: [], contentWidth: Int(size.x), contentHeight: Int(size.y)))
        return try ScenePuppetPlan.make(model: Self.model(mesh, bones: bones), rigPath: "rig.mdl",
                                        materialPath: "materials/\(material).json", source: source, imageSize: size,
                                        builder: builder)
    }

    private func draw(_ plan: ScenePuppetPlan, source: Picture, pose: ScenePuppetPose) throws -> [UInt8] {
        XCTAssertTrue(renderer.waitUntilReady(plan), "the mesh pipeline compiles")
        return try draw(plan, texture: try Self.texture(source, device: device), pose: pose)
    }

    private func draw(_ plan: ScenePuppetPlan, texture: MTLTexture, pose: ScenePuppetPose) throws -> [UInt8] {
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let target = try XCTUnwrap(renderer.albedo(plan, ScenePuppetRenderer.Draw(
            layerID: "puppet", source: texture, pose: pose, frame: BuiltinFrameContext(), values: EmptySceneValues(),
            assetTexture: { _, _ in nil }), commandBuffer: commands))
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertEqual(SIMD2(target.width, target.height), SIMD2(texture.width, texture.height))
        return try ScenePuppetTestSupport.rgba8(target, device: device)
    }

    private func assertEqual(_ actual: [UInt8], _ expected: [UInt8], tolerance: Int, file: StaticString = #filePath,
                             line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        var worst = 0, at = 0
        for index in actual.indices where index < expected.count {
            // Colour under zero alpha is undefined; compare straight colour only where it shows.
            if index % 4 != 3, expected[index - index % 4 + 3] == 0 { continue }
            let delta = abs(Int(actual[index]) - Int(expected[index]))
            if delta > worst { worst = delta; at = index }
        }
        XCTAssertLessThanOrEqual(worst, tolerance, "worst channel difference at byte \(at)", file: file, line: line)
    }

    // MARK: - Rigs

    static func translation(_ offset: SIMD3<Float>) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4(offset, 1)
        return matrix
    }

    static func model(_ mesh: MDLMesh, bones: Int) -> MDLModel {
        let skeleton = MDLSkeleton(version: 1, bones: (0..<bones).map {
            MDLBone(name: "bone\($0)", flags: 1, parent: $0 == 0 ? 0xFFFF_FFFF : 0, matrix: matrix_identity_float4x4, properties: "")
        })
        return MDLModel(tag: "MDLV0013", version: 13, legacyFormat: mesh.format.rawValue, materialsPerMesh: 1, meshes: [mesh],
                        skeleton: skeleton, end: 0, trailingByteCount: 0)
    }

    static func mesh(format: UInt32, flags: UInt32) -> MDLMesh {
        MDLMesh(materials: ["materials/image4.json"], flags: flags, format: MDLVertexFormat(rawValue: format),
                vertexData: Data(), indexData: Data())
    }

    /// Axis-aligned quads, `position` (left, top, right, bottom in image pixels, y up) textured
    /// from `uv` (left, top, right, bottom), each on one bone.
    static func mesh(quads: [(position: SIMD4<Float>, uv: SIMD4<Float>)], bones: [UInt32]? = nil, flags: UInt32 = 0) -> MDLMesh {
        var vertices = Data(), indices: [UInt16] = []
        for (index, quad) in quads.enumerated() {
            let bone = bones?[index] ?? 0
            let base = UInt16(index * 4)
            for (x, y, u, v) in [(quad.position.x, quad.position.y, quad.uv.x, quad.uv.y),
                                 (quad.position.z, quad.position.y, quad.uv.z, quad.uv.y),
                                 (quad.position.x, quad.position.w, quad.uv.x, quad.uv.w),
                                 (quad.position.z, quad.position.w, quad.uv.z, quad.uv.w)] {
                vertices += vertex(SIMD3(x, y, 0), bone: bone, uv: SIMD2(u, v))
            }
            indices += [base, base + 1, base + 2, base + 1, base + 3, base + 2]
        }
        return MDLMesh(materials: ["materials/image4.json"], flags: flags, format: MDLVertexFormat(rawValue: 0x1800009),
                       vertexData: vertices, indexData: indices.withUnsafeBytes { Data($0) })
    }

    /// A `columns` × `rows` grid laid over an image of `size` pixels, as WE's editor builds a rig:
    /// position `(uv − ½) · size` with v flipped, every triangle counter-clockwise (y up).
    static func gridMesh(size: SIMD2<Float>, columns: Int, rows: Int, flags: UInt32 = 0) -> MDLMesh {
        var vertices = Data(), indices: [UInt16] = []
        for row in 0...rows {
            for column in 0...columns {
                let uv = SIMD2(Float(column) / Float(columns), Float(row) / Float(rows))
                vertices += vertex(SIMD3((uv.x - 0.5) * size.x, (0.5 - uv.y) * size.y, 0), bone: 0, uv: uv)
            }
        }
        for row in 0..<rows {
            for column in 0..<columns {
                let a = UInt16(row * (columns + 1) + column), b = a + 1, c = a + UInt16(columns + 1), d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        return MDLMesh(materials: ["materials/image4.json"], flags: flags, format: MDLVertexFormat(rawValue: 0x1800009),
                       vertexData: vertices, indexData: indices.withUnsafeBytes { Data($0) })
    }

    /// One vertex of format 0x1800009: position, blend indices, blend weights, uv.
    static func vertex(_ position: SIMD3<Float>, bone: UInt32, uv: SIMD2<Float>) -> Data {
        var data = Data()
        for value in [position.x, position.y, position.z] { withUnsafeBytes(of: value.bitPattern.littleEndian) { data += $0 } }
        for value in [bone, 0, 0, 0] as [UInt32] { withUnsafeBytes(of: value.littleEndian) { data += $0 } }
        for value in [1, 0, 0, 0] as [Float] { withUnsafeBytes(of: value.bitPattern.littleEndian) { data += $0 } }
        for value in [uv.x, uv.y] { withUnsafeBytes(of: value.bitPattern.littleEndian) { data += $0 } }
        return data
    }
}

/// No user properties, timelines or scripts.
struct EmptySceneValues: SceneValueContext {
    func userProperty(_ name: String) -> String? { nil }
}

enum ScenePuppetTestSupport {
    private static let kernel = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void readRGBA8(texture2d<float, access::sample> source [[texture(0)]], device uchar4 *out [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= source.get_width() || gid.y >= source.get_height()) return;
        constexpr sampler nearest(filter::nearest, coord::pixel);
        float4 c = source.sample(nearest, float2(gid) + 0.5);
        out[gid.y * source.get_width() + gid.x] = uchar4(round(saturate(c) * 255.0));
    }
    """

    /// Any texture's texels (compressed, private or float) as RGBA8 rows from the top.
    static func rgba8(_ texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
        let library = try device.makeLibrary(source: kernel, options: nil)
        let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "readRGBA8")))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let buffer = try XCTUnwrap(device.makeBuffer(length: texture.width * texture.height * 4, options: .storageModeShared))
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commands.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: texture.width, height: texture.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return [UInt8](UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: buffer.length))
    }
}
