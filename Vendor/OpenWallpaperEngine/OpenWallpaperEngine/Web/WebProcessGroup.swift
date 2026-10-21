//
//  WebProcessGroup.swift
//  Open Wallpaper Engine
//

import WebKit

/// Shares one WebContent process between the pages that show the same web wallpaper on several
/// displays. WebKit's private `_relatedWebView` configuration key places a new page in the process
/// of an existing one; each page keeps its own user content controller, scheme handler, properties
/// and audio, so the pages stay independent. Where the key is missing the page gets its own
/// process, as before. Pages are held weakly, so a closed page drops out on its own.
@MainActor
final class WebProcessGroup {
    private static let setRelated = NSSelectorFromString("_setRelatedWebView:")

    private struct Entry {
        weak var webView: WKWebView?
    }

    private var pages: [URL: [Entry]] = [:]

    /// A live page already showing `wallpaper`, if any.
    func relatedWebView(for wallpaper: URL) -> WKWebView? {
        pages[wallpaper]?.lazy.compactMap(\.webView).first
    }

    /// Points `configuration` at a live page showing `wallpaper`. Returns whether it did.
    @discardableResult
    func relate(_ configuration: WKWebViewConfiguration, to wallpaper: URL) -> Bool {
        guard configuration.responds(to: Self.setRelated),
              let related = relatedWebView(for: wallpaper) else { return false }
        // WebKit raises unless a related page shares its process pool and data store.
        configuration.processPool = related.configuration.processPool
        configuration.websiteDataStore = related.configuration.websiteDataStore
        configuration.perform(Self.setRelated, with: related)
        return true
    }

    /// Records `webView` as showing `wallpaper`, forgetting any earlier wallpaper it showed.
    func register(_ webView: WKWebView, for wallpaper: URL) {
        for key in Array(pages.keys) {
            let alive = pages[key, default: []].filter { $0.webView != nil && $0.webView !== webView }
            pages[key] = alive.isEmpty ? nil : alive
        }
        pages[wallpaper, default: []].append(Entry(webView: webView))
    }
}
