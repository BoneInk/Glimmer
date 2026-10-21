import XCTest
import simd
@testable import OpenWallpaperEngine

/// WE 2.8.0.42's own Puppet Warp and model editor files from capture request 509
/// (`Tests/Fixtures/Models/PuppetGroundTruth509`; we-test-wp-images,
/// tools/peer/requests/owe-beta7/models-open/509-mdlv-unknowns). `base` is a 512×256 image of a red
/// bar (left) and a blue bar (right) with the bones `red` and its child `blue` (head at the
/// image's centre); every other file changes one thing from it, and WE's stills of each as the
/// running wallpaper say what WE draws (docs/models-plan.md §1.2–§1.5, §2.13).
final class PuppetGroundTruth509Tests: XCTestCase {
    private static func model(_ name: String) throws -> MDLModel {
        try MDLReader.read(try Fixtures.data("Models/PuppetGroundTruth509/\(name).mdl"))
    }

    /// The bounds of the vertices of the blue bar (texture u past ½) or the red one.
    private static func bar(_ mesh: MDLMesh, blue: Bool) throws -> (min: SIMD2<Float>, max: SIMD2<Float>) {
        let positions = try XCTUnwrap(mesh.floatValues(.position))
        let uvs = try XCTUnwrap(mesh.floatValues(.texCoord))
        var low = SIMD2<Float>(repeating: .infinity), high = -low
        for vertex in 0..<mesh.vertexCount where (uvs[2 * vertex] > 0.5) == blue {
            let point = SIMD2(positions[3 * vertex], positions[3 * vertex + 1])
            low = simd_min(low, point)
            high = simd_max(high, point)
        }
        return (low, high)
    }

    /// `layout` is `mesh`'s positions, within the editor's float noise.
    private static func assertClose(_ layout: [SIMD3<Float>], _ mesh: MDLMesh, _ message: String,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let positions = try XCTUnwrap(mesh.floatValues(.position))
        XCTAssertEqual(layout.count * 3, positions.count, message, file: file, line: line)
        let worst = zip(layout.flatMap { [$0.x, $0.y, $0.z] }, positions).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(worst, 1e-3, message, file: file, line: line)
    }

    private static func animator(_ model: MDLModel, clip: UInt64, isModel: Bool = false) throws -> ScenePuppetAnimator {
        let skeleton = try XCTUnwrap(model.skeleton)
        let clips = model.animations ?? []
        let order = isModel ? nil : ScenePuppetDrawOrder(mesh: model.meshes[0], skeleton: skeleton, clips: clips)
        return ScenePuppetAnimator(skeleton: skeleton, clips: clips, layers: [WEAnimationLayer(animation: clip)],
                                   model: isModel, drawOrder: order)
    }

    // MARK: - A: Lock Geometry for Vertex Editing, Edit Deformation

    /// Moving the blue bar's vertices 150 px up writes the optional blob of `MDLV` 21 (u32 1 and
    /// 196 × 12 bytes, +2360 bytes before `MDLS`): the texture layout's positions, `base`'s.
    /// `a_Position` holds the moved mesh, which WE's wallpaper draws (`mo2_509a_moved_t3`: blue
    /// 150 px up, red in place); with no layers the bind pose draws `a_Position` as it is.
    func testMovedVerticesDrawWhereTheyWereMovedAndKeepTheTextureLayout() throws {
        let base = try Self.model("base"), moved = try Self.model("a_moved")
        XCTAssertNil(base.meshes[0].extraPositions)
        let blob = try XCTUnwrap(moved.meshes[0].extraPositions)
        XCTAssertEqual(blob.discarded, 1)
        XCTAssertEqual(blob.data.count, 12 * 196)
        XCTAssertEqual(moved.sections.first?.offset, (base.sections.first?.offset ?? 0) + 2360)
        let layout = try XCTUnwrap(moved.meshes[0].textureLayoutPositions)
        try Self.assertClose(layout, base.meshes[0], "the texture layout is base's mesh")

        let blueBefore = try Self.bar(base.meshes[0], blue: true), blueAfter = try Self.bar(moved.meshes[0], blue: true)
        XCTAssertEqual(blueAfter.min.y - blueBefore.min.y, 150, accuracy: 0.5)
        XCTAssertEqual(blueAfter.max.x, blueBefore.max.x, accuracy: 0.01)
        XCTAssertEqual(try Self.bar(moved.meshes[0], blue: false).min, try Self.bar(base.meshes[0], blue: false).min)

        // The texture layout decides whether the bind pose is the texture's; the coordinates agree.
        let mesh = moved.meshes[0]
        XCTAssertFalse(ScenePuppetPlan.matches(mesh.vertexData, format: mesh.format, layout: layout))
        XCTAssertFalse(ScenePuppetPlan.isTextureLayout(mesh.vertexData, format: mesh.format, imageSize: SIMD2(512, 256)))
        XCTAssertTrue(ScenePuppetPlan.matches(base.meshes[0].vertexData, format: mesh.format, layout: layout))
        XCTAssertTrue(ScenePuppetPlan.isTextureLayout(base.meshes[0].vertexData, format: mesh.format, imageSize: SIMD2(512, 256)))

        // No layers: the palette is the identity, so the moved positions are what draws.
        let animator = try Self.animator(moved, clip: 99)
        animator.advance(delta: 1 / 30, values: EmptySceneValues())
        for bone in animator.pose.bones {
            for column in 0..<4 { XCTAssertEqual(simd_distance(bone[column], matrix_identity_float4x4[column]), 0, accuracy: 1e-4) }
        }
        XCTAssertEqual(animator.pose.bonesAlpha, [1, 1])
        XCTAssertNil(animator.pose.drawRanges)
    }

    // MARK: - B: Limb Depth Order

    /// The editor splits the index buffer into one range per bone (bone, 0, first, count) in
    /// depth order, and writes the depths (default 100 per bone in order). "Move Limb to Back" on
    /// blue only lowers its depth to 0, level with red, and leaves the ranges as they were: WE draws
    /// blue over red where the clip swings it across (`mo2_509b_b_clip_order_t1`, as `b_clip`'s),
    /// so a static depth draws the file's order.
    func testAStaticDepthDrawsTheFilesOrder() throws {
        let base = try Self.model("base"), order = try Self.model("b_clip_order")
        XCTAssertEqual(base.skeleton?.boneDepths, [0, 100])
        XCTAssertEqual(order.skeleton?.boneDepths, [0, 0])
        XCTAssertEqual(order.skeleton?.boneIndices, [0, 1])
        let ranges = try XCTUnwrap(order.meshes[0].boneRanges(boneCount: 2))
        XCTAssertEqual(ranges, [MDLMesh.BoneRange(bone: 0, firstIndex: 0, indexCount: 594),
                                MDLMesh.BoneRange(bone: 1, firstIndex: 594, indexCount: 486)])
        XCTAssertEqual(order.meshes[0].boneRanges(boneCount: 2), base.meshes[0].boneRanges(boneCount: 2))
        XCTAssertNil(ScenePuppetDrawOrder(mesh: order.meshes[0], skeleton: try XCTUnwrap(order.skeleton),
                                          clips: order.animations ?? []), "no clip keys a depth: the buffer draws as it is")
        let animator = try Self.animator(order, clip: 23)
        animator.advance(delta: 1, values: EmptySceneValues())
        XCTAssertNil(animator.pose.drawRanges)
    }

    /// A keyed Depth offset (stepped: blue −200 for frames 0…29, 0 from 30; mesh flag 0x8) reorders the parts at
    /// run time: blue's part draws under red's while its depth is below red's
    /// (`mo2_509b_b_clip_keyed_order_t1`: blue hidden under red), over it after.
    func testAKeyedDepthOffsetReordersTheParts() throws {
        let model = try Self.model("b_clip_keyed_order")
        XCTAssertEqual(model.meshes[0].flags, 0x8, "the editor marks the keyed order")
        XCTAssertEqual(try Self.model("b_clip_order").meshes[0].flags, 0)
        let clip = try XCTUnwrap(model.animations?.first)
        XCTAssertNil(clip.boneAlphaTracks)
        let depth = try XCTUnwrap(clip.boneDepthTracks)
        XCTAssertEqual(depth.count, 2)
        XCTAssertEqual(depth[0].samples, Array(repeating: 0, count: 61))
        XCTAssertEqual(Array(depth[1].samples[0..<30]), Array(repeating: -200, count: 30))
        XCTAssertEqual(Array(depth[1].samples[30..<60]), Array(repeating: 0, count: 30))

        let animator = try Self.animator(model, clip: 23)
        XCTAssertEqual(animator.pose.drawRanges, [.init(firstIndex: 0, indexCount: 1080)], "at rest: the file's order")
        animator.advance(delta: 0.5, values: EmptySceneValues())
        XCTAssertEqual(animator.pose.drawRanges, [.init(firstIndex: 594, indexCount: 486), .init(firstIndex: 0, indexCount: 594)],
                       "frame 15: blue (100 − 200) under red (0)")
        animator.advance(delta: 0.7, values: EmptySceneValues())
        XCTAssertEqual(animator.pose.drawRanges, [.init(firstIndex: 0, indexCount: 1080)], "frame 36: blue (100) over red")
    }

    // MARK: - C: Reference Pose

    /// "Reference Pose" with blue turned 90° makes that pose the rig's bind pose: blue's `MDLS`
    /// matrix is turned 90°, the mesh is skinned into it (`a_Position`: the blue bar stands up),
    /// the texture layout goes into the `MDLV` 21 blob (as A), and `MDLE0002` keeps the bones'
    /// locals from before (base's bind). WE's wallpaper without layers draws the reference pose
    /// (`mo2_509c_refpose_t3`): the bind pose drawn from `a_Position`, as here, `MDLE` unread.
    func testTheReferencePoseIsWhatARigWithoutLayersDraws() throws {
        let base = try Self.model("base"), reference = try Self.model("c_refpose")
        XCTAssertEqual(reference.sections.map(\.tag), ["MDLS0004", "MDLE0002"])
        let pose = try XCTUnwrap(reference.referencePose)
        let bones = try XCTUnwrap(reference.skeleton?.bones)
        let original = try XCTUnwrap(base.skeleton?.bones)
        for (index, matrix) in pose.enumerated() {
            for column in 0..<4 {
                XCTAssertEqual(simd_distance(matrix[column], original[index].matrix[column]), 0, accuracy: 1e-4,
                               "MDLE is base's bind local of \(original[index].name)")
            }
        }
        XCTAssertEqual(bones[1].matrix.columns.0.y, 1, accuracy: 1e-4, "blue's bind turned 90°")
        XCTAssertEqual(bones[1].matrix.columns.1.x, -1, accuracy: 1e-4)
        try Self.assertClose(try XCTUnwrap(reference.meshes[0].textureLayoutPositions), base.meshes[0], "the texture layout")
        let straight = try Self.bar(base.meshes[0], blue: true), turned = try Self.bar(reference.meshes[0], blue: true)
        XCTAssertGreaterThan(straight.max.x - straight.min.x, 2 * (straight.max.y - straight.min.y), "base: lying")
        XCTAssertGreaterThan(turned.max.y - turned.min.y, 1.5 * (straight.max.y - straight.min.y), "reference: standing up")
        XCTAssertGreaterThan(turned.min.y, 0, "above the head")
        XCTAssertEqual(try Self.bar(reference.meshes[0], blue: false).max, try Self.bar(base.meshes[0], blue: false).max)

        let animator = try Self.animator(reference, clip: 23)
        animator.advance(delta: 3, values: EmptySceneValues())
        for bone in animator.pose.bones {
            for column in 0..<4 {
                XCTAssertEqual(simd_distance(bone[column], matrix_identity_float4x4[column]), 0, accuracy: 1e-4, "no clip 23: the bind pose")
            }
        }
    }

    // MARK: - D: bone flag 0x1

    /// An imported FBX (`RootNode` → armature object `Rig` → bones `root`, `mid`, `tip`, `loose`;
    /// the `Pivot` empty above `Rig` dropped by WE's importer): flag 0x1 on every armature bone,
    /// weighted or not, 0 on the other nodes. `MDLA` has one track per node in node order, the
    /// flag-0 nodes' held at their bind, so playing every track as it is draws what WE does.
    func testBoneFlagOneMarksArmatureBonesAndEveryNodeHasATrack() throws {
        let model = try Self.model("d_bone_flags")
        let bones = try XCTUnwrap(model.skeleton?.bones)
        XCTAssertEqual(bones.map(\.name), ["RootNode", "Rig", "root", "mid", "loose", "tip"])
        XCTAssertEqual(bones.map(\.flags), [0, 0, 1, 1, 1, 1])
        XCTAssertEqual(bones.map(\.parentIndex), [nil, 0, 1, 2, 2, 3])
        let clip = try XCTUnwrap(model.animations?.first)
        XCTAssertEqual(clip.boneTracks.count, 6)
        XCTAssertTrue(clip.boneTracks.allSatisfy { !$0.isDisabled })

        let animator = try Self.animator(model, clip: 22, isModel: true)
        animator.advance(delta: 0.5, values: EmptySceneValues())
        let rest = SceneSkeleton(try XCTUnwrap(model.skeleton)).restLocal
        for node in 0..<2 {
            for column in 0..<4 {
                XCTAssertEqual(simd_distance(animator.locals[node][column], rest[node][column]), 0, accuracy: 1e-3,
                               "\(bones[node].name) stays at its bind")
            }
        }
        XCTAssertGreaterThan(simd_distance(animator.locals[3][1], rest[3][1]), 0.1, "mid turns")
    }

    // MARK: - E: the clip record's Frame offset

    /// The model editor's Add Clip with Frame offset 10 writes it as the record's third u32
    /// (`00000000 1e000000 0a000000 ffffffff`, the files' only differing byte, 0x2530). Played, it
    /// starts the clip 10 frames in (a phase shift; WE's box at t matched offset 0's at about t + 0.5 s,
    /// within the captures' jitter of the 1/3 s).
    func testTheFrameOffsetStartsTheClipThatManyFramesIn() throws {
        let zero = try Self.model("e_offset0"), ten = try Self.model("e_offset10")
        let bytes0 = try Fixtures.data("Models/PuppetGroundTruth509/e_offset0.mdl")
        let bytes10 = try Fixtures.data("Models/PuppetGroundTruth509/e_offset10.mdl")
        XCTAssertEqual(bytes0.count, bytes10.count)
        XCTAssertEqual(zip(bytes0, bytes10).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset), [0x2530])
        let cut = try XCTUnwrap(ten.animation(id: 26))
        XCTAssertEqual(cut.reference, MDLAnimation.Reference(animation: 0, startFrame: 0, endFrame: 30, frameOffset: 10, rootBone: -1))
        XCTAssertEqual(zero.animation(id: 26)?.reference?.frameOffset, 0)

        let layer = SceneAnimationLayer(key: 0, name: "", clip: 1, animation: cut)
        XCTAssertEqual(layer.clock.time, 10 / 30, accuracy: 1e-6)
        XCTAssertEqual(SceneAnimationLayer(key: 0, name: "", clip: 1, animation: try XCTUnwrap(zero.animation(id: 26))).clock.time, 0)

        for t: Float in [0.25, 0.5] {
            let shifted = try Self.animator(ten, clip: 26, isModel: true), plain = try Self.animator(zero, clip: 26, isModel: true)
            shifted.advance(delta: t, values: EmptySceneValues())
            plain.advance(delta: t + 10 / 30, values: EmptySceneValues())
            for column in 0..<4 {
                XCTAssertEqual(simd_distance(shifted.locals[2][column], plain.locals[2][column]), 0, accuracy: 1e-3,
                               "offset 10 at \(t) s is offset 0 at \(t) s + 10 frames")
            }
        }
    }

    // MARK: - F: per-bone Opacity

    /// Blue's Opacity keyed 1 → 0 over frames 0…30 is the second scalar list (`MDLA` 3), and the
    /// editor sets mesh flag 0x4 (`b_clip` without it has 0). WE fades the bar (blue pixels
    /// 2459 / 137 / 72 at 0.5 / 0.8 / 1 s): the material has `SKINNING_ALPHA` and `g_BonesAlpha`
    /// follows the track.
    func testAKeyedBoneOpacityFadesItsPart() throws {
        let model = try Self.model("f_alpha")
        let mesh = model.meshes[0]
        XCTAssertEqual(mesh.flags, 0x4)
        XCTAssertTrue(mesh.usesSkinningAlpha)
        XCTAssertEqual(try Self.model("b_clip").meshes[0].flags, 0)
        let clip = try XCTUnwrap(model.animations?.first)
        let alpha = try XCTUnwrap(clip.boneAlphaTracks)
        XCTAssertEqual(alpha[0].samples, Array(repeating: 1, count: 61))
        XCTAssertEqual(alpha[1].samples[0], 1)
        XCTAssertEqual(alpha[1].samples[30], 0, accuracy: 1e-3)
        XCTAssertNil(clip.boneDepthTracks)
        XCTAssertEqual(ImagePuppetCombos(mesh: mesh, boneCount: 2).combos, ["SKINNING": 1, "BONECOUNT": 2, "SKINNING_ALPHA": 1])

        let animator = try Self.animator(model, clip: 23)
        XCTAssertEqual(animator.pose.bonesAlpha, [1, 1])
        var seen: [Float] = []
        var time: Float = 0
        for target: Float in [0.5, 0.8, 1.0] {
            animator.advance(delta: target - time, values: EmptySceneValues())
            time = target
            XCTAssertEqual(animator.pose.bonesAlpha[0], 1, "red stays")
            seen.append(animator.pose.bonesAlpha[1])
        }
        XCTAssertEqual(seen[0], alpha[1].samples[15], accuracy: 0.02)
        XCTAssertLessThan(seen[1], 0.12)
        XCTAssertLessThan(seen[2], 0.02)
        XCTAssertGreaterThan(seen[0], seen[1])
    }
}
