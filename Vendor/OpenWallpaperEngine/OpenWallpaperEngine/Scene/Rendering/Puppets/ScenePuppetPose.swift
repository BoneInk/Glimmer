import simd

/// The bone palette a puppet's mesh is drawn with: `g_Bones` and `g_BonesAlpha` (0x140206430).
/// Each bone maps a bind-pose mesh position to its posed one, column vectors (`p′ = bone · p`),
/// i.e. WE's `boneWorld · inverseBind` (row vectors, 0x1402220a0) transposed; the shader reads its
/// upper 3×4 (`mat4x3`). The bind pose is every bone the identity with alpha 1.
struct ScenePuppetPose: Equatable {
    var bones: [simd_float4x4]
    var bonesAlpha: [Float]
    /// The blend shapes' uniforms (`SceneMorphRig.puppetUniforms`); nil for a rig without targets.
    var morph: SceneMorphUniforms? = nil
    /// The texture channels' weights, `g_BlendMap` flattened (`ScenePuppetAnimator.channelWeights`);
    /// empty is every channel 0.
    var blendMap: [Float] = []
    /// The index ranges in the order they draw (`ScenePuppetDrawOrder`); nil draws the index
    /// buffer as it is.
    var drawRanges: [ScenePuppetDrawOrder.Range]? = nil

    static func bind(boneCount: Int) -> ScenePuppetPose {
        ScenePuppetPose(bones: Array(repeating: matrix_identity_float4x4, count: boneCount),
                        bonesAlpha: Array(repeating: 1, count: boneCount))
    }

    /// `g_Bones` as `mat4x3` components: per bone its four columns' x, y and z.
    var boneComponents: [Float] {
        bones.flatMap { bone in
            [bone.columns.0, bone.columns.1, bone.columns.2, bone.columns.3].flatMap { [$0.x, $0.y, $0.z] }
        }
    }
}
