import simd

/// Bone attachments on Puppet Warp images (docs/models-plan.md §2.6, §5.15): an object whose
/// `attachment` names an attachment point of its parent's rig (`MDAT`) hangs from that bone,
/// `world = parentWorld · boneWorld[bone] · attachment matrix · local` (0x1401dd7d0, 0x140224970),
/// the bone as the parent's animator last posed it. It is M3's `SceneAttachmentProviding` for the
/// 3D hierarchy and the 2D hierarchy's `Attachments`. The library's one attachment is the
/// witcher's sword (3803167460 object 258 on "правая рука").
struct ScenePuppetAttachments: SceneAttachmentProviding {
    /// The parent's rig and animator, by object id; nil for an object without a posed rig.
    let rig: (String) -> (plan: ScenePuppetPlan, animator: ScenePuppetAnimator)?

    /// `boneWorld · matrix` of the parent's attachment with exactly that name, in the parent's
    /// model space (its image's pixels, centred, y up).
    func attachmentWorld(_ object: SceneAttachedObject) -> simd_float4x4? {
        guard let (plan, animator) = rig(object.parentID) else { return nil }
        return Self.matrix(named: object.attachment, in: plan.attachments, worlds: animator.worlds)
    }

    static func matrix(named name: String, in attachments: [MDLAttachment], worlds: [simd_float4x4]) -> simd_float4x4? {
        guard let attachment = attachments.first(where: { $0.name == name }), Int(attachment.bone) < worlds.count else {
            return nil
        }
        return worlds[Int(attachment.bone)] * attachment.matrix
    }

    /// The same in the 2D hierarchy's terms: the matrix's x and y rows and translation.
    func affine(child: String, parent: String, name: String) -> SceneAffineTransform? {
        attachmentWorld(SceneAttachedObject(id: child, parentID: parent, attachment: name)).map(Self.affine)
    }

    static func affine(_ m: simd_float4x4) -> SceneAffineTransform {
        SceneAffineTransform(linear: simd_float2x2(SIMD2(m.columns.0.x, m.columns.0.y), SIMD2(m.columns.1.x, m.columns.1.y)),
                             translation: SIMD2(m.columns.3.x, m.columns.3.y))
    }

    /// A 2D world transform as a 4×4 matrix (the object table's `worldMatrix`, z untouched).
    static func matrix(_ world: SceneAffineTransform) -> simd_float4x4 {
        let x = world.linear.columns.0, y = world.linear.columns.1
        return simd_float4x4(columns: (SIMD4(x.x, x.y, 0, 0), SIMD4(y.x, y.y, 0, 0), SIMD4(0, 0, 1, 0),
                                       SIMD4(world.translation.x, world.translation.y, 0, 1)))
    }
}
