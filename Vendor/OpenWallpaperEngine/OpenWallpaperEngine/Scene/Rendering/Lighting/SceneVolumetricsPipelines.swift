import Foundation
import Metal
import simd

/// The GPU side of WE's volumetrics passes (`SceneVolumetrics`): pipelines for the translated util
/// shaders, their meshes, uniform blocks and the depth conversion.
///
/// Pipelines compile off the render thread, like the effect graph's; a frame whose pipelines
/// aren't ready draws no volumetrics.
final class SceneVolumetricsPipelines {
    /// How a pass rasterises: which faces it keeps and whether it writes depth.
    enum Raster: Hashable {
        /// `volumetrics_back`: the far faces' depth, nothing else.
        case farFacesDepth
        /// `volumetrics_front`: the near faces, blended.
        case nearFaces
        /// `volumetrics_fullscreen`, the blur and the combine: every triangle.
        case everything
    }

    private struct Key: Hashable {
        let variant: String
        let color: MTLPixelFormat
        let raster: Raster
        let blending: String
    }

    private let device: MTLDevice
    private let lock = NSLock()
    private var ready: [Key: MTLRenderPipelineState] = [:] // guarded by lock
    private var pending: Set<Key> = [] // guarded by lock
    private var failed: Set<Key> = [] // guarded by lock
    private var landed = 0 // guarded by lock
    private let compileQueue = DispatchQueue(label: "owe.volumetrics.pipelines", qos: .userInitiated)
    private let clipDepth: MTLComputePipelineState
    let farDepth: MTLDepthStencilState
    let noDepth: MTLDepthStencilState
    let linearClamp: MTLSamplerState
    let nearestClamp: MTLSamplerState
    private var meshes: [SceneVolumeMesh.Shape: (positions: MTLBuffer, indices: MTLBuffer, count: Int)] = [:]
    let fullscreenTriangle: MTLBuffer
    /// The effect graph's quad (`EffectGraphRenderer`): a strip whose texcoord (0, 0) lands on the
    /// first row, so the blur and the combine map rows 1:1.
    let quadPositions: MTLBuffer
    let quadTexCoords: MTLBuffer
    let zeroAttributes: MTLBuffer

    init?(device: MTLDevice) {
        self.device = device
        do {
            let library = try SceneMetalLibrary.load(device: device)
            guard let function = library.makeFunction(name: "volumetricsClipDepth") else {
                OWELog.error(.scene, "The volumetrics depth kernel is missing from the app's library")
                return nil
            }
            clipDepth = try device.makeComputePipelineState(function: function)
        } catch {
            OWELog.error(.scene, "The volumetrics depth kernel can't be made: \(error)")
            return nil
        }
        // Reversed depth: the nearest far face is the greatest (WE's GREATER, 0x140099050).
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .greater
        depth.isDepthWriteEnabled = true
        let none = MTLDepthStencilDescriptor()
        none.depthCompareFunction = .always
        none.isDepthWriteEnabled = false
        func sampler(_ filter: MTLSamplerMinMagFilter) -> MTLSamplerState? {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = filter
            descriptor.magFilter = filter
            descriptor.sAddressMode = .clampToEdge
            descriptor.tAddressMode = .clampToEdge
            return device.makeSamplerState(descriptor: descriptor)
        }
        let triangle = SceneVolumeMesh.fullscreenTriangle.flatMap { [$0.x, $0.y, $0.z] }
        let positions: [Float] = [-1, -1, 0, 1, -1, 0, -1, 1, 0, 1, 1, 0]
        let texCoords: [Float] = [0, 0, 1, 0, 0, 1, 1, 1]
        guard let farDepth = device.makeDepthStencilState(descriptor: depth),
              let noDepth = device.makeDepthStencilState(descriptor: none),
              let linear = sampler(.linear), let nearest = sampler(.nearest),
              let fullscreen = device.makeBuffer(bytes: triangle, length: triangle.count * 4),
              let quadPositions = device.makeBuffer(bytes: positions, length: positions.count * 4),
              let quadTexCoords = device.makeBuffer(bytes: texCoords, length: texCoords.count * 4),
              let zero = device.makeBuffer(length: 64) else { return nil }
        self.farDepth = farDepth
        self.noDepth = noDepth
        linearClamp = linear
        nearestClamp = nearest
        fullscreenTriangle = fullscreen
        self.quadPositions = quadPositions
        self.quadTexCoords = quadTexCoords
        zeroAttributes = zero
    }

    // MARK: - Pipelines

    /// Starts compiling every pipeline `plan` draws with, for light buffers and a scene of `sceneFormat`.
    func prepare(_ plan: SceneVolumetricsPlan, sceneFormat: MTLPixelFormat) {
        let buffer = Self.lightBufferFormat(scene: sceneFormat)
        for light in plan.lights {
            _ = pipeline(light.back, color: .invalid, raster: .farFacesDepth)
            _ = pipeline(light.front, color: buffer, raster: .nearFaces)
            _ = pipeline(light.fullscreen, color: buffer, raster: .everything)
        }
        for pass in [plan.blurH, plan.blurV].compactMap({ $0 }) { _ = pipeline(pass, color: buffer, raster: .everything) }
        _ = pipeline(plan.combine, color: sceneFormat, raster: .everything)
    }

    /// Every pipeline of `plan` compiled or failed (tests, prewarming).
    func waitUntilReady(_ plan: SceneVolumetricsPlan, sceneFormat: MTLPixelFormat, timeout: TimeInterval = 60) -> Bool {
        prepare(plan, sceneFormat: sceneFormat)
        let deadline = Date().addingTimeInterval(timeout)
        while lock.withLock({ !pending.isEmpty }) {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return true
    }

    var failedCount: Int { lock.withLock { failed.count } }
    /// Whether a pipeline is still compiling: a frame drawn now lacks the volumes.
    var hasPendingPipelines: Bool { lock.withLock { !pending.isEmpty } }
    /// Compiles finished so far, however they ended.
    var pipelinesLanded: Int { lock.withLock { landed } }

    /// WE's light buffers are the frame buffer's class: RGBA8, or RGBA16F in HDR (0x140196e49).
    static func lightBufferFormat(scene: MTLPixelFormat) -> MTLPixelFormat {
        scene == .rgba16Float ? .rgba16Float : .rgba8Unorm
    }

    /// The pass's pipeline, or nil while it compiles (the compile is started) or after it failed.
    func pipeline(_ pass: SceneVolumetricsPass, color: MTLPixelFormat, raster: Raster) -> MTLRenderPipelineState? {
        let key = Key(variant: pass.variantKey, color: color, raster: raster, blending: pass.blending)
        let start: Bool = lock.withLock {
            if ready[key] != nil || failed.contains(key) || pending.contains(key) { return false }
            pending.insert(key)
            return true
        }
        if start {
            let device = self.device, variant = pass.variant
            compileQueue.async { [weak self] in
                let made = Self.compile(variant, key: key, device: device)
                guard let self else { return }
                self.lock.withLock {
                    self.pending.remove(key)
                    self.landed += 1
                    if let made { self.ready[key] = made } else { self.failed.insert(key) }
                }
            }
        }
        return lock.withLock { ready[key] }
    }

    private static func compile(_ variant: TranslatedShaderVariant, key: Key, device: MTLDevice) -> MTLRenderPipelineState? {
        do {
            let (vertexLibrary, fragmentLibrary) = try variant.makeLibraries(device: device)
            guard let vertex = vertexLibrary.makeFunction(name: "main0"),
                  let fragment = fragmentLibrary.makeFunction(name: "main0") else {
                throw ShaderCompilerError.failed(step: "metal", output: "entry point main0 missing")
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.vertexDescriptor = EffectGraphRenderer.vertexDescriptor(for: vertex)
            if key.raster == .farFacesDepth {
                // WE's back target is depth alone (format 0x1b, 0x140196dc7).
                descriptor.depthAttachmentPixelFormat = .depth32Float
            } else {
                descriptor.fragmentFunction = fragment
                descriptor.colorAttachments[0].pixelFormat = key.color
                if let blend = EffectGraphRenderer.blendMode(key.blending) {
                    let attachment = descriptor.colorAttachments[0]!
                    attachment.isBlendingEnabled = true
                    attachment.sourceRGBBlendFactor = blend.source
                    attachment.sourceAlphaBlendFactor = blend.source
                    attachment.destinationRGBBlendFactor = blend.destination
                    attachment.destinationAlphaBlendFactor = blend.destination
                }
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            OWELog.error(.shader, "Volumetrics pipeline failed (\(key.variant.prefix(12))): \(error)")
            return nil
        }
    }

    // MARK: - Drawing

    /// `shape`'s vertex and index buffers, made once.
    func mesh(_ shape: SceneVolumeMesh.Shape) -> (positions: MTLBuffer, indices: MTLBuffer, count: Int)? {
        if let made = meshes[shape] { return made }
        let mesh = SceneVolumeMesh.make(shape)
        let flat = mesh.positions.flatMap { [$0.x, $0.y, $0.z] }
        guard let positions = device.makeBuffer(bytes: flat, length: flat.count * 4),
              let indices = device.makeBuffer(bytes: mesh.indices, length: mesh.indices.count * 2) else { return nil }
        meshes[shape] = (positions, indices, mesh.indices.count)
        return meshes[shape]
    }

    /// Faces wound outward (`SceneVolumeMesh`) that face the camera turn counter-clockwise on
    /// screen after `transform` (object to clip space) when it keeps orientation: with clip depth
    /// growing away from the eye, a kept orientation mirrors them once, and the translator's y
    /// flip mirrors them back. A reversed projection's depth grows towards the eye, which flips
    /// the determinant's sign and not the screen's winding.
    static func frontWinding(_ transform: simd_float4x4, reversedDepth: Bool) -> MTLWinding {
        (transform.determinant > 0) != reversedDepth ? .counterClockwise : .clockwise
    }

    /// The pass's `WEUniforms` block: `values` by uniform name, then WE's built-ins.
    static func uniforms(_ pass: SceneVolumetricsPass, values: [String: [Float]], frame: BuiltinFrameContext,
                         targetSize: SIMD2<Float>) -> [UInt8] {
        guard let layout = pass.variant.uniforms else { return [] }
        var bytes = [UInt8](repeating: 0, count: layout.size)
        let context = BuiltinPassContext(targetSize: targetSize)
        for member in layout.members.values {
            if let value = values[member.name] ?? BuiltinUniforms.value(
                named: member.name, frame: frame, pass: context, arrayCount: member.count > 1 ? member.count : nil) {
                UniformWriter.write(value, member: member, into: &bytes)
            }
        }
        return bytes
    }

    static func flat(_ matrix: simd_float4x4) -> [Float] {
        [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    /// Converts `depth` (a Metal depth target) to the clip depth WE's shaders read, into `clip`
    /// (`volumetricsClipDepth`).
    func encodeClipDepth(_ depth: MTLTexture, into clip: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "volumetrics clip depth"
        encoder.setComputePipelineState(clipDepth)
        encoder.setTexture(depth, index: 0)
        encoder.setTexture(clip, index: 1)
        let group = MTLSize(width: 8, height: 8, depth: 1)
        encoder.dispatchThreadgroups(MTLSize(width: (clip.width + 7) / 8, height: (clip.height + 7) / 8, depth: 1),
                                     threadsPerThreadgroup: group)
        encoder.endEncoding()
    }
}
