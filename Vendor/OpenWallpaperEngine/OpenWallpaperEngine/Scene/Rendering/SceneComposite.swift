import Metal

/// The final pass that puts the scene target on the drawable.
enum SceneComposite {
    /// `layerDescriptor` with blending off and alpha left alone: WE presents the scene's colour and
    /// ignores its alpha, which translucent and `normal` layers leave below 1 in partly transparent
    /// areas. Blending it over the drawable's clear colour would darken those areas.
    static func pipelineDescriptor(basedOn layerDescriptor: MTLRenderPipelineDescriptor) -> MTLRenderPipelineDescriptor {
        let descriptor = layerDescriptor.copy() as! MTLRenderPipelineDescriptor
        descriptor.colorAttachments[0].isBlendingEnabled = false
        descriptor.colorAttachments[0].writeMask = [.red, .green, .blue]
        return descriptor
    }
}
