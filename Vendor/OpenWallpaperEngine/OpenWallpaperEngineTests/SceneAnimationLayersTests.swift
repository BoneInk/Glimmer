import XCTest
import simd
@testable import OpenWallpaperEngine

/// Animation layers (docs/models-plan.md §2.8): the weight's ramps (0x14026c8b0), the clip modes
/// on WE's clip clock, replace, nlerp blend, additive layers, disabled tracks, insertion order and
/// events, on hand-built skeletons and clips whose poses are known.
final class SceneAnimationLayersTests: XCTestCase {
    // MARK: - Fixtures

    /// One bone at the origin, or a chain along x.
    static func skeleton(bones: Int = 1, bind: [simd_float4x4]? = nil) -> SceneSkeleton {
        SceneSkeleton(MDLSkeleton(version: 1, bones: (0..<bones).map {
            MDLBone(name: "b\($0)", flags: 1, parent: $0 == 0 ? 0xFFFF_FFFF : UInt32($0 - 1),
                    matrix: bind?[$0] ?? matrix_identity_float4x4, properties: "")
        }))
    }

    /// A clip whose every frame is `pose(frame)` for every bone; `disabled` bones' tracks are off.
    static func clip(id: UInt64 = 1, name: String = "clip", mode: String = "loop", fps: Float = 10, frames: UInt32 = 20,
                     bones: Int = 1, disabled: Set<Int> = [], events: [MDLAnimation.Event] = [],
                     pose: (Int) -> MDLBonePose) -> MDLAnimation {
        let samples = (0...Int(frames)).flatMap { frame -> [Float] in
            let p = pose(frame)
            return [p.position.x, p.position.y, p.position.z, p.euler.x, p.euler.y, p.euler.z, p.scale.x, p.scale.y, p.scale.z]
        }
        return MDLAnimation(id: id, name: name, modeName: mode, fps: fps, frames: frames, flags: 0,
                            boneTracks: (0..<bones).map { MDLAnimation.Track(flags: disabled.contains($0) ? 1 : 0, samples: samples) },
                            events: events)
    }

    static func still(_ position: SIMD3<Float> = .zero, angle: Float = 0, scale: Float = 1) -> (Int) -> MDLBonePose {
        { _ in MDLBonePose(position: position, euler: SIMD3(0, 0, angle), scale: SIMD3(repeating: scale)) }
    }

    private func layer(_ clip: MDLAnimation, key: Int = 0, index: Int = 0, blendIn: Bool = false, blendOut: Bool = false,
                       blendTime: Float = 0.5, blend: Float = 1, additive: Bool = false) -> SceneAnimationLayer {
        SceneAnimationLayer(key: key, name: clip.name, clip: index, animation: clip, additive: additive, blendIn: blendIn,
                            blendOut: blendOut, blendTime: blendTime, blend: blend)
    }

    private func angle(_ q: simd_quatf) -> Float { 2 * atan2(q.imag.z, q.real) }

    // MARK: - Weights

    /// Blend-in: `min(t / min(duration/2, blendTime), 1)`; at 0, half the ramp, blendTime, duration/2.
    func testTheBlendInRamp() {
        let clip = Self.clip(pose: Self.still())                 // 2 s
        var ramped = layer(clip, blendIn: true, blendTime: 0.5, blend: 0.8)
        let expected: [(Float, Float)] = [(0, 0), (0.25, 0.4), (0.5, 0.8)]
        for (time, weight) in expected {
            ramped.clock.time = time
            ramped.blendIn = true
            XCTAssertEqual(ramped.weight(), weight, accuracy: 1e-6, "blend-in at \(time)")
        }
        // A blend time longer than half the clip ramps over half the clip.
        var long = layer(clip, blendIn: true, blendTime: 5)
        long.clock.time = 0.5
        XCTAssertEqual(long.weight(), 0.5, accuracy: 1e-6)
        long.clock.time = 1                                       // duration / 2
        XCTAssertEqual(long.weight(), 1, accuracy: 1e-6)
        XCTAssertFalse(long.blendIn, "a looping clip's blend-in ends once its ramp reached 1")
        // A single clip keeps ramping in every time it restarts.
        var single = layer(Self.clip(mode: "single", pose: Self.still()), blendIn: true)
        single.clock.time = 0.5
        XCTAssertEqual(single.weight(), 1, accuracy: 1e-6)
        XCTAssertTrue(single.blendIn)
        // No time to ramp: min(duration, blendTime) at or below FLT_EPSILON.
        var none = layer(clip, blendIn: true, blendTime: 0)
        XCTAssertEqual(none.weight(), 1)
    }

    /// Blend-out, kept only for single clips: `min((duration − t) / min(duration/2, blendTime), 1)`.
    func testTheBlendOutRampOnlyForSingleClips() {
        var single = layer(Self.clip(mode: "single", pose: Self.still()), blendOut: true, blendTime: 0.5)
        let expected: [(Float, Float)] = [(0, 1), (1, 1), (1.5, 1), (1.75, 0.5), (2, 0)]
        for (time, weight) in expected {
            single.clock.time = time
            XCTAssertEqual(single.weight(), weight, accuracy: 1e-6, "blend-out at \(time)")
        }
        let looping = layer(Self.clip(pose: Self.still()), blendOut: true)
        XCTAssertFalse(looping.blendOut, "WE drops blendout on a clip that isn't single (0x140223548)")
    }

    // MARK: - Modes and the ended signal

    func testModesAndEndedLayers() {
        let skeleton = Self.skeleton()
        for (mode, steps, time, ended) in [("loop", 5, Float(0.5), [3]), ("mirror", 5, Float(1.5), [3]),
                                           ("single", 5, Float(2), [3])] {
            var stack = SceneAnimationLayerStack(skeleton: skeleton, clips: [Self.clip(mode: mode, pose: Self.still())])
            stack.insert(layer(stack.clips[0]))
            var endedAt: [Int] = []
            for step in 0..<steps {
                var update = SceneAnimationLayerUpdate()
                _ = stack.evaluate(delta: 0.5, update: &update)
                if !update.ended.isEmpty { endedAt.append(step) }
            }
            XCTAssertEqual(stack.layers[0].clock.time, time, accuracy: 1e-5, mode)
            XCTAssertEqual(endedAt, ended, "\(mode) ends once, on the step that reaches 2 s")
        }
    }

    /// A single clip from `playSingleAnimation` goes away once finished.
    func testASinglePlayLayerIsRemovedWhenFinished() {
        var stack = SceneAnimationLayerStack(skeleton: Self.skeleton(), clips: [Self.clip(mode: "single", pose: Self.still())])
        var single = layer(stack.clips[0], key: 7)
        single.removesWhenFinished = true
        stack.insert(single)
        var update = SceneAnimationLayerUpdate()
        _ = stack.evaluate(delta: 1.5, update: &update)
        XCTAssertEqual(stack.layers.count, 1)
        _ = stack.evaluate(delta: 1, update: &update)
        XCTAssertTrue(stack.layers.isEmpty)
        XCTAssertEqual(update.removed, [7])
    }

    /// Events fire once as the clock crosses their frame (at `frame / fps`).
    func testClipEvents() {
        let clip = Self.clip(events: [MDLAnimation.Event(frame: 5, name: "step")], pose: Self.still())
        var stack = SceneAnimationLayerStack(skeleton: Self.skeleton(), clips: [clip])
        stack.insert(layer(clip, key: 3))
        var fired: [SceneAnimationLayerUpdate.Event] = []
        for _ in 0..<6 {
            var update = SceneAnimationLayerUpdate()
            _ = stack.evaluate(delta: 0.2, update: &update)
            fired += update.events
        }
        XCTAssertEqual(fired, [.init(layer: 3, name: "step", frame: 5)])
    }

    // MARK: - Applying

    /// The clip is sampled between the two frames around the time: translation lerped.
    func testSamplingBetweenFrames() {
        let clip = Self.clip(pose: { frame in MDLBonePose(position: SIMD3(Float(frame) * 10, 0, 0), euler: .zero, scale: SIMD3(repeating: 1)) })
        var stack = SceneAnimationLayerStack(skeleton: Self.skeleton(), clips: [clip])
        stack.insert(layer(clip))
        var update = SceneAnimationLayerUpdate()
        let pose = stack.evaluate(delta: 0.25, update: &update)   // frame 2.5
        XCTAssertEqual(pose[0].translation.x, 25, accuracy: 1e-3)
    }

    /// w = 1 replaces; a layer above with 0 < w < 1 nlerps from it; w = 0 is skipped.
    func testReplaceThenBlend() {
        let a = Self.clip(id: 1, name: "a", pose: Self.still(SIMD3(10, 0, 0), angle: 0))
        let b = Self.clip(id: 2, name: "b", pose: Self.still(SIMD3(20, 0, 0), angle: .pi / 2))
        var stack = SceneAnimationLayerStack(skeleton: Self.skeleton(), clips: [a, b])
        stack.insert(layer(a, key: 0, index: 0))
        stack.insert(layer(b, key: 1, index: 1, blend: 0.5))
        var update = SceneAnimationLayerUpdate()
        let pose = stack.evaluate(delta: 0, update: &update)
        XCTAssertEqual(pose[0].translation.x, 15, accuracy: 1e-4)
        XCTAssertEqual(angle(pose[0].rotation), .pi / 4, accuracy: 1e-4, "nlerp halfway between 0 and 90° about z")

        stack.update(key: 1) { $0.blend = 0 }
        XCTAssertEqual(stack.evaluate(delta: 0, update: &update)[0].translation.x, 10, accuracy: 1e-4, "w = 0 is skipped")
    }

    /// Additive: `pose + w·(sample − bind)` for translation and scale, the rotation's change from
    /// the bind pose nlerped by w and composed on the pose.
    func testAdditiveLayers() {
        let bind = SceneBoneTransform(translation: SIMD3(1, 0, 0), rotation: simd_quatf(angle: 0.2, axis: SIMD3(0, 0, 1)),
                                      scale: SIMD3(repeating: 1))
        let skeleton = Self.skeleton(bind: [bind.matrix])
        let base = Self.clip(id: 1, name: "base", pose: Self.still(SIMD3(10, 0, 0), angle: 0.5, scale: 2))
        let add = Self.clip(id: 2, name: "add", pose: Self.still(SIMD3(3, 0, 0), angle: 0.2 + .pi / 2, scale: 3))
        var stack = SceneAnimationLayerStack(skeleton: skeleton, clips: [base, add])
        stack.insert(layer(base, key: 0, index: 0))
        stack.insert(layer(add, key: 1, index: 1, blend: 0.5, additive: true))
        var update = SceneAnimationLayerUpdate()
        let pose = stack.evaluate(delta: 0, update: &update)[0]
        XCTAssertEqual(pose.translation.x, 10 + 0.5 * (3 - 1), accuracy: 1e-4)
        XCTAssertEqual(pose.scale.x, 2 + 0.5 * (3 - 1), accuracy: 1e-4)
        XCTAssertEqual(angle(pose.rotation), 0.5 + .pi / 4, accuracy: 1e-4)
        // At full weight an additive layer still adds (it doesn't replace).
        stack.update(key: 1) { $0.blend = 1 }
        XCTAssertEqual(stack.evaluate(delta: 0, update: &update)[0].translation.x, 12, accuracy: 1e-4)
    }

    /// Additive rotations on non-commuting axes (0x1401f9820; WE's capture MG3): the change from
    /// the bind pose is `bind⁻¹ · sample`, nlerped from the identity by w, and composed after the
    /// pose: `pose · Δ`. A pose turned 90° about x with Δ = 90° about z sends +y to −x (as WE draws
    /// it, not +z); at w = 0.5 Δ is 45°.
    func testAdditiveRotationsComposeAfterThePose() {
        let bind = SceneBoneTransform(translation: .zero, rotation: simd_quatf(angle: 0.4, axis: SIMD3<Float>(1, 0, 0)),
                                      scale: SIMD3<Float>(repeating: 1))
        let turn = simd_quatf(angle: Float.pi / 2, axis: SIMD3<Float>(0, 0, 1))
        let sample = SceneBoneTransform(translation: .zero, rotation: bind.rotation * turn, scale: SIMD3<Float>(repeating: 1))
        let pose = SceneBoneTransform(translation: .zero, rotation: simd_quatf(angle: Float.pi / 2, axis: SIMD3<Float>(1, 0, 0)),
                                      scale: SIMD3<Float>(repeating: 1))
        let up = SIMD3<Float>(0, 1, 0)
        let full = SceneAnimationLayerStack.add(sample, over: pose, bind: bind, weight: 1).rotation.act(up)
        XCTAssertLessThan(simd_distance(full, SIMD3<Float>(-1, 0, 0)), 1e-4, "\(full)")
        let half = SceneAnimationLayerStack.add(sample, over: pose, bind: bind, weight: 0.5).rotation.act(up)
        let expected = SIMD3<Float>(-Float(0.5).squareRoot(), 0, Float(0.5).squareRoot())
        XCTAssertLessThan(simd_distance(half, expected), 1e-4, "\(half)")
    }

    /// A disabled track leaves its bone as the layers below (or the bind pose) have it.
    func testADisabledTrackKeepsThePoseBelow() {
        let bind = [ScenePuppetTests.translation(SIMD3(5, 0, 0)), ScenePuppetTests.translation(SIMD3(0, 7, 0))]
        let skeleton = Self.skeleton(bones: 2, bind: bind)
        let clip = Self.clip(bones: 2, disabled: [1], pose: Self.still(SIMD3(40, 40, 0)))
        var stack = SceneAnimationLayerStack(skeleton: skeleton, clips: [clip])
        stack.insert(layer(clip))
        var update = SceneAnimationLayerUpdate()
        let pose = stack.evaluate(delta: 0, update: &update)
        XCTAssertEqual(pose[0].translation, SIMD3(40, 40, 0))
        XCTAssertEqual(pose[1].translation, SIMD3(0, 7, 0), "the bind transform")
        let worlds = skeleton.worlds(locals: pose.map(\.matrix))
        XCTAssertEqual(worlds[1].columns.3, SIMD4(40, 47, 0, 1), "a child follows its posed parent")
    }

    /// An invisible layer neither advances nor applies.
    func testAnInvisibleLayerIsFrozen() {
        let clip = Self.clip(pose: Self.still(SIMD3(9, 0, 0)))
        var stack = SceneAnimationLayerStack(skeleton: Self.skeleton(), clips: [clip])
        var hidden = layer(clip)
        hidden.visible = false
        stack.insert(hidden)
        var update = SceneAnimationLayerUpdate()
        let pose = stack.evaluate(delta: 0.7, update: &update)
        XCTAssertEqual(pose[0].translation, .zero)
        XCTAssertEqual(stack.layers[0].clock.time, 0)
    }

    /// `autosort` goes before the trailing additive layers, `index` is clamped, else appended.
    func testInsertionOrder() {
        let clip = Self.clip(pose: Self.still())
        var stack = SceneAnimationLayerStack(skeleton: Self.skeleton(), clips: [clip])
        stack.insert(layer(clip, key: 0))
        stack.insert(layer(clip, key: 1, additive: true))
        stack.insert(layer(clip, key: 2, additive: true))
        stack.insert(layer(clip, key: 3), autosort: true)
        XCTAssertEqual(stack.layers.map(\.key), [0, 3, 1, 2])
        stack.insert(layer(clip, key: 4), index: 99)
        XCTAssertEqual(stack.layers.map(\.key), [0, 3, 1, 4, 2])
        stack.insert(layer(clip, key: 5))
        XCTAssertEqual(stack.layers.last?.key, 5)
    }

    // MARK: - The skeleton

    /// The bind pose's palette is the identity, and its decomposition rebuilds the bind matrices.
    func testTheBindPoseIsTheIdentity() {
        let bind = [SceneBoneTransform(translation: SIMD3(3, 4, 5), rotation: simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3(1, 2, 3))),
                                       scale: SIMD3(2, 3, 4)).matrix,
                    ScenePuppetTests.translation(SIMD3(-9, 1, 0))]
        let skeleton = Self.skeleton(bones: 2, bind: bind)
        for (index, matrix) in skeleton.bindPose.map(\.matrix).enumerated() {
            for column in 0..<4 {
                XCTAssertLessThan(simd_length(matrix[column] - bind[index][column]), 1e-4)
            }
        }
        for entry in skeleton.palette(worlds: skeleton.bindWorld) {
            for column in 0..<4 {
                XCTAssertLessThan(simd_length(entry[column] - matrix_identity_float4x4[column]), 1e-5)
            }
        }
    }

    /// A puppet whose editor placed a part away from its place in the texture (3238423642: the head
    /// drawn beside the body, put on the neck): the bone matrix keeps the texture's place, which
    /// skins, and the `.mdl`'s rest block the placed one, which every clip's unanimated track holds.
    /// Ten additive layers each holding the rest value add nothing (not ten times the move), and a
    /// rig without layers draws at rest.
    func testAdditiveLayersAddToTheRestPoseNotTheSkinningBind() {
        let texturePlace = ScenePuppetTests.translation(SIMD3(-1468, -173, 0))
        let placed = ScenePuppetTests.translation(SIMD3(64, 55, 0))
        var mdl = MDLSkeleton(version: 2, bones: [MDLBone(name: "head", flags: 1, parent: 0xFFFF_FFFF,
                                                          matrix: texturePlace, properties: "")])
        mdl.bindMatrices = [placed]
        let skeleton = SceneSkeleton(mdl)
        let clips = (0..<10).map { Self.clip(id: UInt64($0 + 1), pose: Self.still(SIMD3(64, 55, 0))) }
        var stack = SceneAnimationLayerStack(skeleton: skeleton, clips: clips)
        for index in clips.indices { stack.insert(layer(clips[index], key: index, index: index, additive: true)) }
        var update = SceneAnimationLayerUpdate()
        let pose = stack.evaluate(delta: 0.1, update: &update)[0]
        XCTAssertEqual(pose.translation.x, 64, accuracy: 1e-3)
        XCTAssertEqual(pose.translation.y, 55, accuracy: 1e-3)
        // Skinning still maps from the texture's place: the palette moves the head by the placement.
        let entry = skeleton.palette(worlds: skeleton.worlds(locals: [pose.matrix]))[0]
        XCTAssertEqual(entry.columns.3.x, 64 + 1468, accuracy: 1e-2)
        XCTAssertEqual(entry.columns.3.y, 55 + 173, accuracy: 1e-2)
        XCTAssertEqual(skeleton.restWorld[0].columns.3.x, 64, accuracy: 1e-3)
    }
}
