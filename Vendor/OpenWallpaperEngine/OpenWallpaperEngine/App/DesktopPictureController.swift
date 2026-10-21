import AppKit
import Combine

extension Notification.Name {
    /// A web wallpaper's page drew a snapshot for the desktop picture; the object is a
    /// `WebWallpaperPageSnapshot`. Posted on the main thread.
    static let webWallpaperPageSnapshot = Notification.Name("OpenWallpaperEngine.webWallpaperPageSnapshot")
}

/// A web wallpaper page's snapshot (`Notification.Name.webWallpaperPageSnapshot`).
struct WebWallpaperPageSnapshot {
    var wallpaperDirectory: URL
    var image: CGImage
}

/// The app's side of the desktop pictures (`DesktopPictureSync`): on while Settings shows the
/// wallpaper on the lock screen, tints the menu bar with it (both read the desktop picture) or
/// themes the menu bar (Theming › Menu Bar), and only in a copy that may change it
/// (`DesktopSnapshotCache.mayChangeDesktopPicture`).
///
/// It plans every display from the wallpapers each one shows (clones, stretches, splits, display
/// options), and updates after any of those change, a scene saves a snapshot or a page draws one.
/// A Space change, a wake or a display change shows the current pictures again, since macOS
/// sets a picture on the current Space only. Turning both settings off, or quitting, puts the
/// user's pictures back. Theming's menu bar strips (`DesktopPictureTheming`) are read at each
/// refresh, and theming refreshes when they change.
@MainActor
final class DesktopPictureController {
    private static let fallbackKey = "OSWallpaper"

    let sync: DesktopPictureSync
    /// The screen saver's own stills while the desktop pictures don't follow the wallpapers: the
    /// same pictures, written but never set (`DesktopPictureSync.setsPictures` false).
    let saverSync: DesktopPictureSync?
    /// Whether the screen saver wants each display's still (the Screen Saver plugin is on and
    /// this copy keeps its stills).
    var wantsScreenSaverStills: () -> Bool = { false }
    private let mayChange: Bool
    private weak var viewModel: WallpaperViewModel?
    private weak var settings: GlobalSettingsViewModel?
    private var cancellables = Set<AnyCancellable>()
    private var wasActive = false

    init(sync: DesktopPictureSync, saverSync: DesktopPictureSync? = nil,
         mayChange: Bool = DesktopSnapshotCache.mayChangeDesktopPicture) {
        self.sync = sync
        self.saverSync = saverSync
        self.mayChange = mayChange
    }

    static func system() -> DesktopPictureController {
        var saverFiles = LockScreenPicture.current
        saverFiles.namePrefix = LockScreenPicture.saverPrefix
        return DesktopPictureController(
            sync: DesktopPictureSync(setter: SystemDesktopPictures(), files: .current, loader: .current),
            saverSync: DesktopPictureSync(setter: SystemDesktopPictures(), files: saverFiles, loader: .current,
                                          setsPictures: false))
    }

    /// What `refresh` writes the pictures for.
    enum Mode: Equatable {
        /// The desktop pictures (and from them the screen saver's stills).
        case desktop
        /// The screen saver's stills only.
        case screenSaverStills
    }

    /// The pictures written: the desktop's while they follow the wallpapers, else the screen
    /// saver's own while it wants them, else none.
    nonisolated static func mode(followsWallpapers: Bool, wantsScreenSaverStills: Bool) -> Mode? {
        if followsWallpapers { return .desktop }
        return wantsScreenSaverStills ? .screenSaverStills : nil
    }

    /// Whether the desktop pictures follow the wallpapers.
    var isActive: Bool {
        guard mayChange, let settings = settings?.settings else { return false }
        return Self.followsWallpapers(settings)
    }

    /// Whether `settings` want the desktop pictures to follow the wallpapers. Theming's menu bar
    /// strip alone is enough.
    nonisolated static func followsWallpapers(_ settings: GlobalSettings) -> Bool {
        settings.lockScreenPicture || settings.adjustMenuBarTint || settings.theming.wantsMenuBarStrip
    }

    private var displays: [DesktopPicturePlan.Display] {
        NSScreen.screens.compactMap { screen in
            DesktopSnapshotCache.displayID(screen).map {
                DesktopPicturePlan.Display(id: $0, frame: screen.frame, scale: screen.backingScaleFactor)
            }
        }
    }

    func observe(_ viewModel: WallpaperViewModel, settings: GlobalSettingsViewModel) {
        self.viewModel = viewModel
        self.settings = settings
        guard mayChange else { return }
        saveUsersPicture()
        let center = NotificationCenter.default
        center.publisher(for: .webWallpaperPageSnapshot)
            .sink { [weak self] note in
                MainActor.assumeIsolated {
                    guard let page = note.object as? WebWallpaperPageSnapshot else { return }
                    self?.sync.webFrameCaptured(page.image, wallpaperDirectory: page.wallpaperDirectory)
                }
            }
            .store(in: &cancellables)
        let changes: [AnyPublisher<Void, Never>] = [
            viewModel.$wallpapers.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$layoutResolution.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$wallpaperPlacement.map { _ in () }.eraseToAnyPublisher(),
            viewModel.displayOptions.$entries.map { _ in () }.eraseToAnyPublisher(),
            settings.$settings.map(Self.followsWallpapers).removeDuplicates()
                .map { _ in () }.eraseToAnyPublisher(),
            settings.$settings.map(\.screenSaver).removeDuplicates()
                .map { _ in () }.eraseToAnyPublisher(),
            center.publisher(for: .sceneLoadingSnapshotSaved).map { _ in () }.eraseToAnyPublisher(),
            center.publisher(for: .webWallpaperPageSnapshot).map { _ in () }.eraseToAnyPublisher(),
        ]
        // `@Published` emits before it stores: the debounce reads the stored values.
        Publishers.MergeMany(changes)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
            .store(in: &cancellables)
        let workspace = NSWorkspace.shared.notificationCenter
        let reasserts: [AnyPublisher<Void, Never>] = [
            workspace.publisher(for: NSWorkspace.activeSpaceDidChangeNotification).map { _ in () }.eraseToAnyPublisher(),
            workspace.publisher(for: NSWorkspace.didWakeNotification).map { _ in () }.eraseToAnyPublisher(),
            workspace.publisher(for: NSWorkspace.screensDidWakeNotification).map { _ in () }.eraseToAnyPublisher(),
            center.publisher(for: NSApplication.didChangeScreenParametersNotification).map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(reasserts)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.reassert() } }
            .store(in: &cancellables)
    }

    /// Updates every display's picture, or puts the user's back when the pictures were just
    /// turned off.
    func refresh() {
        let active = isActive
        if !active, wasActive { restoreUsersPictures() }
        guard let mode = Self.mode(followsWallpapers: active, wantsScreenSaverStills: mayChange && wantsScreenSaverStills()),
              let target = mode == .desktop ? sync : saverSync else { return }
        if mode == .desktop { wasActive = true }
        guard let viewModel else { return }
        let plans = DesktopPicturePlan.plans(
            displays: displays, resolution: viewModel.layoutResolution,
            wallpaper: { id in
                let wallpaper = viewModel.wallpaper(for: id)
                return wallpaper.project == .invalid ? nil : wallpaper
            },
            options: { viewModel.displayOptions(on: $0) })
        let placement = viewModel.wallpaperPlacement
        let strips = mode == .desktop ? DesktopPictureTheming.strips() : nil
        Task { await target.update(plans, placement: placement, strips: strips) }
    }

    /// The current Space, a wake or a display change may show another picture: shows each
    /// display's own again, and draws the displays that have none yet.
    func reassert() {
        guard isActive else { return }
        if !sync.reassert(displays.map(\.id)).isEmpty { refresh() }
    }

    /// Puts the user's pictures back on the connected displays (Settings turned the pictures off,
    /// or the app quits).
    func restoreUsersPictures() {
        wasActive = false
        guard mayChange else { return }
        sync.restoreUsersPictures(displays.map(\.id), fallback: UserDefaults.app.url(forKey: Self.fallbackKey))
    }

    /// Saves the main display's picture as the user's (`OSWallpaper`), the fallback for a
    /// display with no recorded picture, unless it is one of OWE's (an earlier run that ended
    /// without restoring it) or gone.
    private func saveUsersPicture() {
        let showing = NSScreen.screens.first.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        let saved = UserDefaults.app.url(forKey: Self.fallbackKey)
        if let picture = sync.files.userPicture(saved: saved, showing: showing) {
            UserDefaults.app.set(picture, forKey: Self.fallbackKey)
        } else if saved != nil {
            UserDefaults.app.removeObject(forKey: Self.fallbackKey)
        }
    }
}
