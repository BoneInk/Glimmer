import simd

/// What a model or Puppet Warp image is hit tested with besides its world matrix, read once from
/// its `.mdl` (docs/scenescript-plan.md §4.8, "Models" and "Hit boxes").
///
/// - A **model** (object type 5) is hit through its box (`MDLModel.bounds`, the union of its
///   meshes' boxes, ±131072 without one: model data +0x1b8 / +0x1c4).
/// - Its **hit boxes** are the skeleton's optional per-bone `{vec3, mat4}` block
///   (`MDLSkeleton.boneVectors`, model data +0x1a0, 0x4c bytes a bone): half extents and the box's
///   frame in its bone's space. WE's editor compiles one per bone into a Puppet Warp rig: the
///   bounds of the vertices the bone moves (capture 538). They don't decide the hit; they name it (`CursorEvent.hitBox`),
///   and on a model also give the local position.
/// - A puppet tries its hit boxes in its bones' draw-depth order (`MDLSkeleton.boneIndices`, model
///   data +0x1d0), from the end: without that order it has none to try.
struct SceneScriptCursorShape: Equatable {
    struct HitBox: Equatable {
        /// The bone's name; its index when the name is empty (0x140053e40, `std::to_string`).
        var name: String
        var halfExtents: SIMD3<Float>
        /// The box's frame in its bone's space (column-vector, the `.mdl`'s memory).
        var matrix: simd_float4x4
    }

    enum Kind: Equatable {
        /// A model object and its box.
        case model(MDLBounds)
        /// A Puppet Warp image and its bones in draw-depth order.
        case puppet(order: [Int])
    }

    var kind: Kind
    /// One per bone, by bone index; empty without the block.
    var hitBoxes: [HitBox] = []

    /// A model object's shape.
    static func model(_ mdl: MDLModel) -> Self {
        Self(kind: .model(mdl.bounds), hitBoxes: hitBoxes(of: mdl))
    }

    /// A Puppet Warp image's shape, or nil when it has no hit boxes to try (0x1401fd70b…0x1401fd73f:
    /// the event's `hitBox` stays unset; its quad is hit tested like any image's).
    static func puppet(_ mdl: MDLModel) -> Self? {
        let boxes = hitBoxes(of: mdl)
        guard !boxes.isEmpty, let order = mdl.skeleton?.boneIndices, !order.isEmpty else { return nil }
        return Self(kind: .puppet(order: order.map { Int($0) }), hitBoxes: boxes)
    }

    private static func hitBoxes(of mdl: MDLModel) -> [HitBox] {
        guard let skeleton = mdl.skeleton, let vectors = skeleton.boneVectors else { return [] }
        return vectors.enumerated().map { index, box in
            let name = index < skeleton.bones.count ? skeleton.bones[index].name : ""
            return HitBox(name: name.isEmpty ? String(index) : name, halfExtents: box.vector, matrix: box.matrix)
        }
    }
}
