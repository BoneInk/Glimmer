import simd

/// Puppet Warp inverse kinematics (docs/models-plan.md §2.16): WE's kinematic-chain solver
/// (0x140271910) on a puppet's `MDLS` IK sets, run in the puppet update's bone loop
/// (0x14020365b…0x1402037a6) only while an animation layer plays, as WE does.
///
/// Per bone, parents first, as `SceneSkeleton.worlds` / `SceneBonePhysics.worlds` pose them:
/// - A bone the compiler flags 0x2 (it hangs on its link) that roots no set is **held**: it keeps
///   the model-space matrix the solver last wrote (WE's persistent rig+0x2c8, 0x1402006ef…
///   0x140200a53), skipping its clip track, the blend rules and its physics.
/// - Any other bone is posed as usual, and when it roots a set (bone+0xd4, written by the loader
///   at 0x140262d07 for the set's first bone) the solver runs after its physics: the set's link
///   setup (0x14026f4c0, not implemented: it only acts on link constraints no capture has), the
///   rope step when the set's flag 0x1 is on (0x14026eb60, `rope`), then up to 10 FABRIK
///   iterations and the write-back. The chain's other bones come later in the loop and are held.
///
/// Positions are model space; a matrix's translation is its column 3 (WE's row 3) and its basis
/// columns are WE's rows (the convention of `SceneBonePhysicsMath`). Render thread only.
final class ScenePuppetIK {
    /// One kinematic chain of a set (the `MDLS` joint record, 40 bytes at runtime).
    struct Joint: Equatable {
        /// The chain's end, the effector.
        var bone: Int
        /// 0x1: the effector follows its IK target link; 0x2: never laid straight; 0x4: a rope
        /// chain (`rope`).
        var flags: UInt32
        /// The chain's length: at or past it the target is out of reach and the chain lies
        /// straight (0x140271d74).
        var length: Float
        /// The nearest the effector gets to the root: a nearer target is pushed out to it
        /// (0x140271b8a; only when positive).
        var minimumDistance: Float
        /// Root first, the effector last.
        var bones: [Int]
    }

    struct Element: Equatable {
        /// The chain's base, which every joint's backward pass leaves at their mean.
        var bone: Int
        var joints: [Joint]
    }

    struct ChainSet: Equatable {
        /// The bone the set runs at; the forward pass starts there.
        var bone: Int
        /// Its links (the link setup's and the bend rules').
        var links: [Int]
        var elements: [Element]
        /// The loader's flag 0x1 (0x140263338): a rope joint is in the set.
        var hasRope: Bool
    }

    /// A rule hung on a link (an `MDLS` constraint on a bone with flag 0x2, 0x1402629a2): with
    /// flag 0x10000 the solver keeps a target's chain bent away from `bone`'s x axis
    /// (0x14027248d…0x14027299f).
    struct LinkRule: Equatable {
        var flags: UInt32
        var a: UInt32
        var bone: Int
        var f0: Float
        var f1: Float
    }

    /// A rope chain's passes (0x14026eb60 before the solver, 0x14026e340 inside it), which share
    /// this solver's model matrices. Nil until the rope is built.
    protocol RopePass: AnyObject {
        func step(set: ChainSet, ik: ScenePuppetIK, delta: Float, objectWorld: simd_float4x4)
        func constrain(joint: Joint, ik: ScenePuppetIK, forward: Bool)
    }

    static let maximumIterations = 10

    let sets: [ChainSet]
    /// Per bone: the set it roots.
    let setOfBone: [Int?]
    /// Per bone: whether it is held (flag 0x2 without a set).
    let held: [Bool]
    /// Per bone: the distance to its parent (the `MDLS` per-bone floats at model+0xd8).
    let lengths: [Float]
    /// Per bone: each child's rest direction in the bone's space (the `MDLS` u32-keyed maps at
    /// model+0xf0, keyed by the child).
    let restAxes: [[Int: SIMD3<Float>]]
    /// Per bone: its first IK-target link (type 0) and its first orientation-controller link
    /// (type 1): the two bone → link maps (rig+0x128, rig+0x170).
    let targetLink: [Int: Int]
    let poleLink: [Int: Int]
    /// Per link: the rules hung on it.
    let linkRules: [[LinkRule]]
    /// Per bone: its `MDLS` properties.
    let properties: [MDLBonePhysics?]
    /// The links' rest transforms, which a layer whose clip has no link track leaves.
    let linkBind: [SceneBoneTransform]
    let parents: [Int?]
    /// Per link: its bone.
    let linkBones: [Int]

    /// Model-space matrices as WE keeps them from frame to frame: every bone's as the loop last
    /// posed it, a held bone's as the solver last wrote it.
    private(set) var models: [simd_float4x4]
    /// The links' model-space matrices this frame (rig+0x2e0): their tracks' rotation and
    /// translation (0x140200520…0x14020063d), without scale.
    private(set) var links: [simd_float4x4]
    weak var rope: RopePass?

    /// Nil for a skeleton without an IK set.
    init?(_ skeleton: MDLSkeleton) {
        let count = skeleton.bones.count
        guard !skeleton.ikSets.isEmpty, count > 0 else { return nil }
        func bone(_ value: UInt32) -> Int { min(Int(value), count - 1) }
        sets = skeleton.ikSets.map { set in
            ChainSet(bone: bone(set.bone), links: set.links.map { Int($0) },
                     elements: set.elements.map { element in
                         Element(bone: bone(element.bone), joints: element.joints.map { joint in
                             Joint(bone: bone(joint.bone), flags: joint.flags, length: joint.f0,
                                   minimumDistance: joint.f1, bones: joint.bones.map(bone))
                         })
                     },
                     hasRope: set.elements.contains { $0.joints.contains { $0.flags & 0x4 != 0 } })
        }
        var setOfBone = [Int?](repeating: nil, count: count)
        for (index, set) in sets.enumerated() { setOfBone[set.bone] = index }
        self.setOfBone = setOfBone
        held = (0..<count).map { skeleton.bones[$0].flags & 0x2 != 0 && setOfBone[$0] == nil }
        lengths = (0..<count).map { $0 < skeleton.mapIDs.count ? Float(bitPattern: skeleton.mapIDs[$0]) : 0 }
        restAxes = (0..<count).map { index in
            guard index < skeleton.maps.count else { return [:] }
            var axes: [Int: SIMD3<Float>] = [:]
            for entry in skeleton.maps[index] where axes[Int(entry.key)] == nil { axes[Int(entry.key)] = entry.value }
            return axes
        }
        var targets: [Int: Int] = [:], poles: [Int: Int] = [:]
        for (index, link) in skeleton.links.enumerated() {
            if link.type == 0, targets[Int(link.bone)] == nil { targets[Int(link.bone)] = index }
            if link.type == 1, poles[Int(link.bone)] == nil { poles[Int(link.bone)] = index }
        }
        targetLink = targets
        poleLink = poles
        var rules = [[LinkRule]](repeating: [], count: skeleton.links.count)
        for constraint in skeleton.constraints where Int(constraint.bone) < count
            && skeleton.bones[Int(constraint.bone)].flags & 0x2 != 0 {
            // 0x1402629b4: the bone's link of type 0.
            guard let link = targets[Int(constraint.bone)] else { continue }
            rules[link].append(LinkRule(flags: constraint.flags, a: constraint.a, bone: bone(constraint.b),
                                        f0: constraint.f0 ?? 0, f1: max(constraint.f1 ?? 0, 0)))
        }
        linkRules = rules
        properties = skeleton.bones.map { MDLBonePhysics(properties: $0.properties) }
        linkBones = skeleton.links.map { Int($0.bone) }
        linkBind = skeleton.links.map { SceneBoneTransform(matrix: $0.matrix) }
        parents = skeleton.bones.enumerated().map { index, bone in bone.parentIndex.flatMap { $0 < index ? $0 : nil } }
        models = SceneSkeleton(skeleton).restWorld
        links = skeleton.links.map(\.matrix)
    }

    // MARK: - The bone loop

    /// The frame's delta and object world, for the rope step.
    private(set) var delta: Float = 0
    private(set) var objectWorld = matrix_identity_float4x4

    /// A frame the solver runs in: the links' pose from the layers
    /// (`SceneAnimationLayerStack.linkPose`), the delta and the object's world.
    func beginFrame(links pose: [SceneBoneTransform], delta: Float, objectWorld: simd_float4x4) {
        self.delta = delta
        self.objectWorld = objectWorld
        links = pose.map { transform in
            var matrix = simd_float4x4(transform.rotation)
            matrix.columns.3 = SIMD4(transform.translation, 1)
            return matrix
        }
    }

    /// A held bone's matrix, which replaces its posed one; nil for any other bone.
    func heldModel(_ bone: Int) -> simd_float4x4? {
        bone < held.count && held[bone] ? models[bone] : nil
    }

    /// After bone `bone` is posed (and stepped) into `worlds`: keeps it, and runs its set.
    func posed(bone: Int, worlds: inout [simd_float4x4]) {
        guard bone < models.count, bone < worlds.count else { return }
        models[bone] = worlds[bone]
        guard let set = setOfBone[bone] else { return }
        solve(sets[set])
        for index in worlds.indices { worlds[index] = models[index] }
    }

    // MARK: - The solver (0x140271910)

    func position(_ bone: Int) -> SIMD3<Float> {
        let t = models[bone].columns.3
        return SIMD3(t.x, t.y, t.z)
    }

    func setPosition(_ bone: Int, _ p: SIMD3<Float>) {
        models[bone].columns.3 = SIMD4(p, models[bone].columns.3.w)
    }

    func linkPosition(_ link: Int) -> SIMD3<Float> {
        let t = links[link].columns.3
        return SIMD3(t.x, t.y, t.z)
    }

    private func flags(_ bone: Int) -> MDLBonePhysics.Flags { properties[bone]?.flags ?? [] }

    func solve(_ set: ChainSet) {
        if set.hasRope { rope?.step(set: set, ik: self, delta: delta, objectWorld: objectWorld) }
        let root = position(set.bone)
        for iteration in 0..<Self.maximumIterations {
            for element in set.elements.reversed() {
                var sum = SIMD3<Float>.zero
                var count: Float = 0
                for joint in element.joints.reversed() {
                    if joint.flags & 0x4 != 0 {
                        rope?.constrain(joint: joint, ik: self, forward: false)
                        continue
                    }
                    backward(joint, base: element.bone)
                    sum += position(element.bone)
                    count += 1
                }
                if count > 0 { setPosition(element.bone, sum / count) }
            }
            if iteration == 0 { applyBendRules(set) }
            if forward(set, root: root) { break }
        }
        writeBack(set)
    }

    /// One joint's backward pass (0x140271a9a…0x14027233e): the effector onto its target, then
    /// each parent placed its length from its child, toward where it was (FABRIK), the
    /// orientation controller choosing the bend; out of reach, the chain laid straight.
    private func backward(_ joint: Joint, base: Int) {
        let bones = joint.bones
        let a = position(base)
        var b: SIMD3<Float>
        if joint.flags & 0x1 != 0, let link = targetLink[joint.bone] { b = linkPosition(link) } else { b = position(joint.bone) }
        var distance = simd_length(b - a)
        let n = (b - a) / distance
        if joint.minimumDistance > 0, joint.minimumDistance > distance {
            b += n * (joint.minimumDistance - distance)
            distance = joint.minimumDistance
        }
        // The orientation controller across the line to the target (0x140271be8…0x140271d0b).
        var pole = SIMD3<Float>.zero
        if let link = poleLink[joint.bone] {
            let w = linkPosition(link) - b
            pole = w - n * simd_dot(w, n)
        }
        setPosition(joint.bone, b)
        guard bones.count > 1 else { return }
        if distance >= joint.length, joint.flags & 0x2 == 0 {
            for index in stride(from: bones.count - 1, through: 1, by: -1) {
                setPosition(bones[index - 1], position(bones[index]) - n * lengths[bones[index]])
            }
            return
        }
        let across = simd_cross(n, pole)
        let poleSquared = simd_length_squared(pole)
        var reach: Float = 0
        for index in stride(from: bones.count - 1, through: 1, by: -1) {
            let current = position(bones[index])
            var v = position(bones[index - 1]) - current
            if index > 1, flags(bones[index - 1]).contains(.ikConstrained) {
                var direction = -(v / simd_length(v))
                constrainAngle(&direction, joint: joint, index: index - 1)
                v = -direction
            }
            let length = lengths[bones[index]]
            if index == bones.count - 1 || joint.length * 0.5 > reach + length {
                if poleSquared > 0.01 {
                    let unit = across / simd_length(across)
                    v -= unit * simd_dot(v, unit)
                }
                let side = simd_dot(v, pole)
                // WE's pole isn't a unit vector: this is its reflection only in name.
                if side < 0 { v -= 2 * pole * side }
            }
            setPosition(bones[index - 1], current + v / simd_length(v) * length)
            reach += length
        }
    }

    /// The forward pass (0x14027299f…0x140272de8): every chain from its base, the set's own bone
    /// back where it was posed; true when every targeted effector is within √0.1 of its target.
    private func forward(_ set: ChainSet, root: SIMD3<Float>) -> Bool {
        var converged = true
        for element in set.elements {
            for joint in element.joints {
                if joint.flags & 0x4 != 0 {
                    rope?.constrain(joint: joint, ik: self, forward: true)
                    continue
                }
                let start = element.bone == set.bone ? root : position(element.bone)
                setPosition(element.bone, start)
                let bones = joint.bones
                if bones.count != 1 {
                    for index in 0..<(bones.count - 1) {
                        let current = position(bones[index])
                        let next = position(bones[index + 1])
                        var direction = (next - current) / simd_length(next - current)
                        if index > 0, flags(bones[index]).contains(.ikConstrained) {
                            constrainAngle(&direction, joint: joint, index: index)
                        }
                        setPosition(bones[index + 1], current + direction * lengths[bones[index + 1]])
                    }
                }
                if joint.flags & 0x1 != 0, let link = targetLink[joint.bone],
                   simd_length_squared(position(joint.bone) - linkPosition(link)) > 0.1 {
                    converged = false
                }
            }
        }
        return converged
    }

    /// `ikce` (0x14026df30): the chain bone `bones[index]` turns from its parent's direction by
    /// `ikrminl`…`ikrmaxl` radians at most, about z (the direction's x and y; its length kept).
    private func constrainAngle(_ direction: inout SIMD3<Float>, joint: Joint, index: Int) {
        let bone = joint.bones[index]
        guard let parent = parents[bone], let limits = properties[bone] else { return }
        let up = SceneBonePhysicsMath.unit(position(bone) - position(parent))
        let frame = simd_float3x3(SceneBonePhysicsMath.alignment(from: SIMD3(1, 0, 0), to: up))
        let planar = SIMD3(direction.x, direction.y, 0)
        let length = simd_length(planar)
        let local = frame.inverse * (planar / length)
        let angle = atan2(local.y, local.x)
        var correction: Float = limits.ikMinimumAngle > angle ? limits.ikMinimumAngle - angle : 0
        if angle > limits.ikMaximumAngle {
            let other = limits.ikMaximumAngle - angle
            if correction == 0 || abs(correction) > abs(other) { correction = other }
        }
        guard correction != 0 else { return }
        let turned = frame * (simd_float3x3(simd_quatf(angle: correction, axis: SIMD3(0, 0, 1))) * local) * length
        direction.x = turned.x
        direction.y = turned.y
    }

    /// Iteration 0's link rules with flag 0x10000 (0x14027248d…0x140272996): along a targeted
    /// chain, within the distance from its root to the rule's bone, a joint on the side of that
    /// bone's x axis is mirrored across the line through its neighbours.
    private func applyBendRules(_ set: ChainSet) {
        for link in set.links where link < linkRules.count {
            let bone = linkBone(link)
            for rule in linkRules[link] where rule.flags & 0x10000 != 0 {
                for element in set.elements {
                    for joint in element.joints where joint.bone == bone {
                        bend(joint, away: rule.bone)
                    }
                }
            }
        }
    }

    private func linkBone(_ link: Int) -> Int { link < linkBones.count ? linkBones[link] : -1 }

    private func bend(_ joint: Joint, away reference: Int) {
        let bones = joint.bones
        guard bones.count > 2 else { return }
        let axisRow = models[reference].columns.0
        let axis = SIMD3(axisRow.x, axisRow.y, axisRow.z) / simd_length(axisRow)
        let reach = simd_length(position(reference) - position(bones[0]))
        var remaining = reach
        var index = 1
        var budget = 32
        while budget > 0, index + 1 < bones.count {
            remaining -= lengths[bones[index]]
            if 0 > remaining { break }
            let previous = position(bones[index - 1])
            let span = position(bones[index + 1]) - previous
            let normal = simd_cross(simd_cross(span, axis), span)
            if simd_length_squared(normal) >= 0.01 {
                let unit = normal / simd_length(normal)
                let current = position(bones[index])
                let side = simd_dot(unit, current - previous)
                if side > 1.1920929e-7 {
                    setPosition(bones[index], current - 2 * unit * side)
                    remaining = reach
                    index = 1
                }
            }
            budget -= 1
            index += 1
        }
    }

    // MARK: - The write-back (0x140272dee…0x140273d6e)

    /// The chain bones turned from their rest axis onto the solved direction to the next bone;
    /// a targeted effector takes its target's orientation, turned to point at the target as it
    /// overstretches when `ikr` is on; a base shared by several chains takes their mean turn.
    private func writeBack(_ set: ChainSet) {
        for element in set.elements {
            let shared = element.joints.count != 1
            for joint in element.joints {
                let bones = joint.bones
                if bones.count > 1 {
                    for index in (shared ? 1 : 0)..<(bones.count - 1) {
                        turn(bones[index], toward: bones[index + 1])
                    }
                }
                if joint.flags & 0x1 != 0 { orientEffector(joint) }
            }
            if shared, !element.joints.isEmpty {
                var mean = SceneBonePhysicsMath.identity
                let weight = 1 / Float(element.joints.count)
                for joint in element.joints where joint.bones.count > 1 {
                    let child = joint.bones[1]
                    let direction = SceneBonePhysicsMath.unit(position(child) - position(element.bone))
                    let axis = restAxes[element.bone][child] ?? SIMD3(1, 0, 0)
                    mean = SceneBonePhysicsMath.slerp(mean, SceneBonePhysicsMath.alignment(from: axis, to: direction), weight)
                }
                setBasis(element.bone, simd_float3x3(mean))
            }
        }
    }

    /// The bone's basis becomes the turn from its rest axis toward `child` onto the solved
    /// direction (WE's product with the rig+0x328 matrix, the identity in every editor rig [?]).
    private func turn(_ bone: Int, toward child: Int) {
        let direction = SceneBonePhysicsMath.unit(position(child) - position(bone))
        let axis = restAxes[bone][child] ?? SIMD3(1, 0, 0)
        setBasis(bone, simd_float3x3(SceneBonePhysicsMath.alignment(from: axis, to: direction)))
    }

    private func orientEffector(_ joint: Joint) {
        let effector = joint.bone
        let effectorFlags = flags(effector)
        if effectorFlags.contains(.ikFreeEndpoint) {
            // 0x14027371e: a free end keeps its parent's orientation.
            let bones = joint.bones
            guard bones.count > 2 else { return }
            let parent = models[bones[bones.count - 2]]
            models[effector].columns.0 = parent.columns.0
            models[effector].columns.1 = parent.columns.1
            models[effector].columns.2 = parent.columns.2
            return
        }
        guard let link = targetLink[effector] else { return }
        let target = links[link]
        func row(_ c: SIMD4<Float>) -> SIMD3<Float> { SceneBonePhysicsMath.unit(SIMD3(c.x, c.y, c.z)) }
        var basis = simd_float3x3(row(target.columns.0), row(target.columns.1), row(target.columns.2))
        if effectorFlags.contains(.ikEndRotation) {
            let toTarget = linkPosition(link) - position(effector)
            let squared = simd_length_squared(toTarget)
            if squared > 1 {
                let distance = squared.squareRoot()
                let distanceForFullTurn = properties[effector]?.ikRotationDistance ?? 50
                let t = min((distance - 1) / distanceForFullTurn, 1)
                let pointing = SceneBonePhysicsMath.alignment(from: SIMD3(1, 0, 0), to: toTarget / distance)
                basis = simd_float3x3(SceneBonePhysicsMath.slerp(simd_quatf(basis), pointing, t))
            }
        }
        setBasis(effector, basis)
    }

    private func setBasis(_ bone: Int, _ basis: simd_float3x3) {
        models[bone].columns.0 = SIMD4(basis.columns.0, 0)
        models[bone].columns.1 = SIMD4(basis.columns.1, 0)
        models[bone].columns.2 = SIMD4(basis.columns.2, 0)
    }
}

extension SceneAnimationLayerStack {
    /// The links' pose from the visible layers, as the bones' (`apply`): the track at the layer's
    /// position, replacing, blended or added by its weight; a link without a track keeps `bind`
    /// (WE blends the links' SoA with the bones', rig+0x248).
    func linkPose(bind: [SceneBoneTransform]) -> [SceneBoneTransform] {
        var pose = bind
        for layer in layers where layer.visible {
            var copy = layer
            let weight = copy.weight()
            guard weight != 0 else { continue }
            let (clip, first) = source(of: layer.clip)
            guard let tracks = clip.linkTracks else { continue }
            let position = layer.clock.samplePosition
            for link in pose.indices where link < tracks.count {
                let track = tracks[link]
                let frames = track.samples.count / MDLBonePose.floatCount
                guard !track.isDisabled, frames > 0 else { continue }
                func frame(_ f: Int32) -> Int { max(0, min(Int(f) + first, frames - 1)) }
                let sample = SceneBoneTransform.blend(SceneBoneTransform(track.pose(at: frame(position.frame0))),
                                                      SceneBoneTransform(track.pose(at: frame(position.frame1))),
                                                      position.fraction)
                if layer.additive {
                    pose[link] = Self.add(sample, over: pose[link], bind: bind[link], weight: weight)
                } else if weight == 1 {
                    pose[link] = sample
                } else {
                    pose[link] = SceneBoneTransform.blend(pose[link], sample, weight)
                }
            }
        }
        return pose
    }
}
