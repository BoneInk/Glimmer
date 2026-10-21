import Foundation

/// The Discover and Workshop menus' "Set as Wallpaper" and "Set as Screen Saver": the item is
/// downloaded as Download does (into the Wallpaper Storage folder, with its dependencies), unless
/// it is installed already, then applied as the library applies it, or set as the screen saver
/// with its default settings (`ScreenSaverSelectionService.setAsScreenSaver`: a scene or a web
/// page drawn live, a video's own file; a web page without the Chromium engine offers its
/// install instead). The download shows its progress and errors as any download does;
/// setting the screen saver and its errors show in the same place (`downloadState(for:)`).
@MainActor
final class WorkshopSetAsFlow: ObservableObject {
    enum Action: Equatable {
        case wallpaper, screenSaver
    }

    /// Where an item's run is, from its download on.
    enum Phase: Equatable {
        case downloading(Action)
        case settingScreenSaver
        case failed(String)
    }

    /// What a run needs from the app; tests stub it.
    struct Environment {
        /// In the library as the user's own item (`WorkshopViewModel.isDownloaded`). Cheap: the menu asks it.
        var isInstalled: @MainActor (_ workshopId: String) -> Bool
        /// The installed wallpaper of the item, if any.
        var installedWallpaper: @MainActor (_ workshopId: String) -> WEWallpaper?
        /// Whether a download can start (steamcmd is there and logged in).
        var canDownload: @MainActor () -> Bool
        /// Downloads the item as Download does; the completion gets its folder, or nil when it failed.
        var download: @MainActor (WorkshopItem, _ completion: @escaping @MainActor (URL?) -> Void) -> Void
        /// The wallpaper in a downloaded folder, as the library reads it.
        var wallpaper: @MainActor (_ folder: URL) -> WEWallpaper?
        var setWallpaper: @MainActor (WEWallpaper) -> Void
        /// Whether the downloaded wallpaper can be set as the screen saver now (`ScreenSaverSelectionService.availability`).
        var screenSaverAvailability: @MainActor (WEWallpaper) -> ScreenSaverSelectionService.Availability
        /// Offers to install the Chromium engine, which the wallpaper needs in the screen saver.
        var offerChromium: @MainActor (WEWallpaper) -> Void
        var setScreenSaver: @MainActor (WEWallpaper, _ completion: @escaping @MainActor (Bool) -> Void) -> Void
    }

    @Published private(set) var phases: [String: Phase] = [:]
    private let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    /// Whether the menu item can run for `item`: its type can be set, it isn't running already,
    /// and it is installed or can be downloaded.
    func canRun(_ action: Action, for item: WorkshopItem) -> Bool {
        switch action {
        case .wallpaper:
            guard WallpaperSetAsRules.canSetWallpaper(item) else { return false }
        case .screenSaver:
            guard WallpaperSetAsRules.canSetScreenSaver(item) else { return false }
        }
        switch phases[item.id] {
        case .downloading?, .settingScreenSaver?: return false
        case .failed?, nil: break
        }
        return environment.isInstalled(item.id) || environment.canDownload()
    }

    func run(_ action: Action, for item: WorkshopItem) {
        guard canRun(action, for: item) else { return }
        if environment.isInstalled(item.id), let installed = environment.installedWallpaper(item.id) {
            apply(action, installed, id: item.id)
            return
        }
        phases[item.id] = .downloading(action)
        let id = item.id
        environment.download(item) { [weak self] folder in
            guard let self else { return }
            // A failed download shows its own error (`SteamCmdService.downloadProgress`).
            guard let folder else {
                self.phases[id] = nil
                return
            }
            guard let wallpaper = self.environment.wallpaper(folder) else {
                OWELog.error(.workshop, "Workshop item \(id) downloaded, but its folder holds no wallpaper to set")
                self.phases[id] = .failed(Self.cantSetMessage(action))
                return
            }
            self.apply(action, wallpaper, id: id)
        }
    }

    private func apply(_ action: Action, _ wallpaper: WEWallpaper, id: String) {
        switch action {
        case .wallpaper:
            guard WallpaperSetAsRules.canSetWallpaper(wallpaper) else {
                phases[id] = .failed(Self.cantSetMessage(action))
                return
            }
            phases[id] = nil
            environment.setWallpaper(wallpaper)
        case .screenSaver:
            switch environment.screenSaverAvailability(wallpaper) {
            case .available:
                break
            case .needsChromium:
                phases[id] = nil
                environment.offerChromium(wallpaper)
                return
            case .unavailable(let reason):
                phases[id] = .failed(reason)
                return
            }
            phases[id] = .settingScreenSaver
            environment.setScreenSaver(wallpaper) { [weak self] succeeded in
                self?.phases[id] = succeeded ? nil
                    : .failed(String(localized: "The wallpaper couldn't be set as the screen saver. The logs say why."))
            }
        }
    }

    /// What the item's card shows over its download's state: setting the screen saver, or why the run failed.
    func downloadState(for workshopId: String) -> SteamCmdService.DownloadState? {
        switch phases[workshopId] {
        case .settingScreenSaver?:
            return .downloading(status: String(localized: "Setting the screen saver…",
                                               comment: "Workshop card: the downloaded wallpaper is being set as the screen saver"))
        case .failed(let message)?:
            return .failed(message)
        case .downloading?, nil:
            return nil
        }
    }

    private static func cantSetMessage(_ action: Action) -> String {
        switch action {
        case .wallpaper:
            return String(localized: "This item can't be set as the wallpaper.",
                          comment: "Workshop card: the downloaded item is an application wallpaper or not a wallpaper")
        case .screenSaver:
            return String(localized: "Screen savers are made from scene, web and video wallpapers",
                          comment: "Details panel: why an application wallpaper has no screen saver")
        }
    }
}
