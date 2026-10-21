import XCTest
import simd
@testable import OpenWallpaperEngine

/// Root motion against WE 2.8.0.42 (docs/test-risks.md MG4, docs/models-plan.md §2.8): the model
/// editor's own `.mdl` (`mg4-rootmotion-all-on.mdl`: a box skinned to the bone `root` under
/// `RootNode` and `Rig`, whose clip "Scene (Clip 5)", id 26, cut from "Scene", id 16, moves the root
/// by (1, 2, 3)·s(t) and turns it by (0.3, 0.6, 0.9)·s(t) in Blender's axes over 30 frames, its last
/// frame equal to its first). The editor's nine settings differ only in the clip flags byte (at
/// 0x17D4: 0x04 Match loop, 0x08/0x10/0x20 position x/y/z, 0x80 rotation y) and the root bone (the
/// u32 at 0x2534).
///
/// WE's captures (we-test-wp-images @ 2aad5f2: tools/peer/models_gt/mg4/clips, README and
/// tools/peer/requests/owe-beta3) show WE takes the flagged axes out of the root's pose each frame
/// and never moves the object by them, with nothing carried from loop to loop; with yaw and a
/// position axis the model turns by the root's yaw (all on). The stack has no object motion to
/// apply, so these tests check the pose, and its box against the captures.
final class SceneRootMotionTests: XCTestCase {
    struct Variant {
        var name: String
        var flags: UInt32
        var rootBone: Int32
        /// WE's box centroid on the 1920×1080 screen at frames 5, 10, 15, 20 and 25 of a loop, read
        /// from its capture `clips/mg4p_<name>.mp4` (6 s at 30 fps, from the frame the box jumps
        /// back to its start); nil for the settings whose file is the same as another's.
        var we: [SIMD2<Float>]? = nil
    }

    static let variants: [Variant] = [
        Variant(name: "bone_none", flags: 0x401, rootBone: -1,
                we: [SIMD2(946, 556), SIMD2(892, 539), SIMD2(849, 527), SIMD2(782, 510), SIMD2(737, 498)]),
        Variant(name: "root_all_off", flags: 0x401, rootBone: 2),
        Variant(name: "root_posX", flags: 0xc01, rootBone: 2,
                we: [SIMD2(931, 550), SIMD2(886, 535), SIMD2(831, 517), SIMD2(724, 484), SIMD2(671, 469)]),
        Variant(name: "root_posY", flags: 0x1401, rootBone: 2,
                we: [SIMD2(936, 559), SIMD2(862, 558), SIMD2(779, 559), SIMD2(611, 563), SIMD2(530, 566)]),
        Variant(name: "root_posZ", flags: 0x2401, rootBone: 2,
                we: [SIMD2(945, 574), SIMD2(894, 626), SIMD2(852, 675), SIMD2(793, 746), SIMD2(764, 783)]),
        Variant(name: "root_rotX", flags: 0x401, rootBone: 2),
        Variant(name: "root_rotY", flags: 0x8401, rootBone: 2,
                we: [SIMD2(931, 551), SIMD2(885, 537), SIMD2(851, 531), SIMD2(789, 530), SIMD2(769, 530)]),
        Variant(name: "root_rotZ", flags: 0x401, rootBone: 2),
        Variant(name: "root_all_on", flags: 0xbc01, rootBone: 2,
                we: [SIMD2(915, 582), SIMD2(834, 649), SIMD2(776, 742), SIMD2(740, 911), SIMD2(742, 998)]),
    ]

    static var allOff: Variant { variants[1] }
    static var yawOnly: Variant { variants[6] }
    static var allOn: Variant { variants[8] }

    static let flagsOffset = 0x17D4
    static let rootBoneOffset = 0x2534

    /// The editor's file with another setting written in.
    static func data(_ variant: Variant) throws -> Data {
        var data = try Data(contentsOf: Fixtures.url("Models/mg4-rootmotion-all-on.mdl"))
        data[flagsOffset] = UInt8((variant.flags >> 8) & 0xff)
        withUnsafeBytes(of: variant.rootBone.littleEndian) { bytes in
            for (index, byte) in bytes.enumerated() { data[rootBoneOffset + index] = byte }
        }
        return data
    }

    func testTheEditorsClipRecord() throws {
        let model = try MDLModel(contentsOf: Fixtures.url("Models/mg4-rootmotion-all-on.mdl"))
        let clips = try XCTUnwrap(model.animations)
        XCTAssertEqual(clips.map(\.id), [16, 26])
        XCTAssertEqual(clips.map(\.name), ["Scene", "Scene (Clip 5)"])
        XCTAssertNil(clips[0].reference)
        XCTAssertEqual(clips[1].flags, 0xbc01, "reference, Match loop, position x y z, rotation y")
        XCTAssertEqual(clips[1].reference,
                       MDLAnimation.Reference(animation: 0, startFrame: 0, endFrame: 30, frameOffset: 0, rootBone: 2))
        XCTAssertEqual(model.skeleton?.bones.map(\.name), ["RootNode", "Rig", "root"])
    }

    /// Every setting the editor wrote reads back as written; with the capture's files present
    /// (`OWE_MG4_VARIANTS`, or the peer's ground-truth folder) those are read too.
    func testEveryEditorVariantParses() throws {
        let folder = ProcessInfo.processInfo.environment["OWE_MG4_VARIANTS"]
            ?? "/Volumes/980Pro/dd-agentREF/peer/tools/peer/models_gt/mg4/mdl_variants"
        var files = 0
        for variant in Self.variants {
            var sources = [try Self.data(variant)]
            let file = URL(fileURLWithPath: folder).appending(path: "rootmotion_\(variant.name).mdl")
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                XCTAssertEqual(data, sources[0], "\(variant.name): the editor's file is the fixture with its two fields")
                sources.append(data)
                files += 1
            }
            for data in sources {
                let model = try MDLReader.read(data)
                let clip = try XCTUnwrap(model.animations?.last, variant.name)
                XCTAssertEqual(clip.id, 26, variant.name)
                XCTAssertEqual(clip.flags, variant.flags, variant.name)
                XCTAssertEqual(clip.reference?.rootBone, variant.rootBone, variant.name)
                XCTAssertEqual(clip.reference?.endFrame, 30, variant.name)
            }
        }
        if files > 0 { XCTAssertEqual(files, Self.variants.count) }
    }

    /// WE's fast-fail: without Match loop, root-motion Start and End frames must lie in the clip.
    func testRootMotionFramesPastTheClipAreRefused() throws {
        var data = try Self.data(Self.variants[2])
        data[Self.flagsOffset] = 0x08  // position x without Match loop
        data[Self.rootBoneOffset - 8] = 31  // End frame 31 of a 30-frame clip
        XCTAssertThrowsError(try MDLReader.read(data))
        data[Self.rootBoneOffset - 8] = 30
        XCTAssertNoThrow(try MDLReader.read(data))
    }

    /// The flags byte at 0x17D4 is bits 8…15 of the clip flags: 0xBC is position x, y, z, rotation
    /// y and Match loop, after the clip record's own bit (0x01).
    func testTheFlagsByte() throws {
        var data = try Self.data(Self.allOn)
        let flags: [(UInt8, UInt32)] = [
            (0x04, MDLAnimation.Flag.matchLoop), (0x08, MDLAnimation.Flag.rootPositionX),
            (0x10, MDLAnimation.Flag.rootPositionY), (0x20, MDLAnimation.Flag.rootPositionZ),
            (0x80, MDLAnimation.Flag.rootRotationY),
        ]
        for (byte, flag) in flags {
            data[Self.flagsOffset] = byte
            let clip = try XCTUnwrap(try MDLReader.read(data).animations?.last)
            XCTAssertEqual(clip.flags, MDLAnimation.Flag.reference | flag, String(format: "0x%02x", byte))
        }
        data[Self.flagsOffset] = 0xBC
        XCTAssertEqual(try XCTUnwrap(try MDLReader.read(data).animations?.last).flags, 0xbc01)
    }

    /// All off: the root plays its full motion, the pose a model without root motion has.
    func testAllOffPlaysTheFullMotion() throws {
        let rooted = try Self.rootPath(Self.allOff, rootMotion: true)
        let plain = try Self.rootPath(Self.allOff, rootMotion: false)
        for (a, b) in zip(rooted, plain) {
            XCTAssertLessThan(simd_distance(a.translation, b.translation), 1e-5)
            XCTAssertEqual(a.yaw, b.yaw, accuracy: 1e-5)
        }
        XCTAssertGreaterThan(Self.spread(rooted.map(\.translation)), 0.1, "the root travels")
        XCTAssertGreaterThan(rooted.map { abs($0.yaw) }.max() ?? 0, 0.1, "the root turns")
    }

    /// Yaw only: the yaw the root gained since the start (YA, in the model's space) comes out of
    /// its local rotation, `quat(YA⁻¹) · q` (0x140225900, in its parent's frame); its translation
    /// plays as with all off, and the model doesn't turn (WE's rotY capture keeps its heading).
    func testYawOnlyStripsTheRootsYaw() throws {
        let yaw = try Self.poses(Self.yawOnly)
        let full = try Self.poses(Self.allOff)
        var largest: Float = 0
        for (a, b) in zip(yaw, full) {
            let gained = try Self.gainedYaw(b)
            largest = max(largest, abs(gained))
            let stripped = simd_quatf(angle: -gained, axis: SIMD3(0, 1, 0)) * b.locals[2].rotation
            XCTAssertLessThan(Self.angle(a.locals[2].rotation, stripped), 1e-3, "the root's yaw comes out")
            XCTAssertLessThan(simd_distance(a.locals[2].translation, b.locals[2].translation), 1e-4, "the translation plays")
            for bone in [0, 1] {
                XCTAssertLessThan(Self.angle(a.locals[bone].rotation, b.locals[bone].rotation), 1e-5, "no turn")
            }
        }
        XCTAssertGreaterThan(largest, 0.3, "the root gains yaw to strip")
    }

    /// All on: the root's local translation gains `start − current` on every axis, as each axis
    /// alone does (the per-axis captures), so the offsets add up; its yaw comes out as with yaw
    /// only; and the model turns about its origin by the yaw the root gained (the all-on capture).
    func testAllOnStripsEveryAxisAndTurnsTheModel() throws {
        let on = try Self.poses(Self.allOn)
        let off = try Self.poses(Self.allOff)
        let yaw = try Self.poses(Self.yawOnly)
        let axes = try Self.variants[2...4].map { try Self.poses($0) }
        for frame in on.indices {
            let base = off[frame].locals[2].translation
            let offsets = axes.map { $0[frame].locals[2].translation - base }
            for (axis, offset) in offsets.enumerated() {
                XCTAssertLessThan(simd_length(offset - simd_dot(offset, Self.unit(axis)) * Self.unit(axis)), 1e-4,
                                  "each flag moves its own local axis")
            }
            let expected = base + offsets.reduce(SIMD3<Float>(repeating: 0), +)
            XCTAssertLessThan(simd_distance(on[frame].locals[2].translation, expected), 1e-3, "frame \(frame)")
            XCTAssertLessThan(Self.angle(on[frame].locals[2].rotation, yaw[frame].locals[2].rotation), 1e-3)
            let turn = simd_quatf(angle: try Self.gainedYaw(off[frame]), axis: SIMD3(0, 1, 0))
            XCTAssertLessThan(Self.angle(on[frame].locals[0].rotation, turn * off[frame].locals[0].rotation), 1e-3,
                              "the model turns by the root's yaw")
        }
        let travel = Self.spread(on.map { $0.locals[2].translation })
        XCTAssertGreaterThan(travel, 0.1, "the strip lands on the parent's axes, so the root still moves")
    }

    /// `IModelLayer.rootmotion` written by a script: switched off, the model plays as one authored
    /// without root motion; switched back on, from the next frame as one authored with it.
    func testRootMotionSwitchesPerFrame() throws {
        let model = try MDLReader.read(try Self.data(Self.allOn))
        var switched = try Self.stack(model, rootMotion: true)
        var plain = try Self.stack(model, rootMotion: false)
        var rooted = try Self.stack(model, rootMotion: true)
        var updates = (SceneAnimationLayerUpdate(), SceneAnimationLayerUpdate(), SceneAnimationLayerUpdate())
        switched.runsRootMotion = false
        for _ in 0..<40 {
            let a = switched.evaluate(delta: 1.0 / 30, update: &updates.0)
            let b = plain.evaluate(delta: 1.0 / 30, update: &updates.1)
            _ = rooted.evaluate(delta: 1.0 / 30, update: &updates.2)
            XCTAssertLessThan(simd_distance(a[2].translation, b[2].translation), 1e-6)
        }
        switched.runsRootMotion = true
        let a = switched.evaluate(delta: 1.0 / 30, update: &updates.0)
        let b = plain.evaluate(delta: 1.0 / 30, update: &updates.1)
        let c = rooted.evaluate(delta: 1.0 / 30, update: &updates.2)
        XCTAssertLessThan(simd_distance(a[2].translation, c[2].translation), 1e-6, "on again: as authored with it")
        XCTAssertGreaterThan(simd_distance(a[2].translation, b[2].translation), 1e-3, "root motion moves the root")
    }

    /// The box's path through a loop, played as the capture's project plays it (layer on clip 26,
    /// model scale 0.01, camera 8 6 8 → 0 1 0, fov 50, 1920×1080), against WE's MG4 captures, with
    /// the object never moved by root motion. All off is the root bone with no axis, the same
    /// file as `bone_none`, whose capture stands for it. 20 px mean: the clips repeat frames, so
    /// a sample's phase is only known to about a frame, and the box moves up to 30 px a frame.
    func testTheLoopFollowsWEsCaptures() throws {
        let captured: [(Variant, [SIMD2<Float>])] = [
            (Self.allOff, try XCTUnwrap(Self.variants[0].we)),
            (Self.yawOnly, try XCTUnwrap(Self.yawOnly.we)),
            (Self.allOn, try XCTUnwrap(Self.allOn.we)),
        ] + Self.variants[2...4].compactMap { variant in variant.we.map { (variant, $0) } }
        for (variant, we) in captured {
            let path = try Self.screenPath(variant)
            let errors: [Float] = zip(path, we).map { simd_distance($0, $1) }
            let mean: Float = errors.reduce(0, +) / Float(errors.count)
            XCTAssertLessThan(mean, 20, "\(variant.name): ours \(path), WE's \(we)")
        }
    }

    /// WE 2.8.0.42's owe-beta3 answer (branch `we-test-wp-images` @ 2aad5f2,
    /// tools/peer/requests/owe-beta3/README.md and `rootmotion_strips.png`, taken from the MG4 clips
    /// `tools/peer/models_gt/mg4/clips/mg4p_root_{all_off,rotY,all_on}.mp4`): the box centroid at
    /// the recording's whole seconds and half seconds, tools/peer/models_gt/mg4/README.md's table.
    /// Its points are on the 1920×1080 frame whatever its heading says (all on reaches y 940).
    /// The recordings don't start on a loop: their loops begin 19 to 21 frames into each second,
    /// so the whole seconds fall on frames 9 to 11 of a loop and the half seconds 15 frames later.
    /// The clips repeat frames, so each point's frame is known to ±2 (the rotY clip's box is at
    /// the table's half-second point 3 frames early), and the box moves up to 30 px a frame: each
    /// point must lie within 40 px of the box's path over those frames, in every loop. 40 px is the
    /// per-frame check's largest error (yaw only, frame 25: 35 px).
    func testTheBeta3LoopAndMidCycleCentroids() throws {
        let table: [(Variant, second: SIMD2<Float>, half: SIMD2<Float>)] = [
            (Self.allOff, SIMD2(905, 542), SIMD2(743, 499)),
            (Self.yawOnly, SIMD2(927, 549), SIMD2(785, 529)),
            (Self.allOn, SIMD2(857, 627), SIMD2(743, 940)),
        ]
        for (variant, second, half) in table {
            for loop in 1...3 {
                for (point, frames) in [(second, 7...13), (half, 22...28)] {
                    let path = try Self.screenPath(variant, steps: frames.map { $0 + 30 * loop })
                    let nearest = zip(path, path.dropFirst()).map { Self.distance(point, $0, $1) }.min() ?? .infinity
                    XCTAssertLessThan(nearest, 40, "\(variant.name) loop \(loop): ours \(path), WE's \(point)")
                }
            }
        }
    }

    /// Nothing accumulates: each loop poses the root as the last did, for every setting. Sampled
    /// half a frame off the frame times, where the clock's truncation can't round either way;
    /// positions to 1e-2 in the model's units (the root travels hundreds; the clock's float sum
    /// drifts by about 1e-3 over five loops).
    func testNoAccumulationAcrossLoops() throws {
        let frames = [5, 10, 15, 20, 25]
        for variant in [Self.allOff, Self.yawOnly, Self.allOn] {
            let loops = (0..<5).map { loop in frames.map { $0 + 30 * loop } }
            let path = try Self.rootPath(variant, rootMotion: true, steps: loops.flatMap { $0 }, offset: 0.5 / 30)
            for loop in 1..<5 {
                for index in frames.indices {
                    let a = path[index], b = path[loop * frames.count + index]
                    XCTAssertLessThan(simd_distance(a.translation, b.translation), 1e-2, "\(variant.name) loop \(loop)")
                    XCTAssertEqual(a.yaw, b.yaw, accuracy: 1e-3, "\(variant.name) loop \(loop)")
                }
            }
        }
    }

    /// A clip the editor cut without Match loop reads its source clip from its Start frame in a
    /// model (0x14021c6b3), whatever tracks it carries; with Match loop, or on a puppet, it reads
    /// its own.
    func testACutClipWithoutMatchLoopReadsItsSource() throws {
        let skeleton = SceneAnimationLayersTests.skeleton()
        let source = SceneAnimationLayersTests.clip(id: 16, name: "Scene", fps: 10, frames: 20) { frame in
            MDLBonePose(position: SIMD3(Float(frame), 0, 0), euler: .zero, scale: SIMD3(repeating: 1))
        }
        var cut = SceneAnimationLayersTests.clip(id: 26, name: "cut", fps: 10, frames: 5) { _ in
            MDLBonePose(position: SIMD3(0, -7, 0), euler: .zero, scale: SIMD3(repeating: 1))
        }
        cut.flags = MDLAnimation.Flag.reference
        cut.reference = MDLAnimation.Reference(animation: 0, startFrame: 8, endFrame: 13, frameOffset: 0, rootBone: -1)
        func translation(_ clip: MDLAnimation, model: Bool) -> SIMD3<Float> {
            var stack = SceneAnimationLayerStack(skeleton: skeleton, clips: [source, clip], model: model)
            stack.insert(SceneAnimationLayer(key: 1, name: "cut", clip: 1, animation: clip))
            var update = SceneAnimationLayerUpdate()
            return stack.evaluate(delta: 0.2, update: &update)[0].translation  // frame 2 of the cut
        }
        XCTAssertEqual(translation(cut, model: true), SIMD3(10, 0, 0), "the source's frame 8 + 2")
        XCTAssertEqual(translation(cut, model: false), SIMD3(0, -7, 0), "a puppet reads the clip's own")
        cut.flags |= MDLAnimation.Flag.matchLoop
        XCTAssertEqual(translation(cut, model: true), SIMD3(0, -7, 0), "with Match loop the clip's own")
    }

    // MARK: - The path

    static func stack(_ model: MDLModel, rootMotion: Bool) throws -> SceneAnimationLayerStack {
        let skeleton = SceneSkeleton(try XCTUnwrap(model.skeleton))
        let clips = try XCTUnwrap(model.animations)
        var stack = SceneAnimationLayerStack(skeleton: skeleton, clips: clips, model: true, rootMotion: rootMotion)
        let index = try XCTUnwrap(stack.clipIndex(id: 26), "the layer names the clip, 26, not the source 16")
        stack.insert(SceneAnimationLayer(key: 900, name: "clip", clip: index, animation: clips[index]))
        return stack
    }

    struct RootSample {
        /// The root's model-space position.
        var translation: SIMD3<Float>
        /// The root's yaw since frame 0 (radians).
        var yaw: Float
    }

    /// The root bone's model-space position and yaw after each of `steps` frames of 1/30 s (by
    /// default frames 5, 10, 15, 20 and 25 of the second loop), the clock first moved by `offset`.
    static func rootPath(_ variant: Variant, rootMotion: Bool, steps: [Int] = [35, 40, 45, 50, 55],
                         offset: Float = 0) throws -> [RootSample] {
        let model = try MDLReader.read(try data(variant))
        var stack = try stack(model, rootMotion: rootMotion)
        let skeleton = stack.skeleton
        func root(_ pose: [SceneBoneTransform]) -> simd_float4x4 { skeleton.worlds(locals: pose.map(\.matrix))[2] }
        var update = SceneAnimationLayerUpdate()
        let first = rotation(root(stack.evaluate(delta: offset, update: &update)))
        var samples: [RootSample] = []
        for step in 1...(steps.max() ?? 0) {
            let pose = stack.evaluate(delta: 1.0 / 30, update: &update)
            guard steps.contains(step) else { continue }
            let world = root(pose)
            samples.append(RootSample(translation: SceneRootMotion.translation(world),
                                      yaw: yawAngle(rotation(world) * first.inverse)))
        }
        return samples
    }

    /// A model-space rotation without the skeleton's scale (the editor's `Rig` scales by 100).
    static func rotation(_ matrix: simd_float4x4) -> simd_float3x3 {
        let r = SceneRootMotion.rotation(matrix)
        return simd_float3x3(simd_normalize(r.columns.0), simd_normalize(r.columns.1), simd_normalize(r.columns.2))
    }

    /// The angle of a rotation's yaw (`SceneRootMotion.yaw`, whose columns are (c, 0, −s),
    /// (0, 1, 0), (s, 0, c)).
    static func yawAngle(_ rotation: simd_float3x3) -> Float {
        let yaw = SceneRootMotion.yaw(rotation)
        return atan2(yaw.columns.2.x, yaw.columns.2.z)
    }

    struct Pose {
        var locals: [SceneBoneTransform]
        var worlds: [simd_float4x4]
        /// The root's world at the clip's first frame.
        var start: simd_float4x4
    }

    /// The pose half a frame past frames 2, 6, …, 26 of the second loop (off the frame times).
    static func poses(_ variant: Variant) throws -> [Pose] {
        let model = try MDLReader.read(try data(variant))
        var stack = try stack(model, rootMotion: true)
        let skeleton = stack.skeleton
        let plain = try Self.stack(model, rootMotion: false)
        let start = skeleton.worlds(locals: plain.skeleton.bindPose.indices.map { bone in
            plain.sample(plain.layers[0])[bone]?.matrix ?? plain.skeleton.bindPose[bone].matrix
        })[2]
        var update = SceneAnimationLayerUpdate()
        _ = stack.evaluate(delta: 0.5 / 30, update: &update)
        var poses: [Pose] = []
        for step in 1...56 {
            let pose = stack.evaluate(delta: 1.0 / 30, update: &update)
            guard step > 30, step % 4 == 2 else { continue }
            poses.append(Pose(locals: pose, worlds: skeleton.worlds(locals: pose.map(\.matrix)), start: start))
        }
        return poses
    }

    /// The yaw the root gained since the clip's first frame in an all-off pose, in the model's
    /// space (YA): its world rotation against the start's.
    static func gainedYaw(_ pose: Pose) throws -> Float {
        yawAngle(rotation(pose.worlds[2]) * rotation(pose.start).inverse)
    }

    /// The angle between two rotations (radians).
    static func angle(_ a: simd_quatf, _ b: simd_quatf) -> Float {
        let d = abs(simd_dot(a.normalized.vector, b.normalized.vector))
        return 2 * acos(min(d, 1))
    }

    static func unit(_ axis: Int) -> SIMD3<Float> {
        var v = SIMD3<Float>(repeating: 0)
        v[axis] = 1
        return v
    }

    /// The box centre on screen after each of `steps` frames of 1/30 s (by default frames 5, 10,
    /// 15, 20 and 25 of the second loop). The object stays at the origin, scale 0.01: root motion
    /// never moves it.
    static func screenPath(_ variant: Variant, steps: [Int] = [35, 40, 45, 50, 55]) throws -> [SIMD2<Float>] {
        let model = try MDLReader.read(try data(variant))
        var stack = try stack(model, rootMotion: true)
        let bounds = model.bounds
        let centre = (bounds.min + bounds.max) * 0.5
        let object = SceneWorldMatrix.local(SceneLocalTransform3D(origin: .zero, scale: SIMD3(repeating: 0.01), angles: .zero))
        var update = SceneAnimationLayerUpdate()
        var path: [SIMD2<Float>] = []
        for step in 1...(steps.max() ?? 0) {
            let pose = stack.evaluate(delta: 1.0 / 30, update: &update)
            guard steps.contains(step) else { continue }
            let palette = stack.skeleton.palette(worlds: stack.skeleton.worlds(locals: pose.map(\.matrix)))
            let placed: SIMD4<Float> = object * (palette[2] * SIMD4<Float>(centre, 1))
            path.append(screen(SIMD3(placed.x, placed.y, placed.z)))
        }
        return path
    }

    /// Through the capture's camera: eye 8 6 8, centre 0 1 0, a 50° vertical fov, 16:9.
    static func screen(_ point: SIMD3<Float>) -> SIMD2<Float> {
        let eye = SIMD3<Float>(8, 6, 8)
        let forward = simd_normalize(SIMD3<Float>(0, 1, 0) - eye)
        let side = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        let up = simd_cross(side, forward)
        let relative = point - eye
        let depth: Float = simd_dot(relative, forward)
        let tangent: Float = tan(25 * Float.pi / 180)
        let x: Float = simd_dot(relative, side) / depth / tangent / (16.0 / 9.0)
        let y: Float = simd_dot(relative, up) / depth / tangent
        return SIMD2(960 + x * 960, 540 - y * 540)
    }

    /// The distance of `point` from the segment `a`…`b`.
    static func distance(_ point: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let length = simd_length_squared(ab)
        let t = length > 0 ? min(max(simd_dot(point - a, ab) / length, 0), 1) : 0
        return simd_distance(point, a + ab * t)
    }

    /// The largest distance of a point from the first.
    static func spread(_ points: [SIMD3<Float>]) -> Float {
        points.map { simd_distance($0, points[0]) }.max() ?? 0
    }
}
