import AppKit
import Combine
import OWETheming

/// Settings › General › Theming: macOS follows the main display's wallpaper's scheme colour
/// (docs/theming.md). The colour and the system preferences come from `OWETheming`; this owns
/// when they apply: when the wallpaper, its scheme colour, the screens or the settings change,
/// debounced. The preferences go through `SystemThemeApplier` (originals saved first, restored
/// when a checkbox or the master switch goes off, on quit when chosen, and after a crash at the
/// next launch). A new icon or folder colour restarts the Dock once it settles
/// (`DockRestartScheduler`). The menu bar strips fill the top of each wallpaper window (what the
/// transparent menu bar shows) and are drawn into the desktop pictures OWE sets
/// (`DesktopPictureTheming`).
@MainActor
final class ThemingController: ObservableObject {
    /// The colour applied now; nil when theming is off or the wallpaper has none.
    @Published private(set) var color: ThemeColor?
    /// Whether the colour is the snapshot's main colour rather than a scheme colour.
    @Published private(set) var isDerivedColor = false
    /// The icon style or tint changed since the Dock last started and the Dock doesn't restart by
    /// itself: Settings offers the button.
    @Published private(set) var needsDockRestart = false
    /// The accent of the app's own windows: the colour while Accent Color is on and the app follows
    /// the theme (`ThemingSettings.appTint`); nil for the system accent. `ThemeTintSync` applies it.
    @Published private(set) var appTint: ThemeColor?

    private let writer: SystemAppearanceWriter
    private let applier: SystemThemeApplier
    private let dock: DockRestartScheduler
    private let services: WallpaperServices
    /// The strips changed: the wallpaper windows and the desktop pictures get (or lose) them.
    private let stripsChanged: () -> Void
    private var settings = ThemingSettings()
    private weak var wallpaperViewModel: WallpaperViewModel?
    private var cancellables: [AnyCancellable] = []
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?
    /// Bumped by every update, so a dominant colour found for an older one is dropped.
    private var generation = 0
    private(set) var strips: DesktopPictureStrips?

    static let debounce: TimeInterval = 0.4
    private static let queue = DispatchQueue(label: "OWE.Theming", qos: .utility)
    /// Each picture's main colour, per wallpaper snapshot or preview file and its version.
    nonisolated private static let dominantColors = DominantColorCache()

    init(writer: SystemAppearanceWriter, store: ThemingJournalStore, dock: DockRestarting,
         services: WallpaperServices = .shared, stripsChanged: @escaping () -> Void) {
        self.writer = writer
        // Before the applier recovers a crashed session: the Dock started with today's values.
        self.dock = DockRestartScheduler(restarter: dock, writer: writer,
                                         logError: { OWELog.error(.settings, "\($0)") })
        applier = SystemThemeApplier(writer: writer, store: store)
        self.services = services
        self.stripsChanged = stripsChanged
    }

    /// The app's controller: the real preferences and Dock, or none written and no Dock restarted in
    /// an isolated copy (tests, development copies), which never changes the Mac's settings.
    static func make(stripsChanged: @escaping () -> Void) -> ThemingController {
        let isolated: Bool = AppStorageLocation.current.isIsolated
        let writer: SystemAppearanceWriter = isolated ? ReadOnlyAppearanceWriter() : GlobalPreferencesWriter()
        let dock = LoggedDockRestart(restarter: isolated ? nil : SystemDockRestarter())
        let store = UserDefaultsJournalStore(defaults: .app, logError: { OWELog.error(.settings, "\($0)") })
        return ThemingController(writer: writer, store: store, dock: dock, stripsChanged: stripsChanged)
    }

    // MARK: Lifecycle

    /// At launch: puts back what a crashed session changed, then follows the settings and the
    /// main display's wallpaper.
    func start(settings: AnyPublisher<ThemingSettings, Never>, wallpapers: WallpaperViewModel) {
        if applier.recoverAfterUncleanExit() {
            OWELog.info(.settings, "Theming: restored the system colours a session that didn't quit left changed")
        }
        wallpaperViewModel = wallpapers
        cancellables = [
            settings.removeDuplicates().sink { [weak self] value in
                self?.settings = value
                self?.schedule()
            },
            wallpapers.$wallpapers.map { _ in () }.sink { [weak self] in self?.schedule() },
        ]
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .sceneUserPropertiesDidChange, object: nil, queue: .main) { [weak self] note in
                let keys = note.userInfo?["keys"] as? [String] ?? []
                guard keys.contains(SchemeColorSource.propertyName) else { return }
                MainActor.assumeIsolated { self?.schedule() }
            },
            center.addObserver(forName: .wallpaperPropertiesDidSave, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            },
            center.addObserver(forName: .sceneLoadingSnapshotSaved, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.settings.usesDominantColor, !self.isUsingSchemeColor else { return }
                    self.schedule()
                }
            },
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            },
        ]
    }

    /// On quit: the originals go back when the user chose "Restore on quit".
    func stop() {
        pending?.cancel()
        cancellables = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        applier.endSession(restoring: settings.restoresOnQuit)
        appTint = nil
        // A restore on quit, or a settle still pending, shows in the Dock now.
        if settings.restartsDockAutomatically { dock.settle() }
    }

    // MARK: Updating

    private var isUsingSchemeColor: Bool { color != nil && !isDerivedColor }

    /// Updates after the changes settle.
    func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.update() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    private func update() {
        generation &+= 1
        guard settings.wantsColor, let model = wallpaperViewModel else {
            apply(nil, derived: false)
            return
        }
        let screenId = WallpaperViewModel.mainScreenId()
        let wallpaper = model.wallpaper(for: screenId)
        let scope = model.propertyScope(for: screenId)
        let scheme = SchemeColorSource.resolve(
            running: services.userProperties(wallpaper: scope.runtimeKey(directory: wallpaper.settingsDirectory)),
            userSet: WallpaperSettingsIdentity.resolve(wallpaper).userSetValues(scope: scope),
            projectValue: wallpaper.project.general?.properties.schemecolor?.value)
        if let scheme {
            apply(scheme, derived: false)
            return
        }
        guard settings.usesDominantColor else {
            apply(nil, derived: false)
            return
        }
        let generation = generation
        let candidates = pictureCandidates(for: wallpaper)
        Self.queue.async { [weak self] in
            let dominant: ThemeColor? = Self.dominantColor(of: candidates)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    self.apply(dominant, derived: dominant != nil)
                }
            }
        }
    }

    private func apply(_ newColor: ThemeColor?, derived: Bool) {
        let desired = ThemePlan.preferences(for: newColor, settings: settings,
                                            currentIconTheme: writer.value(for: .iconAppearanceTheme))
        let written = applier.apply(desired)
        if !written.isEmpty { OWELog.info(.settings, "Theming: wrote \(written.map(\.rawValue).sorted())") }
        updateDock(iconsWritten: written.contains { $0.change == .iconAppearance })
        if color != newColor { color = newColor }
        if isDerivedColor != derived { isDerivedColor = derived }
        let tint = settings.appTint(for: newColor)
        if appTint != tint { appTint = tint }

        let newStrips: DesktopPictureStrips? = settings.wantsMenuBarStrip ? newColor.map {
            DesktopPictureStrips(color: $0, displays: Self.stripDisplays(NSScreen.screens))
        } : nil
        guard newStrips != strips else { return }
        strips = newStrips
        stripsChanged()
    }

    /// The Dock shows a new icon style or tint only once it starts. With "Restart the Dock
    /// automatically" it restarts after the values settle (`DockRestartScheduler`: once per settle,
    /// never for unchanged values); otherwise Settings offers the button.
    private func updateDock(iconsWritten: Bool) {
        if settings.restartsDockAutomatically {
            if iconsWritten || needsDockRestart { dock.iconPreferencesChanged() }
            if needsDockRestart { needsDockRestart = false }
        } else {
            dock.cancel()
            let outOfDate = dock.isOutOfDate
            if needsDockRestart != outOfDate { needsDockRestart = outOfDate }
        }
    }

    /// Restarts the Dock now (the button), when it shows other values than those stored.
    func restartDock() {
        dock.settle()
        needsDockRestart = dock.isOutOfDate
    }

    // MARK: Pictures

    /// The menu bar strip geometry of `screens`, by display id.
    static func stripDisplays(_ screens: [NSScreen]) -> [UInt32: MenuBarStripDisplay] {
        var displays: [UInt32: MenuBarStripDisplay] = [:]
        for screen in screens {
            guard let id = DesktopSnapshotCache.displayID(screen) else { continue }
            let height = MenuBarStrip.height(frame: screen.frame, visibleFrame: screen.visibleFrame,
                                             safeAreaTop: screen.safeAreaInsets.top)
            guard height > 0 else { continue }
            displays[id] = MenuBarStripDisplay(size: screen.frame.size, menuBarHeight: height)
        }
        return displays
    }

    /// Where the main display's wallpaper has a picture, best first: its scene snapshot, the
    /// desktop picture OWE made of it, its Workshop preview. Resolved off the main thread.
    private func pictureCandidates(for wallpaper: WEWallpaper) -> PictureCandidates {
        let main = NSScreen.main
        let size = main.map { SIMD2(Int($0.frame.width * $0.backingScaleFactor), Int($0.frame.height * $0.backingScaleFactor)) }
        return PictureCandidates(
            isScene: wallpaper.project.type.caseInsensitiveCompare("scene") == .orderedSame,
            directory: wallpaper.wallpaperDirectory,
            pixelSize: size ?? SIMD2(1920, 1080),
            desktopPicture: main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
                .flatMap { LockScreenPicture.current.isLockPicture($0) ? $0 : nil },
            preview: wallpaper.project.preview.map { wallpaper.wallpaperDirectory.appending(path: $0) })
    }

    struct PictureCandidates: Sendable {
        var isScene: Bool
        var directory: URL
        var pixelSize: SIMD2<Int>
        /// The main display's desktop picture, when it is one of OWE's (`DesktopPictureSync`).
        var desktopPicture: URL?
        var preview: URL?
    }

    nonisolated private static func dominantColor(of candidates: PictureCandidates) -> ThemeColor? {
        ThreadGuards.assertBackground("ThemingController.dominantColor")
        var urls: [URL] = []
        if candidates.isScene, let snapshot = SceneLoadingSnapshotStore.current.bestSnapshot(
            forWallpaperAt: candidates.directory, pixelSize: candidates.pixelSize) {
            urls.append(snapshot)
        }
        if !candidates.isScene, let desktop = candidates.desktopPicture, LockScreenPicture.fileExists(desktop) {
            urls.append(desktop)
        }
        if let preview = candidates.preview { urls.append(preview) }
        for url in urls {
            if let color = dominantColors.color(fileAt: url) { return color }
        }
        return nil
    }
}

/// The app's Dock restart, logged; an isolated copy (no restarter) only logs.
private final class LoggedDockRestart: DockRestarting {
    private let restarter: DockRestarting?

    init(restarter: DockRestarting?) { self.restarter = restarter }

    func restartDock() throws {
        guard let restarter else {
            OWELog.info(.settings, "Theming: would restart the Dock (isolated copy)")
            return
        }
        try restarter.restartDock()
        OWELog.info(.settings, "Theming: restarted the Dock to show the icon and folder colour")
    }
}
