import simd

/// A rig's physics bones in motion (docs/models-plan.md §2.14): spring and rigid bones whose tip
/// lags behind the bone's motion, falls under gravity and springs back, as WE's puppet update
/// simulates them (0x14020136e…0x140203648; the model update's copy is 0x14021d702). Every
/// frame each bone is posed in turn, parents first; a physics bone's model-space matrix then
/// takes its simulated rotation and offset in its own space, `model · P`, before its children
/// are posed from it. The step is the frame's: WE uses the update's delta, scaled to 60 frames a
/// second where it integrates the angular velocity. The state is per bone (puppet+0x3b8, 0x50
/// bytes each): the angular velocity, the Euler angles, the offset and the velocity, both in the
/// world. Render thread only.
struct SceneBonePhysics {
    struct State: Equatable {
        var angularVelocity = SceneBonePhysicsMath.identity
        var angles = SIMD3<Float>.zero
        var offset = SIMD3<Float>.zero
        var velocity = SIMD3<Float>.zero
    }

    /// What a step needs besides the pose: the frame's delta, the object's world matrix, and each
    /// bone's world matrix as the last frame left it (WE's double-buffered puppet+0x340/+0x348).
    struct Frame {
        var delta: Float
        var objectWorld: simd_float4x4
        var previousWorlds: [simd_float4x4]
    }

    /// Per bone: its constraint when it is simulated.
    let constraints: [MDLBonePhysics?]
    private(set) var states: [State]
    /// Per physics bone: the transform its last step put on it, which later poses between steps
    /// (a script's local write) keep [I].
    private(set) var transforms: [simd_float4x4?]

    /// Nil for a skeleton without a simulated bone.
    init?(_ skeleton: MDLSkeleton) {
        let constraints = skeleton.bones.map { bone in
            MDLBonePhysics(properties: bone.properties).flatMap { $0.isSimulated ? $0 : nil }
        }
        guard constraints.contains(where: { $0 != nil }) else { return nil }
        self.constraints = constraints
        states = Array(repeating: State(), count: constraints.count)
        transforms = Array(repeating: nil, count: constraints.count)
    }

    /// Model-space matrices from local ones, parents first, each physics bone stepped with
    /// `frame` (without one, it keeps its last transform). `adjust` changes a bone's matrix
    /// before its step, as `SceneSkeleton.worlds` does (WE blends a bone by its rules, then
    /// steps it: 0x140200df2, 0x14020136e). `ik` as `SceneSkeleton.worlds`: a held bone skips
    /// its rules and step (0x1402006ef jumps past them), a chain's root solves after its step.
    mutating func worlds(locals: [simd_float4x4], skeleton: SceneSkeleton, frame: Frame?,
                         adjust: ((Int, simd_float4x4, [simd_float4x4]) -> simd_float4x4)? = nil,
                         ik: ScenePuppetIK? = nil) -> [simd_float4x4] {
        let scale = frame.map { Self.meanScale($0.objectWorld) } ?? 1
        var worlds: [simd_float4x4] = []
        worlds.reserveCapacity(locals.count)
        for index in locals.indices {
            if let held = ik?.heldModel(index) {
                worlds.append(held)
                continue
            }
            let parent = index < skeleton.parents.count ? skeleton.parents[index] : nil
            var model = parent.map { worlds[$0] * locals[index] } ?? locals[index]
            if let adjust { model = adjust(index, model, worlds) }
            if index < constraints.count, let constraint = constraints[index] {
                if let frame, index < frame.previousWorlds.count {
                    transforms[index] = Self.step(constraint, state: &states[index], world: frame.objectWorld * model,
                                                  previous: frame.previousWorlds[index], delta: frame.delta, scale: scale)
                }
                if let transform = transforms[index] { model = model * transform }
            }
            worlds.append(model)
            ik?.posed(bone: index, worlds: &worlds)
        }
        return worlds
    }

    /// `applyBonePhysicsImpulse` (0x140210990): `linear` joins the bone's velocity, and its
    /// angular velocity turns by the Euler angles `angularDegrees`.
    mutating func applyImpulse(bone: Int, linear: SIMD3<Float>, angularDegrees: SIMD3<Float>) {
        guard states.indices.contains(bone) else { return }
        states[bone].velocity += linear
        states[bone].angularVelocity = states[bone].angularVelocity
            * SceneBonePhysicsMath.quaternion(euler: angularDegrees * SceneBonePhysicsMath.degrees)
    }

    /// `resetBonePhysicsSimulation` (0x140210e10): the bone's state as it loaded.
    mutating func reset(bone: Int) {
        guard states.indices.contains(bone) else { return }
        states[bone] = State()
    }

    /// The mean length of the object's axes, which scales gravity and the maximum distance
    /// (0x140200462…0x1402004fa).
    static func meanScale(_ world: simd_float4x4) -> Float {
        let x = simd_length(SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z))
        let y = simd_length(SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z))
        let z = simd_length(SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z))
        return (y + x + z) / 3
    }

    /// One bone's step: `world` is its world matrix posed from the animation and its parents'
    /// physics this frame, `previous` its final one last frame. Returns the transform `P` its
    /// model matrix takes (`model · P`).
    static func step(_ constraint: MDLBonePhysics, state: inout State, world: simd_float4x4, previous: simd_float4x4,
                     delta: Float, scale: Float) -> simd_float4x4 {
        let basis = simd_float3x3(SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z),
                                  SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z),
                                  SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z))
        let origin = SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
        let inverse = basis.inverse
        // Where the tip was last frame, in the bone's space this frame.
        let previousTipWorld = previous * SIMD4(constraint.tip, 1)
        let previousTip = inverse * (SIMD3(previousTipWorld.x, previousTipWorld.y, previousTipWorld.z) - origin)
        // Where the simulated rotation and offset put it now; gravity pulls the target across it.
        let rotatedTip = SceneBonePhysicsMath.euler(state.angles) * constraint.tip
        var target = rotatedTip + inverse * state.offset
        var velocity = state.velocity
        if constraint.flags.contains(.gravity) {
            let gravity = inverse * constraint.gravityDirection * (constraint.mass * scale)
            let along = SceneBonePhysicsMath.unit(rotatedTip)
            target -= gravity - along * simd_dot(along, gravity)
            if constraint.flags.contains(.translation) {
                velocity += constraint.gravityDirection * (constraint.mass * delta * 1000)
            }
        }
        if constraint.flags.contains(.rotation) {
            let lag = Lag(distance: min(simd_length(target - previousTip), delta * 900),
                          alignment: SceneBonePhysicsMath.alignment(from: SceneBonePhysicsMath.unit(target),
                                                                    to: SceneBonePhysicsMath.unit(previousTip)))
            rotate(constraint, state: &state, lag: lag, delta: delta)
        }
        if constraint.flags.contains(.translation) {
            let previousOrigin = SIMD3(previous.columns.3.x, previous.columns.3.y, previous.columns.3.z)
            translate(constraint, state: &state, velocity: velocity, moved: origin - previousOrigin, world: world,
                      delta: delta, scale: scale)
        }
        let rotation = SceneBonePhysicsMath.euler(state.angles)
        return simd_float4x4(columns: (SIMD4(rotation.columns.0, 0), SIMD4(rotation.columns.1, 0),
                                       SIMD4(rotation.columns.2, 0), SIMD4(inverse * state.offset, 1)))
    }

    /// How far the tip lags behind where it was, and the turn back there.
    struct Lag {
        var distance: Float
        var alignment: simd_quatf
    }

    /// The rotation (0x140201a37… rigid, 0x140202a44… spring): the lag and, for a spring, the
    /// pull back to the rest pose turn the angular velocity; the torque limit; a step of it
    /// (normalised to 60 frames a second) turns the angles; the angle limits and locked axes;
    /// then friction slows it.
    static func rotate(_ constraint: MDLBonePhysics, state: inout State, lag: Lag, delta: Float) {
        typealias M = SceneBonePhysicsMath
        let spring = !constraint.flags.contains(.rigid)
        var velocity = state.angularVelocity
        velocity = velocity * M.slerp(M.identity, lag.alignment, min(lag.distance * constraint.rotationInertia * M.degrees, 1))
        if spring {
            let rest = M.quaternion(euler: -state.angles)
            velocity = velocity * M.slerp(M.identity, rest, min(constraint.rotationStiffness * M.degrees * delta, 1))
        }
        if constraint.flags.contains(.limitTorque) { velocity = M.limitTorque(velocity, degrees: constraint.maxTorque) }
        let turn = M.slerp(M.identity, velocity, min(delta / 0.016666668, 1))
        var angles = M.angles(simd_float3x3(turn) * M.euler(state.angles))
        let locks: [MDLBonePhysics.Flags] = [.lockRotationX, .lockRotationY, .lockRotationZ]
        if spring {
            for axis in 0..<3 { angles[axis] = constraint.flags.contains(locks[axis]) ? 0 : M.wrap(angles[axis]) }
        }
        if constraint.flags.contains(.limitAngles) {
            let unclamped = angles
            angles = simd_min(simd_max(angles, constraint.minAngles), constraint.maxAngles)
            // The excess stops: its rotation comes off the angular velocity.
            velocity = M.quaternion(euler: unclamped - angles).conjugate * velocity
        }
        if !spring {
            for axis in 0..<3 where constraint.flags.contains(locks[axis]) { angles[axis] = 0 }
        }
        state.angles = angles
        state.angularVelocity = M.slerp(velocity, M.identity, min(delta * constraint.rotationFriction, 1))
    }

    /// The offset (0x140202254… rigid, 0x1402034a9… spring): it keeps `1 − inertia` of where the
    /// bone moved from, a spring pulls its velocity back, the velocity moves it; the locked axes
    /// and the maximum distance; then friction slows the velocity. `moved` is how far the bone's
    /// origin went since last frame, `velocity` the state's with this frame's gravity.
    static func translate(_ constraint: MDLBonePhysics, state: inout State, velocity: SIMD3<Float>, moved: SIMD3<Float>,
                          world: simd_float4x4, delta: Float, scale: Float) {
        var velocity = velocity
        let kept = state.offset - (state.offset + moved) * constraint.translationInertia
        var offset: SIMD3<Float>
        if constraint.flags.contains(.rigid) {
            offset = kept + velocity * delta
        } else {
            velocity -= kept * (delta * constraint.translationStiffness)
            offset = kept + velocity * delta
        }
        let locks: [MDLBonePhysics.Flags] = [.lockTranslationX, .lockTranslationY, .lockTranslationZ]
        for axis in 0..<3 where constraint.flags.contains(locks[axis]) {
            let column = world[axis]
            let direction = SIMD3(column.x, column.y, column.z)
            offset -= direction * (simd_dot(offset, direction) / simd_dot(direction, direction))
        }
        let limit = scale * constraint.maxDistance
        if limit > 0, limit * limit < simd_length_squared(offset) {
            offset *= limit / simd_length(offset)
        }
        velocity -= velocity * min(delta * constraint.translationFriction, 1)
        state.offset = offset
        state.velocity = velocity
    }
}
