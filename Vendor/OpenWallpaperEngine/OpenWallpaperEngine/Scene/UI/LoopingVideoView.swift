import AVKit
import SwiftUI

/// A player's video, filling its frame, with no controls.
struct LoopingVideoView: NSViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = gravity
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        view.videoGravity = gravity
    }
}

/// A video file looping silently, filling its frame, with no controls: a video wallpaper in the
/// Scene Edit / Export's modes. The player stops with the view.
struct LoopingVideoFileView: View {
    let url: URL
    var gravity: AVLayerVideoGravity = .resizeAspectFill
    @StateObject private var loop = VideoLoop()

    var body: some View {
        LoopingVideoView(player: loop.player, gravity: gravity)
            .onAppear { loop.play(url) }
            .onDisappear { loop.stop() }
    }
}

/// The looping player behind `LoopingVideoFileView`.
@MainActor
final class VideoLoop: ObservableObject {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var url: URL?

    init() {
        player.isMuted = true
        WallpaperAVPlayer.route(player)
    }

    func play(_ url: URL) {
        if self.url != url {
            self.url = url
            player.removeAllItems()
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        }
        player.play()
    }

    func stop() {
        player.pause()
    }
}
