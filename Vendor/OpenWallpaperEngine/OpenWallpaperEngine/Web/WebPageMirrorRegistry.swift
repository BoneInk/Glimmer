import AppKit

/// The pages a clone's or stretch's displays share: each source display's page view (a
/// `ChromiumPageView`) and the mirrors showing it on the other displays. A mirror
/// follows its source as the source's view is made again (another wallpaper, the other engine).
@MainActor
final class WebPageMirrorRegistry {
    private final class WeakView {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    private final class WeakSharing {
        weak var sharing: ScreenSaverPageSharing?
        init(_ sharing: ScreenSaverPageSharing) { self.sharing = sharing }
    }

    private var sources: [String: WeakView] = [:]
    private var sharings: [String: WeakSharing] = [:]
    private var mirrors: [String: [WebPageMirrorView]] = [:]

    /// `view` shows `screenId`'s page; its mirrors show it from now on. `sharing` is what the
    /// live screen saver draws the page through, when it can.
    func setSource(_ view: NSView, for screenId: String, sharing: ScreenSaverPageSharing? = nil) {
        sources[screenId] = WeakView(view)
        sharings[screenId] = sharing.map(WeakSharing.init)
        mirrors[screenId]?.forEach { $0.attach(view) }
    }

    /// `view` no longer shows `screenId`'s page (a newer view may already).
    func removeSource(_ view: NSView, for screenId: String) {
        guard sources[screenId]?.view === view else { return }
        sources[screenId] = nil
        sharings[screenId] = nil
        mirrors[screenId]?.forEach { $0.attach(nil) }
    }

    func source(for screenId: String) -> NSView? { sources[screenId]?.view }

    /// `screenId`'s Chromium page for the live screen saver, while it shows `wallpaper`.
    func sharing(for screenId: String, showing wallpaper: WEWallpaper) -> ScreenSaverPageSharing? {
        guard sources[screenId]?.view != nil, let sharing = sharings[screenId]?.sharing,
              sharing.sharedPage != nil, sharing.shows(wallpaper) else { return nil }
        return sharing
    }

    func add(_ mirror: WebPageMirrorView) {
        var list = mirrors[mirror.sourceScreenId] ?? []
        guard !list.contains(where: { $0 === mirror }) else { return }
        list.append(mirror)
        mirrors[mirror.sourceScreenId] = list
        mirror.attach(source(for: mirror.sourceScreenId))
    }

    func remove(_ mirror: WebPageMirrorView) {
        mirrors[mirror.sourceScreenId]?.removeAll { $0 === mirror }
        if mirrors[mirror.sourceScreenId]?.isEmpty == true { mirrors[mirror.sourceScreenId] = nil }
        mirror.attach(nil)
    }

    /// The mirrors showing `screenId`'s page.
    func mirrors(of screenId: String) -> [WebPageMirrorView] { mirrors[screenId] ?? [] }
}
