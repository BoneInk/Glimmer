import Foundation
import Metal

/// The pipelines the scene pass draws with natively (a layer's quad blended normally or
/// additively, and an unblended region copy), in each format the scene target can have: the
/// drawable's in LDR, RGBA16F in HDR (docs/lighting-plan.md §2.6). With WE's MSAA setting the
/// scene pass draws multisampled, and a perspective scene's pass has a depth buffer
/// (`SceneDepthStates`, docs/models-plan.md §2.4); the pipelines for a sample count above 1 or a
/// depth format are made when first asked for.
final class SceneLayerPipelines {
    struct Pipelines {
        let normal: MTLRenderPipelineState
        let additive: MTLRenderPipelineState
        let copy: MTLRenderPipelineState
        /// The copy writing colour only, the target's alpha kept (`SceneMetalLayer.clearsSceneAlpha`).
        let colourCopy: MTLRenderPipelineState
        /// The copy resample added onto the target's colour, its alpha kept: a reduced-resolution
        /// additive particle pass composited back (`SceneRenderSettings.reducedResolutionParticles`).
        let addCopy: MTLRenderPipelineState
        /// A layer quad drawn through a 3D camera (`sceneVertex3D`, `SceneLayerPlacement`); nil
        /// without that vertex function.
        let placedNormal: MTLRenderPipelineState?
        let placedAdditive: MTLRenderPipelineState?
    }

    private struct Variant: Hashable {
        var format: MTLPixelFormat
        var sampleCount: Int
        var depthFormat: MTLPixelFormat
    }

    private struct Functions {
        let vertex: MTLFunction
        let fragment: MTLFunction
        let copy: MTLFunction
        let placedVertex: MTLFunction?
    }

    private let byFormat: [MTLPixelFormat: Pipelines]
    private let fallback: Pipelines
    private let fallbackFormat: MTLPixelFormat
    private let device: MTLDevice
    private let functions: Functions
    /// Made on first use, on the render thread; nil for one that failed (logged once). Behind
    /// `variantsLock`, so a frame drawn on another thread can't corrupt it.
    private var variants: [Variant: Pipelines?] = [:]
    /// Target formats `pipelines(for:)` had none for and drew with the first format's (logged
    /// once each). Behind `variantsLock`.
    private var unmadeFormats: Set<MTLPixelFormat> = []
    private let variantsLock = NSLock()

    /// The pipelines for each of `formats`, the first of which `pipelines(for:)` falls back to.
    /// `placedVertex` is `sceneVertex3D`. Throws when one can't be made.
    init(device: MTLDevice, vertex: MTLFunction, fragment: MTLFunction, copyFragment: MTLFunction,
         placedVertex: MTLFunction? = nil, formats: [MTLPixelFormat]) throws {
        let functions = Functions(vertex: vertex, fragment: fragment, copy: copyFragment, placedVertex: placedVertex)
        var byFormat: [MTLPixelFormat: Pipelines] = [:]
        for format in formats where byFormat[format] == nil {
            byFormat[format] = try Self.make(device: device, functions: functions,
                                             variant: Variant(format: format, sampleCount: 1, depthFormat: .invalid))
        }
        guard let first = formats.first, let fallback = byFormat[first] else {
            throw ShaderCompilerError.failed(step: "metal", output: "no scene target format")
        }
        self.byFormat = byFormat
        self.fallback = fallback
        fallbackFormat = first
        self.device = device
        self.functions = functions
    }

    /// The pipelines drawing into a single-sampled target of `format` without depth; the first
    /// format's for one they weren't made for (logged once per format).
    func pipelines(for format: MTLPixelFormat?) -> Pipelines {
        guard let format else { return fallback }
        if let made = byFormat[format] { return made }
        variantsLock.lock()
        let isNew = unmadeFormats.insert(format).inserted
        variantsLock.unlock()
        if isNew {
            OWELog.debug(.scene, "Layer pipelines: no pipelines for target format \(format.rawValue); drawing with format \(fallbackFormat.rawValue)'s")
        }
        return fallback
    }

    /// The pipelines drawing into a `sampleCount`-sample target of `format` with a `depthFormat`
    /// depth attachment (`.invalid`: none); nil when they can't be made (the caller draws
    /// single-sampled). Called on the render thread; safe from any.
    func pipelines(for format: MTLPixelFormat, sampleCount: Int,
                   depthFormat: MTLPixelFormat = .invalid) -> Pipelines? {
        guard sampleCount > 1 || depthFormat != .invalid else { return pipelines(for: format) }
        let key = Variant(format: format, sampleCount: max(sampleCount, 1), depthFormat: depthFormat)
        variantsLock.lock()
        defer { variantsLock.unlock() }
        if let known = variants[key] { return known }
        do {
            let made = try Self.make(device: device, functions: functions, variant: key)
            variants[key] = made
            return made
        } catch {
            let what = sampleCount > 1 ? "\(sampleCount)× MSAA" : "depth"
            OWELog.error(.scene, "The scene's \(what) pipelines can't be made; it draws without: \(error)")
            variants[key] = .some(nil)
            return nil
        }
    }

    /// The layer pipeline's descriptor in `format`: source-over blending.
    static func layerDescriptor(vertex: MTLFunction, fragment: MTLFunction, format: MTLPixelFormat) -> MTLRenderPipelineDescriptor {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = format
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.sourceAlphaBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return descriptor
    }

    private static func make(device: MTLDevice, functions: Functions, variant: Variant) throws -> Pipelines {
        func blended(_ vertex: MTLFunction, additive: Bool) throws -> MTLRenderPipelineState {
            let descriptor = layerDescriptor(vertex: vertex, fragment: functions.fragment, format: variant.format)
            descriptor.rasterSampleCount = variant.sampleCount
            descriptor.depthAttachmentPixelFormat = variant.depthFormat
            if additive {
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        let copyDescriptor = MTLRenderPipelineDescriptor()
        copyDescriptor.vertexFunction = functions.vertex
        copyDescriptor.fragmentFunction = functions.copy
        copyDescriptor.colorAttachments[0].pixelFormat = variant.format
        copyDescriptor.rasterSampleCount = variant.sampleCount
        copyDescriptor.depthAttachmentPixelFormat = variant.depthFormat
        let copy = try device.makeRenderPipelineState(descriptor: copyDescriptor)
        copyDescriptor.colorAttachments[0].writeMask = [.red, .green, .blue]
        let colourCopy = try device.makeRenderPipelineState(descriptor: copyDescriptor)
        copyDescriptor.colorAttachments[0].writeMask = .all
        let add = copyDescriptor.colorAttachments[0]!
        add.isBlendingEnabled = true
        add.sourceRGBBlendFactor = .one
        add.destinationRGBBlendFactor = .one
        add.sourceAlphaBlendFactor = .zero
        add.destinationAlphaBlendFactor = .one
        return Pipelines(normal: try blended(functions.vertex, additive: false),
                         additive: try blended(functions.vertex, additive: true),
                         copy: copy, colourCopy: colourCopy, addCopy: try device.makeRenderPipelineState(descriptor: copyDescriptor),
                         placedNormal: try functions.placedVertex.map { try blended($0, additive: false) },
                         placedAdditive: try functions.placedVertex.map { try blended($0, additive: true) })
    }
}
