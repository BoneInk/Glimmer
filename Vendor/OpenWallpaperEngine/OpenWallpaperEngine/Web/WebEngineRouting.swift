import Combine
import Foundation

extension Notification.Name {
    /// Posted when the Chromium engine is installed, updated or removed.
    static let chromiumEngineChanged = Notification.Name("ChromiumEngineChanged")
}

/// Which engine plays a web wallpaper.
enum WebEngine: String, Equatable {
    case webKit
    case chromium
}

/// A wallpaper's own choice of engine, from its details.
enum WebEngineOverride: String, CaseIterable, Equatable {
    case automatic
    case webKit
    case chromium
}

/// The routing rule. A Chromium page costs about 550 MB against far less in WebKit, so WebKit plays
/// web wallpapers by default and Chromium only those that need it: the engine is installed and
/// the wallpaper uses a Chromium-only API (`ChromiumFeatureAdvisor`: the static scan, or WebKit's
/// runtime probe, which switches the wallpaper on its next load). A wallpaper's override wins
/// while the engine is installed.
enum WebEngineRouting {
    static func engine(installed: Bool, needsChromium: Bool, override: WebEngineOverride) -> WebEngine {
        guard installed else { return .webKit }
        switch override {
        case .webKit: return .webKit
        case .chromium: return .chromium
        case .automatic: return needsChromium ? .chromium : .webKit
        }
    }
}

/// The active Chromium engine on disk, readable from anywhere (the installer is main-actor bound).
enum ChromiumEngineInstallation {
    /// The active install's folder, nil without a complete one.
    static func activeInstall(in root: URL = ChromiumEngineInstaller.defaultRoot) -> URL? {
        guard let active = VersionedInstallState.read(in: root).active else { return nil }
        let folder = root.appending(path: active, directoryHint: .isDirectory)
        return ChromiumEnginePackage.manifest(in: folder) != nil ? folder : nil
    }

    static func profileDirectory(in root: URL = ChromiumEngineInstaller.defaultRoot) -> URL {
        root.appending(path: ".profile", directoryHint: .isDirectory)
    }
}

/// Picks each web wallpaper's engine when its view is built, and republishes when the engine is
/// installed or removed or an override changes, so the views are rebuilt. A finding that arrives
/// while a wallpaper plays (the runtime probe) takes effect on its next load.
@MainActor
final class WebEngineRouter: ObservableObject {
    static let shared = WebEngineRouter()

    /// `UserDefaults.app`: overrides by wallpaper folder path.
    static let overridesKey = "WebEngineOverrides"

    @Published private(set) var installed: Bool
    @Published private(set) var overrides: [String: WebEngineOverride]
    private var observer: NSObjectProtocol?
    private let isInstalled: () -> Bool
    private let defaults: UserDefaults
    private let store: ChromiumFeatureStore
    private let scanner: (URL) -> ChromiumFeatureScanner.Result
    private let contentKey: (URL) -> String

    init(isInstalled: @escaping () -> Bool = { ChromiumEngineInstallation.activeInstall() != nil },
         defaults: UserDefaults = .app,
         store: ChromiumFeatureStore = ChromiumFeatureStore(defaults: .app),
         scanner: @escaping (URL) -> ChromiumFeatureScanner.Result = ChromiumFeatureScanner.scan(directory:),
         contentKey: @escaping (URL) -> String = ChromiumFeatureScanner.contentKey(of:)) {
        self.isInstalled = isInstalled
        self.defaults = defaults
        self.store = store
        self.scanner = scanner
        self.contentKey = contentKey
        installed = isInstalled()
        let raw = defaults.dictionary(forKey: Self.overridesKey) as? [String: String] ?? [:]
        overrides = raw.compactMapValues(WebEngineOverride.init(rawValue:))
        observer = NotificationCenter.default.addObserver(forName: .chromiumEngineChanged, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        let installed = isInstalled()
        if installed != self.installed { self.installed = installed }
    }

    private static func path(of wallpaper: WEWallpaper) -> String {
        wallpaper.wallpaperDirectory.standardizedFileURL.path
    }

    func override(for wallpaper: WEWallpaper) -> WebEngineOverride {
        overrides[Self.path(of: wallpaper)] ?? .automatic
    }

    func setOverride(_ choice: WebEngineOverride, for wallpaper: WEWallpaper) {
        let path = Self.path(of: wallpaper)
        overrides[path] = choice == .automatic ? nil : choice
        defaults.set(overrides.mapValues(\.rawValue), forKey: Self.overridesKey)
    }

    /// Whether `wallpaper`'s current content uses Chromium-only APIs. Reads the stored finding
    /// (the static scan and runtime failures), scanning once if there is none for this content.
    func needsChromium(_ wallpaper: WEWallpaper) -> Bool {
        guard wallpaper.project.type.lowercased() == "web" else { return false }
        let path = Self.path(of: wallpaper)
        let key = contentKey(wallpaper.wallpaperDirectory)
        if let finding = store.finding(for: path), finding.contentKey == key {
            return !finding.features.isEmpty
        }
        let result = scanner(wallpaper.wallpaperDirectory)
        store.setFinding(ChromiumFeatureFinding(contentKey: result.contentKey, staticFeatures: result.features), for: path)
        return !result.features.isEmpty
    }

    /// The engine for `wallpaper` now.
    func engine(for wallpaper: WEWallpaper) -> WebEngine {
        let choice = override(for: wallpaper)
        // Nothing to read when the answer can't be Chromium or doesn't depend on the finding.
        guard installed else { return .webKit }
        let needs = choice == .automatic ? needsChromium(wallpaper) : false
        return WebEngineRouting.engine(installed: installed, needsChromium: needs, override: choice)
    }
}
