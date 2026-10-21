import AppKit
import Metal

/// WE's user colour correction (docs/lighting-plan.md §2.6 step 6): the wallpaper's "Image
/// filter" and colour options run WE's `materials/util/ccsimple.json` on the finished frame,
/// after the bloom and its combine and before the camera fade.
///
/// WE makes the pass only when the settings aren't identity (`wallpaper64.exe` 0x1401826a2…
/// 0x1401826f3), with `COL` when the colour options apply and `LUT` when a filter does, binds
/// `lut/<filter>` (a 32³ volume in `materials/lut`) to slot 1 and sets `params` and `lutparams`
/// (0x140182969…0x140182ea3). Here the pass is planned per combo set the first time it is needed;
/// its LUT slot holds a stand-in and the chosen filter's volume is bound each frame, so a new
/// filter doesn't replan the pass.
final class SceneColorCorrection {
    static let effectFile = "engine:ccsimple.json"
    static let effectDocument = #"{"passes": [{"material": "materials/util/ccsimple.json"}]}"#
    /// The effect graph's state for the pass's targets.
    static let stateID = "engine:ccsimple"
    /// The state for its run on the detail patch (`ScenePostProcess.finishDetailPatch`).
    static let patchStateID = "engine:ccsimple:detail"
    /// The name the plan's LUT slot is planned with; the frame binds the chosen filter's volume.
    static let plannedLUT = "lut/neutral"

    private struct Variant: Hashable {
        var color: Bool
        var filter: Bool
    }

    private let builder: SceneEffectPlanBuilder
    private var plans: [Variant: SceneEffectPlan] = [:]
    private var failedPlans: Set<Variant> = []
    private var luts: [String: MTLTexture] = [:]
    private var failedLUTs: Set<String> = []

    /// Plans with `builder`'s translator, files and engine combos. Throws when WE's pass can't be
    /// planned at all (checked with both combos on, the variant that samples everything).
    static func build(with builder: SceneEffectPlanBuilder) throws -> SceneColorCorrection {
        let correction = SceneColorCorrection(builder: builder)
        _ = try correction.makePlan(Variant(color: true, filter: true))
        return correction
    }

    private init(builder: SceneEffectPlanBuilder) {
        let document = Data(Self.effectDocument.utf8)
        let standIn = NSImage(size: NSSize(width: 1, height: 1))
        self.builder = SceneEffectPlanBuilder(
            translator: builder.translator,
            readFile: { $0 == Self.effectFile ? document : builder.readFile($0) },
            // The LUT slot is bound per frame (`encode`); the plan only needs to hold it.
            loadTexture: { name, _ in name == Self.plannedLUT ? .image(standIn) : nil },
            sceneEngineCombos: builder.sceneEngineCombos)
        luts.reserveCapacity(1)
    }

    /// The pass for `settings`, or nil when it can't be planned (logged once).
    func plan(for settings: SceneColorCorrectionSettings) -> SceneEffectPlan? {
        let variant = Variant(color: settings.appliesColor, filter: settings.appliesFilter)
        if let plan = plans[variant] { return plan }
        guard !failedPlans.contains(variant) else { return nil }
        do {
            return try makePlan(variant)
        } catch {
            failedPlans.insert(variant)
            OWELog.error(.scene, "WE's colour correction (COL \(variant.color), LUT \(variant.filter)) can't be planned: \(error)")
            return nil
        }
    }

    private func makePlan(_ variant: Variant) throws -> SceneEffectPlan {
        var combos: [String: Int] = [:]
        if variant.color { combos["COL"] = 1 }
        if variant.filter { combos["LUT"] = 1 }
        var pass: [String: Any] = ["combos": combos]
        if variant.filter { pass["textures"] = [NSNull(), Self.plannedLUT] }
        let json = try JSONSerialization.data(withJSONObject: ["file": Self.effectFile, "passes": [pass]])
        let plan = try builder.build(try JSONDecoder().decode(WEObjectEffect.self, from: json))
        guard plan.passes.count == 1, plan.passes[0].variant != nil else {
            throw SceneEffectPlanError.missing("ccsimple's shader")
        }
        plans[variant] = plan
        return plan
    }

    /// `materials/lut/<name>.tex` as a 3D texture; nil (logged once) when it can't be read.
    func lut(named name: String, device: MTLDevice) -> MTLTexture? {
        if let texture = luts[name] { return texture }
        guard !failedLUTs.contains(name) else { return nil }
        let path = "materials/lut/\(name).tex"
        do {
            guard let data = builder.readFile(path) else { throw SceneEffectPlanError.missing(path) }
            let volume = try TEXVolume(texData: data)
            guard let texture = Self.texture(volume, device: device) else {
                throw SceneEffectPlanError.missing("a \(volume.width)×\(volume.height)×\(volume.depth) texture")
            }
            luts[name] = texture
            return texture
        } catch {
            failedLUTs.insert(name)
            OWELog.error(.scene, "Image filter \(name) can't be loaded; the frame draws without it: \(error)")
            return nil
        }
    }

    static func texture(_ volume: TEXVolume, device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = volume.width
        descriptor.height = volume.height
        descriptor.depth = volume.depth
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let row = volume.width * 4
        volume.rgba.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, volume.width, volume.height, volume.depth), mipmapLevel: 0,
                            slice: 0, withBytes: raw.baseAddress!, bytesPerRow: row, bytesPerImage: row * volume.height)
        }
        return texture
    }

    /// The live values WE writes to the pass: `params` and `lutparams`.
    static func constants(_ settings: SceneColorCorrectionSettings) -> [SceneScriptConstantWrite] {
        let params = settings.params
        return [SceneScriptConstantWrite(material: 0, name: "params", value: [params.x, params.y, params.z, params.w]),
                SceneScriptConstantWrite(material: 0, name: "lutparams", value: [settings.filterAmount])]
    }

    /// Encodes the pass on `frame` and returns the corrected frame, a `format` texture; nil when the
    /// settings are identity (WE makes no pass), or the pass or its filter isn't ready (the frame
    /// shows as it is).
    func encode(on frame: MTLTexture, settings: SceneColorCorrectionSettings, effects: EffectGraphRenderer,
                builtins: BuiltinFrameContext, values: SceneValueContext, frameIndex: UInt64,
                format: MTLPixelFormat = .rgba8Unorm, stateID: String = SceneColorCorrection.stateID,
                commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard !settings.isIdentity, let plan = plan(for: settings) else { return nil }
        var lut: MTLTexture?
        if settings.appliesFilter {
            lut = self.lut(named: settings.filter, device: frame.device)
            guard lut != nil else { return nil }
        }
        var context = EffectGraphRenderer.Context(
            frame: builtins, values: values, assetTexture: { _, _ in lut },
            sceneSnapshot: frame, layerColor: SIMD3(repeating: 1), layerAlpha: 1)
        context.inputVersion = frameIndex
        context.frameBufferFormat = format
        context.constantWrites = [plan.effectIndex: Self.constants(settings)]
        return effects.apply([plan], to: frame, layerID: stateID, context: context, commandBuffer: commandBuffer)
    }
}
