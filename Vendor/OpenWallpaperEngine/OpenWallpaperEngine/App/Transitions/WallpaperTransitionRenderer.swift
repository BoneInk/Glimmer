import Foundation
import Metal
import simd

/// Draws WE's playlist transitions with Metal (`WallpaperTransitionShaders.metal`). Each frame is
/// one pass: the outgoing wallpaper as the effect leaves it, premultiplied, for source-over onto the
/// live incoming one; nothing samples the incoming wallpaper. CRT and Ice also need the outgoing
/// picture's blurred mip chain, built once per transition by `prepareOutgoing`.
///
/// Thread-safe: each transition encodes its frames on its own thread. The pipelines, the
/// textures and the facet mesh are built outside `lock` and stored under it; everything else is
/// set once in `init`.
final class WallpaperTransitionRenderer: @unchecked Sendable {
    struct RenderError: Error, CustomStringConvertible {
        /// The transition, or nil for what all of them share (the Metal library).
        let kind: WallpaperTransitionKind?
        let reason: String

        var description: String {
            kind.map { "Transition \($0) (\($0.rawValue)): \(reason)" } ?? "Transitions: \(reason)"
        }
    }

    /// WE's cbuffer g_bufDynamic, as the shaders' `TransitionUniforms` lays it out.
    private struct Uniforms {
        var progress: Float
        var hash: Float
        var hash2: Float
        var random: Float
        var aspectRatio: Float
        var width: Float
        var height: Float
        var padding: Float = 0
        var viewProjection: simd_float4x4
        var viewProjectionInverse: simd_float4x4
    }

    private struct PipelineKey: Hashable {
        let kind: WallpaperTransitionKind
        let pixelFormat: UInt
    }

    let device: MTLDevice
    private let library: MTLLibrary
    private let viewProjection: simd_float4x4
    private let viewProjectionInverse: simd_float4x4

    private let lock = NSLock()
    // Guarded by `lock`.
    private var pipelines: [PipelineKey: MTLRenderPipelineState] = [:]
    private var gaussianPipelines: [UInt: MTLRenderPipelineState] = [:]
    private var textures: WallpaperTransitionTextures?
    private var facets: (buffer: MTLBuffer, vertexCount: Int)?

    /// Bricks: 4 sets of 3 + 4 bricks (the geometry shader's BRICKS_PER_SET × SET_COUNT).
    private static let brickCount = 28

    init(device: MTLDevice) throws {
        self.device = device
        do {
            library = try SceneMetalLibrary.load(device: device)
        } catch {
            throw RenderError(kind: nil, reason: "the engine's Metal library can't be loaded: \(error)")
        }
        viewProjection = Self.shatterCamera()
        viewProjectionInverse = viewProjection.inverse
    }

    // MARK: - Preparing

    /// Compiles (and caches) what `kind` needs for targets of `pixelFormat`, and its textures/mesh. Any thread.
    func preparePipelines(for kind: WallpaperTransitionKind, pixelFormat: MTLPixelFormat) throws {
        _ = try pipeline(for: kind, pixelFormat: pixelFormat)
        if Self.samplesMipChain(kind) { _ = try gaussianPipeline(pixelFormat: .bgra8Unorm, kind: kind) }
        if kind == .boilover { _ = try cloudTextures() }
        if kind == .glassShatter { _ = try facetMesh() }
    }

    /// The outgoing picture as `kind` samples it: `texture` itself, or a mipmapped copy (the
    /// gaussian chain) for the kinds that sample mips. Encoded into `commandBuffer`. An sRGB
    /// texture is read through a plain view, so the effects see its stored values, as WE does.
    func prepareOutgoing(_ texture: MTLTexture, for kind: WallpaperTransitionKind,
                         commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        let source = try samplingView(of: texture, kind: kind)
        guard Self.samplesMipChain(kind) else { return source }
        return try mipChain(of: source, kind: kind, commandBuffer: commandBuffer)
    }

    // MARK: - Drawing

    /// Draws `kind` at `progress` (0...1) into `target`, cleared to transparent first: the outgoing
    /// picture with the transition's coverage, premultiplied, for source-over onto the incoming wallpaper.
    func encode(_ kind: WallpaperTransitionKind, progress: Float, outgoing: MTLTexture, seed: WallpaperTransitionSeed,
                into target: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        let pipeline = try pipeline(for: kind, pixelFormat: target.pixelFormat)
        let source = try samplingView(of: outgoing, kind: kind)
        let mesh = kind == .glassShatter ? try facetMesh() : nil
        let clouds = kind == .boilover ? try cloudTextures() : nil
        var uniforms = Uniforms(progress: progress, hash: seed.hash, hash2: seed.hash2, random: seed.random,
                                aspectRatio: Float(target.width) / Float(target.height),
                                width: Float(target.width), height: Float(target.height),
                                viewProjection: viewProjection, viewProjectionInverse: viewProjectionInverse)

        let passDescriptor = MTLRenderPassDescriptor()
        let attachment = passDescriptor.colorAttachments[0]!
        attachment.texture = target
        attachment.storeAction = .store
        attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        // The quad effects write every pixel, so only the meshes need the clear.
        attachment.loadAction = Self.drawsMesh(kind) ? .clear : .dontCare
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            throw RenderError(kind: kind, reason: "no render command encoder")
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        if let clouds {
            encoder.setFragmentTexture(clouds.noise, index: 1)
            encoder.setFragmentTexture(clouds.clouds, index: 2)
        }
        if let mesh {
            encoder.setVertexBuffer(mesh.buffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.vertexCount)
        } else if kind == .bricks {
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: Self.brickCount)
        } else {
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
    }

    // MARK: - Kinds

    /// CRT and Ice read g_Texture0MipMapped.
    static func samplesMipChain(_ kind: WallpaperTransitionKind) -> Bool {
        kind == .crt || kind == .ice
    }

    /// Bricks and Glass shatter draw pieces that leave the rest of the target empty and overlap.
    private static func drawsMesh(_ kind: WallpaperTransitionKind) -> Bool {
        kind == .bricks || kind == .glassShatter
    }

    // MARK: - Pipelines

    private func pipeline(for kind: WallpaperTransitionKind, pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let key = PipelineKey(kind: kind, pixelFormat: pixelFormat.rawValue)
        if let cached = lock.withLock({ pipelines[key] }) { return cached }
        let made = try makePipeline(for: kind, pixelFormat: pixelFormat)
        return lock.withLock {
            if let cached = pipelines[key] { return cached }
            pipelines[key] = made
            return made
        }
    }

    private func makePipeline(for kind: WallpaperTransitionKind, pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let vertexName: String
        let fragmentName: String
        switch kind {
        case .bricks: (vertexName, fragmentName) = ("transitionBricksVertex", "transitionFragment")
        case .glassShatter: (vertexName, fragmentName) = ("transitionShatterVertex", "transitionShatterFragment")
        default: (vertexName, fragmentName) = ("transitionQuadVertex", "transitionFragment")
        }
        let constants = MTLFunctionConstantValues()
        var effect = Int32(kind.rawValue)
        constants.setConstantValue(&effect, type: .int, index: 0)

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Transition \(kind)"
        do {
            descriptor.vertexFunction = try library.makeFunction(name: vertexName, constantValues: constants)
            descriptor.fragmentFunction = try library.makeFunction(name: fragmentName, constantValues: constants)
        } catch {
            throw RenderError(kind: kind, reason: "its shader functions can't be made: \(error)")
        }
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        if Self.drawsMesh(kind) {
            // Overlapping pieces lay premultiplied over each other.
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw RenderError(kind: kind, reason: "its pipeline for \(pixelFormat.rawValue) can't be made: \(error)")
        }
    }

    private func gaussianPipeline(pixelFormat: MTLPixelFormat, kind: WallpaperTransitionKind) throws -> MTLRenderPipelineState {
        if let cached = lock.withLock({ gaussianPipelines[pixelFormat.rawValue] }) { return cached }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Transition mip chain"
        descriptor.vertexFunction = library.makeFunction(name: "transitionQuadVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "transitionGaussianFragment")
        guard descriptor.vertexFunction != nil, descriptor.fragmentFunction != nil else {
            throw RenderError(kind: kind, reason: "the mip chain's shader functions aren't in the library")
        }
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        let made: MTLRenderPipelineState
        do {
            made = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw RenderError(kind: kind, reason: "the mip chain's pipeline for \(pixelFormat.rawValue) can't be made: \(error)")
        }
        return lock.withLock {
            if let cached = gaussianPipelines[pixelFormat.rawValue] { return cached }
            gaussianPipelines[pixelFormat.rawValue] = made
            return made
        }
    }

    // MARK: - Resources

    private func cloudTextures() throws -> WallpaperTransitionTextures {
        if let cached = lock.withLock({ textures }) { return cached }
        let loaded: WallpaperTransitionTextures
        do {
            loaded = try WallpaperTransitionTextures.load(device: device, assetsDirectory: WallpaperEngineAssets.directory)
        } catch {
            throw RenderError(kind: .boilover, reason: "its textures can't be loaded: \(error)")
        }
        return lock.withLock {
            if let cached = textures { return cached }
            textures = loaded
            return loaded
        }
    }

    private func facetMesh() throws -> (buffer: MTLBuffer, vertexCount: Int) {
        if let cached = lock.withLock({ facets }) { return cached }
        let vertices = WallpaperTransitionFacets.make()
        let length = vertices.count * MemoryLayout<WallpaperTransitionFacets.Vertex>.stride
        guard let buffer = vertices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: length) }) else {
            throw RenderError(kind: .glassShatter, reason: "no buffer for its \(vertices.count) facet vertices")
        }
        buffer.label = "Transition facets"
        return lock.withLock {
            if let cached = facets { return cached }
            facets = (buffer, vertices.count)
            return (buffer, vertices.count)
        }
    }

    // MARK: - Outgoing picture

    /// `texture`, or a non-sRGB view of it: WE blends the stored (gamma-encoded) values.
    private func samplingView(of texture: MTLTexture, kind: WallpaperTransitionKind) throws -> MTLTexture {
        let plain: MTLPixelFormat
        switch texture.pixelFormat {
        case .bgra8Unorm_srgb: plain = .bgra8Unorm
        case .rgba8Unorm_srgb: plain = .rgba8Unorm
        default: return texture
        }
        guard let view = texture.makeTextureView(pixelFormat: plain) else {
            throw RenderError(kind: kind, reason: "no \(plain.rawValue) view of the outgoing picture (\(texture.pixelFormat.rawValue))")
        }
        return view
    }

    /// g_Texture0MipMapped: level 0 is the picture, and each level after it the 3×3 gaussian of the
    /// one before at half the size, down to 1×1.
    private func mipChain(of source: MTLTexture, kind: WallpaperTransitionKind,
                          commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        let gaussian = try gaussianPipeline(pixelFormat: source.pixelFormat, kind: kind)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat, width: source.width,
                                                                  height: source.height, mipmapped: true)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        guard let chain = device.makeTexture(descriptor: descriptor),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw RenderError(kind: kind, reason: "no \(source.width)×\(source.height) mip chain for the outgoing picture")
        }
        chain.label = "Transition outgoing mip chain"
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                  to: chain, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = chain
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        for level in 1..<chain.mipmapLevelCount {
            guard let above = chain.makeTextureView(pixelFormat: chain.pixelFormat, textureType: .type2D,
                                                    levels: (level - 1)..<level, slices: 0..<1) else {
                throw RenderError(kind: kind, reason: "no view of mip level \(level - 1)")
            }
            pass.colorAttachments[0].level = level
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw RenderError(kind: kind, reason: "no render command encoder for mip level \(level)")
            }
            encoder.setRenderPipelineState(gaussian)
            encoder.setFragmentTexture(above, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }
        return chain
    }

    // MARK: - Camera

    /// g_ViewProjection for Glass shatter: a 45° perspective camera on +z looking at the z = 0
    /// plane from the distance where the plane's [-1, 1]² exactly fills the target, so the
    /// unbroken pane at progress 0 is the picture. Column-major, for `matrix * vector` in Metal
    /// (WE's HLSL multiplies row vectors, `mul(v, M)`, with the transpose).
    static func shatterCamera() -> simd_float4x4 {
        let distance: Float = 1 / tanf(Float.pi / 8)
        let near: Float = 0.1
        let far: Float = 100
        // x and y scale by the distance, so (x, y, 0) lands on NDC (x, y) whatever the aspect.
        let projection = simd_float4x4(columns: (SIMD4<Float>(distance, 0, 0, 0), SIMD4<Float>(0, distance, 0, 0),
                                                 SIMD4<Float>(0, 0, far / (near - far), -1),
                                                 SIMD4<Float>(0, 0, near * far / (near - far), 0)))
        let view = simd_float4x4(columns: (SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0),
                                           SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(0, 0, -distance, 1)))
        let viewProjection: simd_float4x4 = projection * view
        return viewProjection
    }
}
