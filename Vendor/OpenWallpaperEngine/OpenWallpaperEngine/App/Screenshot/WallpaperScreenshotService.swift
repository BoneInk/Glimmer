import AVFoundation
import AppKit
import Metal
import WebKit

/// WE's "Take screenshot" (`core_tray_take_screenshot`, the `screenshot` hotkey): a picture of the
/// wallpaper on the display under the pointer, without desktop icons or windows, saved as a PNG
/// (`WallpaperScreenshotWriter`).
///
/// - Scenes, and videos on the Metal path: the running instance draws its current moment again,
///   unstepped, at the chosen size (`GSScreenshotResolution`), every pass at that size.
/// - AVKit videos: the frame the player shows now, at the video's own size.
/// - Web wallpapers (and videos WebKit plays): the page's snapshot at the chosen width.
/// - Pages in the Chromium engine (web wallpapers and the videos it plays): one frame drawn at the
///   chosen width (`ChromiumBrowserPage.capture`); a paused or hidden page gives its last frame.
@MainActor
final class WallpaperScreenshotService {
    enum Failure: LocalizedError {
        case nothingToCapture
        case captureFailed
        case timedOut

        var errorDescription: String? {
            switch self {
            case .nothingToCapture: return String(localized: "No wallpaper is showing on this display.")
            case .captureFailed: return String(localized: "The wallpaper's picture couldn't be captured.")
            case .timedOut: return String(localized: "The Chromium engine didn't draw the wallpaper in time.")
            }
        }
    }

    private let wallpapers: WallpaperViewModel
    private let settings: () -> GlobalSettings
    /// The wallpaper window of a display, by screen id.
    private let window: (String) -> NSWindow?
    private let device = MTLCreateSystemDefaultDevice()

    init(wallpapers: WallpaperViewModel, settings: @escaping () -> GlobalSettings,
         window: @escaping (String) -> NSWindow?) {
        self.wallpapers = wallpapers
        self.settings = settings
        self.window = window
    }

    /// The display under the pointer, else the main one.
    static func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    /// Takes a screenshot of `screen`'s wallpaper and saves it; returns the file.
    func take(on screen: NSScreen) async throws -> URL {
        let screenID = WallpaperViewModel.screenId(for: screen)
        let wallpaper = wallpapers.wallpaper(for: screenID)
        guard wallpaper.project != .invalid else { throw Failure.nothingToCapture }
        let settings = settings()
        let display = SIMD2(Int((screen.frame.width * screen.backingScaleFactor).rounded()),
                            Int((screen.frame.height * screen.backingScaleFactor).rounded()))
        let size = settings.screenshotResolution.pixelSize(display: display, maxSide: maxTextureSide)
        let image = try await capture(screenID: screenID, pixelSize: size, backingScale: screen.backingScaleFactor)
        let folder = WallpaperScreenshotWriter.folder(setting: settings.screenshotFolder)
        let title = wallpaper.project.displayTitle
        let url = try await Task.detached(priority: .userInitiated) {
            try WallpaperScreenshotWriter.write(image, title: title, to: folder)
        }.value
        OWELog.info(.app, "Screenshot of \(wallpaper.wallpaperDirectory.lastPathComponent) saved: \(url.lastPathComponent) (\(image.width)×\(image.height))")
        return url
    }

    /// The GPU's largest 2D texture side: 16384 on every Mac GPU this app runs on.
    private var maxTextureSide: Int {
        guard let device else { return 8192 }
        return device.supportsFamily(.apple3) || device.supportsFamily(.mac2) ? 16384 : 8192
    }

    private func capture(screenID: String, pixelSize: SIMD2<Int>, backingScale: CGFloat) async throws -> CGImage {
        let key = wallpapers.instanceKey(for: screenID)
        if let scene = wallpapers.sceneInstances.instance(for: key) {
            return try await withCheckedThrowingContinuation { continuation in
                scene.renderLoop.captureScreenshot(pixelSize: pixelSize) { image in
                    if let image { continuation.resume(returning: image) } else { continuation.resume(throwing: Failure.captureFailed) }
                }
            }
        }
        if let video = wallpapers.videoInstances.instance(for: key.wallpaper) {
            return try await Self.currentFrame(of: video.player)
        }
        guard let window = window(screenID), var content = window.contentView else { throw Failure.nothingToCapture }
        // A display mirroring another's page (a clone's or stretch's member) shows that page.
        if let mirror = Self.pageMirror(in: content), let source = mirror.source { content = source }
        if let webView = Self.webView(in: content) {
            return try await Self.snapshot(of: webView, pixelWidth: pixelSize.x, backingScale: backingScale)
        }
        if let chromium = Self.chromiumPageView(in: content) {
            return try await Self.capture(chromium.page, pixelWidth: pixelSize.x)
        }
        throw Failure.nothingToCapture
    }

    static func pageMirror(in view: NSView) -> WebPageMirrorView? {
        if let mirror = view as? WebPageMirrorView { return mirror }
        for subview in view.subviews {
            if let mirror = pageMirror(in: subview) { return mirror }
        }
        return nil
    }

    static func chromiumPageView(in view: NSView) -> ChromiumPageView? {
        if let pageView = view as? ChromiumPageView { return pageView }
        for subview in view.subviews {
            if let pageView = chromiumPageView(in: subview) { return pageView }
        }
        return nil
    }

    /// The Chromium page drawn `pixelWidth` pixels wide, or its last frame; none at all is a timeout.
    static func capture(_ page: ChromiumBrowserPage, pixelWidth: Int, timeout: TimeInterval = 5) async throws -> CGImage {
        let image: CGImage? = await withCheckedContinuation { continuation in
            page.capture(pixelWidth: pixelWidth, timeout: timeout) { continuation.resume(returning: $0) }
        }
        guard let image else { throw Failure.timedOut }
        return image
    }

    /// The frame `player` shows now, at the video's own size.
    static func currentFrame(of player: AVPlayer) async throws -> CGImage {
        guard let asset = player.currentItem?.asset else { throw Failure.nothingToCapture }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: player.currentTime()).image
    }

    static func webView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let webView = webView(in: subview) { return webView }
        }
        return nil
    }

    /// The page as it shows now, `pixelWidth` pixels wide.
    static func snapshot(of webView: WKWebView, pixelWidth: Int, backingScale: CGFloat) async throws -> CGImage {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        configuration.snapshotWidth = NSNumber(value: Double(pixelWidth) / Double(max(backingScale, 1)))
        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw Failure.captureFailed }
        return cgImage
    }
}

extension AppDelegate {
    /// Status menu › Take Screenshot, and the `screenshot` hotkey.
    @objc func takeScreenshot() {
        guard let screen = WallpaperScreenshotService.targetScreen() else { return }
        let service = WallpaperScreenshotService(
            wallpapers: wallpaperViewModel, settings: { [unowned self] in globalSettingsViewModel.settings },
            window: { [unowned self] in wallpaperWindows[$0] })
        Task {
            do {
                try await service.take(on: screen)
            } catch {
                OWELog.error(.app, "Screenshot failed: \(error.localizedDescription)")
                NSSound.beep()
            }
        }
    }
}
