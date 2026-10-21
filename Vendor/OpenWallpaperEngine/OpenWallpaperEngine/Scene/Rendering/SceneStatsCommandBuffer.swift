import Foundation
import Metal

/// Stand-ins for a frame's command buffer and its encoders while the stats overlay counts the frame
/// (`SceneFrameStatsRecorder`). Each answers the few messages it counts (a draw, a pipeline, a
/// texture, a render pass, a copy) and passes them on; every other message goes straight to the
/// real object (`forwardingTarget(for:)`), so the renderer's code draws as before. They exist only
/// while stats are shown: a frame without them is the real command buffer.
///
/// Metal's protocols are Objective-C protocols, whose existentials are a plain object reference,
/// so the stand-in is handed out as one (`unsafeBitCast`) and every call reaches it by message.
class SceneStatsForwarder: NSObject {
    let forwarded: NSObject
    let recorder: SceneFrameStatsRecorder

    init(_ forwarded: NSObject, recorder: SceneFrameStatsRecorder) {
        self.forwarded = forwarded
        self.recorder = recorder
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        forwarded
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || forwarded.responds(to: aSelector)
    }

    override func conforms(to aProtocol: Protocol) -> Bool {
        forwarded.conforms(to: aProtocol)
    }

    override var description: String { forwarded.description }
}

final class SceneStatsCommandBuffer: SceneStatsForwarder {
    static func wrap(_ buffer: MTLCommandBuffer, recorder: SceneFrameStatsRecorder) -> MTLCommandBuffer {
        guard let object = buffer as? NSObject else { return buffer }
        return unsafeBitCast(SceneStatsCommandBuffer(object, recorder: recorder), to: MTLCommandBuffer.self)
    }

    private var real: MTLCommandBuffer { unsafeBitCast(forwarded, to: MTLCommandBuffer.self) }

    @objc(renderCommandEncoderWithDescriptor:)
    func renderCommandEncoder(descriptor: MTLRenderPassDescriptor) -> MTLRenderCommandEncoder? {
        guard let encoder = real.makeRenderCommandEncoder(descriptor: descriptor) else { return nil }
        recorder.renderPass(descriptor)
        return SceneStatsRenderEncoder.wrap(encoder, recorder: recorder)
    }

    @objc(blitCommandEncoder)
    func blitCommandEncoder() -> MTLBlitCommandEncoder? {
        real.makeBlitCommandEncoder().map { SceneStatsBlitEncoder.wrap($0, recorder: recorder) }
    }

    @objc(blitCommandEncoderWithDescriptor:)
    func blitCommandEncoder(descriptor: MTLBlitPassDescriptor) -> MTLBlitCommandEncoder? {
        real.makeBlitCommandEncoder(descriptor: descriptor).map { SceneStatsBlitEncoder.wrap($0, recorder: recorder) }
    }
}

final class SceneStatsRenderEncoder: SceneStatsForwarder {
    static func wrap(_ encoder: MTLRenderCommandEncoder, recorder: SceneFrameStatsRecorder) -> MTLRenderCommandEncoder {
        guard let object = encoder as? NSObject else { return encoder }
        return unsafeBitCast(SceneStatsRenderEncoder(object, recorder: recorder), to: MTLRenderCommandEncoder.self)
    }

    private var real: MTLRenderCommandEncoder { unsafeBitCast(forwarded, to: MTLRenderCommandEncoder.self) }

    @objc(setRenderPipelineState:)
    func setRenderPipelineState(_ state: MTLRenderPipelineState) {
        recorder.program(state)
        real.setRenderPipelineState(state)
    }

    @objc(setFragmentTexture:atIndex:)
    func setFragmentTexture(_ texture: MTLTexture?, index: Int) {
        recorder.texture(texture)
        real.setFragmentTexture(texture, index: index)
    }

    @objc(setVertexTexture:atIndex:)
    func setVertexTexture(_ texture: MTLTexture?, index: Int) {
        recorder.texture(texture)
        real.setVertexTexture(texture, index: index)
    }

    @objc(setFragmentTextures:withRange:)
    func setFragmentTextures(_ textures: UnsafePointer<MTLTexture?>, range: NSRange) {
        for offset in 0..<range.length { recorder.texture(textures[offset]) }
        real.setFragmentTextures(Array(UnsafeBufferPointer(start: textures, count: range.length)),
                                 range: range.location..<(range.location + range.length))
    }

    @objc(drawPrimitives:vertexStart:vertexCount:)
    func drawPrimitives(_ type: MTLPrimitiveType, vertexStart: Int, vertexCount: Int) {
        recorder.draw(type, vertices: vertexCount)
        real.drawPrimitives(type: type, vertexStart: vertexStart, vertexCount: vertexCount)
    }

    @objc(drawPrimitives:vertexStart:vertexCount:instanceCount:)
    func drawPrimitives(_ type: MTLPrimitiveType, vertexStart: Int, vertexCount: Int, instanceCount: Int) {
        recorder.draw(type, vertices: vertexCount, instances: instanceCount)
        real.drawPrimitives(type: type, vertexStart: vertexStart, vertexCount: vertexCount, instanceCount: instanceCount)
    }

    @objc(drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:)
    func drawPrimitives(_ type: MTLPrimitiveType, vertexStart: Int, vertexCount: Int, instanceCount: Int, baseInstance: Int) {
        recorder.draw(type, vertices: vertexCount, instances: instanceCount)
        real.drawPrimitives(type: type, vertexStart: vertexStart, vertexCount: vertexCount, instanceCount: instanceCount,
                            baseInstance: baseInstance)
    }

    @objc(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:)
    func drawIndexedPrimitives(_ type: MTLPrimitiveType, indexCount: Int, indexType: MTLIndexType, indexBuffer: MTLBuffer,
                               indexBufferOffset: Int) {
        recorder.draw(type, vertices: indexCount)
        real.drawIndexedPrimitives(type: type, indexCount: indexCount, indexType: indexType, indexBuffer: indexBuffer,
                                   indexBufferOffset: indexBufferOffset)
    }

    @objc(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:)
    func drawIndexedPrimitives(_ type: MTLPrimitiveType, indexCount: Int, indexType: MTLIndexType, indexBuffer: MTLBuffer,
                               indexBufferOffset: Int, instanceCount: Int) {
        recorder.draw(type, vertices: indexCount, instances: instanceCount)
        real.drawIndexedPrimitives(type: type, indexCount: indexCount, indexType: indexType, indexBuffer: indexBuffer,
                                   indexBufferOffset: indexBufferOffset, instanceCount: instanceCount)
    }

    @objc(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:)
    func drawIndexedPrimitives(_ type: MTLPrimitiveType, indexCount: Int, indexType: MTLIndexType, indexBuffer: MTLBuffer,
                               indexBufferOffset: Int, instanceCount: Int, baseVertex: Int, baseInstance: Int) {
        recorder.draw(type, vertices: indexCount, instances: instanceCount)
        real.drawIndexedPrimitives(type: type, indexCount: indexCount, indexType: indexType, indexBuffer: indexBuffer,
                                   indexBufferOffset: indexBufferOffset, instanceCount: instanceCount,
                                   baseVertex: baseVertex, baseInstance: baseInstance)
    }

    @objc(drawPrimitives:indirectBuffer:indirectBufferOffset:)
    func drawPrimitives(_ type: MTLPrimitiveType, indirectBuffer: MTLBuffer, indirectBufferOffset: Int) {
        recorder.drawIndirect()
        real.drawPrimitives(type: type, indirectBuffer: indirectBuffer, indirectBufferOffset: indirectBufferOffset)
    }

    @objc(drawIndexedPrimitives:indexType:indexBuffer:indexBufferOffset:indirectBuffer:indirectBufferOffset:)
    func drawIndexedPrimitives(_ type: MTLPrimitiveType, indexType: MTLIndexType, indexBuffer: MTLBuffer, indexBufferOffset: Int,
                               indirectBuffer: MTLBuffer, indirectBufferOffset: Int) {
        recorder.drawIndirect()
        real.drawIndexedPrimitives(type: type, indexType: indexType, indexBuffer: indexBuffer, indexBufferOffset: indexBufferOffset,
                                   indirectBuffer: indirectBuffer, indirectBufferOffset: indirectBufferOffset)
    }
}

final class SceneStatsBlitEncoder: SceneStatsForwarder {
    static func wrap(_ encoder: MTLBlitCommandEncoder, recorder: SceneFrameStatsRecorder) -> MTLBlitCommandEncoder {
        guard let object = encoder as? NSObject else { return encoder }
        return unsafeBitCast(SceneStatsBlitEncoder(object, recorder: recorder), to: MTLBlitCommandEncoder.self)
    }

    private var real: MTLBlitCommandEncoder { unsafeBitCast(forwarded, to: MTLBlitCommandEncoder.self) }

    @objc(copyFromTexture:toTexture:)
    func copy(from source: MTLTexture, to destination: MTLTexture) {
        recorder.copy()
        real.copy(from: source, to: destination)
    }

    @objc(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:)
    func copy(from source: MTLTexture, sourceSlice: Int, sourceLevel: Int, sourceOrigin: MTLOrigin, sourceSize: MTLSize,
              to destination: MTLTexture, destinationSlice: Int, destinationLevel: Int, destinationOrigin: MTLOrigin) {
        recorder.copy()
        real.copy(from: source, sourceSlice: sourceSlice, sourceLevel: sourceLevel, sourceOrigin: sourceOrigin,
                  sourceSize: sourceSize, to: destination, destinationSlice: destinationSlice,
                  destinationLevel: destinationLevel, destinationOrigin: destinationOrigin)
    }

    @objc(copyFromTexture:sourceSlice:sourceLevel:toTexture:destinationSlice:destinationLevel:sliceCount:levelCount:)
    func copy(from source: MTLTexture, sourceSlice: Int, sourceLevel: Int, to destination: MTLTexture,
              destinationSlice: Int, destinationLevel: Int, sliceCount: Int, levelCount: Int) {
        recorder.copy()
        real.copy(from: source, sourceSlice: sourceSlice, sourceLevel: sourceLevel, to: destination,
                  destinationSlice: destinationSlice, destinationLevel: destinationLevel,
                  sliceCount: sliceCount, levelCount: levelCount)
    }
}
