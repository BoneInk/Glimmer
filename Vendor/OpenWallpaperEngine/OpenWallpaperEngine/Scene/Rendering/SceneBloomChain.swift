import Foundation
import Metal

/// WE's LDR bloom (docs/lighting-plan.md §2.6; setup `0x14017f1b0`, run `0x140183949`): four of
/// WE's own `materials/util` passes on the finished frame, translated and run by the effect graph
/// like any effect's passes.
///
/// | # | Material | In → out | Size |
/// |---|---|---|---|
/// | 1 | `downsample_quarter_bloom` | `_rt_FullFrameBuffer` → `_rt_4FrameBuffer` | 1/4 |
/// | 2 | `downsample_eighth_blur_v` | `_rt_4FrameBuffer` → `_rt_8FrameBuffer` | 1/8 |
/// | 3 | `blur_h_bloom` | `_rt_8FrameBuffer` → `_rt_Bloom` | 1/8 |
/// | 4 | `combine_ldr` | `_rt_FullFrameBuffer` + `_rt_Bloom` → the frame | 1 |
///
/// Every target is RGBA8 in LDR. `g_TexelSize` is 1 / the frame's size in every pass (§5.2 [I]):
/// only then is pass 1 an exact 4×4 box, and passes 2 and 3 step one 1/8 texel.
///
/// WE hard-codes the chain; it has no effect.json. `effectDocument` states it in effect.json form,
/// so `SceneEffectPlanBuilder` resolves WE's materials, shaders and targets as it does an effect's.
struct SceneBloomChain {
    let plan: SceneEffectPlan

    /// The chain as effect.json. The name can't collide with a wallpaper's file: `:` isn't in any.
    static let effectFile = "engine:bloom_ldr.json"
    static let effectDocument = """
        {
          "passes": [
            {"material": "materials/util/downsample_quarter_bloom.json", "target": "_rt_4FrameBuffer"},
            {"material": "materials/util/downsample_eighth_blur_v.json", "target": "_rt_8FrameBuffer"},
            {"material": "materials/util/blur_h_bloom.json", "target": "_rt_Bloom"},
            {"material": "materials/util/combine_ldr.json"}
          ],
          "fbos": [
            {"name": "_rt_4FrameBuffer", "scale": 4, "format": "rgba8888"},
            {"name": "_rt_8FrameBuffer", "scale": 8, "format": "rgba8888"},
            {"name": "_rt_Bloom", "scale": 8, "format": "rgba8888"}
          ]
        }
        """
    /// The effect graph's state for the chain's targets.
    static let stateID = "engine:bloom"
    /// WE sets the constants on pass 1 only (§2.6).
    private static let constantsPass = 0

    enum BuildError: Error, CustomStringConvertible {
        case incomplete(String)

        var description: String {
            switch self {
            case .incomplete(let reason): return "the bloom chain is incomplete: \(reason)"
            }
        }
    }

    /// Plans the chain with `builder`'s translator, files and engine combos.
    static func build(with builder: SceneEffectPlanBuilder) throws -> SceneBloomChain {
        let document = Data(effectDocument.utf8)
        let engine = SceneEffectPlanBuilder(
            translator: builder.translator,
            readFile: { $0 == effectFile ? document : builder.readFile($0) },
            loadTexture: builder.loadTexture,
            sceneEngineCombos: builder.sceneEngineCombos)
        let effect = try JSONDecoder().decode(WEObjectEffect.self, from: Data(#"{"file": "\#(effectFile)"}"#.utf8))
        let plan = try engine.build(effect)
        guard plan.passes.count == 4 else { throw BuildError.incomplete("\(plan.passes.count) of 4 passes planned") }
        for pass in plan.passes where pass.variant == nil {
            throw BuildError.incomplete("pass \(pass.materialIndex) has no shader")
        }
        return SceneBloomChain(plan: plan)
    }

    /// The live values WE writes to pass 1's `g_BloomStrength`, `g_BloomThreshold` and `g_BloomTint`.
    static func constants(strength: Float, threshold: Float, tint: SIMD3<Float>) -> [SceneScriptConstantWrite] {
        [SceneScriptConstantWrite(material: constantsPass, name: "bloomstrength", value: [strength]),
         SceneScriptConstantWrite(material: constantsPass, name: "bloomthreshold", value: [threshold]),
         SceneScriptConstantWrite(material: constantsPass, name: "bloomtint", value: [tint.x, tint.y, tint.z])]
    }

    /// Encodes the chain on `frame` (`_rt_FullFrameBuffer`) and returns the combined frame, an RGBA8
    /// texture of its size; nil while a pass's pipeline is still compiling or one failed.
    /// `referenceSize` is the frame's size at full detail (`ScenePostProcess.Frame.bloomReferenceSize`;
    /// the frame's own when nil), whose texels the passes step in.
    func encode(on frame: MTLTexture, strength: Float, threshold: Float, tint: SIMD3<Float>,
                effects: EffectGraphRenderer, builtins: BuiltinFrameContext, values: SceneValueContext,
                frameIndex: UInt64, referenceSize: SIMD2<Float>? = nil, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        var context = EffectGraphRenderer.Context(
            frame: builtins, values: values,
            // The util materials of the chain sample no asset.
            assetTexture: { _, _ in nil },
            sceneSnapshot: frame, layerColor: SIMD3(repeating: 1), layerAlpha: 1)
        context.inputVersion = frameIndex
        context.texelSizeReference = referenceSize ?? SIMD2(Float(frame.width), Float(frame.height))
        context.constantWrites = [plan.effectIndex: Self.constants(strength: strength, threshold: threshold, tint: tint)]
        return effects.apply([plan], to: frame, layerID: Self.stateID, context: context, commandBuffer: commandBuffer)
    }
}
