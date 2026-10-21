#if GW_PREVIEW_READINESS_TESTS
import AppKit
import AVKit
import Observation
import SwiftUI

// Only the unrelated Scene/Web providers are substituted. The production
// AVPlayerView representable, KVO observations and teardown run unchanged.
struct AppStorage {}
enum VideoGravityMode { case fill, fit }
struct WallpaperItem {
    let id = UUID()
    let fileURL: URL
    var fileExists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }
    var isSceneWallpaper: Bool { false }
    var isWebWallpaper: Bool { false }
    var isVideoWallpaper: Bool { true }
}
struct SceneWallpaperPreviewView: View {
    let item: WallpaperItem; let isPaused: Bool; let storage: AppStorage; var onReady: (() -> Void)? = nil; var onFailure: ((String) -> Void)? = nil
    var body: some View { Color.clear }
}
struct WebWallpaperPreviewView: View {
    let item: WallpaperItem; let isPaused: Bool; let storage: AppStorage; var onReady: (() -> Void)? = nil; var onFailure: ((String) -> Void)? = nil
    var onTransitionSnapshot: ((NSImage?) -> Void)? = nil
    var body: some View { Color.clear }
}
@main @MainActor enum WallpaperPreviewReadinessTests {
    static func playerViews(_ view: NSView) -> [AVPlayerView] {
        (view as? AVPlayerView).map { [$0] } ?? view.subviews.flatMap(playerViews)
    }
    static func main() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: AnyView(Color.black))
        window.contentView = host; window.orderFrontRegardless()
        precondition(CommandLine.arguments.count == 2, "Usage: WallpaperPreviewReadinessTests <test-video-path>")
        let video = URL(fileURLWithPath: CommandLine.arguments[1])
        precondition(FileManager.default.fileExists(atPath: video.path), "Test video must exist")
        var readyCount = 0
        var failures: [String] = []
        for iteration in 1...2 {
            let item = WallpaperItem(fileURL: video)
            let start = Date()
            host.rootView = AnyView(PlayerPreviewView(item: item, isPaused: true, isMuted: true,
                volume: 0, rate: 1, gravity: .fit,
                onReady: { readyCount += 1 }, onFailure: { failures.append($0) }).id(item.id))
            while readyCount < iteration, Date().timeIntervalSince(start) < 5 {
                try? await Task.sleep(for: .milliseconds(20))
            }
            precondition(readyCount == iteration && failures.isEmpty,
                "Paused production AVPlayerView must emit first-frame readiness: \(failures)")
            let views = playerViews(host)
            precondition(views.count == 1 && views[0].isReadyForDisplay && views[0].player?.rate == 0,
                "Readiness must not require playing a paused preview")
            print("PASS: paused real AVPlayerView \(iteration) ready in \(String(format: "%.3f", Date().timeIntervalSince(start)))s; rate remains 0")
            let playerView = views[0]
            host.rootView = AnyView(Color.black)
            try? await Task.sleep(for: .milliseconds(150))
            precondition(playerView.player == nil, "Dismantle must remove player and invalidate observations")
            precondition(readyCount == iteration, "No stale readiness callback may survive teardown")
            print("PASS: route \(iteration) teardown removes player and prevents late readiness")
        }
        let invalidURL = FileManager.default.temporaryDirectory.appendingPathComponent("gw-invalid-preview-\(UUID()).mp4")
        try! Data("invalid video fixture".utf8).write(to: invalidURL)
        defer { try? FileManager.default.removeItem(at: invalidURL) }
        let broken = WallpaperItem(fileURL: invalidURL)
        host.rootView = AnyView(PlayerPreviewView(item: broken, isPaused: true, isMuted: true,
            volume: 0, rate: 1, gravity: .fit, onReady: { readyCount += 1 },
            onFailure: { failures.append($0) }).id(broken.id))
        let failureStart = Date()
        while failures.isEmpty, Date().timeIntervalSince(failureStart) < 5 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        precondition(!failures.isEmpty && readyCount == 2,
            "Actual looper/currentItem failure must report failure rather than readiness")
        print("PASS: broken video reports actual looper/currentItem failure without marking preview ready")
        host.rootView = AnyView(Color.black)
        window.orderOut(nil)
        print("PASS: actual paused-first-frame KVO and two-route cleanup; no desktop/lock screen or library access")
    }
}
#endif
