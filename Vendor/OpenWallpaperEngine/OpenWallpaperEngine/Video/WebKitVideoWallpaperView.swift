//
//  WebKitVideoWallpaperView.swift
//  Open Wallpaper Engine
//

import SwiftUI
import WebKit

/// A video wallpaper AVFoundation can't decode (`WebKitVideoPlayer.handles`) on one display: a
/// page per display, like a web wallpaper, paused by that display's playback rule and heard only
/// on the wallpaper's audible display, and moved by its music sync like the AVKit path.
struct WebKitVideoWallpaperView: NSViewRepresentable {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    /// Redraws the view when a music-sync control changes.
    @ObservedObject var musicSyncStore = VideoMusicSyncStore.shared
    let screenId: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let wallpaper = wallpaperViewModel.wallpaper(for: screenId)
        let player = WebKitVideoPlayer(url: wallpaper.mediaURL, readAccess: wallpaper.wallpaperDirectory)
        context.coordinator.player = player
        player.state = state(for: wallpaper)
        player.musicSync = VideoMusicSyncEffect(wallpaper)
        // The WebKit initializer always makes a WKWebView.
        return player.webView ?? WKWebView()
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let wallpaper = wallpaperViewModel.wallpaper(for: screenId)
        context.coordinator.player?.state = state(for: wallpaper)
        context.coordinator.player?.musicSync = VideoMusicSyncEffect(wallpaper)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.player?.stop()
        coordinator.player = nil
    }

    private func state(for wallpaper: WEWallpaper) -> WebKitVideoPlayer.State {
        Self.state(for: wallpaper, wallpaperViewModel: wallpaperViewModel, screenId: screenId, engine: .webKit)
    }

    /// The player's state on `screenId`: the pause of the displays showing its page (its own and
    /// those mirroring it), the wallpaper's audible display and volume, placement and rate. Shared
    /// with the Chromium view.
    @MainActor
    static func state(for wallpaper: WEWallpaper, wallpaperViewModel: WallpaperViewModel,
                      screenId: String, engine: WebEngine) -> WebKitVideoPlayer.State {
        let key = WallpaperInstanceKey(wallpaper)
        let muted = !wallpaperViewModel.pagePlaysAudio(of: screenId, engine: engine) || wallpaperViewModel.playVolume == 0
            || !wallpaperViewModel.wallpaperPlayback(of: key).playsSound
        return WebKitVideoPlayer.State(placement: wallpaperViewModel.wallpaperPlacement,
                                       paused: !wallpaperViewModel.pageRendersFrames(of: screenId, engine: engine),
                                       muted: muted,
                                       volume: wallpaperViewModel.playVolume,
                                       // A page per display: its own playback rate (WE's option).
                                       rate: wallpaperViewModel.playRate
                                           * Float(wallpaperViewModel.displayOptions(on: screenId).playbackRate))
    }

    @MainActor
    final class Coordinator: WebPageSourceCoordinator {
        var player: WebKitVideoPlayer?
    }
}
