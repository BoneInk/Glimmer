import AppKit
import Combine

/// Settings › Plugins › Screen Saver. While on, the bundled saver is installed and shows the
/// screen saver's layout (`ScreenSaverLayoutPlan`: per display, cloned, or one stretched over the
/// displays' canvas), every loop drawn live by the app while the screen saver runs (`liveLoops`,
/// `ScreenSaverLiveController`): scenes, video wallpapers (`ScreenSaverLiveVideo`), and web
/// wallpapers and WebM videos through Chromium. Nothing is recorded, linked or copied. Off removes
/// the saver.
///
/// - Only the user's own copy installs the saver and writes where it reads
///   (`ScreenSaverInstaller.mayInstall`, `ScreenSaverVideoStore`'s isolated folder).
/// - While a wallpaper is picked as the screen saver (`ScreenSaverSettingsStore.livePick`) it is
///   drawn live on every display; otherwise the desktop's layout is.
@MainActor
final class ScreenSaverPlugin: ObservableObject {
    /// What the Details pane says about a wallpaper in the screen saver.
    enum Status: Equatable {
        /// The screen saver shows it, drawn live.
        case available
        /// Not a wallpaper the screen saver shows (`isEligible`).
        case notEligible
        /// A web wallpaper or WebM video, drawn only by the Chromium engine, which isn't installed.
        case needsChromium
    }

    private let store: ScreenSaverVideoStore
    private let installer: ScreenSaverInstaller
    let settingsStore: ScreenSaverSettingsStore
    @Published private(set) var isEnabled = false
    /// The view model whose displays the plan follows (`observe(_:)`).
    private(set) weak var viewModel: WallpaperViewModel?
    private var observation: AnyCancellable?
    private static let fileQueue = DispatchQueue(label: "OWE.ScreenSaverPlugin", qos: .utility)

    init(store: ScreenSaverVideoStore = .current, installer: ScreenSaverInstaller = .current,
         settingsStore: ScreenSaverSettingsStore = ScreenSaverSettingsStore()) {
        self.store = store
        self.installer = installer
        self.settingsStore = settingsStore
    }

    /// Whether the screen saver shows `wallpaper`: scenes and videos in a container AVFoundation
    /// plays (drawn live by the app), web wallpapers and WebM videos (drawn live through Chromium);
    /// never application wallpapers.
    nonisolated static func isEligible(_ wallpaper: WEWallpaper) -> Bool {
        isScene(wallpaper) || ScreenSaverVideoSource.isEligible(wallpaper) || isWeb(wallpaper) || isWebMVideo(wallpaper)
    }

    nonisolated static func isScene(_ wallpaper: WEWallpaper) -> Bool {
        wallpaper.project != .invalid && wallpaper.project.type.caseInsensitiveCompare("scene") == .orderedSame
    }

    nonisolated static func isWeb(_ wallpaper: WEWallpaper) -> Bool {
        wallpaper.project != .invalid && wallpaper.project.type.caseInsensitiveCompare("web") == .orderedSame
    }

    nonisolated static func isWebMVideo(_ wallpaper: WEWallpaper) -> Bool {
        wallpaper.project != .invalid && wallpaper.project.type.caseInsensitiveCompare("video") == .orderedSame
            && (wallpaper.project.file as NSString).pathExtension.lowercased() == "webm"
    }

    /// What to show for `wallpaper`: nil while the plugin is off. Scenes and videos are available
    /// at once, a web page or WebM video once Chromium is installed.
    nonisolated static func status(for wallpaper: WEWallpaper, enabled: Bool, chromiumInstalled: Bool) -> Status? {
        guard enabled else { return nil }
        guard isEligible(wallpaper) else { return .notEligible }
        if isWeb(wallpaper) || isWebMVideo(wallpaper) { return chromiumInstalled ? .available : .needsChromium }
        return .available
    }

    func status(for wallpaper: WEWallpaper) -> Status? {
        Self.status(for: wallpaper, enabled: isEnabled, chromiumInstalled: ChromiumEngineInstaller.hasActiveInstall)
    }

    /// The plugin's setting or the shown wallpapers changed: installs or removes the saver, and
    /// reads the shown videos' sizes ahead of the next screen saver (`wallpaper` before a view
    /// model is observed).
    func update(enabled: Bool, wallpaper: WEWallpaper?) {
        let wasEnabled = isEnabled
        isEnabled = enabled
        let store = store, installer = installer
        guard enabled else {
            if wasEnabled { Self.fileQueue.async { installer.uninstall(); store.removeAll() } }
            return
        }
        if !wasEnabled {
            Self.fileQueue.async { installer.install() }
        }
        prefetchVideoInfo(fallback: wallpaper)
    }

    /// Follows the wallpapers, the layouts and the displays: the shown videos' sizes are read
    /// ahead of the next screen saver.
    func observe(_ viewModel: WallpaperViewModel) {
        self.viewModel = viewModel
        let screens = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).map { _ in () }
        observation = Publishers.Merge3(viewModel.$wallpapers.map { _ in () }, viewModel.$screenSaverLayout.map { _ in () }, screens)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isEnabled else { return }
                    self.prefetchVideoInfo(fallback: nil)
                }
            }
    }

    /// Reads the size and frame rate of the videos the next screen saver draws, in the background.
    private func prefetchVideoInfo(fallback: WEWallpaper?) {
        var wallpapers = viewModel.map { Array($0.displayedWallpapers.values) } ?? []
        if let fallback { wallpapers.append(fallback) }
        if let pick = livePick { wallpapers.append(pick) }
        ScreenSaverVideoSource.prefetchInfo(of: wallpapers.filter(ScreenSaverVideoSource.isEligible).map(\.mediaURL))
    }

    /// The plan for the displays now, with each planned content's wallpaper by its id.
    func currentPlan(fallback: WEWallpaper?) -> (plan: ScreenSaverLayoutPlan, wallpapers: [String: WEWallpaper]) {
        var wallpapers: [String: WEWallpaper] = [:]
        func content(_ wallpaper: WEWallpaper, scope: WallpaperPropertyScope) -> ScreenSaverLayoutPlan.Content {
            let id = wallpaper.wallpaperDirectory.standardizedFileURL.path
            wallpapers[id] = wallpaper
            // A video plays as it is: its user properties don't change its frames.
            guard !ScreenSaverVideoSource.isEligible(wallpaper) else { return ScreenSaverLayoutPlan.Content(id: id) }
            return ScreenSaverLayoutPlan.Content(id: id, properties: WallpaperServices.shared.userProperties(
                wallpaper: scope.runtimeKey(directory: wallpaper.settingsDirectory)))
        }
        let scales = Dictionary(NSScreen.screens.map { (WallpaperViewModel.screenId(for: $0), $0.backingScaleFactor) },
                                uniquingKeysWith: max)
        let identities = viewModel?.connectedDisplays() ?? DisplayIdentity.connected()
        let displays = identities.map {
            ScreenSaverLayoutPlan.Display(screenId: $0.screenId, identity: $0.identity, frame: $0.frame, scale: scales[$0.screenId] ?? 1)
        }
        guard let viewModel else {
            var shown: [String: ScreenSaverLayoutPlan.Content] = [:]
            if let fallback {
                let fallback = content(fallback, scope: .shared)
                for display in displays { shown[display.screenId] = fallback }
            }
            let plan = ScreenSaverLayoutPlan(ScreenSaverDisplayLayout(), wallpaperLayout: .perDisplay, resolution: .empty,
                                             displays: displays, shown: shown)
            return (plan, wallpapers)
        }
        var displayed: [String: ScreenSaverLayoutPlan.Content] = [:]
        for (screen, wallpaper) in viewModel.displayedWallpapers {
            displayed[screen] = content(wallpaper, scope: viewModel.instanceKey(for: screen).properties)
        }
        let resolution = viewModel.layoutResolution
        let shown = ScreenSaverLayoutPlan.shown(displayed, screenIds: displays.map(\.screenId), resolution: resolution)
        let plan = ScreenSaverLayoutPlan(viewModel.screenSaverLayout, wallpaperLayout: viewModel.displayLayout.layout,
                                         resolution: resolution, displays: displays, shown: shown)
        return (plan, wallpapers)
    }

    /// Whether the saver follows the desktop's wallpapers: on, with nothing picked as the screen
    /// saver (the live screen saver then draws the desktop's layout, `ScreenSaverLiveController`).
    var followsDesktop: Bool {
        isEnabled && settingsStore.livePick == nil
    }

    /// The wallpaper picked as the screen saver (Scene Edit / Export's Screen Saver mode, Set as
    /// Screen Saver), while the plugin is on and it is still in the library.
    var livePick: WEWallpaper? {
        guard isEnabled, let pick = settingsStore.livePick else { return nil }
        return InstalledLibrary.wallpaper(at: URL(filePath: pick.wallpaperDirectory, directoryHint: .isDirectory), hiding: [])
    }
}
