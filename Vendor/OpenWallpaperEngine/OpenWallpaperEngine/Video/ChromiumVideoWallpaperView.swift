import SwiftUI

/// A WebM video AVFoundation can't decode, played by Chromium while the Chromium engine plays web
/// content (`WebEngineRouting`): the same player and music sync as `WebKitVideoWallpaperView`,
/// with the video's page in a Chromium browser drawn into this window's Metal layer.
struct ChromiumVideoWallpaperView: NSViewRepresentable {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    /// Redraws the view when a music-sync control changes.
    @ObservedObject var musicSyncStore = VideoMusicSyncStore.shared
    let screenId: String

    func makeCoordinator() -> WebKitVideoWallpaperView.Coordinator { WebKitVideoWallpaperView.Coordinator() }

    func makeNSView(context: Context) -> ChromiumPageView {
        let wallpaper = wallpaperViewModel.wallpaper(for: screenId)
        let page = ChromiumBrowserPage(startScripts: [], frameRate: Int(AppDelegate.shared.globalSettingsViewModel.effectiveSettings.fps))
        let view = ChromiumPageView(page: page)
        let player = WebKitVideoPlayer(chromiumPage: page, url: wallpaper.mediaURL, readAccess: wallpaper.wallpaperDirectory)
        context.coordinator.player = player
        player.state = state(for: wallpaper)
        player.musicSync = VideoMusicSyncEffect(wallpaper)
        context.coordinator.share(view, of: screenId, through: wallpaperViewModel.webPageMirrors, sharing: player)
        return view
    }

    func updateNSView(_ nsView: ChromiumPageView, context: Context) {
        let wallpaper = wallpaperViewModel.wallpaper(for: screenId)
        context.coordinator.player?.state = state(for: wallpaper)
        context.coordinator.player?.musicSync = VideoMusicSyncEffect(wallpaper)
    }

    static func dismantleNSView(_ nsView: ChromiumPageView, coordinator: WebKitVideoWallpaperView.Coordinator) {
        coordinator.stopSharing()
        coordinator.player?.stop()
        coordinator.player = nil
    }

    private func state(for wallpaper: WEWallpaper) -> WebKitVideoPlayer.State {
        WebKitVideoWallpaperView.state(for: wallpaper, wallpaperViewModel: wallpaperViewModel, screenId: screenId,
                                       engine: .chromium)
    }
}
