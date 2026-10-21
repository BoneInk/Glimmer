import simd

/// Puppet Warp's rope chain ("Rope with N elements": Kinematic chain › Behavior Rope;
/// docs/models-plan.md §2.14, §2.16), WE's rope step (0x14026eb60) and the solver's rope pass
/// (0x14026e340) on `ScenePuppetIK`'s model matrices. A rope joint (flag 0x4) is a chain of
/// Verlet points in the world, the root pinned to its bone and, unless `ikfe` frees it, the end
/// to its IK target; `ikse` lets the chain stretch to reach it. Per frame, before the solver: each
/// point but the pinned ones moves by `2p − q`, minus friction, plus the scene's gravity times the
/// tip's mass (`ge`) and the scene's wind, times dt²; the bone takes the new point. Then, in the
/// solver's single iteration (a rope joint never makes it iterate again), one backward and one
/// forward Gauss–Seidel sweep hold each segment at its length (times the stretch). The sweep moves
/// the points only, so the bones show the step's positions and the sweep acts from the next frame
/// on, as in WE (its write-back reads the model matrices, 0x140272dee). Render thread only.
final class ScenePuppetRope: ScenePuppetIK.RopePass {
    /// What the step reads from the scene: its gravity and wind (`ScenePhysicsSettings`), the
    /// running time and the orthographic width the wind's noise is laid over.
    struct Environment: Equatable {
        var physics = ScenePhysicsSettings()
        var time: Float = 0
        var projectionWidth: Float = 1920
    }

    var environment = Environment()
    /// Per bone, its point now and last frame, in the world (the physics state's +0x34, +0x40).
    private var current: [SIMD3<Float>]
    private var previous: [SIMD3<Float>]
    /// Per bone: whether its rope has started (+0x4c on a rope's base): the first step puts every
    /// point where its bone is.
    private var started: [Bool]

    init(boneCount: Int) {
        current = Array(repeating: .zero, count: boneCount)
        previous = current
        started = Array(repeating: false, count: boneCount)
    }

    /// `resetBonePhysicsSimulation` clears the bone's state, the rope's start among it.
    func reset(bone: Int) {
        guard started.indices.contains(bone) else { return }
        started[bone] = false
        current[bone] = .zero
        previous[bone] = .zero
    }

    private static func transform(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let r = m * SIMD4(p, 1)
        return SIMD3(r.x, r.y, r.z)
    }

    func step(set: ScenePuppetIK.ChainSet, ik: ScenePuppetIK, delta: Float, objectWorld: simd_float4x4) {
        let inverse = objectWorld.inverse
        let dt2 = delta * delta
        for element in set.elements.reversed() {
            for joint in element.joints where joint.flags & 0x4 != 0 {
                let bones = joint.bones
                let a = ik.position(element.bone)
                var b = joint.flags & 0x1 != 0 ? ik.targetLink[joint.bone].map(ik.linkPosition) ?? ik.position(joint.bone)
                    : ik.position(joint.bone)
                let properties = ik.properties[joint.bone]
                let flags = properties?.flags ?? []
                if !flags.contains(.ikStretch) {
                    let distance = simd_length(b - a)
                    if distance > joint.length { b = a + (b - a) / distance * joint.length }
                }
                current[element.bone] = Self.transform(objectWorld, a)
                let free = flags.contains(.ikFreeEndpoint)
                let last = free ? bones.count : bones.count - 1
                if !free {
                    ik.setPosition(joint.bone, b)
                    current[joint.bone] = Self.transform(objectWorld, b)
                }
                if !started[element.bone] {
                    started[element.bone] = true
                    for index in 1..<max(last, 1) {
                        let p = Self.transform(objectWorld, ik.position(bones[index]))
                        current[bones[index]] = p
                        previous[bones[index]] = p
                    }
                }
                guard last > 1 else { continue }
                let friction = properties?.translationFriction ?? 0
                let mass = properties?.mass ?? 0
                let gravity = flags.contains(.gravity) ? environment.physics.gravity * mass : .zero
                for index in 1..<last {
                    let bone = bones[index]
                    let p = current[bone], q = previous[bone]
                    var next = 2 * p - q
                    if dt2 > 1.1920929e-7, friction > 0.01, simd_length_squared(q - p) > 9.9999997e-5 {
                        next += (q - p) * dt2 * (1 / dt2) * friction
                    }
                    var force = gravity
                    if let wind = SceneBonePhysicsWind.force(environment.physics, x: next.x, time: environment.time,
                                                             projectionWidth: environment.projectionWidth) {
                        force += wind
                    }
                    next += force * dt2
                    previous[bone] = p
                    current[bone] = next
                    ik.setPosition(bone, Self.transform(inverse, next))
                }
            }
        }
    }

    func constrain(joint: ScenePuppetIK.Joint, ik: ScenePuppetIK, forward: Bool) {
        let bones = joint.bones
        guard bones.count > 1 else { return }
        let world = ik.objectWorld, inverse = world.inverse
        let flags = ik.properties[joint.bone]?.flags ?? []
        let span = simd_length(current[joint.bone] - current[bones[0]])
        let stretch: Float = span > joint.length && flags.contains(.ikStretch) ? span / joint.length : 1
        let last = flags.contains(.ikFreeEndpoint) ? bones.count : bones.count - 1
        guard last > 1 else { return }
        for step in 1..<last {
            let child = forward ? bones[step] : bones[bones.count - step]
            let parent = forward ? bones[step - 1] : bones[bones.count - step - 1]
            let rest = stretch * ik.lengths[child]
            var c = Self.transform(inverse, current[child]), p = Self.transform(inverse, current[parent])
            let distance = simd_length(c - p)
            let error = rest - distance
            guard abs(error) > 0.001 else { continue }
            let direction = distance > 0.01 ? (c - p) / distance : SIMD3<Float>(0.707, 0.707, 0)
            if forward, step == 1 {
                c += direction * error
                current[child] = Self.transform(world, c)
            } else if !forward, step == 1 {
                p -= direction * error
                current[parent] = Self.transform(world, p)
            } else {
                let half = error * 0.5
                p -= direction * half
                c += direction * half
                current[parent] = Self.transform(world, p)
                current[child] = Self.transform(world, c)
            }
        }
    }
}
