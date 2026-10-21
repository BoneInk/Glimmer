import Combine
import Foundation

/// What is known about one web wallpaper's use of Chromium-only APIs, for its current content.
struct ChromiumFeatureFinding: Codable, Equatable {
    /// `ChromiumFeatureScanner.contentKey`: a finding of other content is stale.
    var contentKey: String
    /// Found by reading the code.
    var staticFeatures: [String]
    /// Seen failing while the page ran in WebKit.
    var runtimeFeatures: [String] = []

    /// Both, in catalog order.
    var features: [ChromiumFeature] {
        ChromiumFeatureCatalog.ordered(staticFeatures + runtimeFeatures)
    }
}

/// The alert to show: this wallpaper uses these features and Chromium isn't installed.
struct ChromiumAdvice: Identifiable, Equatable {
    var wallpaperPath: String
    var title: String
    var contentKey: String
    var features: [ChromiumFeature]

    var id: String { wallpaperPath + "|" + contentKey + "|" + features.map(\.id).joined(separator: ",") }

    /// The APIs as one list, e.g. "navigator.serial, EyeDropper".
    var featureList: String { features.map(\.api).joined(separator: ", ") }
}

/// Findings and "Use Anyway" choices, kept in `UserDefaults` by wallpaper folder.
struct ChromiumFeatureStore {
    static let findingsKey = "ChromiumFeatureFindings"
    static let useAnywayKey = "ChromiumFeatureUseAnyway"

    let defaults: UserDefaults

    func finding(for path: String) -> ChromiumFeatureFinding? {
        guard let all = defaults.dictionary(forKey: Self.findingsKey), let data = all[path] as? Data else { return nil }
        return OWELog.attempt(.web, "Stored Chromium finding for \(path)") { try JSONDecoder().decode(ChromiumFeatureFinding.self, from: data) }
    }

    func setFinding(_ finding: ChromiumFeatureFinding, for path: String) {
        var all = defaults.dictionary(forKey: Self.findingsKey) ?? [:]
        do {
            all[path] = try JSONEncoder().encode(finding)
        } catch {
            OWELog.error(.web, "Can't store the Chromium feature finding for \(path): \(error)")
            return
        }
        defaults.set(all, forKey: Self.findingsKey)
    }

    /// The content key the user chose "Use Anyway" for, if any.
    func useAnywayKey(for path: String) -> String? {
        (defaults.dictionary(forKey: Self.useAnywayKey) as? [String: String])?[path]
    }

    func setUseAnyway(contentKey: String, for path: String) {
        var all = defaults.dictionary(forKey: Self.useAnywayKey) as? [String: String] ?? [:]
        all[path] = contentKey
        defaults.set(all, forKey: Self.useAnywayKey)
    }
}

/// Points out web wallpapers that need Chromium while it isn't installed: scans a wallpaper when
/// it loads or is inspected (cached per content key), collects what WebKit's runtime probe
/// reports, and raises `pendingAdvice` when the user applies such a wallpaper. "Use Anyway" is
/// remembered per wallpaper until its content changes.
@MainActor
final class ChromiumFeatureAdvisor: ObservableObject {
    static let shared = ChromiumFeatureAdvisor()

    /// Findings by wallpaper folder path, for the library's badge.
    @Published private(set) var findings: [String: ChromiumFeatureFinding] = [:]
    /// The alert waiting to be shown (`ContentView`).
    @Published var pendingAdvice: ChromiumAdvice?

    private let store: ChromiumFeatureStore
    private let engine: () -> WebEngine
    private let scanner: (URL) -> ChromiumFeatureScanner.Result
    private let contentKey: (URL) -> String
    /// Wallpapers applied and still waiting for their scan to decide on an alert.
    private var awaitingAdvice: Set<String> = []
    private var scans: [String: Task<ChromiumFeatureFinding?, Never>] = [:]

    init(store: ChromiumFeatureStore = ChromiumFeatureStore(defaults: .app),
         engine: (() -> WebEngine)? = nil,
         scanner: @escaping (URL) -> ChromiumFeatureScanner.Result = ChromiumFeatureScanner.scan(directory:),
         contentKey: @escaping (URL) -> String = ChromiumFeatureScanner.contentKey(of:)) {
        self.store = store
        self.engine = engine ?? { WebEngineRouter.shared.installed ? .chromium : .webKit }
        self.scanner = scanner
        self.contentKey = contentKey
    }

    /// Whether an alert is due: WebKit plays the wallpaper, it uses Chromium-only features, and
    /// the user hasn't chosen "Use Anyway" for this content.
    nonisolated static func shouldAdvise(engine: WebEngine, finding: ChromiumFeatureFinding?, useAnywayKey: String?) -> Bool {
        guard engine == .webKit, let finding, !finding.features.isEmpty else { return false }
        return useAnywayKey != finding.contentKey
    }

    private static func isWeb(_ wallpaper: WEWallpaper) -> Bool {
        wallpaper.project.type.lowercased() == "web"
    }

    private static func path(of wallpaper: WEWallpaper) -> String {
        wallpaper.wallpaperDirectory.standardizedFileURL.path
    }

    /// The cached finding for `wallpaper`'s current content, scanning if there is none. Reading
    /// files happens off the main thread.
    @discardableResult
    func scan(_ wallpaper: WEWallpaper) async -> ChromiumFeatureFinding? {
        guard Self.isWeb(wallpaper) else { return nil }
        let path = Self.path(of: wallpaper)
        if let running = scans[path] { return await running.value }
        let directory = wallpaper.wallpaperDirectory
        let cached = findings[path] ?? store.finding(for: path)
        let contentKey = self.contentKey
        let scanner = self.scanner
        let task = Task<ChromiumFeatureFinding?, Never> {
            let finding = await Task.detached(priority: .utility) { () -> ChromiumFeatureFinding in
                let key = contentKey(directory)
                if let cached, cached.contentKey == key { return cached }
                let result = scanner(directory)
                return ChromiumFeatureFinding(contentKey: result.contentKey, staticFeatures: result.features)
            }.value
            return finding
        }
        scans[path] = task
        let finding = await task.value
        scans[path] = nil
        if let finding {
            if finding != cached { store.setFinding(finding, for: path) }
            findings[path] = finding
            if !finding.features.isEmpty {
                OWELog.info(.web, "\(wallpaper.project.title) uses Chromium-only APIs: \(finding.features.map(\.api).joined(separator: ", "))")
            }
        }
        return finding
    }

    /// The user applied `wallpaper`: alert once its scan is in, if one is due.
    func wallpaperApplied(_ wallpaper: WEWallpaper) {
        guard Self.isWeb(wallpaper) else { return }
        let path = Self.path(of: wallpaper)
        awaitingAdvice.insert(path)
        Task {
            let finding = await scan(wallpaper)
            guard awaitingAdvice.remove(path) != nil else { return }
            adviseIfDue(wallpaper, finding: finding)
        }
    }

    /// WebKit's probe saw the page fail on `featureIds`.
    func recordRuntime(_ featureIds: [String], for wallpaper: WEWallpaper) {
        guard Self.isWeb(wallpaper), !featureIds.isEmpty else { return }
        let path = Self.path(of: wallpaper)
        Task {
            guard var finding = await scan(wallpaper) else { return }
            let new = Set(featureIds).subtracting(finding.runtimeFeatures).subtracting(finding.staticFeatures)
            guard !new.isEmpty else { return }
            finding.runtimeFeatures = ChromiumFeatureCatalog.ordered(finding.runtimeFeatures + Array(new)).map(\.id)
            findings[path] = finding
            store.setFinding(finding, for: path)
            OWELog.info(.web, "\(wallpaper.project.title) failed on Chromium-only APIs at run time: \(new.sorted().joined(separator: ", "))")
            adviseIfDue(wallpaper, finding: finding)
        }
    }

    private func adviseIfDue(_ wallpaper: WEWallpaper, finding: ChromiumFeatureFinding?) {
        let path = Self.path(of: wallpaper)
        guard Self.shouldAdvise(engine: engine(), finding: finding, useAnywayKey: store.useAnywayKey(for: path)),
              let finding else { return }
        let advice = ChromiumAdvice(wallpaperPath: path, title: wallpaper.project.displayTitle,
                                    contentKey: finding.contentKey, features: finding.features)
        // One alert at a time; a newer finding for the same wallpaper replaces the shown one.
        if pendingAdvice == nil || pendingAdvice?.wallpaperPath == path {
            pendingAdvice = advice
        }
    }

    /// "Use Anyway": the wallpaper keeps playing in WebKit and isn't pointed out again until its
    /// content changes.
    func useAnyway(_ advice: ChromiumAdvice) {
        store.setUseAnyway(contentKey: advice.contentKey, for: advice.wallpaperPath)
        if pendingAdvice?.wallpaperPath == advice.wallpaperPath { pendingAdvice = nil }
    }

    /// "Open Plugins": Settings › Plugins with the Chromium engine highlighted. Asked again next
    /// time unless the engine gets installed.
    func openPlugins(_ advice: ChromiumAdvice) {
        if pendingAdvice?.wallpaperPath == advice.wallpaperPath { pendingAdvice = nil }
        AppDelegate.shared.openSettings(.plugins, anchor: SettingsAnchor.chromium)
    }

    /// The features found for `wallpaper`, for its badge (nil before a scan).
    func features(of wallpaper: WEWallpaper) -> [ChromiumFeature]? {
        findings[Self.path(of: wallpaper)]?.features
    }
}
