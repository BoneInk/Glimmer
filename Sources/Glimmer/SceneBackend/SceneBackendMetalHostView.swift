import AppKit
import CoreImage
import IOSurface
@preconcurrency import Metal
@preconcurrency import MetalKit

@MainActor
final class SceneBackendMetalHostView: MTKView, MTKViewDelegate {
    var onScreenChange: ((NSScreen?) -> Void)?
    private let commands: MTLCommandQueue
    private let imageContext: CIContext
    private var retainedFrame: MTLTexture?
    private var pooledTextures: [TextureKey: [MTLTexture]] = [:]
    private var activeTextureKey: TextureKey?
    private var textureAllocationCount = 0
    private var consumeGeneration: UInt64 = 0
    private var aspectFill = true
    private var screenTokens = [NSObjectProtocol]()
    private static let maximumPooledTextures = 2
    private static let maximumSourceTextures = 3
    private var sourceTextures: [UUID: SourceTextureMapping] = [:]
    private var sourceTextureSlots: [UUID] = []
    private var sourceTextureContext: SourceTextureContext?
    private var sourceTextureAllocationCount = 0
    var onDrawableForTesting: ((ObjectIdentifier) -> Void)?

    var retainedFrameSizeForTesting: CGSize? {
        retainedFrame.map { CGSize(width: $0.width, height: $0.height) }
    }

    var pooledTextureCountForTesting: Int {
        pooledTextures.values.reduce(0) { $0 + $1.count }
    }

    var textureAllocationCountForTesting: Int {
        textureAllocationCount
    }

    var sourceTextureCountForTesting: Int { sourceTextures.count }
    var sourceTextureAllocationCountForTesting: Int { sourceTextureAllocationCount }

    /// Drop the helper's input mappings when its session is closed. Submitted
    /// commands retain their mapping until completion, including during reload.
    func resetSourceTextureCache() {
        sourceTextures.removeAll(keepingCapacity: true)
        sourceTextureSlots.removeAll(keepingCapacity: true)
        sourceTextureContext = nil
    }

    static func make() throws -> SceneBackendMetalHostView {
        guard let device = MTLCreateSystemDefaultDevice(), let commands = device.makeCommandQueue() else {
            throw UniversalSceneBackendError.unavailable
        }
        return SceneBackendMetalHostView(device: device, commands: commands)
    }

    private init(device: MTLDevice, commands: MTLCommandQueue) {
        self.commands = commands
        imageContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        super.init(frame: .init(x: 0, y: 0, width: 640, height: 360), device: device)
        delegate = self; framebufferOnly = false; colorPixelFormat = .bgra8Unorm
        enableSetNeedsDisplay = true; isPaused = true; autoResizeDrawable = true
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        layer?.isOpaque = true
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); stopScreenObservation()
        if window != nil, retainedFrame != nil {
            setNeedsDisplay(bounds)
        }
        guard let window, onScreenChange != nil else { return }
        screenTokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.onScreenChange?(self?.window?.screen) } })
        screenTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.onScreenChange?(self?.window?.screen) } })
        onScreenChange?(window.screen)
    }

    func setAspectFill(_ value: Bool) {
        guard aspectFill != value else { return }
        aspectFill = value
        setNeedsDisplay(bounds)
    }

    func consume(surface: IOSurface, token: SceneFrameToken) async throws {
        let source = try validatedSourceTexture(surface: surface, token: token)
        guard let retained = makePooledTexture(width: token.width, height: token.height),
              let command = commands.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else {
            throw UniversalSceneBackendError.unavailable
        }
        blit.copy(from: source.texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: .init(x: 0, y: 0, z: 0),
                  sourceSize: .init(width: token.width, height: token.height, depth: 1),
                  to: retained, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: .init(x: 0, y: 0, z: 0))
        blit.endEncoding()
        let previous = retainedFrame.map(TextureTransfer.init)
        consumeGeneration &+= 1
        let generation = consumeGeneration
        let transfer = TextureTransfer(retained)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { [weak self, source] completed in
                // Cache eviction/reset must not release an IOSurface while the
                // GPU is still reading it. Completion is the ownership boundary.
                withExtendedLifetime(source) {}
                Task { @MainActor in
                    guard completed.status == .completed else {
                        continuation.resume(throwing: UniversalSceneBackendError.invalidFrame); return
                    }
                    guard let self, self.consumeGeneration == generation else {
                        self?.recycle(transfer.texture)
                        continuation.resume()
                        return
                    }
                    self.retainedFrame = transfer.texture
                    if let previous { self.retire(previous.texture) }
                    if self.window != nil {
                        // MTKView owns the drawable lifecycle. Acquiring/presenting
                        // currentDrawable outside draw() leaves its cached drawable
                        // alive and subsequent frames can present the first one again.
                        self.draw()
                    } else {
                        self.setNeedsDisplay(self.bounds)
                    }
                    continuation.resume()
                }
            }
            command.commit()
        }
    }

    private func validatedSourceTexture(surface: IOSurface, token: SceneFrameToken) throws -> SourceTextureMapping {
        // Validate the untrusted wire metadata on every frame, before even a
        // cache hit. A reused slot is never permission to skip these checks.
        guard token.pixelFormat == "BGRA8Unorm", token.width > 0, token.height > 0,
              token.width <= 8192, token.height <= 8192,
              token.width * token.height <= 16_777_216,
              token.bytesPerRow >= token.width * 4,
              IOSurfaceGetWidth(surface) == token.width,
              IOSurfaceGetHeight(surface) == token.height,
              IOSurfaceGetBytesPerRow(surface) == token.bytesPerRow,
              IOSurfaceGetPixelFormat(surface) == 0x4247_5241,
              let device
        else { throw UniversalSceneBackendError.invalidFrame }

        let context = SourceTextureContext(sessionID: token.sessionID, generation: token.generation,
                                           width: token.width, height: token.height,
                                           bytesPerRow: token.bytesPerRow, pixelFormat: token.pixelFormat)
        if context != sourceTextureContext {
            resetSourceTextureCache()
            sourceTextureContext = context
        }
        let surfaceID = IOSurfaceGetID(surface)
        if let cached = sourceTextures[token.slotID], cached.surfaceID == surfaceID {
            touchSourceTextureSlot(token.slotID)
            return cached
        }
        guard let texture = device.makeTexture(descriptor: Self.surfaceDescriptor(token),
                                               iosurface: surface, plane: 0) else {
            throw UniversalSceneBackendError.invalidFrame
        }
        let mapping = SourceTextureMapping(surface: surface, texture: texture)
        sourceTextureAllocationCount += 1
        if sourceTextures[token.slotID] == nil, sourceTextures.count == Self.maximumSourceTextures,
           let oldest = sourceTextureSlots.first {
            sourceTextures.removeValue(forKey: oldest)
            sourceTextureSlots.removeFirst()
        }
        sourceTextures[token.slotID] = mapping
        touchSourceTextureSlot(token.slotID)
        return mapping
    }

    private func touchSourceTextureSlot(_ slotID: UUID) {
        sourceTextureSlots.removeAll { $0 == slotID }
        sourceTextureSlots.append(slotID)
    }

    private func makePooledTexture(width: Int, height: Int) -> MTLTexture? {
        let key = TextureKey(width: width, height: height)
        // Only retired textures for the current frame size are useful. Keeping
        // textures from earlier sizes would let a resize sequence fill the small
        // global pool and force an allocation for every frame at the new size.
        // These entries have already passed their retirement fence, so dropping
        // them cannot release a texture that the GPU is still reading.
        if key != activeTextureKey {
            activeTextureKey = key
            pooledTextures.removeAll(keepingCapacity: true)
        }
        if var available = pooledTextures[key], let texture = available.popLast() {
            pooledTextures[key] = available
            return texture
        }
        guard let device else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        textureAllocationCount += 1
        return texture
    }

    /// A texture can only be reused after every earlier command buffer on the
    /// queue has completed. An empty fence command is ordered after prior draw
    /// reads and makes that GPU dependency explicit instead of trusting Swift
    /// actor serialization alone.
    private func retire(_ texture: MTLTexture) {
        let transfer = TextureTransfer(texture)
        guard let fence = commands.makeCommandBuffer() else { return }
        fence.addCompletedHandler { [weak self] completed in
            guard completed.status == .completed else { return }
            Task { @MainActor in self?.recycle(transfer.texture) }
        }
        fence.commit()
    }

    private func recycle(_ texture: MTLTexture) {
        let key = TextureKey(width: texture.width, height: texture.height)
        // A fence callback can arrive after the host moved to another size.
        // Never let such stale entries consume the active size's two slots.
        guard key == activeTextureKey else { return }
        let count = pooledTextures.values.reduce(0) { $0 + $1.count }
        guard count < Self.maximumPooledTextures else { return }
        pooledTextures[key, default: []].append(texture)
    }

    func draw(in view: MTKView) {
        guard let retainedFrame, let drawable = currentDrawable,
              let command = commands.makeCommandBuffer() else { return }
        do {
            try encode(texture: retainedFrame, to: drawable.texture, command: command)
            onDrawableForTesting?(ObjectIdentifier(drawable as AnyObject))
            command.present(drawable); command.commit()
        } catch { return }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if retainedFrame != nil {
            setNeedsDisplay(bounds)
        }
    }

    private func encode(texture: MTLTexture, to destination: MTLTexture, command: MTLCommandBuffer,
                        aspectFill: Bool? = nil) throws {
        guard let raw = CIImage(mtlTexture: texture, options: [.colorSpace: Self.colorSpace]) else {
            throw UniversalSceneBackendError.invalidFrame
        }
        // Shared Metal frames have a top-left row origin. Core Image uses a
        // bottom-left image origin; correct it once at the display boundary.
        let source = raw.transformed(by: CGAffineTransform(scaleX: 1, y: -1))
            .transformed(by: CGAffineTransform(translationX: 0, y: raw.extent.height))
        let bounds = CGRect(x: 0, y: 0, width: destination.width, height: destination.height)
        let fills = aspectFill ?? self.aspectFill
        let scale = fills
            ? max(bounds.width / source.extent.width, bounds.height / source.extent.height)
            : min(bounds.width / source.extent.width, bounds.height / source.extent.height)
        guard scale.isFinite, scale > 0 else { throw UniversalSceneBackendError.invalidFrame }
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let moved = scaled.transformed(by: CGAffineTransform(
            translationX: bounds.midX - scaled.extent.midX, y: bounds.midY - scaled.extent.midY))
        let black = CIImage(color: .black).cropped(to: bounds)
        imageContext.render(moved.composited(over: black), to: destination, commandBuffer: command,
                            bounds: bounds, colorSpace: Self.colorSpace)
    }

    private static func surfaceDescriptor(_ token: SceneFrameToken) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: token.width, height: token.height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead]
        return descriptor
    }

    private func stopScreenObservation() {
        screenTokens.forEach(NotificationCenter.default.removeObserver); screenTokens = []
    }

    isolated deinit {
        screenTokens.forEach(NotificationCenter.default.removeObserver)
    }

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private struct TextureKey: Hashable {
        let width: Int
        let height: Int
    }

    private struct SourceTextureContext: Equatable {
        let sessionID: UUID
        let generation: UInt64
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let pixelFormat: String
    }
}

extension SceneBackendMetalHostView {
    /// Test-only GPU readback of the retained source frame. Production `consume`
    /// and `draw` never read a frame back to the CPU.
    func retainedFrameBytesForTesting() async throws -> [UInt8] {
        guard let retainedFrame, let device else {
            throw UniversalSceneBackendError.unavailable
        }
        let width = retainedFrame.width, height = retainedFrame.height
        let bytesPerRow = width * 4
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let staging = device.makeTexture(descriptor: descriptor),
              let command = commands.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else {
            throw UniversalSceneBackendError.unavailable
        }
        blit.copy(from: retainedFrame, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: .init(x: 0, y: 0, z: 0),
                  sourceSize: .init(width: width, height: height, depth: 1),
                  to: staging, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: .init(x: 0, y: 0, z: 0))
        blit.endEncoding()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { completed in
                if completed.status == .completed { continuation.resume() }
                else { continuation.resume(throwing: UniversalSceneBackendError.invalidFrame) }
            }
            command.commit()
        }
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { buffer in
            staging.getBytes(buffer.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return bytes
    }

    /// Test-only rendering through the same display encode used by `draw`.
    func renderedFrameBytesForTesting(pixelSize: CGSize, aspectFill: Bool) async throws -> [UInt8] {
        guard let retainedFrame, let device,
              pixelSize.width.isFinite, pixelSize.height.isFinite,
              pixelSize.width > 0, pixelSize.height > 0 else {
            throw UniversalSceneBackendError.invalidFrame
        }
        let width = Int(pixelSize.width.rounded())
        let height = Int(pixelSize.height.rounded())
        guard width > 0, height > 0 else {
            throw UniversalSceneBackendError.invalidFrame
        }
        let bytesPerRow = width * 4
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let destination = device.makeTexture(descriptor: descriptor),
              let command = commands.makeCommandBuffer() else {
            throw UniversalSceneBackendError.unavailable
        }
        try encode(texture: retainedFrame, to: destination, command: command,
                   aspectFill: aspectFill)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { completed in
                if completed.status == .completed { continuation.resume() }
                else { continuation.resume(throwing: UniversalSceneBackendError.invalidFrame) }
            }
            command.commit()
        }
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { buffer in
            destination.getBytes(buffer.baseAddress!, bytesPerRow: bytesPerRow,
                                 from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return bytes
    }
}

private final class TextureTransfer: @unchecked Sendable {
    let texture: MTLTexture
    init(_ texture: MTLTexture) { self.texture = texture }
}

private final class SourceTextureMapping: @unchecked Sendable {
    // XPC may deliver a new Swift wrapper for the same kernel surface. Holding
    // that surface alive makes its IOSurface ID a stable identity (no ID reuse).
    let surface: IOSurface
    let surfaceID: IOSurfaceID
    let texture: MTLTexture

    init(surface: IOSurface, texture: MTLTexture) {
        self.surface = surface
        surfaceID = IOSurfaceGetID(surface)
        self.texture = texture
    }
}
