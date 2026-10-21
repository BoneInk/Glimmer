import Foundation
import simd

/// A particle system's material, resolved at load for Wallpaper Engine's own particle shaders
/// (`genericparticle`, `genericropeparticle` or a workshop shader in their place).
struct ParticleMaterialPlan {
    /// One way to run the material's shader. The renderer uses the first stage whose pipeline
    /// builds; when none does, the system keeps the built-in particle draw.
    struct Stage {
        enum Geometry: Hashable {
            /// The `.geom` stage folded into the vertex stage (`GeometryShaderEmulation`): one
            /// instance per record, `vertexCount` indices each, as a triangle list. Over the strip's
            /// vertices, or one vertex per index when the stage restarts strips.
            case emulated(vertexCount: Int, restartsStrips: Bool = false)
            /// WE's no-geometry-shader stream (`GS_ENABLED` 0): each record expanded on the GPU to
            /// four vertices, drawn as two triangles.
            case expandedQuads

            /// The triangle list each instance draws, over the vertex ids the stage reads
            /// (`gl_VertexID`): the strip's triangles, each strip vertex once.
            var indices: [UInt32] {
                switch self {
                case .emulated(let count, true): return GeometryShaderEmulation.listIndices(count: count)
                case .emulated(let count, false): return GeometryShaderEmulation.stripIndices(vertices: count / 3 + 2)
                case .expandedQuads: return GeometryShaderEmulation.stripIndices(vertices: 4)
                }
            }
        }

        let geometry: Geometry
        let variant: TranslatedShaderVariant
        /// Identifies the variant (`ShaderVariantTranslator.cacheKey`).
        let variantKey: String
        let textures: [Int: SceneEffectTextureInput]
        let constants: ShaderConstantResolver.ResolvedConstants

        /// Reads `_rt_FullFrameBuffer` (refraction).
        var readsSceneSnapshot: Bool {
            textures.values.contains { if case .sceneSnapshot = $0 { return true } else { return false } }
        }
    }

    /// The material JSON, for logs.
    let materialPath: String
    /// The shader actually used (the rope renderers swap in `genericropeparticle`).
    let shader: String
    let format: ParticleVertexFormat
    /// Material blending (`translucent`, `additive`, `normal`…).
    let blending: String
    let stages: [Stage]
    /// `g_RenderVar0` of sprite trails: `(length, maxlength, minlength, 0)`.
    let trailLengths: SIMD4<Float>
    /// Set when texture 0 is a sprite sheet (`SPRITESHEET`).
    let spriteSheet: SpriteSheet?
    /// Each texture slot's `.tex` flags, which pick its sampler (clamp or repeat, bilinear or
    /// nearest). A slot without an entry samples as WE's default: repeat, bilinear.
    var textureFlags: [Int: TEXFlags] = [:]
    /// The pass's `depthtest`, `depthwrite` and `cullmode` (docs/models-plan.md §2.4; the halo:
    /// test on, write off), which the system draws with where the scene pass has depth.
    var raster = SceneRasterState.engineDefault
}
