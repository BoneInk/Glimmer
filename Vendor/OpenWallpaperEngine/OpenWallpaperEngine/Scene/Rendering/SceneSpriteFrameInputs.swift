import Metal
import simd

/// The current sprite-sheet frame of an animated layer, cut out of its atlas, for the layer's
/// effects to start from. WE's base pass draws the layer's material (its `SPRITESHEET` UVs) into
/// a buffer of the frame's size, so the effects see one frame, texel for texel, and their masks
/// and resolutions line up with it; the layer then draws the effects' output whole. Fed the atlas
/// instead, every effect would run over the whole sheet and the layer would draw one frame's
/// share of that (a mask's corner stretched over the quad). An image inside a padded `.tex` is cut
/// out of its allocation the same way, as WE's base pass draws it into a buffer of the image's size.
/// A block-compressed texture is decoded into the cut (`spriteFrameCutFragment`), since a blit
/// copies only whole blocks.
final class SceneSpriteFrameInputs {
    struct Input {
        let texture: MTLTexture
        /// Bumped whenever the frame cut into `texture` changes (`EffectGraphRenderer.Context.inputVersion`).
        let version: UInt64
    }

    private struct Entry {
        var texture: MTLTexture
        var atlas: ObjectIdentifier
        var region: MTLRegion
        var version: UInt64
    }

    private let device: MTLDevice
    private var entries: [String: Entry] = [:]
    private var nextVersion: UInt64 = 1 << 40

    /// Decodes a rect of a block-compressed texture, made on first use; nil when it can't be made.
    private lazy var cutPipeline: MTLRenderPipelineState? = {
        guard let library = SceneMetalLibrary.make(device: device),
              let vertex = library.makeFunction(name: "spriteFrameCutVertex"),
              let fragment = library.makeFunction(name: "spriteFrameCutFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = Self.decodedFormat
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            OWELog.error(.scene, "Sprite frame cut pipeline failed: \(error)")
            return nil
        }
    }()

    /// What a block-compressed texture's cut is decoded into (WE's DXT formats are all unorm).
    static let decodedFormat = MTLPixelFormat.rgba8Unorm

    init(device: MTLDevice) { self.device = device }

    static func isBlockCompressed(_ format: MTLPixelFormat) -> Bool {
        (MTLPixelFormat.bc1_rgba.rawValue...MTLPixelFormat.bc7_rgbaUnorm_srgb.rawValue).contains(format.rawValue)
    }

    /// The atlas's pixel rect `frame` covers; nil when the frame is the whole texture, sheared or
    /// turned (`widthY`/`heightX`), or off the texture.
    static func region(of frame: RenderTextureFrame) -> MTLRegion? {
        guard frame.uvAxisX.y == 0, frame.uvAxisY.x == 0 else { return nil }
        let size = SIMD2(Float(frame.texture.width), Float(frame.texture.height))
        let origin = (frame.uvOrigin * size).rounded(.toNearestOrAwayFromZero)
        let extent = (SIMD2(frame.uvAxisX.x, frame.uvAxisY.y) * size).rounded(.toNearestOrAwayFromZero)
        guard origin.x >= 0, origin.y >= 0, extent.x >= 1, extent.y >= 1,
              origin.x + extent.x <= size.x, origin.y + extent.y <= size.y,
              origin != .zero || extent != size else { return nil }
        return MTLRegionMake2D(Int(origin.x), Int(origin.y), Int(extent.x), Int(extent.y))
    }

    /// `frame` cut out of its atlas into the layer's own texture (copied on `commandBuffer` when the
    /// frame changed); nil when the frame is its whole texture or can't be cut out.
    func input(_ frame: RenderTextureFrame, layerID: String, commandBuffer: MTLCommandBuffer) -> Input? {
        guard let region = Self.region(of: frame) else { return nil }
        let atlas = ObjectIdentifier(frame.texture)
        if let entry = entries[layerID], entry.atlas == atlas, entry.region.origin.x == region.origin.x,
           entry.region.origin.y == region.origin.y, entry.texture.width == region.size.width,
           entry.texture.height == region.size.height {
            return Input(texture: entry.texture, version: entry.version)
        }
        let decodes = Self.isBlockCompressed(frame.texture.pixelFormat)
        let format = decodes ? Self.decodedFormat : frame.texture.pixelFormat
        var texture = entries[layerID]?.texture
        if texture?.width != region.size.width || texture?.height != region.size.height || texture?.pixelFormat != format {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: region.size.width, height: region.size.height, mipmapped: false)
            descriptor.usage = decodes ? [.shaderRead, .renderTarget] : [.shaderRead]
            descriptor.storageMode = .private
            texture = device.makeTexture(descriptor: descriptor)
        }
        guard let texture else { return nil }
        if decodes {
            guard let pipeline = cutPipeline else { return nil }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            var origin = SIMD2<UInt32>(UInt32(region.origin.x), UInt32(region.origin.y))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(frame.texture, index: 0)
            encoder.setFragmentBytes(&origin, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        } else {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
            blit.copy(from: frame.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: region.origin, sourceSize: region.size,
                      to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
            blit.endEncoding()
        }
        nextVersion &+= 1
        entries[layerID] = Entry(texture: texture, atlas: atlas, region: region, version: nextVersion)
        return Input(texture: texture, version: nextVersion)
    }

    func releaseLayer(_ id: String) { entries.removeValue(forKey: id) }
    func releaseAll() { entries.removeAll() }
}
