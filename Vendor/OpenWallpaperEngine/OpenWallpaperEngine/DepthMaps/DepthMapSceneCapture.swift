import CoreGraphics
import Foundation
import Metal
import OWEEditor
import OWESceneEditing

/// One still frame of a scene wallpaper drawn offscreen by the real loader and renderer, as the
/// Live Photo and the screen saver's loop are drawn (`LivePhotoRenderer`), for a depth map made
/// from what a layer (or the scene) looks like rather than from a texture: text, solid,
/// composition and fullscreen layers, animated images, particle systems and the whole scene.
///
/// The scene is read with the editor's current edits, the layers not asked for hidden; it runs
/// from load to `stillTime` (so particles have spawned and animations have moved, which is why
/// the section says the depth comes from one frame), with no pointer and silent, at the scene's
/// own size (capped at `maximumSide`), and the layer's rectangle is cut out.
@MainActor
enum DepthMapSceneCapture {
    enum Failure: LocalizedError {
        case noScene, timedOut, readBack

        var errorDescription: String? {
            String(localized: "The scene couldn’t be drawn to make a depth map.", table: "DepthMaps",
                   comment: "Depth map generation error: the offscreen render failed")
        }
    }

    /// Scene seconds from load to the still.
    static let stillTime = 2.0
    static let frameRate = 30
    nonisolated static let maximumSide = 4096
    static var timeoutSeconds: TimeInterval = 60

    /// The overlay with every layer not in `drawn` hidden.
    nonisolated static func overlay(_ overlay: SceneEditOverlay, drawing drawn: Set<Int>?, of all: [Int]) -> SceneEditOverlay {
        guard let drawn else { return overlay }
        var result = overlay
        for id in all where !drawn.contains(id) {
            result.setField("visible", to: .bool(false), of: id)
        }
        return result
    }

    /// The pixel rectangle of `sceneRect` (scene units from the bottom-left) in a frame of
    /// `pixels` showing `sceneSize`, clamped to it; nil when nothing of it is in the frame.
    nonisolated static func pixelRect(of sceneRect: CGRect, sceneSize: SIMD2<Double>, pixels: SIMD2<Int>) -> CGRect? {
        guard sceneSize.x > 0, sceneSize.y > 0 else { return nil }
        let scaleX = Double(pixels.x) / sceneSize.x, scaleY = Double(pixels.y) / sceneSize.y
        let rect = CGRect(x: sceneRect.minX * scaleX, y: (sceneSize.y - sceneRect.maxY) * scaleY,
                          width: sceneRect.width * scaleX, height: sceneRect.height * scaleY).integral
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: pixels.x, height: pixels.y))
        return clamped.isNull || clamped.width < 1 || clamped.height < 1 ? nil : clamped
    }

    /// The frame's pixel size for a scene of `sceneSize` (3D scenes: 1920 × 1080).
    nonisolated static func pixelSize(for sceneSize: SIMD2<Double>?) -> SIMD2<Int> {
        guard let sceneSize, sceneSize.x >= 1, sceneSize.y >= 1 else { return SIMD2(1920, 1080) }
        let scale = min(1, Double(maximumSide) / max(sceneSize.x, sceneSize.y))
        return SIMD2(max(1, Int((sceneSize.x * scale).rounded())), max(1, Int((sceneSize.y * scale).rounded())))
    }

    /// The still frame for `request`.
    static func render(_ wallpaper: WEWallpaper, request: DepthMapSourceRequest) async throws -> CGImage {
        let edits = Self.overlay(request.overlay, drawing: request.drawnLayers, of: request.allLayers)
        let settings = LivePhotoRenderer.renderSettings(from: OffscreenRendering.globalSettings(from: .app))
        // The scene is read and its content built off the main thread, as the app's instances do.
        let (model, content) = try await Task.detached(priority: .userInitiated) { () throws -> (SceneContentLoader, SceneMetalContent) in
            let model = SceneContentLoader(wallpaper: wallpaper, overlay: edits)
            model.setRenderSettings(settings)
            guard let content = model.metalContent() else { throw Failure.noScene }
            return (model, content)
        }.value
        try Task.checkCancellation()
        let scratch = FileManager.default.temporaryDirectory.appending(path: "owe-depthmap-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) } // Scratch scripts' storage; a leftover is harmless.
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: scratch),
                                           media: SilentMediaSession(), spectrum: { .silent })
        guard let renderer = SceneMetalRenderer(pixelFormat: .bgra8Unorm, scriptServices: services,
                                                screenID: "depthmap-\(wallpaper.wallpaperDirectory.lastPathComponent)")
        else { throw Failure.noScene }
        defer {
            renderer.releaseContent()
            withExtendedLifetime(model) {}
        }
        let pixels = pixelSize(for: request.sceneSize)
        let drawable = SIMD2(Float(pixels.x), Float(pixels.y))
        // Silent, as a Live Photo is; clock layers stay (their depth is asked for too).
        renderer.sounds.setTargetGain(0)
        renderer.audioSpectrumFrame = { _ in .silent }
        renderer.renderSettings = settings
        let start: CFTimeInterval = 1000
        renderer.wallTime = { start }
        renderer.holdsClock = true
        renderer.setContent(content)
        let viewport = SceneViewport(drawableSize: drawable, pointSize: drawable, cursor: nil, frameRateLimit: frameRate)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !renderer.hasContent, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        var settled = 0
        while renderer.hasContent, settled < 3, Date() < deadline {
            try Task.checkCancellation()
            renderer.renderShared([viewport])
            renderer.lastCommandBuffer?.waitUntilCompleted()
            try await Task.sleep(for: .milliseconds(5))
            settled = renderer.hasPendingEffectPipelines ? 0 : settled + 1
        }
        guard renderer.hasContent, settled >= 3 else { throw Failure.timedOut }
        renderer.holdsClock = false
        let frames = Int(stillTime * Double(frameRate))
        for index in 1...frames {
            try Task.checkCancellation()
            let time = start + Double(index) / Double(frameRate)
            renderer.wallTime = { time }
            renderer.renderShared([viewport])
            renderer.lastCommandBuffer?.waitUntilCompleted()
            await Task.yield()
        }
        guard let frame = await capture(renderer, pixelSize: pixels) else { throw Failure.readBack }
        guard let sceneRect = request.sceneRect, let sceneSize = request.sceneSize else { return frame }
        guard let crop = pixelRect(of: sceneRect, sceneSize: sceneSize, pixels: pixels),
              let cropped = frame.cropping(to: crop) else { throw Failure.readBack }
        return cropped
    }

    private static func capture(_ renderer: SceneMetalRenderer, pixelSize: SIMD2<Int>) async -> CGImage? {
        let capture = FrameCapture()
        guard renderer.captureSharedFrame(pixelSize: pixelSize, pixelsPerPoint: 1, completion: { capture.finish($0) }) else {
            return nil
        }
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: capture.done.wait(timeout: .now() + 10) == .success)
            }
        }
        return finished ? capture.image : nil
    }
}
