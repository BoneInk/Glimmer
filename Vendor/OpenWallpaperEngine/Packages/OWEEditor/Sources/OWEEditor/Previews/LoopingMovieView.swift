import AppKit
import AVFoundation
import SwiftUI

/// A preview loop, muted, played while the tile shows.
struct LoopingMovieView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> LoopingMovieNSView {
        LoopingMovieNSView(url: url)
    }

    func updateNSView(_ view: LoopingMovieNSView, context: Context) {
        view.show(url)
    }

    static func dismantleNSView(_ view: LoopingMovieNSView, coordinator: ()) {
        view.stop()
    }
}

final class LoopingMovieNSView: NSView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var url: URL?
    private let playerLayer = AVPlayerLayer()

    init(url: URL) {
        super.init(frame: .zero)
        wantsLayer = true
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
        show(url)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func show(_ url: URL) {
        guard url != self.url else { return }
        self.url = url
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { player.pause() } else if url != nil { player.play() }
    }

    func stop() {
        player.pause()
        looper = nil
        player.removeAllItems()
    }
}
