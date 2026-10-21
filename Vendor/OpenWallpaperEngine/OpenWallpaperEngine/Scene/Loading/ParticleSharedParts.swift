/// The parts of a particle system built from its definition, material and blending alone, which
/// every copy of that definition draws with: the material (its blending applied), texture 0 and
/// its sprite sheet, the material plan of each renderer (shader variants, textures, constants)
/// and the built-in draw's converted texture. What differs between copies (transform, instance
/// overrides, object, seed, control points, visibility) is applied per copy over them.
struct ParticleSharedParts {
    let material: WEMaterial
    let source: SceneMetalTextureSource
    let spriteSheet: SpriteSheet?
    /// The first renderer's material plan; nil keeps the built-in draw.
    let materialPlan: ParticleMaterialPlan?
    let fallbackSource: SceneMetalTextureSource?
    /// The material plans of the renderers after the first, in authored order.
    let rendererMaterials: [ParticleMaterialPlan?]
}
