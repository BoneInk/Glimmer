//
//  VideoWallpaperView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/13.
//

import Cocoa
import SwiftUI
import AVKit

struct VideoWallpaperView: NSViewRepresentable {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @ObservedObject var viewModel: VideoWallpaperViewModel
    let screenId: String

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()

        view.player = viewModel.player

        view.videoGravity = videoGravity(for: wallpaperViewModel.wallpaperPlacement)

        // hide any unneeded ui component, we want just the video output
        view.controlsStyle = .none

        // make sure this video player won't show any info in the system control center
        view.updatesNowPlayingInfoCenter = false

        // mark the flag as unneeded, improve performance and reduce power drain
        view.allowsVideoFrameAnalysis = false

        return view
    }

    /// Playback, volume and sound follow the app's controls in the shared view model; a display
    /// only places the picture.
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.videoGravity = videoGravity(for: wallpaperViewModel.wallpaperPlacement)
    }

    private func videoGravity(for placement: WallpaperPlacement) -> AVLayerVideoGravity {
        switch placement {
        case .stretch:
            return .resize
        case .fill, .zoom:
            return .resizeAspectFill
        case .fit, .center:
            return .resizeAspect
        }
    }
}

/// A video wallpaper (AVKit path) on one display: a view of the video's shared player
/// (`WallpaperViewModel.videoInstances`), so the video decodes and plays its sound once however
/// many displays show it. `WallpaperView` keys it by the wallpaper, so a display switched to
/// another video gets that video's player.
struct AudioReactiveVideoWallpaperView: View {
    typealias Lease = WallpaperInstanceLease<WallpaperInstanceKey, VideoWallpaperViewModel>

    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @StateObject private var lease: Lease
    let screenId: String

    init(wallpaperViewModel: WallpaperViewModel, screenId: String) {
        self.wallpaperViewModel = wallpaperViewModel
        self.screenId = screenId
        let wallpaper = wallpaperViewModel.wallpaper(for: screenId)
        self._lease = StateObject(wrappedValue: Lease(wallpaperViewModel.videoInstances, key: WallpaperInstanceKey(wallpaper)) {
            VideoWallpaperViewModel(wallpaper: wallpaper, wallpaperViewModel: wallpaperViewModel)
        })
    }

    private var viewModel: VideoWallpaperViewModel { lease.instance }

    var body: some View {
        TimelineView(.animation) { _ in
            let effect = VideoMusicSyncEffect(wallpaperViewModel.wallpaper(for: screenId))
            let audioLevel = viewModel.musicSyncLevel
            VideoWallpaperView(wallpaperViewModel: wallpaperViewModel, viewModel: viewModel, screenId: screenId)
                .scaleEffect(effect.zoom(at: audioLevel))
                .rotationEffect(.degrees(effect.tilt(at: audioLevel)))
                .saturation(effect.saturation(at: audioLevel))
                .onChange(of: audioLevel) { _, newValue in
                    NotificationCenter.default.post(name: .videoMusicSyncAudioLevelDidChange,
                                                    object: nil,
                                                    userInfo: ["level": newValue])
                }
                .clipped()
        }
        .overlay { VideoPreparationOverlay(viewModel: viewModel) }
    }
}

/// "Preparing video…" while the video's playable copy is made (`RepairedVideoCache`).
private struct VideoPreparationOverlay: View {
    @ObservedObject var viewModel: VideoWallpaperViewModel

    var body: some View {
        if viewModel.isPreparingVideo {
            ZStack {
                Color.black
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing video…")
                }
                .foregroundStyle(.white.opacity(0.75))
            }
            .ignoresSafeArea()
        }
    }
}
