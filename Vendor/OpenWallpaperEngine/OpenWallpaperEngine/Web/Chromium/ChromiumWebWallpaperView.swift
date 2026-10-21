import SwiftUI

/// A web wallpaper on one display, rendered by Chromium (`WebEngineRouting`): the same
/// `WebWallpaperViewModel` as the WebKit view, talking to a `ChromiumBrowserPage` instead of a
/// WKWebView. Frames come from the helper's IOSurfaces into this window's Metal layer.
struct ChromiumWebWallpaperView: NSViewRepresentable {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @StateObject var viewModel: WebWallpaperViewModel
    let screenId: String

    init(wallpaperViewModel: WallpaperViewModel, screenId: String) {
        self.wallpaperViewModel = wallpaperViewModel
        self.screenId = screenId
        self._viewModel = StateObject(wrappedValue: WebWallpaperViewModel(wallpaper: wallpaperViewModel.wallpaper(for: screenId),
                                                                          propertyScope: wallpaperViewModel.propertyScope(for: screenId),
                                                                          media: AppDelegate.shared.mediaSession))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ChromiumPageView {
        let page = ChromiumBrowserPage(startScripts: WebWallpaperViewModel.documentStartScripts,
                                       frameRate: viewModel.frameRate)
        let view = ChromiumPageView(page: page)
        context.coordinator.page = page
        viewModel.renderWatchdog = wallpaperViewModel.renderWatchdog
        viewModel.page = page
        page.onMessage = { [weak viewModel] name, body in viewModel?.receivePageMessage(name: name, body: body) }
        page.onLoad = { [weak viewModel] status in
            if status < 0 { OWELog.error(.web, "Chromium couldn't load the web wallpaper (error \(status))") }
            viewModel?.pageDidFinishLoading()
        }
        viewModel.onFrameRateChange = { [weak page] fps in page?.setFrameRate(fps) }
        viewModel.applySchedulingPolicy()
        context.coordinator.share(view, of: screenId, through: wallpaperViewModel.webPageMirrors, viewModel: viewModel)
        Self.load(page, viewModel: viewModel)
        return view
    }

    static func dismantleNSView(_ nsView: ChromiumPageView, coordinator: Coordinator) {
        coordinator.stopSharing()
        coordinator.page?.close()
        coordinator.page = nil
    }

    /// Opens the current wallpaper's page: local pages through `owe-wallpaper://local/…` with
    /// WE's patches, remote embeds at an https origin, as the WebKit view loads them.
    static func load(_ page: ChromiumBrowserPage, viewModel: WebWallpaperViewModel) {
        viewModel.pageWillLoad()
        let wallpaper = viewModel.currentWallpaper
        ChromiumFeatureAdvisorScan.scan(wallpaper)
        switch WebWallpaperView.pageLoad(pageFile: viewModel.fileUrl, relativePath: wallpaper.project.file) {
        case .remoteEmbed(let html):
            page.load(.init(url: URL(string: ChromiumResourceServing.embedPageURL)!, directory: nil, embedHTML: html))
        case .scheme(let url):
            let patches = viewModel.compatPatches
            if patches != nil {
                OWELog.info(.web, "Serving \(wallpaper.project.title) with WE's compatibility patches")
            }
            page.load(.init(url: url, directory: viewModel.readAccessURL,
                            patches: patches ?? WebCompatPatches(actions: []), userFiles: viewModel.userFiles))
        case nil:
            OWELog.error(.web, "Can't load web wallpaper \(wallpaper.project.title): invalid page path \(wallpaper.project.file)")
        }
    }

    func updateNSView(_ nsView: ChromiumPageView, context: Context) {
        let selectedWallpaper = wallpaperViewModel.wallpaper(for: screenId)
        let currentWallpaper = viewModel.currentWallpaper
        if WebWallpaperView.pageURL(of: selectedWallpaper) != WebWallpaperView.pageURL(of: currentWallpaper) {
            viewModel.currentWallpaper = selectedWallpaper
            viewModel.stopAudio()
            Self.load(nsView.page, viewModel: viewModel)
        }
        nsView.page.evaluate(WebWallpaperView.placementScript(wallpaperViewModel.wallpaperPlacement))
        let settings = AppDelegate.shared.globalSettingsViewModel.settings
        nsView.standardResolution = settings.webStandardResolution
        nsView.halfResolution = WebPageScale.halfResolution(settings)
        let key = WallpaperInstanceKey(selectedWallpaper)
        viewModel.setPaused(!wallpaperViewModel.pageRendersFrames(of: screenId, engine: .chromium))
        viewModel.setMuted(!wallpaperViewModel.pagePlaysAudio(of: screenId, engine: .chromium) || wallpaperViewModel.playVolume == 0
                           || !wallpaperViewModel.wallpaperPlayback(of: key).playsSound)
    }

    final class Coordinator: WebPageSourceCoordinator {
        var page: ChromiumBrowserPage?
    }
}

/// Starts the static scan of a web wallpaper as it loads (cached per content key), so its
/// findings are ready for the library and the alert.
enum ChromiumFeatureAdvisorScan {
    static func scan(_ wallpaper: WEWallpaper) {
        Task { @MainActor in await ChromiumFeatureAdvisor.shared.scan(wallpaper) }
    }
}
