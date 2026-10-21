import simd

/// A clip's root motion (docs/models-plan.md §2.8 "Root motion"): the model editor's Motion root
/// bone and axes (`MDLAnimation.Flag`, the clip record `MDLAnimation.Reference`). The editor
/// writes the axes in the clip record's flags byte (the byte at 0x17D4 in its own `.mdl`s, bits
/// 8…15 of the flags, so 0xbc01 reads as that byte 0xBC after the low byte 0x01): 0x04 Match
/// loop, 0x08/0x10/0x20 position x/y/z, 0x80 rotation y (all on: 0xBC). Its UI offers no other
/// rotation.
///
/// WE 2.8.0.42's captures (we-test-wp-images @ 2aad5f2: tools/peer/models_gt/mg4/clips and
/// tools/peer/requests/owe-beta3) settle what it does with them. The flagged axes come out of the
/// root bone's pose as 0x140225900 takes them out (below), each frame from that frame alone: the
/// object's transform never moves and nothing accumulates, so every loop of the clip returns to
/// the same spot. With all axes off the root plays its full motion. Yaw alone strips the root's
/// yaw and the model keeps its heading (the rotY capture: 17 px mean with the strip alone, 67
/// with the model turned). With position axes as well the model turns by the yaw the root gained
/// (`turn`; the all-on capture: 18 px mean with the turn, 110 without). The position strip adds a
/// model-space difference to a local translation, so under a rotated parent it lands on other
/// axes; the per-axis captures follow that (the posY box runs along the model's z), and the
/// all-on box doesn't stay put.
///
/// The root's matrices here are WE's (0x140267580, 0x140267f00): the clip's own samples chained up
/// the parents with translation and rotation only (no scale). Matrices are column-vector (`simd`
/// and glm: column i is WE's row i), so WE's row-major products appear reversed.
struct SceneRootMotion: Equatable {
    /// The root bone.
    let bone: Int
    /// The clip's `MDLAnimation.Flag`s.
    let flags: UInt32
    /// The root's matrix at the start frame (ref+0x1c) and its rotation's inverse (ref+0x5c).
    let start: simd_float4x4
    let startRotationInverse: simd_float3x3

    /// The clip's root motion; nil when it has none: no root-motion flag, no clip record (WE
    /// dereferences the missing record; its capture showed such a model never loading, MG4), or
    /// no root bone.
    init?(clip: MDLAnimation, clips: [MDLAnimation], skeleton: SceneSkeleton) {
        guard clip.flags & MDLAnimation.Flag.rootMotion != 0, let reference = clip.reference,
              reference.rootBone >= 0, Int(reference.rootBone) < skeleton.boneCount else { return nil }
        bone = Int(reference.rootBone)
        flags = clip.flags
        // 0x1402651b7…0x140265232: Match loop reads this clip's first frame, else the source
        // clip's Start frame.
        let matchLoop = clip.flags & MDLAnimation.Flag.matchLoop != 0
        let source = matchLoop || Int(reference.animation) >= clips.count ? clip : clips[Int(reference.animation)]
        let startFrame = matchLoop ? 0 : Int(reference.startFrame)
        start = Self.rootMatrix(source, skeleton: skeleton, bone: bone, frame0: startFrame, frame1: startFrame, fraction: 0)
        startRotationInverse = Self.rotation(start).inverse
    }

    /// One layer's frame (the pose half of 0x140225900): `clip` sampled at `frame0`…`frame1` by
    /// `fraction`, `weight` the layer's. Takes the flagged axes out of the root in `pose`:
    /// - each flagged position axis gains `(start − current)·w`, the model-space difference added
    ///   to the local translation;
    /// - with yaw, the local rotation is pre-multiplied by `YB · YA⁻¹`, which takes the yaw the
    ///   root gained since the start frame out of it.
    /// It depends on the frame alone, so every loop strips the same.
    func apply(clip: MDLAnimation, skeleton: SceneSkeleton, frame0: Int, frame1: Int, fraction: Float,
               weight: Float, pose: inout [SceneBoneTransform]) {
        guard bone < pose.count else { return }
        let current = Self.rootMatrix(clip, skeleton: skeleton, bone: bone, frame0: frame0, frame1: frame1, fraction: fraction)
        let startTranslation = Self.translation(start), currentTranslation = Self.translation(current)
        let axes: [UInt32] = [MDLAnimation.Flag.rootPositionX, MDLAnimation.Flag.rootPositionY, MDLAnimation.Flag.rootPositionZ]
        for (axis, flag) in axes.enumerated() where flags & flag != 0 {
            pose[bone].translation[axis] += (startTranslation[axis] - currentTranslation[axis]) * weight
        }
        if flags & MDLAnimation.Flag.rootRotationY != 0 {
            // The yaw the root gained since the start (YA), and the start's own (YB: the identity
            // but for rounding); the SoA quaternion product at 0x140225ec8 (not normalised).
            let gained = Self.yaw(Self.rotation(current) * startRotationInverse)
            let own = Self.yaw(Self.rotation(start) * startRotationInverse)
            pose[bone].rotation = simd_quatf(own * gained.transpose) * pose[bone].rotation
        }
    }

    /// The yaw (radians, about the model's y) the model turns by this frame, before the stack's
    /// weights: with yaw and a position axis flagged, the yaw the root gained since the start
    /// frame (YA of `apply`); 0 otherwise. Like the strip it depends on the frame alone. The
    /// captures fix when it applies (all on turns, yaw alone doesn't; see the type's note) [I: the
    /// branch in 0x140225900 that gates it].
    func turn(clip: MDLAnimation, skeleton: SceneSkeleton, frame0: Int, frame1: Int, fraction: Float) -> Float {
        let positions = MDLAnimation.Flag.rootPositionX | MDLAnimation.Flag.rootPositionY | MDLAnimation.Flag.rootPositionZ
        guard flags & MDLAnimation.Flag.rootRotationY != 0, flags & positions != 0 else { return 0 }
        let current = Self.rootMatrix(clip, skeleton: skeleton, bone: bone, frame0: frame0, frame1: frame1, fraction: fraction)
        let gained = Self.yaw(Self.rotation(current) * startRotationInverse)
        return atan2(gained.columns.2.x, gained.columns.2.z)
    }

    /// `pose` turned about the model's y axis by `angle`: every bone without a parent, rotation and
    /// translation, so the whole model turns about its origin.
    static func turn(_ pose: inout [SceneBoneTransform], skeleton: SceneSkeleton, by angle: Float) {
        guard angle != 0 else { return }
        let yaw = yawMatrix(sin: sin(angle), cos: cos(angle))
        let rotation = simd_quatf(yaw)
        for bone in pose.indices where bone >= skeleton.parents.count || skeleton.parents[bone] == nil {
            pose[bone].translation = yaw * pose[bone].translation
            pose[bone].rotation = rotation * pose[bone].rotation
        }
    }

    // MARK: - Matrices

    /// The root's matrix in the clip (0x140267f00; 0x140267580 for one frame): each bone's sample
    /// between the two frames, translation lerped and rotation nlerped, as `T · R` without its
    /// scale, chained up the parents. A bone without a track keeps its bind pose.
    static func rootMatrix(_ clip: MDLAnimation, skeleton: SceneSkeleton, bone: Int, frame0: Int, frame1: Int,
                           fraction: Float) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        var index: Int? = bone
        var visited = 0
        while let current = index, current >= 0, current < skeleton.boneCount, visited <= skeleton.boneCount {
            var local = skeleton.bindPose[current]
            if current < clip.boneTracks.count {
                let track = clip.boneTracks[current]
                let count = track.samples.count / MDLBonePose.floatCount
                if count > 0 {
                    let a = SceneBoneTransform(track.pose(at: max(0, min(frame0, count - 1))))
                    let b = SceneBoneTransform(track.pose(at: max(0, min(frame1, count - 1))))
                    local = SceneBoneTransform.blend(a, b, fraction)
                }
            }
            local.scale = SIMD3(repeating: 1)
            matrix = local.matrix * matrix
            index = skeleton.parents[current]
            visited += 1
        }
        return matrix
    }

    static func rotation(_ matrix: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
                      SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
                      SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))
    }

    static func translation(_ matrix: simd_float4x4) -> SIMD3<Float> {
        SIMD3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
    }

    /// The yaw of a rotation (0x140225ab5…0x140225b7a): its z axis projected on the ground plane
    /// and normalised, `f`, as the rotation about y taking z to it. The identity when z is
    /// vertical [I: WE divides by zero there].
    static func yaw(_ rotation: simd_float3x3) -> simd_float3x3 {
        let axis = rotation.columns.2
        let length = (axis.x * axis.x + axis.z * axis.z).squareRoot()
        guard length > 0 else { return matrix_identity_float3x3 }
        return yawMatrix(sin: axis.x / length, cos: axis.z / length)
    }

    /// The rotation about y with that sine and cosine: columns (c, 0, −s), (0, 1, 0), (s, 0, c).
    static func yawMatrix(sin s: Float, cos c: Float) -> simd_float3x3 {
        simd_float3x3(SIMD3(c, 0, -s), SIMD3(0, 1, 0), SIMD3(s, 0, c))
    }
}
