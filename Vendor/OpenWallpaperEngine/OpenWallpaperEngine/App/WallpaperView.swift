//
//  WallpaperView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/6/5.
//

import Cocoa
import SwiftUI
import AVKit

struct WallpaperView: View {
    @ObservedObject var viewModel: WallpaperViewModel
    @ObservedObject var webEngine = WebEngineRouter.shared
    let screenId: String

    var body: some View {
        let wallpaper = viewModel.wallpaper(for: screenId)
        // Scenes and videos run one shared instance per wallpaper and properties; a display that
        // switches wallpaper, or whose properties split from the others', gets a new view, and
        // with it the other instance. An AVKit video has no properties: one player per video.
        let instance = viewModel.instanceKey(for: screenId)
        // A stretched display shows its rect of the canvas: a scene renders the canvas once and
        // each display presents its rect (`SceneCanvasSpan`); a video's one player and each page
        // are sized to the canvas and offset in the display's window.
        let canvas = viewModel.layoutResolution.canvases[screenId]
        let display = canvas == nil ? nil : viewModel.displayRect(of: screenId)
        switch wallpaper.project.type.lowercased() {
        // A remote video is the same pipeline as a local one; only the URL differs.
        case "video", "remote-video":
            // A video AVFoundation can't decode (WebM) plays through WebKit on either framework.
            // With the Chromium engine installed, that page is Chromium's (`WebEngineRouting`).
            if WebKitVideoPlayer.handles(wallpaper.mediaURL) {
                let engine = webEngine.engine(for: wallpaper)
                if let source = viewModel.pageSource(of: screenId, engine: engine) {
                    pageMirror(of: source, engine: engine)
                        .stretched(on: canvas, display: display)
                } else if engine == .chromium {
                    ChromiumVideoWallpaperView(wallpaperViewModel: viewModel, screenId: screenId)
                        .id("\(instance.wallpaper)-chromium")
                        .stretched(on: canvas, display: display)
                } else {
                    WebKitVideoWallpaperView(wallpaperViewModel: viewModel, screenId: screenId).id(instance.wallpaper)
                        .stretched(on: canvas, display: display)
                }
            // The Metal path draws video as a scene layer so the effect stack applies to it; that
            // needs the assets' shaders, so without them video plays through AVKit.
            } else if AppDelegate.shared.globalSettingsViewModel.settings.videoFramework == .metal,
                      WallpaperEngineAssets.directory != nil {
                SceneWallpaperView(wallpaperViewModel: viewModel, screenId: screenId).id(instance)
            } else {
                AudioReactiveVideoWallpaperView(wallpaperViewModel: viewModel, screenId: screenId).id(instance.wallpaper)
                    .stretched(on: canvas, display: display)
            }
        case "scene":
            if WallpaperEngineAssets.directory != nil {
                SceneWallpaperView(wallpaperViewModel: viewModel, screenId: screenId).id(instance)
            } else {
                AssetsMissingWallpaperView()
            }
        case "web":
            // Every web wallpaper plays in Chromium while it is installed and on, else in WebKit;
            // switching rebuilds the view on the other engine. In Chromium a clone's or stretch's
            // other displays show their source display's page.
            let engine = webEngine.engine(for: wallpaper)
            if let source = viewModel.pageSource(of: screenId, engine: engine) {
                pageMirror(of: source, engine: engine)
                    .stretched(on: canvas, display: display)
            } else if engine == .chromium {
                ChromiumWebWallpaperView(wallpaperViewModel: viewModel, screenId: screenId)
                    .id("\(viewModel.propertyScope(for: screenId))-chromium")
                    .stretched(on: canvas, display: display)
            } else {
                WebWallpaperView(wallpaperViewModel: viewModel, screenId: screenId)
                    .id(viewModel.propertyScope(for: screenId))
                    .stretched(on: canvas, display: display)
            }
        case "remote-image":
            RemoteImageWallpaperView(url: URL(string: wallpaper.project.file))
                .stretched(on: canvas, display: display)
        default:
            EmptyView()
        }
    }

    /// `source`'s page on this display (`WebPageMirrorView`), as WE mirrors a clone: one page.
    private func pageMirror(of source: String, engine: WebEngine) -> some View {
        WebPageMirror(registry: viewModel.webPageMirrors, sourceScreenId: source)
            .id("\(source)-mirror-\(engine.rawValue)")
    }
}

private final class RemoteImageLoader: ObservableObject {
    @Published var image: NSImage?
    private var task: URLSessionDownloadTask?

    func load(url: URL?) {
        guard let url else { return }
        let cacheDirectory = AppStorageLocation.current.cachesDirectory
            .appending(path: "Open Wallpaper Engine/RemoteImages")
        let cacheURL = cacheDirectory.appending(path: String(url.absoluteString.hashValue) + ".image")
        if let cached = NSImage(contentsOf: cacheURL) {
            image = cached
            return
        }
        task?.cancel()
        task = URLSession.shared.downloadTask(with: url) { [weak self] temporaryURL, _, _ in
            guard let temporaryURL else { return }
            do {
                try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: temporaryURL, to: cacheURL)
                guard let image = NSImage(contentsOf: cacheURL) else { return }
                DispatchQueue.main.async { self?.image = image }
            } catch {
                OWELog.error(.library, "Remote image cache failed: \(error.localizedDescription)")
            }
        }
        task?.resume()
    }
}

private struct RemoteImageWallpaperView: View {
    let url: URL?
    @StateObject private var loader = RemoteImageLoader()

    var body: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.black
            }
        }
        .ignoresSafeArea()
        .onAppear { loader.load(url: url) }
    }
}
