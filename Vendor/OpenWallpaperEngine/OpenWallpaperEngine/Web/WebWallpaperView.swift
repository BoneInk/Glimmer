//
//  WebWallpaperView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/13.
//

import Cocoa
import SwiftUI
import WebKit

struct WebWallpaperView: NSViewRepresentable {
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

    func makeNSView(context: Context) -> WKWebView {
        let configuration = Self.makeConfiguration()
        viewModel.installBridge(on: configuration.userContentController)
        configuration.setURLSchemeHandler(viewModel.schemeHandler, forURLScheme: WebWallpaperSchemeHandler.scheme)
        viewModel.renderWatchdog = wallpaperViewModel.renderWatchdog
        // The related page only lends its process; this page's configuration stays its own.
        let pageURL = Self.pageURL(of: viewModel.currentWallpaper)
        wallpaperViewModel.webProcessGroup.relate(configuration, to: pageURL)

        let nsView = WKWebView(frame: .zero, configuration: configuration)
        wallpaperViewModel.webProcessGroup.register(nsView, for: pageURL)
        AppDelegate.shared.webDevtools.register(nsView)
        nsView.navigationDelegate = viewModel
        viewModel.webView = nsView
        viewModel.applySchedulingPolicy()
        Self.loadWallpaper(nsView, viewModel: viewModel)
        return nsView
    }

    static func pageURL(of wallpaper: WEWallpaper) -> URL {
        wallpaper.wallpaperDirectory.appending(path: wallpaper.project.file)
    }

    /// The page's configuration before the wallpaper's own parts are added. Local files are
    /// served by `WebWallpaperSchemeHandler`, so no file-URL access preference is changed.
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        return configuration
    }

    /// How a wallpaper's page is loaded.
    enum PageLoad: Equatable {
        /// A page embedding a remote player (YouTube/Vimeo), loaded as a string with an https
        /// origin so the embed accepts it.
        case remoteEmbed(html: String)
        /// A local page, served from the wallpaper folder by `WebWallpaperSchemeHandler`.
        case scheme(URL)
    }

    static func pageLoad(pageFile: URL, relativePath: String) -> PageLoad? {
        // A page that can't be read here is still requested, and the handler answers it with a 404.
        if let html = try? String(contentsOf: pageFile, encoding: .utf8),
           html.contains("youtube.com") || html.contains("vimeo.com") {
            return .remoteEmbed(html: html)
        }
        return WebWallpaperSchemeHandler.url(forRelativePath: relativePath).map(PageLoad.scheme)
    }

    private static func loadWallpaper(_ webView: WKWebView, viewModel: WebWallpaperViewModel) {
        viewModel.pageWillLoad()
        let wallpaper = viewModel.currentWallpaper
        ChromiumFeatureAdvisorScan.scan(wallpaper)
        switch pageLoad(pageFile: viewModel.fileUrl, relativePath: wallpaper.project.file) {
        case .remoteEmbed(let html):
            viewModel.schemeHandler.directory = nil
            webView.loadHTMLString(html, baseURL: URL(string: "https://localhost"))
        case .scheme(let url):
            let patches = viewModel.compatPatches
            if patches != nil {
                OWELog.info(.web, "Serving \(wallpaper.project.title) with WE's compatibility patches")
            }
            viewModel.schemeHandler.directory = viewModel.readAccessURL
            viewModel.schemeHandler.patches = patches ?? WebCompatPatches(actions: [])
            viewModel.schemeHandler.userFiles = viewModel.userFiles
            webView.load(URLRequest(url: url))
        case nil:
            OWELog.error(.web, "Can't load web wallpaper \(wallpaper.project.title): invalid page path \(wallpaper.project.file)")
        }
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let selectedWallpaper = wallpaperViewModel.wallpaper(for: screenId)
        let currentWallpaper = viewModel.currentWallpaper

        if selectedWallpaper.wallpaperDirectory.appending(path: selectedWallpaper.project.file) != currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file) {
            viewModel.currentWallpaper = selectedWallpaper
            // The process was chosen at creation; only later pages of the new wallpaper join this one.
            wallpaperViewModel.webProcessGroup.register(nsView, for: Self.pageURL(of: selectedWallpaper))
            viewModel.stopAudio()
            Self.loadWallpaper(nsView, viewModel: viewModel)
        }
        applyPlacement(wallpaperViewModel.wallpaperPlacement, to: nsView)
        let settings = AppDelegate.shared.globalSettingsViewModel.settings
        WebPageScale.apply(settings, to: nsView)
        // A page per display, so only the one on the wallpaper's audible display plays sound. The
        // playback rules pause each display's page on its own, and silence the wallpaper only when
        // every display showing it is muted, paused or stopped.
        let key = WallpaperInstanceKey(selectedWallpaper)
        viewModel.setPaused(!wallpaperViewModel.playback(onScreen: screenId).rendersFrames)
        viewModel.setMuted(!wallpaperViewModel.shouldPlayAudio(on: screenId) || wallpaperViewModel.playVolume == 0
                           || !wallpaperViewModel.wallpaperPlayback(of: key).playsSound)
    }

    private func applyPlacement(_ placement: WallpaperPlacement, to webView: WKWebView) {
        webView.evaluateJavaScript(Self.placementScript(placement), completionHandler: nil)
    }

    /// Sizes the page and its media to the window as the placement says (both engines).
    static func placementScript(_ placement: WallpaperPlacement) -> String {
        let objectFit: String
        switch placement {
        case .stretch:
            objectFit = "fill"
        case .fill, .zoom:
            objectFit = "cover"
        case .fit, .center:
            objectFit = "contain"
        }
        return "document.documentElement.style.width='100%';document.documentElement.style.height='100%';document.body.style.margin='0';document.body.style.width='100%';document.body.style.height='100%';document.querySelectorAll('video,img,canvas').forEach(function(element){element.style.width='100%';element.style.height='100%';element.style.objectFit='\(objectFit)';});"
    }
}

/// How many pixels a web wallpaper draws per point, from two settings; whichever gives fewer
/// pixels wins:
/// - "Render web wallpapers at standard resolution": on a Retina display the page renders with a
///   device scale factor of 1, so a page that sizes its canvas by `devicePixelRatio` draws a
///   quarter of the pixels.
/// - Texture Resolution's High Performance (`half`): WE starts `webwallpaper64.exe` with
///   `-halfresolution` for it, and only for it (0x14011a681…0x14011a729), so the page renders at
///   half the display's scale in each direction and is stretched to the window.
///
/// WebKit's `_overrideDeviceScaleFactor` (0 = the window's own) has no public equivalent; where it
/// is missing the page keeps its full resolution. Chromium takes the scale as its device scale
/// factor (`ChromiumPageView`).
enum WebPageScale {
    private static let setOverride = NSSelectorFromString("_setOverrideDeviceScaleFactor:")

    /// The page's pixels per point on a display whose backing scale is `backingScale`.
    static func pixelsPerPoint(standardResolution: Bool, halfResolution: Bool, backingScale: CGFloat) -> CGFloat {
        let backing = max(backingScale, 1)
        var scale = backing
        if standardResolution { scale = min(scale, 1) }
        if halfResolution { scale = min(scale, backing / 2) }
        return scale
    }

    /// Texture Resolution asks for WE's `-halfresolution`.
    static func halfResolution(_ settings: GlobalSettings) -> Bool {
        settings.textureResolution == .highPerformance
    }

    /// WebKit's override for the page: 0 keeps the window's own scale.
    static func scaleFactor(standardResolution: Bool, halfResolution: Bool, backingScale: CGFloat) -> CGFloat {
        let scale = pixelsPerPoint(standardResolution: standardResolution, halfResolution: halfResolution,
                                   backingScale: backingScale)
        return scale == max(backingScale, 1) ? 0 : scale
    }

    static func apply(_ settings: GlobalSettings, to webView: WKWebView) {
        apply(standardResolution: settings.webStandardResolution, halfResolution: halfResolution(settings), to: webView)
    }

    static func apply(standardResolution: Bool, halfResolution: Bool = false, to webView: WKWebView) {
        let backingScale = webView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let factor = scaleFactor(standardResolution: standardResolution, halfResolution: halfResolution,
                                 backingScale: backingScale)
        guard webView.responds(to: setOverride), let method = webView.method(for: setOverride) else { return }
        typealias SetOverride = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        if (webView.value(forKey: "_overrideDeviceScaleFactor") as? CGFloat) == factor { return }
        unsafeBitCast(method, to: SetOverride.self)(webView, setOverride, factor)
    }
}
