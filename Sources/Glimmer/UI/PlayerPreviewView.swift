import AVKit
import SwiftUI

/// 播放器预览视图：包装 AVKit 的 `AVPlayerView`，用真实的 AVPlayer 渲染画面。
///
/// 预览与桌面播放相互独立：预览用单独的 AVPlayer，不干扰桌面窗口的播放会话。
struct PlayerPreviewView: View {
    let item: WallpaperItem?
    let isPaused: Bool
    let isMuted: Bool
    let volume: Double
    let rate: Double
    let gravity: VideoGravityMode
    var wallpaperFPS = 30
    var storage = AppStorage()
    var onReady: (() -> Void)? = nil
    var onFailure: ((String) -> Void)? = nil
    var onTransitionSnapshot: ((NSImage?) -> Void)? = nil

    var body: some View {
        if let item, item.isSceneWallpaper {
            SceneWallpaperPreviewView(item: item, isPaused: isPaused, storage: storage, wallpaperFPS: wallpaperFPS,
                                      soundEnabled: !isMuted, soundVolume: volume,
                                      onReady: onReady, onFailure: onFailure)
        } else if let item, item.isWebWallpaper {
            WebWallpaperPreviewView(item: item, isPaused: isPaused, storage: storage, wallpaperFPS: wallpaperFPS, onReady: onReady, onFailure: onFailure, onTransitionSnapshot: onTransitionSnapshot)
        } else {
            VideoPlayerPreviewView(item: item, isPaused: isPaused, isMuted: isMuted,
                                   volume: volume, rate: rate, gravity: gravity, onReady: onReady, onFailure: onFailure)
        }
    }
}

private struct VideoPlayerPreviewView: NSViewRepresentable {
    let item: WallpaperItem?
    let isPaused: Bool
    let isMuted: Bool
    let volume: Double
    let rate: Double
    let gravity: VideoGravityMode
    var onReady: (() -> Void)? = nil
    var onFailure: ((String) -> Void)? = nil

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = gravity == .fill ? .resizeAspectFill : .resizeAspect
        view.showsFrameSteppingButtons = false
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.videoGravity = gravity == .fill ? .resizeAspectFill : .resizeAspect

        guard let item, item.isVideoWallpaper, item.fileExists else {
            context.coordinator.tearDown(view: view)
            return
        }

        let coordinator = context.coordinator
        coordinator.onReady = onReady
        coordinator.onFailure = onFailure
        if coordinator.currentItemID != item.id {
            coordinator.tearDown(view: view)
            let player = AVQueuePlayer()
            let assetItem = AVPlayerItem(url: item.fileURL)
            let looper = AVPlayerLooper(player: player, templateItem: assetItem)
            coordinator.looper = looper
            player.actionAtItemEnd = .none
            view.player = player
            coordinator.player = player
            coordinator.currentItemID = item.id
            coordinator.observeReady(view: view, itemID: item.id)
        }

        guard let player = coordinator.player else { return }
        player.isMuted = isMuted
        player.volume = Float(min(max(volume, 0), 1))
        if isPaused {
            player.pause()
        } else {
            // play() 会把速率重置为 1.0；playImmediately(atRate:) 才能保留倍速选择。
            player.playImmediately(atRate: Float(min(max(rate, 0.25), 4)))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.tearDown(view: nsView)
    }

    @MainActor
    final class Coordinator {
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
        var currentItemID: UUID?
        var onReady: (() -> Void)?
        var onFailure: ((String) -> Void)?
        private var readyObservation: NSKeyValueObservation?
        private var statusObservation: NSKeyValueObservation?
        private var currentItemObservation: NSKeyValueObservation?
        private var looperObservation: NSKeyValueObservation?
        private var readinessReported = false

        func observeReady(view: AVPlayerView, itemID: UUID) {
            readyObservation = view.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor [weak self, weak view] in
                    guard let self, let view, self.currentItemID == itemID, view.isReadyForDisplay, !self.readinessReported else { return }
                    self.readinessReported = true
                    self.onReady?()
                }
            }
            guard let player, let looper else { return }
            currentItemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
                Task { @MainActor [weak self, weak player] in
                    guard let self, let player, self.currentItemID == itemID else { return }
                    self.observeItemStatus(player.currentItem, itemID: itemID)
                }
            }
            looperObservation = looper.observe(\.status, options: [.initial, .new]) { [weak self] looper, _ in
                Task { @MainActor [weak self, weak looper] in
                    guard let self, let looper, self.currentItemID == itemID, self.looper === looper,
                          looper.status == .failed else { return }
                    self.onFailure?(looper.error?.localizedDescription ?? "无法加载视频预览")
                }
            }
        }

        private func observeItemStatus(_ item: AVPlayerItem?, itemID: UUID) {
            statusObservation?.invalidate(); statusObservation = nil
            guard let item else { return }
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item, self.currentItemID == itemID, self.player?.currentItem === item,
                          item.status == .failed else { return }
                    self.onFailure?(item.error?.localizedDescription ?? "无法加载视频预览")
                }
            }
        }

        func tearDown(view: AVPlayerView) {
            readyObservation?.invalidate(); readyObservation = nil
            currentItemObservation?.invalidate(); currentItemObservation = nil
            looperObservation?.invalidate(); looperObservation = nil
            statusObservation?.invalidate(); statusObservation = nil
            readinessReported = false
            player?.pause()
            looper?.disableLooping()
            player?.removeAllItems()
            view.player = nil
            player = nil
            looper = nil
            currentItemID = nil
        }
    }
}
