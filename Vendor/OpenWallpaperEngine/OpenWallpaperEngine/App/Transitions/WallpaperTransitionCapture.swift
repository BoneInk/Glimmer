import AVFoundation
import AppKit
import Metal

/// A transition's outgoing picture: what a display (a split region, or the source of a clone or
/// stretch) shows now, as a texture of the size it fills.
///
/// - Scenes, and videos on the Metal path: the running instance draws its current moment again
///   into a texture that stays on the GPU (`SceneRenderLoop.captureTransitionFrame`).
/// - AVKit videos: the frame the player shows now, placed as the display shows it.
/// - Web wallpapers and WebKit videos: the page's snapshot; Chromium pages: one frame drawn.
@MainActor
enum WallpaperTransitionCapture {
    /// How long a capture may take before the change applies without a transition.
    static let timeout: TimeInterval = 0.75

    /// `screenId`'s wallpaper as it shows now, `pixelSize` pixels; nil when nothing can be
    /// captured in time. `window`: the wallpaper window it shows in (for its page).
    static func capture(screenId: String, pixelSize: SIMD2<Int>, backingScale: CGFloat,
                        wallpapers: WallpaperViewModel, window: NSWindow?, device: MTLDevice) async -> MTLTexture? {
        let key = wallpapers.instanceKey(for: screenId)
        if let scene = wallpapers.sceneInstances.instance(for: key) {
            let texture: MTLTexture? = await withCheckedContinuation { continuation in
                scene.renderLoop.captureTransitionFrame(pixelSize: pixelSize) { continuation.resume(returning: $0) }
            }
            guard let texture else { return nil }
            guard texture.device === device else {
                OWELog.error(.app, "Transition: the scene renders on another GPU than the transition; no transition")
                return nil
            }
            return texture
        }
        let image: CGImage?
        let placement: WallpaperPlacement?
        do {
            if let video = wallpapers.videoInstances.instance(for: key.wallpaper) {
                image = try await WallpaperScreenshotService.currentFrame(of: video.player)
                placement = wallpapers.wallpaperPlacement
            } else if let content = window?.contentView,
                      let webView = WallpaperScreenshotService.webView(in: content) {
                image = try await WallpaperScreenshotService.snapshot(of: webView, pixelWidth: pixelSize.x,
                                                                      backingScale: backingScale)
                placement = nil
            } else if let content = window?.contentView,
                      let page = WallpaperScreenshotService.chromiumPageView(in: content) {
                image = try await WallpaperScreenshotService.capture(page.page, pixelWidth: pixelSize.x, timeout: timeout)
                placement = nil
            } else {
                return nil
            }
        } catch {
            OWELog.error(.app, "Transition: \(screenId)'s wallpaper couldn't be captured: \(error.localizedDescription)")
            return nil
        }
        guard let image else { return nil }
        return await Task.detached(priority: .userInitiated) {
            texture(of: image, pixelSize: pixelSize, placement: placement, device: device)
        }.value
    }

    /// Waits for `capture` up to `timeout`; nil after it.
    static func withTimeout(_ timeout: TimeInterval = timeout,
                            _ capture: @escaping @MainActor () async -> MTLTexture?) async -> MTLTexture? {
        await withTaskGroup(of: MTLTexture?.self) { group in
            group.addTask { await capture() }
            group.addTask {
                // Cancelled as soon as the capture wins.
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// `image` drawn into a `pixelSize` BGRA texture: placed as a video view places it
    /// (`placement`; nil: stretched to the size, as a page's snapshot already is).
    nonisolated static func texture(of image: CGImage, pixelSize: SIMD2<Int>, placement: WallpaperPlacement?,
                                    device: MTLDevice) -> MTLTexture? {
        let width = pixelSize.x, height = pixelSize.y
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bytesPerRow = width * 4
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: info) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: placedRect(imageSize: CGSize(width: image.width, height: image.height),
                                           in: CGSize(width: width, height: height), placement: placement))
        guard let data = context.data else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            OWELog.error(.app, "Transition: can't allocate a \(width)×\(height) texture")
            return nil
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data,
                        bytesPerRow: bytesPerRow)
        return texture
    }

    /// Where a picture of `imageSize` lands in `size` under `placement`, as `AVPlayerView`'s
    /// gravity for it draws it.
    nonisolated static func placedRect(imageSize: CGSize, in size: CGSize, placement: WallpaperPlacement?) -> CGRect {
        let full = CGRect(origin: .zero, size: size)
        guard let placement, imageSize.width > 0, imageSize.height > 0 else { return full }
        let scaleX = size.width / imageSize.width, scaleY = size.height / imageSize.height
        let scale: CGFloat
        switch placement {
        case .stretch: return full
        case .fill, .zoom: scale = max(scaleX, scaleY)
        case .fit, .center: scale = min(scaleX, scaleY)
        }
        let placed = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (size.width - placed.width) / 2, y: (size.height - placed.height) / 2,
                      width: placed.width, height: placed.height)
    }
}
