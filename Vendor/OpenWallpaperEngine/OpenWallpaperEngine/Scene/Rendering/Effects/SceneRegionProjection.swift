import Metal
import simd

/// The scene under a scene-input layer (composition, `copybackground`) that is drawn through a 3D
/// camera, as its base image: a perspective scene's layer, or a `perspective` layer of an
/// orthographic one.
///
/// WE makes a composition layer's image with `materials/util/composelayer.json` (0x1402092d7): the
/// quad covers the layer's buffer, and each texel samples `_rt_FullFrameBuffer` at
/// `v_ScreenCoord`, the quad point's projection by `g_ModelViewProjectionMatrix`, divided per
/// fragment (`composelayer.vert`/`.frag`). The buffer therefore shows exactly the scene the quad
/// covers on screen, in perspective, whatever its parents, timeline, script or rotation put it.
/// The orthographic path is `SceneRegionResample`, where the projection is affine.
final class SceneRegionProjection {
    private let vertex: MTLFunction
    private let fragment: MTLFunction
    private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    /// Formats whose pipeline failed, logged once.
    private var failed: Set<MTLPixelFormat> = []

    init?(device: MTLDevice) {
        guard let library = SceneMetalLibrary.make(device: device),
              let vertex = library.makeFunction(name: "sceneRegionVertex3D"),
              let fragment = library.makeFunction(name: "sceneRegionFragment3D") else {
            OWELog.error(.scene, "Scene region projection: shader functions missing")
            return nil
        }
        self.vertex = vertex
        self.fragment = fragment
    }

    /// Draws the part of `snapshot` (the scene target so far) under `placement`'s quad into
    /// `region`, which it clears first. False when the pipeline or the pass can't be made (logged).
    func draw(_ snapshot: MTLTexture, under placement: SceneLayerPlacement, into region: MTLTexture,
              commandBuffer: MTLCommandBuffer) -> Bool {
        guard let pipeline = pipeline(for: region.pixelFormat, device: region.device) else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = region
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var native = placement.native
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&native, length: MemoryLayout<LayerPlacement3D>.stride, index: 1)
        encoder.setFragmentTexture(snapshot, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return true
    }

    private func pipeline(for format: MTLPixelFormat, device: MTLDevice) -> MTLRenderPipelineState? {
        if let pipeline = pipelines[format] { return pipeline }
        guard !failed.contains(format) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = format
        do {
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[format] = pipeline
            return pipeline
        } catch {
            failed.insert(format)
            OWELog.error(.scene, "Scene region projection pipeline (\(format.rawValue)) failed: \(error)")
            return nil
        }
    }
}
