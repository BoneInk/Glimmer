import CoreGraphics
import Metal

extension SceneMetalRenderer {
    /// Copies the latest shared frame (`renderShared`), as a display of `pixelSize` shows it, into
    /// CPU memory and hands `completion` the picture once the GPU is done, on a Metal thread (nil
    /// if the GPU failed). The copy is one blit into a shared buffer that the image then wraps,
    /// so nothing waits on the GPU. False (and no completion) when there is no frame to copy or
    /// the drawables' format isn't 8-bit BGRA. Render thread.
    func captureSharedFrame(pixelSize: SIMD2<Int>, pixelsPerPoint: Float,
                            completion: @escaping @Sendable (CGImage?) -> Void) -> Bool {
        guard pixelSize.x > 0, pixelSize.y > 0, pixelFormat == .bgra8Unorm || pixelFormat == .bgra8Unorm_srgb else { return false }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: pixelSize.x,
                                                                  height: pixelSize.y, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        let bytesPerRow = (pixelSize.x * 4 + 255) / 256 * 256
        let length = bytesPerRow * pixelSize.y
        guard let target = device.makeTexture(descriptor: descriptor),
              let buffer = device.makeBuffer(length: length, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            OWELog.error(.scene, "Loading snapshot: can't allocate a \(pixelSize.x)×\(pixelSize.y) capture")
            return false
        }
        commandBuffer.label = "Loading snapshot"
        guard encodeSharedFrame(into: target, pixelsPerPoint: pixelsPerPoint, commandBuffer: commandBuffer),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: pixelSize.x, height: pixelSize.y, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: length)
        blit.endEncoding()
        commandBuffer.addCompletedHandler { finished in
            guard finished.status == .completed else {
                OWELog.error(.scene, "Loading snapshot: the capture failed on the GPU: \(finished.error.map { "\($0)" } ?? "unknown")")
                completion(nil)
                return
            }
            completion(Self.image(wrapping: buffer, size: pixelSize, bytesPerRow: bytesPerRow))
        }
        commandBuffer.commit()
        return true
    }

    /// A still of the scene's current moment, as a picture shown later shows it (the lock screen,
    /// the screen saver's): drawn again, unstepped, for `viewports`, without the layers a still
    /// leaves out (`hidesStillLayers`: its text and clock hands), then copied at `pixelSize`
    /// (`captureSharedFrame`). `restores`: the shared frame is drawn again with them after, for
    /// the displays that show it. Render thread.
    func captureStill(pixelSize: SIMD2<Int>, pixelsPerPoint: Float, viewports: [SceneViewport], restores: Bool,
                      completion: @escaping @Sendable (CGImage?) -> Void) -> Bool {
        guard hasContent else { return false }
        hidesStillLayers = true
        redrawShared(viewports)
        let started = captureSharedFrame(pixelSize: pixelSize, pixelsPerPoint: pixelsPerPoint, completion: completion)
        hidesStillLayers = false
        if restores { redrawShared(viewports) }
        return started
    }

    /// A screenshot (WE's "Take screenshot"): the scene's current moment drawn again, without
    /// stepping it (`redrawShared`), at `pixelSize` and 1 pixel per point, so every pass renders at
    /// that size (whatever Render Resolution is) rather than scaling up a display's frame, then
    /// copied as `captureSharedFrame` does.
    /// `restoring` are the displays' viewports when several share the frame: their frame is drawn
    /// again after; with none, the extra frame is freed. False (and no completion) when there is
    /// no content or the copy can't start. Render thread.
    func captureScreenshot(pixelSize: SIMD2<Int>, restoring viewports: [SceneViewport],
                           completion: @escaping @Sendable (CGImage?) -> Void) -> Bool {
        guard hasContent, pixelSize.x > 0, pixelSize.y > 0 else { return false }
        let size = SIMD2<Float>(Float(pixelSize.x), Float(pixelSize.y))
        let frameRate = viewports.map(\.frameRateLimit).max() ?? 60
        // The screenshot sets its own size: drawn for its pixels whatever Render Resolution draws
        // the displays at (4K or the wallpaper's size).
        let live = renderSettings
        renderSettings.renderResolution = .yourDisplay
        redrawShared([SceneViewport(drawableSize: size, pointSize: size, cursor: nil, frameRateLimit: frameRate)])
        let started = captureSharedFrame(pixelSize: pixelSize, pixelsPerPoint: 1, completion: completion)
        renderSettings = live
        if viewports.isEmpty { releaseSharedFrame() } else { redrawShared(viewports) }
        return started
    }

    /// A transition's outgoing picture: the scene's current moment drawn again, unstepped, for the
    /// displays it shows on (`live`), so every pass runs at the size it runs at there and keeps its
    /// history (a feedback effect such as motion blur would start from an empty buffer at another
    /// size), then placed as `present(in:)` places it on a `pixelSize` display, into a texture that
    /// stays on the GPU, in 8-bit BGRA without sRGB decoding, so it samples as the display showed
    /// it. Without a live display it is drawn at `pixelSize`, 1 pixel per point (as
    /// `captureScreenshot`). `sharesFrame`: the displays show the shared frame, which stays; else
    /// it is freed. `completion` gets the picture once the GPU is done (nil if it failed), on a
    /// Metal thread. False (and no completion) when there is no content or the copy can't start.
    /// Render thread.
    func captureTransitionFrame(pixelSize: SIMD2<Int>, live viewports: [SceneViewport], sharesFrame: Bool,
                                completion: @escaping @Sendable (MTLTexture?) -> Void) -> Bool {
        guard hasContent, pixelSize.x > 0, pixelSize.y > 0,
              pixelFormat == .bgra8Unorm || pixelFormat == .bgra8Unorm_srgb else { return false }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: pixelSize.x,
                                                                  height: pixelSize.y, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .pixelFormatView]
        descriptor.storageMode = .private
        guard let target = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            OWELog.error(.scene, "Transition: can't allocate a \(pixelSize.x)×\(pixelSize.y) capture")
            return false
        }
        commandBuffer.label = "Transition capture"
        let size = SIMD2<Float>(Float(pixelSize.x), Float(pixelSize.y))
        redrawShared(viewports.isEmpty
            ? [SceneViewport(drawableSize: size, pointSize: size, cursor: nil, frameRateLimit: 60)] : viewports)
        let encoded = encodeSharedFrame(into: target, pixelsPerPoint: viewports.first?.pixelsPerPoint ?? 1,
                                        commandBuffer: commandBuffer)
        if !sharesFrame { releaseSharedFrame() }
        guard encoded else { return false }
        // The bytes as the display shows them: an sRGB target is read without decoding.
        let picture = target.pixelFormat == .bgra8Unorm ? target : target.makeTextureView(pixelFormat: .bgra8Unorm)
        commandBuffer.addCompletedHandler { finished in
            guard finished.status == .completed else {
                OWELog.error(.scene, "Transition: the capture failed on the GPU: \(finished.error.map { "\($0)" } ?? "unknown")")
                completion(nil)
                return
            }
            completion(picture)
        }
        commandBuffer.commit()
        return true
    }

    /// An sRGB image over `buffer`'s BGRA pixels (alpha ignored); the image keeps the buffer alive.
    private static func image(wrapping buffer: MTLBuffer, size: SIMD2<Int>, bytesPerRow: Int) -> CGImage? {
        let retained = Unmanaged.passRetained(buffer as AnyObject)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: buffer.contents(), size: buffer.length,
                                            releaseData: { info, _, _ in
                                                if let info { Unmanaged<AnyObject>.fromOpaque(info).release() }
                                            }) else {
            retained.release()
            return nil
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        return CGImage(width: size.x, height: size.y, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: colorSpace, bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}
