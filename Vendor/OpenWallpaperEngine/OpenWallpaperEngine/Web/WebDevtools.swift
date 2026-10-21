import AppKit
import WebKit

/// WE's "CEF devtools" (Settings › Advanced, `openWebWallpaperDevtools`): developer tools for the
/// web wallpapers that are playing. Off by default and never stored, so it ends with the session.
/// - WebKit pages become inspectable (`isInspectable`) and Safari's Develop menu lists them.
/// - Chromium pages get Chromium's DevTools on `127.0.0.1:chromiumPort`; CEF serves the list of
///   pages there, as WE's docs describe for its own port, and Chrome's chrome://inspect finds the
///   port by itself. Only processes on this Mac can reach it.
@MainActor
final class WebDevtools: ObservableObject {
    /// Chromium's usual DevTools port, the one chrome://inspect looks at without being told.
    static let chromiumPort = 9222
    static let chromiumListURL = URL(string: "http://127.0.0.1:\(chromiumPort)/")!

    @Published var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            OWELog.info(.web, "Web wallpaper devtools \(isEnabled ? "on" : "off")")
            apply()
        }
    }

    private let chromium: ChromiumBrowserHost
    private let webViews = NSHashTable<WKWebView>.weakObjects()

    init(chromium: ChromiumBrowserHost) {
        self.chromium = chromium
    }

    /// A WebKit wallpaper page: inspectable while devtools are on.
    func register(_ webView: WKWebView) {
        webViews.add(webView)
        webView.isInspectable = isEnabled
    }

    private func apply() {
        webViews.allObjects.forEach { $0.isInspectable = isEnabled }
        chromium.remoteDebuggingPort = isEnabled ? Self.chromiumPort : 0
    }

    /// Where "Open Devtools" goes.
    enum Target: Equatable {
        /// Chromium pages play: their list on the DevTools port.
        case chromium(URL)
        /// Only WebKit pages play: Safari's Develop menu.
        case webKit
        /// WE's "No web wallpaper active."
        case none
    }

    var target: Target {
        if chromium.hasBrowsers { return .chromium(Self.chromiumListURL) }
        if webViews.allObjects.contains(where: { $0.window != nil }) { return .webKit }
        return .none
    }

    /// Opens the devtools of the playing web wallpapers and says where they are.
    @discardableResult
    func open() -> Target {
        let target = target
        switch target {
        case .chromium(let url):
            NSWorkspace.shared.open(url)
        case .webKit:
            if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
                NSWorkspace.shared.openApplication(at: safari, configuration: NSWorkspace.OpenConfiguration())
            }
        case .none:
            break
        }
        return target
    }
}
