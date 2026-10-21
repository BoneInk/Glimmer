#if GW_ACTUAL_MEDIA_TRANSITION_PROBE
import AppKit
import AVKit
import Observation
import SwiftUI

struct AppStorage {}
enum VideoGravityMode { case fill, fit }
struct WallpaperItem {
    let id = UUID()
    let fileURL: URL
    var workshopID: String? { "actual-video" }
    var fileExists: Bool { true }
    var isSceneWallpaper: Bool { false }; var isWebWallpaper: Bool { false }; var isVideoWallpaper: Bool { true }
    var isProjectWallpaper: Bool { false }; var isFavorite: Bool { false }
    var displayTitle: String { "某科学的超电磁炮" }; var title: String { displayTitle }
    var fileSizeText: String { "52.2 MB" }; var resolutionText: String { "2400×1218" }; var durationText: String { "1:00" }
    var filePath: String { fileURL.path }; var originalURL: URL? { nil }; var originalExists: Bool { false }
}
struct WorkshopSearchResult: Identifiable { let id: String }
@MainActor enum ThumbnailCache {
    static let shared = ThumbnailCacheProvider()
    static var image: NSImage!
}
@MainActor final class ThumbnailCacheProvider {
    func thumbnail(for item: WallpaperItem) async -> NSImage? { ThumbnailCache.image }
}
@MainActor enum AuthorPropertyServices {
    static let shared = PropertyProvider()
}
@MainActor final class PropertyProvider { func readySceneHosts(itemID: UUID) -> [String] { [] } }
enum SceneWallpaperPresentation { static func badge(for value: String?) -> String { "Scene" } }
struct SceneWallpaperPreviewView: View {
    let item: WallpaperItem; let isPaused: Bool; let storage: AppStorage; var onReady: (() -> Void)? = nil; var onFailure: ((String) -> Void)? = nil
    var body: some View { Color.clear }
}
struct WebWallpaperPreviewView: View {
    let item: WallpaperItem; let isPaused: Bool; let storage: AppStorage; var onReady: (() -> Void)? = nil; var onFailure: ((String) -> Void)? = nil
    var onTransitionSnapshot: ((NSImage?) -> Void)? = nil
    var body: some View { Color.clear }
}
private struct MotionOverride: EnvironmentKey { static let defaultValue = false }
private struct TransparencyOverride: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var windowGlassReduceMotionOverride: Bool { get { self[MotionOverride.self] } set { self[MotionOverride.self] = newValue } }
    var windowGlassReduceTransparencyOverride: Bool { get { self[TransparencyOverride.self] } set { self[TransparencyOverride.self] = newValue } }
}
@MainActor @Observable private final class MediaState { var ready = false; var failures: [String] = [] }
private struct RealPlayerDestination: View {
    let item: WallpaperItem
    let state: MediaState
    @Environment(\.workspaceWallpaperDetails) var presentation
    var body: some View {
        PlayerPreviewView(item: item,
            isPaused: presentation?.coverImage != nil && presentation?.livePreviewOpacity == 0,
            isMuted: true, volume: 0, rate: 1, gravity: .fill,
            onReady: { state.ready = true }, onFailure: { state.failures.append($0) })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .wallpaperCoverDestination(ready: state.ready, cornerRadius: 0)
    }
}
@MainActor final class ActualMediaProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { do { try await WallpaperActualMediaTransitionProbe.run() } catch { print("FAILED: \(error)") }; NSApplication.shared.terminate(nil) }
    }
}
@main @MainActor enum WallpaperActualMediaTransitionProbe {
    static func main() {
        let app = NSApplication.shared, delegate = ActualMediaProbeDelegate()
        app.delegate = delegate; app.setActivationPolicy(.accessory); app.run(); withExtendedLifetime(delegate) {}
    }
    static func tick(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
    static func capture(_ window: NSWindow, to url: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", "\(window.windowNumber)", url.path]
        try process.run(); process.waitUntilExit()
    }
    static func run() async throws {
        precondition(CommandLine.arguments.count == 4, "Usage: WallpaperActualMediaTransitionProbe <output-dir> <video-path> <cover-path>")
        let output = URL(fileURLWithPath: CommandLine.arguments[1]); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let video = URL(fileURLWithPath: CommandLine.arguments[2])
        precondition(FileManager.default.fileExists(atPath: video.path), "Test video must exist")
        guard let cover = NSImage(contentsOfFile: CommandLine.arguments[3]) else {
            throw NSError(domain: "WallpaperActualMediaTransitionProbe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cover must be a readable image"] )
        }
        ThumbnailCache.image = cover
        let item = WallpaperItem(fileURL: video), presentation = WorkspaceWallpaperDetails(), state = MediaState()
        let root = GeometryReader { geometry in
            WorkspaceWallpaperDetailsHost(presentation: presentation) {
                HStack(spacing: 20) {
                    Color.blue.frame(width: 180)
                    WallpaperCardView(item: item, isSelected: false, isMissing: false,
                        style: .init(reduceTransparency: false, reduceMotion: false), onToggleFavorite: {}, onSelect: {}, onApply: {},
                        onOpenDetails: { presentation.open(item) })
                        .frame(width: 280).padding(.top, 270)
                    Spacer()
                }.padding(.top, geometry.safeAreaInsets.top)
            } detail: { _ in RealPlayerDestination(item: item, state: state) }
                .ignoresSafeArea(.container)
        }
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1000, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        let host = NSHostingView(rootView: root); window.contentView = host; window.makeKeyAndOrderFront(nil); window.orderFrontRegardless()
        await tick(0.4); try capture(window, to: output.appendingPathComponent("before.png"))
        let recording = Process(); recording.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        recording.arguments = ["-x", "-v", "-V", "4", "-l", "\(window.windowNumber)", output.appendingPathComponent("transition.mov").path]
        try recording.run(); await tick(0.5)
        let started = ContinuousClock.now
        presentation.open(item)
        var samples: [[String: String]] = []
        for index in 0..<110 {
            let views = playerViews(host)
            samples.append(["t": "\(ContinuousClock.now-started)", "index": "\(index)", "cover": "\(presentation.coverImage != nil)",
                "coverVisible": "\(presentation.destinationCoverVisible)", "liveOpacity": "\(presentation.livePreviewOpacity)", "ready": "\(state.ready)",
                "playerFrame": "\(views.first?.frame ?? .zero)", "playerTime": "\(views.first?.player?.currentTime().seconds ?? -1)"])
            await tick(1 / 120)
        }
        try capture(window, to: output.appendingPathComponent("live.png"))
        presentation.dismiss(); await tick(1)
        try capture(window, to: output.appendingPathComponent("returned.png"))
        try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("samples.json"))
        while recording.isRunning { await tick(0.1) }
        window.orderOut(nil)
        print("ready=\(state.ready) failures=\(state.failures), recordingStatus=\(recording.terminationStatus), source NSImage=\(ThumbnailCache.image!.size)")
        let asset = AVURLAsset(url: output.appendingPathComponent("transition.mov"))
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceAfter = .zero; generator.requestedTimeToleranceBefore = .zero
        for index in 0..<Int(duration * 60) {
            if let (image, _) = try? await generator.image(at: CMTime(value: Int64(index), timescale: 60)) {
                let bitmap = NSBitmapImageRep(cgImage: image)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(String(format: "frame-%03d.png", index)))
            }
        }
    }
    static func playerViews(_ view: NSView) -> [AVPlayerView] { (view as? AVPlayerView).map { [$0] } ?? view.subviews.flatMap(playerViews) }
}
#endif
