import Foundation
import Metal

/// WE's HDR bloom (docs/lighting-plan.md §2.6; targets `0x14017f346`, constants `0x140184020`,
/// run `0x140183610`, combine `0x140180ad5`): a mip chain of WE's own `materials/util` passes on
/// the finished float frame, translated and run by the effect graph like any effect's passes.
///
/// With `n` = max(1, min(levels, `bloomhdriterations`)), where `levels` is how many times the
/// frame's smaller side halves before reaching 0, at most 8:
///
/// | Pass | Material | In → out | `g_RenderVar0` |
/// |---|---|---|---|
/// | D0 | `hdr_downsample_bloom` | the frame → `_rt_2FrameBuffer` | (1/w, 1/h, −1/w, −1/h) |
/// | D*i*, *i* = 1…n−1 | `hdr_downsample` | RT*i*−1 → RT*i* | D0's × 2^*i* |
/// | U*k*, *k* = n−1…1 | `hdr_upsample`, `hdr_upsample_cubic` for *k* ≥ n−2 | RT*k* → RT*k*−1, additive | D0's × 2^*k* |
/// | combine | `combine_hdr_upsample`, `combine_dhdr_upsample` with display HDR | `_rt_FullFrameBuffer` + RT0 → the frame | (RV.x, RV.y, the last pass's zw) |
///
/// RT*i* is `_rt_<2^(i+1)>FrameBuffer`, RGBA16F at 1/2^(i+1). WE's constants go to D0
/// (`bloomstrength` normalised by the scatter, `blend`, `bloomtint`) and both upsample materials
/// (`scatter`). A HDR frame without bloom goes through `combine_srgb` instead, or `combine_video_hdr` for a HDR
/// video (below).
///
/// Both combines write linear values; WE shows them through its swap chain's sRGB view, so the
/// output here is an sRGB target that the composite reads as the encoded bytes (`encodedView`).
/// RV is the device's `g_RenderVar0.xy`: (SDR white, HDR headroom) / 80 nits on a display in
/// HDR, (1, 0) otherwise (`0x14012b5d9`). With display HDR (`SceneDisplayOutput.extendedRange`)
/// the combine is `combine_dhdr_upsample` and the output an RGBA16F target of linear values that
/// the EDR drawable shows as they are, with RV = (1, headroom − 1) (`SceneDisplayOutput.renderVar`);
/// otherwise RV is (1, 0).
///
/// A HDR video (WE 2.8's "Scene DX11 (HDR Support)" video framework) fills the float frame with
/// linear light rather than sRGB-encoded colour, so WE swaps `combine_srgb` for
/// `combine_video_hdr` (render flag 0x10000, 0x14017fb82): no linearisation, only a clamp to
/// [0, 2 · `g_HDRParams.y`]. `g_HDRParams` is the device's HDR pair, RV's (SDR white, max
/// luminance − SDR white) / 80 nits (`passthroughlinear` divides by its `.x` to get back SDR), so
/// here, in SDR-white units, (1, headroom − 1) on the EDR output (`videoHDRParams`).
struct SceneHDRChain {
    /// Every pass of the chain at 8 levels, both upsample variants and both combines; `plan(levels:)`
    /// picks a frame's passes from it.
    let full: SceneEffectPlan

    static let effectFile = "engine:bloom_hdr.json"
    /// The effect graph's state for the chain's targets.
    static let stateID = "engine:bloom-hdr"
    /// WE's cap on the chain's levels (`0x14017f541`).
    static let maxLevels = 8
    /// The format the combines write: linear values, encoded to sRGB as WE's swap chain view does.
    static let outputFormat = MTLPixelFormat.rgba8Unorm_srgb
    /// The format they write with display HDR: linear values above 1 kept for the EDR drawable.
    static let displayHDROutputFormat = SceneDisplayOutput.extendedPixelFormat

    /// Material (pass) indices in `effectDocument`.
    enum Pass {
        static let downsampleBloom = 0
        /// D*i*, *i* = 1…7.
        static func downsample(_ level: Int) -> Int { level }
        /// U*k* with `hdr_upsample`, *k* = 1…7.
        static func upsample(_ level: Int) -> Int { 7 + level }
        /// U*k* with `hdr_upsample_cubic`, *k* = 1…7.
        static func upsampleCubic(_ level: Int) -> Int { 14 + level }
        static let combine = 22
        static let combineSRGB = 23
        /// `combine_dhdr_upsample` (`DISPLAYHDR` 1), display HDR's combine (0x14017fb49).
        static let combineDisplayHDR = 24
        /// `combine_video_hdr`, a HDR video's combine without bloom in place of `combine_srgb`.
        static let combineVideoHDR = 25
    }

    /// `_rt_<2^(i+1)>FrameBuffer`, level *i*'s target.
    static func target(_ level: Int) -> String { "_rt_\(2 << level)FrameBuffer" }

    /// The chain as effect.json. The name can't collide with a wallpaper's file: `:` isn't in any.
    static let effectDocument: String = {
        func pass(_ material: String, input: String? = nil, bloom: String? = nil, target: String? = nil) -> String {
            var binds: [String] = []
            if let input { binds.append(#"{"name": "\#(input)", "index": 0}"#) }
            if let bloom { binds.append(#"{"name": "\#(bloom)", "index": 1}"#) }
            var fields = [#""material": "materials/util/\#(material).json""#]
            if !binds.isEmpty { fields.append(#""bind": [\#(binds.joined(separator: ", "))]"#) }
            if let target { fields.append(#""target": "\#(target)""#) }
            return "{\(fields.joined(separator: ", "))}"
        }
        var passes = [pass("hdr_downsample_bloom", target: target(0))]
        for level in 1..<maxLevels {
            passes.append(pass("hdr_downsample", input: target(level - 1), target: target(level)))
        }
        for material in ["hdr_upsample", "hdr_upsample_cubic"] {
            for level in 1..<maxLevels {
                passes.append(pass(material, input: target(level), target: target(level - 1)))
            }
        }
        passes.append(pass("combine_hdr_upsample", bloom: target(0)))
        passes.append(pass("combine_srgb"))
        passes.append(pass("combine_dhdr_upsample", bloom: target(0)))
        passes.append(pass("combine_video_hdr"))
        let fbos = (0..<maxLevels).map {
            #"{"name": "\#(target($0))", "scale": \#(2 << $0), "format": "rgba16161616f"}"#
        }
        return #"{"passes": [\#(passes.joined(separator: ",\n"))], "fbos": [\#(fbos.joined(separator: ",\n"))]}"#
    }()

    enum BuildError: Error, CustomStringConvertible {
        case incomplete(String)

        var description: String {
            switch self {
            case .incomplete(let reason): return "the HDR bloom chain is incomplete: \(reason)"
            }
        }
    }

    /// Plans the chain with `builder`'s translator, files and engine combos.
    static func build(with builder: SceneEffectPlanBuilder) throws -> SceneHDRChain {
        let document = Data(effectDocument.utf8)
        let engine = SceneEffectPlanBuilder(
            translator: builder.translator,
            readFile: { $0 == effectFile ? document : builder.readFile($0) },
            loadTexture: builder.loadTexture,
            sceneEngineCombos: builder.sceneEngineCombos)
        let effect = try JSONDecoder().decode(WEObjectEffect.self, from: Data(#"{"file": "\#(effectFile)"}"#.utf8))
        let plan = try engine.build(effect)
        guard plan.passes.count == Pass.combineVideoHDR + 1 else {
            throw BuildError.incomplete("\(plan.passes.count) of \(Pass.combineVideoHDR + 1) passes planned")
        }
        for pass in plan.passes where pass.variant == nil {
            throw BuildError.incomplete("pass \(pass.materialIndex) has no shader")
        }
        return SceneHDRChain(full: plan)
    }

    // MARK: - WE's arithmetic

    /// How many times the frame's smaller side halves before reaching 0, at most 8 (`0x14017f370`);
    /// WE takes the frame as at least 2×2.
    static func levels(width: Int, height: Int) -> Int {
        var side = min(max(width, 2), max(height, 2))
        var levels = 0
        for _ in 0..<maxLevels {
            side /= 2
            if side > 0 { levels += 1 }
        }
        return levels
    }

    /// The levels the chain runs: max(1, min(levels, `bloomhdriterations`)) (`0x140184058`).
    static func runLevels(width: Int, height: Int, iterations: Int) -> Int {
        max(1, min(levels(width: width, height: height), iterations))
    }

    /// The constants WE computes for `n` levels (`0x140184020`).
    struct Constants: Equatable {
        /// `g_BloomStrength`: `bloomhdrstrength` / (1 + scatter^(max(n, 2) − 2)).
        var strength: Float
        /// `g_BloomBlendParams`: (t, t − k, 2k, 0.25 / (k + 1e−5)) with t the threshold, k = t · feather.
        var blend: SIMD4<Float>
        var tint: SIMD3<Float>
        /// `g_BloomScatter` of both upsample materials.
        var scatter: Float

        init(_ settings: SceneHDRBloomSettings, levels: Int, tint: SIMD3<Float>, strengthScale: Float = 1) {
            let exponent = Float(max(levels, 2) - 2)
            strength = settings.strength * strengthScale / (1 + powf(settings.scatter, exponent))
            let knee = settings.threshold * settings.feather
            blend = SIMD4(settings.threshold, settings.threshold - knee, knee + knee, 0.25 / (knee + 1e-5))
            self.tint = tint
            scatter = settings.scatter
        }
    }

    /// The device's `g_RenderVar0.xy` for the combine without display HDR (see the type's comment).
    static let deviceRenderVar = SIMD2<Float>(1, 0)

    /// `g_HDRParams` of `combine_video_hdr` for display HDR's RV, or for a frame on a display
    /// without headroom (nil). WE makes the video HDR only on a HDR display, where the pair is RV;
    /// a frame of it shown on another display is clamped to SDR white instead (y = 0.5), which a
    /// device pair of (1, 0) would turn black.
    static func videoHDRParams(displayHDR: SIMD2<Float>?) -> SIMD2<Float> {
        displayHDR ?? SIMD2(1, 0.5)
    }

    /// `g_RenderVar0` of each pass of `levels` levels on a `size` frame, by material index
    /// (`0x140183610`, `0x140180b26`); `displayHDR` is display HDR's RV, whose combine then takes it.
    static func renderVars(levels: Int, size: SIMD2<Float>, displayHDR: SIMD2<Float>? = nil) -> [Int: SIMD4<Float>] {
        let base = SIMD4<Float>(1 / size.x, 1 / size.y, -1 / size.x, -1 / size.y)
        var vars: [Int: SIMD4<Float>] = [Pass.downsampleBloom: base]
        for level in 1..<max(levels, 1) {
            vars[Pass.downsample(level)] = base * Float(1 << level)
        }
        var last = base
        for level in stride(from: levels - 1, through: 1, by: -1) {
            last = base * Float(1 << level)
            vars[Pass.upsample(level)] = last
            vars[Pass.upsampleCubic(level)] = last
        }
        let device = displayHDR ?? deviceRenderVar
        vars[displayHDR == nil ? Pass.combine : Pass.combineDisplayHDR] = SIMD4(device.x, device.y, last.z, last.w)
        return vars
    }

    /// The plan for a frame: `levels` levels of bloom, or `combine_srgb` alone when `levels` is nil
    /// (a HDR frame without bloom, with display HDR too: 0x140180b9c), `combine_video_hdr` for a
    /// HDR video (`videoHDR`). `displayHDR` combines with `combine_dhdr_upsample`.
    func plan(levels: Int?, displayHDR: Bool = false, videoHDR: Bool = false) -> SceneEffectPlan {
        guard let levels else {
            let combine = videoHDR ? Pass.combineVideoHDR : Pass.combineSRGB
            return SceneEffectPlan(file: full.file, fbos: [], passes: full.passes.filter { $0.materialIndex == combine })
        }
        let n = min(max(levels, 1), Self.maxLevels)
        var indices = [Pass.downsampleBloom] + (1..<n).map(Pass.downsample)
        // Bicubic for the two coarsest upsamples (`0x14018381b`).
        indices += stride(from: n - 1, through: 1, by: -1).map { $0 >= n - 2 ? Pass.upsampleCubic($0) : Pass.upsample($0) }
        indices.append(displayHDR ? Pass.combineDisplayHDR : Pass.combine)
        let byIndex = Dictionary(full.passes.map { ($0.materialIndex, $0) }, uniquingKeysWith: { a, _ in a })
        let names = Set((0..<n).map(Self.target))
        return SceneEffectPlan(file: full.file, fbos: full.fbos.filter { names.contains($0.name) },
                               passes: indices.compactMap { byIndex[$0] })
    }

    /// The constant writes of `constants` (D0's three, and `scatter` on every upsample material).
    static func constantWrites(_ constants: Constants) -> [SceneScriptConstantWrite] {
        var writes = [
            SceneScriptConstantWrite(material: Pass.downsampleBloom, name: "bloomstrength", value: [constants.strength]),
            SceneScriptConstantWrite(material: Pass.downsampleBloom, name: "blend",
                                     value: [constants.blend.x, constants.blend.y, constants.blend.z, constants.blend.w]),
            SceneScriptConstantWrite(material: Pass.downsampleBloom, name: "bloomtint",
                                     value: [constants.tint.x, constants.tint.y, constants.tint.z]),
        ]
        for level in 1..<maxLevels {
            for material in [Pass.upsample(level), Pass.upsampleCubic(level)] {
                writes.append(SceneScriptConstantWrite(material: material, name: "scatter", value: [constants.scatter]))
            }
        }
        return writes
    }

    // MARK: - Running it

    /// Encodes the chain on `frame` (`_rt_FullFrameBuffer`, RGBA16F) with `constants` for
    /// `levels` levels, or `combine_srgb` alone when `levels` is nil (`combine_video_hdr` with
    /// `videoHDR`, the frame then holding linear light); returns the combined frame,
    /// an sRGB texture of its size (RGBA16F with `displayHDR`, display HDR's RV), or nil while a
    /// pass's pipeline is still compiling or one failed.
    /// `referenceSize` is the frame's size at full detail (`ScenePostProcess.Frame.bloomReferenceSize`;
    /// the frame's own when nil), whose texels the passes step in.
    func encode(on frame: MTLTexture, levels: Int?, constants: Constants,
                effects: EffectGraphRenderer, builtins: BuiltinFrameContext, values: SceneValueContext,
                frameIndex: UInt64, referenceSize: SIMD2<Float>? = nil, displayHDR: SIMD2<Float>? = nil,
                videoHDR: Bool = false, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let plan = plan(levels: levels, displayHDR: displayHDR != nil, videoHDR: videoHDR)
        let size = referenceSize ?? SIMD2(Float(frame.width), Float(frame.height))
        var builtins = builtins
        if videoHDR { builtins.hdrParams = Self.videoHDRParams(displayHDR: displayHDR) }
        var context = EffectGraphRenderer.Context(
            frame: builtins, values: values,
            // The util materials of the chain sample no asset.
            assetTexture: { _, _ in nil },
            sceneSnapshot: frame, layerColor: SIMD3(repeating: 1), layerAlpha: 1)
        context.inputVersion = frameIndex
        context.texelSizeReference = size
        context.frameBufferFormat = .rgba16Float
        context.outputFormat = displayHDR == nil ? Self.outputFormat : Self.displayHDROutputFormat
        context.passRenderVars = Self.renderVars(levels: levels ?? 1, size: size, displayHDR: displayHDR).mapValues { [0: $0] }
        context.constantWrites = [plan.effectIndex: Self.constantWrites(constants)]
        return effects.apply([plan], to: frame, layerID: Self.stateID, context: context, commandBuffer: commandBuffer)
    }

    /// `output` as the bytes WE's swap chain shows: its sRGB encoding read without decoding.
    static func encodedView(of output: MTLTexture) -> MTLTexture? {
        guard output.pixelFormat == outputFormat else { return output }
        return output.makeTextureView(pixelFormat: .rgba8Unorm)
    }
}
