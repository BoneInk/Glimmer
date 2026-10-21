import Foundation
import simd

/// A bone's kinematic chain as Wallpaper Engine's Puppet Warp editor offers it (Edit Constraints ›
/// Physics › Simulation mode "Kinematic chain"; docs/models-plan.md §2.14, §2.16): the bone is the
/// chain's end and the `limbDepth` bones above it bend so that it reaches its **IK target**, the
/// controller each clip keys; "Rope" makes the chain a rope that hangs and swings instead. The
/// keys are the compiled ones the player reads (`ik`, `ikd`, `ikg`, `ikr`, `ikrd`, `ikse`, `ikfe`,
/// `ge`, `m`, `tf`), the defaults `makeDefaultPhysicsConstraintSettings`'s (`ui/dist/scripts/
/// scripts.js`). The controllers' keys are offsets from their rest place, as WE's editor keys a
/// controller's Origin.
public struct PuppetBoneIK: Codable, Hashable, Sendable {
    public enum Behavior: String, Codable, CaseIterable, Sendable {
        /// `ikm` "": the chain reaches for the target.
        case inverseKinematics
        /// `ikm` "rope".
        case rope
    }

    /// WE's presets (`ik2limbs`, `ikrope4`).
    public enum Preset: String, CaseIterable, Sendable {
        case arm = "ik2limbs"
        case rope = "ikrope4"
    }

    /// One controller's key: its offset from its rest place and its angle (radians, about z).
    public struct Key: Codable, Hashable, Sendable {
        public var offset: SIMD2<Float>
        public var angle: Float

        public init(offset: SIMD2<Float> = .zero, angle: Float = 0) {
            self.offset = offset
            self.angle = angle
        }

        static func lerp(_ a: Key, _ b: Key, _ t: Float) -> Key {
            Key(offset: a.offset + (b.offset - a.offset) * t, angle: a.angle + (b.angle - a.angle) * t)
        }
    }

    public enum Controller: String, Codable, CaseIterable, Sendable {
        /// The type-0 link: where the chain's end reaches (WE's target diamond).
        case target
        /// The type-1 link: which side the chain bends to (WE's orientation controller).
        case orientation
    }

    public var behavior: Behavior = .inverseKinematics
    /// `ikd` (1…6): how many bones above this one the chain holds.
    public var limbDepth = 2
    /// `ikg`.
    public var orientationController = true
    /// `ikr`, `ikrd` (1…100 px).
    public var rotateWhenOverstretched = true
    public var fullRotationDistance: Float = 25
    /// The rope's `ge`, `ikse`, `ikfe` (only without stretch), `m` (1…2000), `tf` (0…99).
    public var gravity = false
    public var stretch = true
    public var freeEndpoint = false
    public var mass: Float = 20
    public var friction: Float = 20
    /// The orientation controller's rest place in the mesh's space; nil: beside the chain's
    /// middle bone, a segment's length across it.
    public var orientationRest: SIMD2<Float>?
    /// Per clip id, each controller's keys by frame.
    public var targetKeys: [UInt64: [Int: Key]] = [:]
    public var orientationKeys: [UInt64: [Int: Key]] = [:]

    public init() {}

    public init(preset: Preset) {
        self.init()
        if preset == .rope {
            behavior = .rope
            limbDepth = 4
            gravity = true
        }
    }

    /// Whether the chain has an orientation controller (WE's link of type 1).
    public var hasOrientationController: Bool { behavior == .inverseKinematics && orientationController }

    public func keys(_ controller: Controller) -> [UInt64: [Int: Key]] {
        controller == .target ? targetKeys : orientationKeys
    }

    /// The controller's key in clip `clip` at `frame`: a key, else the keys around it
    /// interpolated, else the nearest key; no offset without keys.
    public func key(_ controller: Controller, clip: UInt64, at frame: Float) -> Key {
        guard let keys = keys(controller)[clip], !keys.isEmpty else { return Key() }
        let frames = keys.keys.sorted()
        let before = frames.last { Float($0) <= frame }
        let after = frames.first { Float($0) >= frame }
        switch (before, after) {
        case let (a?, b?) where a != b: return Key.lerp(keys[a]!, keys[b]!, (frame - Float(a)) / Float(b - a))
        case let (a?, _): return keys[a]!
        case let (_, b?): return keys[b]!
        default: return Key()
        }
    }

    public mutating func setKey(_ controller: Controller, clip: UInt64, frame: Int, to key: Key?) {
        var keys = self.keys(controller)[clip] ?? [:]
        keys[frame] = key
        if controller == .target { targetKeys[clip] = keys.isEmpty ? nil : keys } else { orientationKeys[clip] = keys.isEmpty ? nil : keys }
    }

    // MARK: Properties JSON

    /// The keys WE's compiler writes for the chain (it drops `ikm` and keeps `ikfe` only for a
    /// rope without stretch, 0x140011a04…0x140011bbc).
    public var properties: [String: SceneJSONValue] {
        var keys: [String: SceneJSONValue] = [
            "ik": .bool(true), "ikce": .bool(false), "ikd": .number(Double(limbDepth)),
            "ikg": .bool(orientationController), "ikr": .bool(rotateWhenOverstretched),
            "ikrd": .number(Double(fullRotationDistance)), "ikse": .bool(stretch),
            "ge": .bool(gravity), "m": .number(Double(mass)), "tf": .number(Double(friction)),
            "se": .bool(false), "re": .bool(false),
        ]
        if behavior == .rope, !stretch { keys["ikfe"] = .bool(freeEndpoint) }
        return keys
    }

    /// The keys this type owns; the rest of a bone's properties are kept apart.
    static let keys: Set<String> = ["ik", "ikce", "ikd", "ikg", "ikr", "ikrd", "ikse", "ikfe", "ikm", "ikcp", "ikcpn", "ikrmin",
                                    "ikrmax", "ge", "m", "tf", "se", "re", "preset", "layout", "presetresponsiveness"]

    /// The chain of a bone's properties (`ik` true); nil for any other bone. Values of the wrong
    /// type keep the defaults, as the player's reader does.
    public init?(properties: [String: SceneJSONValue], rope: Bool) {
        func bool(_ key: String) -> Bool? { if case .bool(let b)? = properties[key] { return b } else { return nil } }
        func number(_ key: String) -> Float? { if case .number(let n)? = properties[key] { return Float(n) } else { return nil } }
        guard bool("ik") == true else { return nil }
        self.init()
        behavior = rope ? .rope : .inverseKinematics
        if let value = number("ikd") { limbDepth = max(Int(value), 1) }
        orientationController = bool("ikg") ?? orientationController
        rotateWhenOverstretched = bool("ikr") ?? rotateWhenOverstretched
        if let value = number("ikrd") { fullRotationDistance = value }
        stretch = bool("ikse") ?? stretch
        freeEndpoint = bool("ikfe") ?? false
        gravity = bool("ge") ?? false
        if let value = number("m") { mass = value }
        if let value = number("tf") { friction = value }
    }
}

// MARK: - The compiled form

/// What `resourcecompiler64.exe` makes of a rig's kinematic chains (capture 534 and 536): per
/// chain bone flag 0x2, each bone's length to its parent and its children's directions (the `MDLS`
/// maps), the controllers as links (the orientation controller's type 1 first, then the
/// target's type 0, at the end bone's rest place), and an IK set on the chain's first bone.
public struct PuppetKinematicsLayout: Sendable {
    public struct Link: Hashable, Sendable {
        public var bone: Int
        public var type: UInt32
        public var controller: PuppetBoneIK.Controller
        /// Its rest place in the mesh's space.
        public var rest: SIMD2<Float>
    }

    public struct Joint: Hashable, Sendable {
        public var bone: Int
        public var flags: UInt32
        public var length: Float
        public var bones: [Int]
    }

    public struct ChainSet: Hashable, Sendable {
        public var bone: Int
        public var links: [Int]
        public var joints: [Joint]
    }

    public var links: [Link] = []
    public var sets: [ChainSet] = []
    /// Per bone: its distance to its parent.
    public var lengths: [Float] = []
    /// Per bone: each child's unit direction in the bone's space.
    public var restAxes: [[(child: Int, axis: SIMD3<Float>)]] = []
    public var chainBones: Set<Int> = []

    public var isEmpty: Bool { sets.isEmpty }

    public init(_ document: PuppetDocument) {
        let worlds = document.bindWorlds
        for (bone, item) in document.bones.enumerated() {
            guard let ik = item.ik else { continue }
            var chain = [bone]
            var current = item.parent
            while chain.count <= ik.limbDepth, let parent = current {
                chain.insert(parent, at: 0)
                current = document.bones[parent].parent
            }
            guard chain.count > 1 else { continue }
            let end = PuppetMath.origin(of: worlds[bone])
            if ik.hasOrientationController {
                let rest = ik.orientationRest ?? Self.defaultOrientation(chain: chain, worlds: worlds)
                links.append(Link(bone: bone, type: 1, controller: .orientation, rest: rest))
            }
            links.append(Link(bone: bone, type: 0, controller: .target, rest: end))
            let target = links.count - 1
            chainBones.formUnion(chain)
            let length = chain.dropFirst().reduce(Float(0)) { $0 + simd_length(document.bones[$1].local.translation) }
            let joint = Joint(bone: bone, flags: ik.behavior == .rope ? 0x5 : 0x1, length: length, bones: chain)
            if let index = sets.firstIndex(where: { $0.bone == chain[0] }) {
                sets[index].links.append(target)
                sets[index].joints.append(joint)
            } else {
                sets.append(ChainSet(bone: chain[0], links: [target], joints: [joint]))
            }
        }
        guard !sets.isEmpty else { return }
        lengths = document.bones.map { simd_length($0.local.translation) }
        restAxes = document.bones.indices.map { bone in
            document.children(of: bone).compactMap { child in
                let t = document.bones[child].local.translation
                return simd_length(t) > 0 ? (child, simd_normalize(t)) : nil
            }
        }
    }

    /// Beside the chain's middle bone, a segment's length across it (left of the chain).
    static func defaultOrientation(chain: [Int], worlds: [simd_float4x4]) -> SIMD2<Float> {
        let middle = PuppetMath.origin(of: worlds[chain[chain.count - 2]])
        let end = PuppetMath.origin(of: worlds[chain[chain.count - 1]])
        let along = end - middle
        return middle + SIMD2(-along.y, along.x)
    }

    /// Link `index`'s place and angle in clip `clip` at `frame`.
    public func linkPose(_ index: Int, document: PuppetDocument, clip: UInt64?, frame: Float) -> PuppetBoneIK.Key {
        let link = links[index]
        guard let clip, let ik = document.bones[link.bone].ik else { return PuppetBoneIK.Key(offset: link.rest) }
        var key = ik.key(link.controller, clip: clip, at: frame)
        key.offset += link.rest
        return key
    }
}

// MARK: - The preview's solver

/// The player's kinematic chains for the editor's preview (`ScenePuppetIK` and `ScenePuppetRope`,
/// WE's 0x140271910, 0x14026eb60, 0x14026e340): per bone, parents first, a chain bone that roots
/// no set keeps the matrix the solver last wrote, and a set's root solves once posed: FABRIK with
/// the orientation controller, straight out of reach, the end turned by "Rotate when
/// overstretched"; a rope's points move by Verlet under gravity (the scene's default, (0, −1, 0))
/// and are swept once a frame.
public final class PuppetIKSolver: @unchecked Sendable {
    public let layout: PuppetKinematicsLayout
    let ikByBone: [PuppetBoneIK?]
    let held: [Bool]
    let setOfBone: [Int?]
    let parents: [Int?]
    private var models: [simd_float4x4]
    private var links: [simd_float4x4] = []
    private var delta: Float = 0
    private var current: [SIMD3<Float>]
    private var previous: [SIMD3<Float>]
    private var started: Set<Int> = []

    public init?(_ document: PuppetDocument) {
        let layout = PuppetKinematicsLayout(document)
        guard !layout.isEmpty else { return nil }
        self.layout = layout
        ikByBone = document.bones.map(\.ik)
        var sets = [Int?](repeating: nil, count: document.bones.count)
        for (index, set) in layout.sets.enumerated() { sets[set.bone] = index }
        setOfBone = sets
        held = document.bones.indices.map { layout.chainBones.contains($0) && sets[$0] == nil }
        parents = document.bones.map(\.parent)
        models = document.bindWorlds
        current = Array(repeating: .zero, count: document.bones.count)
        previous = current
    }

    /// A frame: the links where the clip (or the layers) put them, and the step's delta.
    public func begin(links poses: [PuppetBoneIK.Key], delta: Float) {
        self.delta = delta
        links = poses.map { key in
            var m = PuppetMath.matrix(translation: .zero, euler: SIMD3(0, 0, key.angle), scale: SIMD3(repeating: 1))
            m.columns.3 = SIMD4(key.offset.x, key.offset.y, 0, 1)
            return m
        }
    }

    public func reset(_ document: PuppetDocument) {
        models = document.bindWorlds
        started = []
    }

    public func heldModel(_ bone: Int) -> simd_float4x4? { bone < held.count && held[bone] ? models[bone] : nil }

    public func posed(bone: Int, worlds: inout [simd_float4x4]) {
        guard bone < models.count, bone < worlds.count else { return }
        models[bone] = worlds[bone]
        guard let set = setOfBone[bone], links.count == layout.links.count else { return }
        solve(layout.sets[set])
        for index in worlds.indices { worlds[index] = models[index] }
    }

    /// Model-space matrices of `locals` with the chains solved (and `adjust`, the blend rules).
    public func worlds(locals: [simd_float4x4],
                       adjust: ((Int, simd_float4x4, [simd_float4x4]) -> simd_float4x4)? = nil) -> [simd_float4x4] {
        var worlds: [simd_float4x4] = []
        for index in locals.indices {
            if let held = heldModel(index) {
                worlds.append(held)
                continue
            }
            let parent = index < parents.count ? parents[index].flatMap { $0 < index ? $0 : nil } : nil
            let model = parent.map { worlds[$0] * locals[index] } ?? locals[index]
            worlds.append(adjust.map { $0(index, model, worlds) } ?? model)
            posed(bone: index, worlds: &worlds)
        }
        return worlds
    }

    private func position(_ bone: Int) -> SIMD3<Float> {
        SIMD3(models[bone].columns.3.x, models[bone].columns.3.y, models[bone].columns.3.z)
    }

    private func setPosition(_ bone: Int, _ p: SIMD3<Float>) { models[bone].columns.3 = SIMD4(p, 1) }

    private func targetLink(of bone: Int) -> Int? {
        layout.links.firstIndex { $0.bone == bone && $0.type == 0 }
    }

    private func poleLink(of bone: Int) -> Int? {
        layout.links.firstIndex { $0.bone == bone && $0.type == 1 }
    }

    private func linkPosition(_ link: Int) -> SIMD3<Float> {
        SIMD3(links[link].columns.3.x, links[link].columns.3.y, links[link].columns.3.z)
    }

    private func solve(_ set: PuppetKinematicsLayout.ChainSet) {
        // A rope moves only on a clock (a paused preview or a scrub holds it) [I: WE's update doesn't run then].
        if delta > 0, set.joints.contains(where: { $0.flags & 0x4 != 0 }) { ropeStep(set) }
        let root = position(set.bone)
        for _ in 0..<10 {
            var sum = SIMD3<Float>.zero
            var count: Float = 0
            for joint in set.joints.reversed() {
                if joint.flags & 0x4 != 0 {
                    ropeSweep(joint, forward: false)
                    continue
                }
                backward(joint, base: set.bone)
                sum += position(set.bone)
                count += 1
            }
            if count > 0 { setPosition(set.bone, sum / count) }
            var converged = true
            for joint in set.joints {
                if joint.flags & 0x4 != 0 {
                    ropeSweep(joint, forward: true)
                    continue
                }
                setPosition(set.bone, root)
                for index in 0..<(joint.bones.count - 1) {
                    let a = position(joint.bones[index]), b = position(joint.bones[index + 1])
                    setPosition(joint.bones[index + 1], a + simd_normalize(b - a) * layout.lengths[joint.bones[index + 1]])
                }
                if let link = targetLink(of: joint.bone), simd_length_squared(position(joint.bone) - linkPosition(link)) > 0.1 {
                    converged = false
                }
            }
            if converged { break }
        }
        writeBack(set)
    }

    private func backward(_ joint: PuppetKinematicsLayout.Joint, base: Int) {
        let bones = joint.bones
        let a = position(base)
        let b = targetLink(of: joint.bone).map(linkPosition) ?? position(joint.bone)
        let distance = simd_length(b - a)
        let n = (b - a) / distance
        var pole = SIMD3<Float>.zero
        if let link = poleLink(of: joint.bone) {
            let w = linkPosition(link) - b
            pole = w - n * simd_dot(w, n)
        }
        setPosition(joint.bone, b)
        if distance >= joint.length {
            for index in stride(from: bones.count - 1, through: 1, by: -1) {
                setPosition(bones[index - 1], position(bones[index]) - n * layout.lengths[bones[index]])
            }
            return
        }
        let across = simd_cross(n, pole)
        var reach: Float = 0
        for index in stride(from: bones.count - 1, through: 1, by: -1) {
            let current = position(bones[index])
            var v = position(bones[index - 1]) - current
            let length = layout.lengths[bones[index]]
            if index == bones.count - 1 || joint.length * 0.5 > reach + length {
                if simd_length_squared(pole) > 0.01 {
                    let unit = across / simd_length(across)
                    v -= unit * simd_dot(v, unit)
                }
                let side = simd_dot(v, pole)
                if side < 0 { v -= 2 * pole * side }
            }
            setPosition(bones[index - 1], current + v / simd_length(v) * length)
            reach += length
        }
    }

    private func align(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> simd_float3x3 {
        simd_float3x3(PuppetPhysicsMath.alignment(from: a, to: b))
    }

    private func setBasis(_ bone: Int, _ basis: simd_float3x3) {
        models[bone].columns.0 = SIMD4(basis.columns.0, 0)
        models[bone].columns.1 = SIMD4(basis.columns.1, 0)
        models[bone].columns.2 = SIMD4(basis.columns.2, 0)
    }

    private func writeBack(_ set: PuppetKinematicsLayout.ChainSet) {
        for joint in set.joints {
            let bones = joint.bones
            for index in 0..<(bones.count - 1) {
                let axis = layout.restAxes[bones[index]].first { $0.child == bones[index + 1] }?.axis ?? SIMD3(1, 0, 0)
                setBasis(bones[index], align(axis, PuppetPhysicsMath.unit(position(bones[index + 1]) - position(bones[index]))))
            }
            guard let ik = ikByBone[joint.bone] else { continue }
            if ik.behavior == .rope, !ik.stretch, ik.freeEndpoint {
                guard bones.count > 2 else { continue }
                let parent = models[bones[bones.count - 2]]
                models[joint.bone].columns.0 = parent.columns.0
                models[joint.bone].columns.1 = parent.columns.1
                models[joint.bone].columns.2 = parent.columns.2
                continue
            }
            guard let link = targetLink(of: joint.bone) else { continue }
            let target = links[link]
            var basis = simd_float3x3(SIMD3(target.columns.0.x, target.columns.0.y, target.columns.0.z),
                                      SIMD3(target.columns.1.x, target.columns.1.y, target.columns.1.z),
                                      SIMD3(target.columns.2.x, target.columns.2.y, target.columns.2.z))
            if ik.behavior == .inverseKinematics, ik.rotateWhenOverstretched {
                let toTarget = linkPosition(link) - position(joint.bone)
                let squared = simd_length_squared(toTarget)
                if squared > 1 {
                    let distance = squared.squareRoot()
                    let t = min((distance - 1) / max(ik.fullRotationDistance, 1), 1)
                    let pointing = PuppetPhysicsMath.alignment(from: SIMD3(1, 0, 0), to: toTarget / distance)
                    basis = simd_float3x3(PuppetPhysicsMath.slerp(simd_quatf(basis), pointing, t))
                }
            }
            setBasis(joint.bone, basis)
        }
    }

    // MARK: Rope

    private func ropeStep(_ set: PuppetKinematicsLayout.ChainSet) {
        let dt2 = delta * delta
        for joint in set.joints where joint.flags & 0x4 != 0 {
            guard let ik = ikByBone[joint.bone] else { continue }
            let bones = joint.bones
            let a = position(set.bone)
            var b = targetLink(of: joint.bone).map(linkPosition) ?? position(joint.bone)
            if !ik.stretch {
                let distance = simd_length(b - a)
                if distance > joint.length { b = a + (b - a) / distance * joint.length }
            }
            current[set.bone] = a
            let free = !ik.stretch && ik.freeEndpoint
            let last = free ? bones.count : bones.count - 1
            if !free {
                setPosition(joint.bone, b)
                current[joint.bone] = b
            }
            if !started.contains(set.bone) {
                started.insert(set.bone)
                for index in 1..<max(last, 1) {
                    current[bones[index]] = position(bones[index])
                    previous[bones[index]] = position(bones[index])
                }
            }
            guard last > 1 else { continue }
            let friction = min(max((ik.friction / 100) * (ik.friction / 100), 0), 1)
            let gravity = ik.gravity ? SIMD3<Float>(0, -1, 0) * ik.mass : .zero
            for index in 1..<last {
                let bone = bones[index]
                let p = current[bone], q = previous[bone]
                var next = 2 * p - q
                if dt2 > 1.1920929e-7, friction > 0.01, simd_length_squared(q - p) > 9.9999997e-5 { next += (q - p) * friction }
                next += gravity * dt2
                previous[bone] = p
                current[bone] = next
                setPosition(bone, next)
            }
        }
    }

    private func ropeSweep(_ joint: PuppetKinematicsLayout.Joint, forward: Bool) {
        guard let ik = ikByBone[joint.bone] else { return }
        let bones = joint.bones
        let span = simd_length(current[joint.bone] - current[bones[0]])
        let stretch: Float = span > joint.length && ik.stretch ? span / joint.length : 1
        let last = !ik.stretch && ik.freeEndpoint ? bones.count : bones.count - 1
        guard last > 1 else { return }
        for step in 1..<last {
            let child = forward ? bones[step] : bones[bones.count - step]
            let parent = forward ? bones[step - 1] : bones[bones.count - step - 1]
            let rest = stretch * layout.lengths[child]
            let v = current[child] - current[parent]
            let distance = simd_length(v)
            let error = rest - distance
            guard abs(error) > 0.001 else { continue }
            let direction = distance > 0.01 ? v / distance : SIMD3<Float>(0.707, 0.707, 0)
            if forward, step == 1 {
                current[child] += direction * error
            } else if !forward, step == 1 {
                current[parent] -= direction * error
            } else {
                current[parent] -= direction * error * 0.5
                current[child] += direction * error * 0.5
            }
        }
    }
}
