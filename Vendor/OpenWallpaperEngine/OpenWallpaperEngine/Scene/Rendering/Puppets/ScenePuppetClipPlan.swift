/// What a Puppet Warp rig with clipping masks draws them with (docs/models-plan.md §2.13a): the
/// plan of its draws (`ScenePuppetClipping`), the clipped parts' material, and, when that material
/// reads the coverage, the mask material and each mask's texture. WE makes the same two materials
/// for every puppet with bones (`puppet+0x428`, `+0x420`; 0x14020a978, 0x14020ab12).
final class ScenePuppetClipPlan {
    let layout: ScenePuppetClipping
    /// The layer's material with `CLIPPINGUVS` and `CLIPPINGTARGET` (`buildPuppetClipTarget`).
    let target: ImageMaterialPlan
    /// `clippingmaskimage4` (`buildPuppetClippingMask`); nil when `target` doesn't sample the
    /// coverage, so drawing it would change nothing (every shader but `genericimage4`).
    let mask: ImageMaterialPlan?
    /// Each mask's painted texture with its key for `ScenePuppetRenderer.Draw.assetTexture`; nil
    /// when it couldn't be found (logged), which leaves that mask's coverage at its clear value.
    let maskTextures: [(key: String, source: SceneMetalTextureSource)?]

    init(layout: ScenePuppetClipping, target: ImageMaterialPlan, mask: ImageMaterialPlan?,
         maskTextures: [(key: String, source: SceneMetalTextureSource)?]) {
        self.layout = layout
        self.target = target
        self.mask = mask
        self.maskTextures = maskTextures
    }

    /// Whether `target`'s variant samples `g_Texture8`.
    static func readsCoverage(_ material: ImageMaterialPlan) -> Bool {
        guard let variant = material.pass.variant else { return false }
        return variant.textureSlots.contains(ImagePuppetCombos.clippingMaskSlot)
            && variant.fragmentMSL.contains("[[texture(\(ImagePuppetCombos.clippingMaskSlot))]]")
    }

    /// The plan for `mesh`'s masks, drawn by the layer material at `materialPath`; nil without
    /// masks. Throws when the materials don't translate.
    static func make(mesh: MDLMesh, boneCount: Int, materialPath: String, combos: ImagePuppetCombos,
                     layerBlending: String, builder: ImageMaterialPlanBuilder, rigPath: String) throws -> ScenePuppetClipPlan? {
        guard let layout = ScenePuppetClipping(mesh: mesh, boneCount: boneCount) else {
            if !(mesh.groups ?? []).isEmpty {
                OWELog.error(.scene, "Puppet rig \(rigPath): its clipping masks name ranges the mesh doesn't have; drawn without them")
            }
            return nil
        }
        guard let target = try builder.buildPuppetClipTarget(materialPath: materialPath, puppet: combos),
              target.pass.variant != nil else { return nil }
        guard readsCoverage(target) else {
            return ScenePuppetClipPlan(layout: layout, target: target, mask: nil, maskTextures: [])
        }
        // 0x14020ad16: `ALPHATOCOVERAGE` when the layer material's blending is byte 3.
        let mask = try builder.buildPuppetClippingMask(puppet: combos,
                                                       alphaToCoverage: layerBlending.lowercased() == "alphatocoverage")
        let textures = layout.masks.map { clipping -> (key: String, source: SceneMetalTextureSource)? in
            guard let source = builder.loadTexture(clipping.texture, materialPath) else {
                OWELog.error(.scene, "Puppet rig \(rigPath): clipping mask texture \(clipping.texture) not found; the mask covers nothing")
                return nil
            }
            return ("\(materialPath)|\(clipping.texture)", source)
        }
        return ScenePuppetClipPlan(layout: layout, target: target, mask: mask, maskTextures: textures)
    }
}
