import simd

/// A bone's local transform as WE keeps a pose: translation, rotation and scale, SoA at
/// skel+0x8 (bind) and skel+0x10 (the pose), 10 floats a bone (docs/models-plan.md §1.4, §2.8).
/// Its matrix scales, then rotates, then translates (WE's row-vector `S·R·T`), which for these
/// column-vector matrices is `T · R · S`.
struct SceneBoneTransform: Equatable {
    var translation: SIMD3<Float>
    var rotation: simd_quatf
    var scale: SIMD3<Float>

    static let identity = SceneBoneTransform(translation: .zero, rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                             scale: SIMD3(repeating: 1))

    init(translation: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }

    /// A clip sample: its Euler angles become q = qz·qy·qx at load (0x1402640c0).
    init(_ pose: MDLBonePose) {
        self.init(translation: pose.position, rotation: pose.rotation, scale: pose.scale)
    }

    /// A bind matrix taken apart: the translation, the columns' lengths as the scale and the
    /// normalised basis as the rotation [I: WE stores the bind pose as TRS; its decomposition
    /// wasn't traced, and every library bind matrix is a rotation, a scale and a translation].
    init(matrix: simd_float4x4) {
        let columns = [matrix.columns.0, matrix.columns.1, matrix.columns.2].map { SIMD3($0.x, $0.y, $0.z) }
        let scale = SIMD3(simd_length(columns[0]), simd_length(columns[1]), simd_length(columns[2]))
        let basis = (0..<3).map { scale[$0] > 0 ? columns[$0] / scale[$0] : SIMD3<Float>.zero }
        let rotation = scale.min() > 0 ? simd_quatf(simd_float3x3(basis[0], basis[1], basis[2])).normalized
            : SceneBoneTransform.identity.rotation
        self.init(translation: SIMD3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z),
                  rotation: rotation, scale: scale)
    }

    /// `T · R · S`.
    var matrix: simd_float4x4 {
        let r = simd_float3x3(rotation)
        return simd_float4x4(columns: (SIMD4(r.columns.0 * scale.x, 0), SIMD4(r.columns.1 * scale.y, 0),
                                       SIMD4(r.columns.2 * scale.z, 0), SIMD4(translation, 1)))
    }

    /// `a + (b − a)·t` for translation and scale; rotation nlerped along the shorter arc
    /// (0x1401f89a0, 0x1401f9020: the sign of `dot(qa, qb)`, then normalised).
    static func blend(_ a: SceneBoneTransform, _ b: SceneBoneTransform, _ t: Float) -> SceneBoneTransform {
        SceneBoneTransform(translation: a.translation + (b.translation - a.translation) * t,
                           rotation: nlerp(a.rotation, b.rotation, t),
                           scale: a.scale + (b.scale - a.scale) * t)
    }

    static func nlerp(_ a: simd_quatf, _ b: simd_quatf, _ t: Float) -> simd_quatf {
        let target = simd_dot(a.vector, b.vector) < 0 ? -b.vector : b.vector
        let mixed = a.vector * (1 - t) + target * t
        let length = simd_length(mixed)
        return length > 0 ? simd_quatf(vector: mixed / length) : a
    }
}

/// A skeleton ready to pose (docs/models-plan.md §2.8, §4.3 M6): each bone's parent, its bind
/// transform relative to the parent, the bind pose in model space and its inverse. Models and
/// Puppet Warp images share it.
///
/// Matrices are column-vector (`p′ = M · p`): a bone's world is `world(parent) · local` (WE's
/// row-vector `local · world(parent)`), and the skinning palette entry is `world · inverseBind`
/// (WE's `g_Bones[i]`, 0x1402220a0, transposed). A bone whose parent is out of range or comes
/// after it is a root, as `MDLSkeleton.bindPoseWorldMatrices` takes it.
struct SceneSkeleton: Equatable {
    let names: [String]
    let parents: [Int?]
    /// The bind transform relative to the parent (the `.mdl` bone matrix).
    let bindLocal: [simd_float4x4]
    /// The rest pose relative to the parent: the `.mdl`'s optional per-bone block after the links
    /// (`MDLSkeleton.bindMatrices`) when it has one, else `bindLocal`. A puppet whose editor moved
    /// a part away from where it sits in the texture (a head drawn beside the body, placed on the
    /// neck) keeps the texture's place in the bone matrices, which skin, and the placed one here;
    /// every clip's unanimated tracks hold these values.
    let restLocal: [simd_float4x4]
    /// `restLocal` as the pose every frame starts from and additive layers add their change to
    /// (skel+0x8).
    let bindPose: [SceneBoneTransform]
    /// `restLocal` in model space: the pose a rig with no layers draws.
    let restWorld: [simd_float4x4]
    let bindWorld: [simd_float4x4]
    /// The inverse of the bind pose chain (0x14021b46f).
    let inverseBind: [simd_float4x4]

    var boneCount: Int { names.count }

    init(_ skeleton: MDLSkeleton) {
        let count = skeleton.bones.count
        names = skeleton.bones.map(\.name)
        let parents = skeleton.bones.enumerated().map { index, bone in
            bone.parentIndex.flatMap { $0 < index ? $0 : nil }
        }
        let orphans = skeleton.bones.indices.filter { skeleton.bones[$0].parentIndex != nil && parents[$0] == nil }
        if !orphans.isEmpty {
            let listed = orphans.map { "\(skeleton.bones[$0].name) (\($0))" }
            OWELog.debug(.scene, "Skeleton: bones \(listed) name a parent out of range or after them; posed as roots")
        }
        let local = skeleton.bones.map(\.matrix)
        self.parents = parents
        bindLocal = local
        let rest = skeleton.bindMatrices.flatMap { $0.count == count ? $0 : nil } ?? local
        restLocal = rest
        bindPose = rest.map(SceneBoneTransform.init(matrix:))
        var world: [simd_float4x4] = []
        world.reserveCapacity(count)
        for index in 0..<count {
            world.append(parents[index].map { world[$0] * local[index] } ?? local[index])
        }
        bindWorld = world
        inverseBind = world.map(\.inverse)
        var restWorld: [simd_float4x4] = []
        restWorld.reserveCapacity(count)
        for index in 0..<count {
            restWorld.append(parents[index].map { restWorld[$0] * rest[index] } ?? rest[index])
        }
        self.restWorld = restWorld
    }

    /// The first bone named `name` (`getBoneIndex`); nil when none is.
    func index(named name: String) -> Int? { names.firstIndex(of: name) }

    /// Model-space matrices from local ones, parents first. `adjust`, when given, changes each
    /// bone's matrix after it is chained from its parent and before its children are (the
    /// blend rules, `SceneBlendRules`), with the bones posed so far. With `ik`, the bones an IK
    /// chain holds keep its result (no chaining, no rules) and a chain's root runs its solver
    /// once posed (`ScenePuppetIK`).
    func worlds(locals: [simd_float4x4],
                adjust: ((Int, simd_float4x4, [simd_float4x4]) -> simd_float4x4)? = nil,
                ik: ScenePuppetIK? = nil) -> [simd_float4x4] {
        var world: [simd_float4x4] = []
        world.reserveCapacity(locals.count)
        for index in locals.indices {
            if let held = ik?.heldModel(index) {
                world.append(held)
                continue
            }
            let parent = index < parents.count ? parents[index] : nil
            let model = parent.map { world[$0] * locals[index] } ?? locals[index]
            world.append(adjust.map { $0(index, model, world) } ?? model)
            ik?.posed(bone: index, worlds: &world)
        }
        return world
    }

    /// The skinning palette: `world · inverseBind` for every bone, the identity in the bind pose.
    func palette(worlds: [simd_float4x4]) -> [simd_float4x4] {
        zip(worlds, inverseBind).map { $0 * $1 }
    }
}
