import Foundation
import Metal

/// WE's camera fade (docs/lighting-plan.md §2.6 step 7, docs/models-plan.md §2.2): while a scene
/// camera path starts or ends, `materials/util/fade.json` is drawn over the finished frame, after
/// the bloom and the colour correction (0x140180c1a…0x140180cc0).
///
/// The pass is WE's own: `fade` fills the frame with `color · 0.7` at alpha `g_Alpha`, blended
/// translucent. `g_Alpha` is the fade (`SceneFrameCamera.fade`); `color` is the material's `tint`,
/// which `usershadervalues` binds to the wallpaper's `schemecolor` property and otherwise has the
/// shader's default (0.315, 0.135, 0.1125). WE makes the pass only for a scene with camera paths
/// (0x140181bae).
final class SceneCameraFade {
    static let effectFile = "engine:camerafade.json"
    static let effectDocument = #"{"passes": [{"material": "materials/util/fade.json"}]}"#

    let pass: SceneEffectPassPlan
    private let variant: TranslatedShaderVariant
    private let program: UniformProgram
    private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var failedFormats: Set<MTLPixelFormat> = []
    private var quad: MTLBuffer?
    /// The last frame's fade: its alpha and the texture it was drawn on (tests).
    private(set) var lastFade: (alpha: Float, frame: MTLTexture)?

    /// Plans the pass with `builder`'s translator, files and engine combos.
    static func build(with builder: SceneEffectPlanBuilder) throws -> SceneCameraFade {
        let document = Data(effectDocument.utf8)
        let engine = SceneEffectPlanBuilder(
            translator: builder.translator,
            readFile: { $0 == effectFile ? document : builder.readFile($0) },
            loadTexture: builder.loadTexture,
            sceneEngineCombos: builder.sceneEngineCombos)
        let effect = try JSONDecoder().decode(WEObjectEffect.self, from: Data(#"{"file": "\#(effectFile)"}"#.utf8))
        let plan = try engine.build(effect)
        guard plan.passes.count == 1, let variant = plan.passes[0].variant else {
            throw SceneEffectPlanError.missing("fade's shader")
        }
        return SceneCameraFade(pass: plan.passes[0], variant: variant)
    }

    private init(pass: SceneEffectPassPlan, variant: TranslatedShaderVariant) {
        self.pass = pass
        self.variant = variant
        program = UniformProgram(layout: variant.uniforms, constants: pass.constants)
    }

    /// Draws the fade over `frame` when `alpha` is above 0 (WE draws none otherwise). `values`
    /// resolves the bound `tint`. `records` false leaves `lastFade` as it is (the detail patch's run).
    func encode(on frame: MTLTexture, alpha: Float, builtins: BuiltinFrameContext, values: SceneValueContext,
                records: Bool = true, commandBuffer: MTLCommandBuffer) {
        if records { lastFade = nil }
        guard alpha > 0, let pipeline = pipeline(for: frame.pixelFormat, device: frame.device),
              let quad = quadBuffer(device: frame.device) else { return }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = frame
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "camera fade"
        encoder.setRenderPipelineState(pipeline)
        var context = BuiltinPassContext(targetSize: SIMD2(Float(frame.width), Float(frame.height)))
        context.alpha = alpha
        program.update(frame: builtins, pass: context, values: values)
        if program.size > 0 {
            program.bytes.withUnsafeBytes { raw in
                encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
                encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
            }
        }
        encoder.setVertexBuffer(quad, offset: 0, index: EffectGraphRenderer.positionBuffer)
        encoder.setVertexBuffer(quad, offset: 0, index: EffectGraphRenderer.texCoordBuffer)
        encoder.setVertexBuffer(quad, offset: 0, index: EffectGraphRenderer.zeroBuffer)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        if records { lastFade = (alpha, frame) }
    }

    /// The full-target strip, as the effect graph draws its passes (x, y, z per vertex; the
    /// texcoord and zero attributes the shader may declare read the same floats, unused).
    private func quadBuffer(device: MTLDevice) -> MTLBuffer? {
        if let quad { return quad }
        let positions: [Float] = [-1, -1, 0, 1, -1, 0, -1, 1, 0, 1, 1, 0, 0, 0, 0, 0]
        quad = device.makeBuffer(bytes: positions, length: positions.count * 4)
        return quad
    }

    /// The pass's pipeline for a target format, made on first use; nil (logged once) when it fails.
    private func pipeline(for format: MTLPixelFormat, device: MTLDevice) -> MTLRenderPipelineState? {
        if let pipeline = pipelines[format] { return pipeline }
        guard !failedFormats.contains(format) else { return nil }
        do {
            let (vertexLibrary, fragmentLibrary) = try variant.makeLibraries(device: device)
            guard let vertex = vertexLibrary.makeFunction(name: "main0"),
                  let fragment = fragmentLibrary.makeFunction(name: "main0") else {
                throw ShaderCompilerError.failed(step: "metal", output: "entry point main0 missing")
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "camera fade"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = format
            if let blend = EffectGraphRenderer.blendMode(pass.blending) {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = blend.source
                attachment.sourceAlphaBlendFactor = blend.source
                attachment.destinationRGBBlendFactor = blend.destination
                attachment.destinationAlphaBlendFactor = blend.destination
            }
            descriptor.vertexDescriptor = EffectGraphRenderer.vertexDescriptor(for: vertex)
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[format] = pipeline
            return pipeline
        } catch {
            failedFormats.insert(format)
            OWELog.error(.shader, "WE's camera fade can't be drawn on \(format.rawValue) targets: \(error)")
            return nil
        }
    }
}
