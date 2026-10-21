import AppKit

/// A page view's place in its model's `WebPageMirrorRegistry`, held by the view's SwiftUI
/// coordinator: the page view is its display's source for mirrors from `share` until
/// `stopSharing`, and the mouse and window visibility over its mirrors count as its own.
@MainActor
class WebPageSourceCoordinator {
    private var stop: (() -> Void)?

    func share(_ view: NSView, of screenId: String, through registry: WebPageMirrorRegistry,
               viewModel: WebWallpaperViewModel? = nil, sharing: ScreenSaverPageSharing? = nil) {
        stopSharing()
        registry.setSource(view, for: screenId, sharing: sharing ?? viewModel)
        (view as? ChromiumPageView)?.mirrors = { [weak registry] in registry?.mirrors(of: screenId) ?? [] }
        viewModel?.mirrorWindows = { [weak registry] in registry?.mirrors(of: screenId).compactMap(\.window) ?? [] }
        stop = { [weak registry, weak view] in
            if let view { registry?.removeSource(view, for: screenId) }
        }
    }

    func stopSharing() {
        stop?()
        stop = nil
    }
}
