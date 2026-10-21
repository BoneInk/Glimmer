import AppKit

/// What is set as the screen saver, from Scene Edit / Export's Screen Saver mode, the library's
/// and Workshop's Set as Screen Saver, and MCP: a wallpaper picked to be drawn live
/// (`ScreenSaverSettingsStore.livePick`), a scene, web page or WebM video with the mode's values, a
/// video wallpaper as it is, which the plugin then draws instead of following the desktop.
/// Nothing is recorded, linked or copied.
@MainActor
final class ScreenSaverSelectionService: ObservableObject {
    /// What setting the screen saver needs from the app: whether the screen saver plugin is on,
    /// and the desktop's wallpaper.
    struct Environment {
        var isPluginEnabled: @MainActor () -> Bool
        /// Turns Settings › Plugins › Screen Saver on (it installs the saver).
        var enablePlugin: @MainActor () -> Void
        var desktopWallpaper: @MainActor () -> WEWallpaper?
        /// The main display's wallpaper (the one with the menu bar), which turning Screen Saver
        /// Same as Wallpaper off picks (`setFollowsDesktop`); nil when it shows none.
        var mainDisplayWallpaper: @MainActor () -> WEWallpaper? = { nil }
    }

    /// A web wallpaper or WebM video Set as Screen Saver was chosen for without the Chromium
    /// engine: the main window offers to install it (`setAsScreenSaver`).
    @Published var chromiumOffer: WEWallpaper?
    let store: ScreenSaverSettingsStore
    private let plugin: ScreenSaverPlugin
    private let environment: Environment

    init(plugin: ScreenSaverPlugin, environment: Environment, store: ScreenSaverSettingsStore = ScreenSaverSettingsStore()) {
        self.plugin = plugin
        self.environment = environment
        self.store = store
    }

    /// The wallpaper picked as the screen saver, drawn live, if any.
    var livePick: ScreenSaverSettingsStore.LivePick? { store.livePick }

    /// Settings › General › Screen Saver Same as Wallpaper: on while nothing is set as the screen
    /// saver, so each display's screen saver shows that display's wallpaper. It is read from the
    /// selection, never stored apart, so it can't disagree with what the screen saver shows.
    var followsDesktop: Bool { store.livePick == nil }

    /// What turning Screen Saver Same as Wallpaper off would set: the main display's wallpaper,
    /// when the screen saver can show it (`availability`); nil otherwise, and the setting stays on.
    func wallpaperForStoppingFollowingDesktop() -> WEWallpaper? {
        guard let wallpaper = environment.mainDisplayWallpaper(), wallpaper.project != .invalid,
              Self.canSet(wallpaper) else { return nil }
        return wallpaper
    }

    /// Turns Screen Saver Same as Wallpaper on (whatever was set as the screen saver goes:
    /// `stopUsingSelection`) or off. Off sets the main display's wallpaper as the screen saver,
    /// with the Screen Saver tab's choices for it if it has any, since "off" with nothing set
    /// would still follow the desktop. A web wallpaper without the Chromium engine offers it
    /// (`chromiumOffer`) and stays on.
    /// `completion` gets whether the setting now reads `follows`.
    func setFollowsDesktop(_ follows: Bool, completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard follows != followsDesktop else {
            completion(true)
            return
        }
        if follows {
            stopUsingSelection()
            completion(true)
            return
        }
        guard let wallpaper = wallpaperForStoppingFollowingDesktop() else {
            OWELog.info(.app, "Screen saver: the main display's wallpaper can't be the screen saver now; it keeps following the desktop")
            completion(false)
            return
        }
        if case .needsChromium = Self.availability(of: wallpaper) {
            chromiumOffer = wallpaper
            completion(false)
            return
        }
        // With the Screen Saver tab's choices for it, if it has any.
        let values = store.values(for: WallpaperSettingsIdentity.resolve(wallpaper, defaults: store.defaults)) ?? [:]
        set(wallpaper, values: values) { [weak self] set in completion(set && self?.followsDesktop == false) }
    }

    /// Where the picked wallpaper's still goes; nil in a copy that never installs the saver.
    var stills: ScreenSaverStillPublisher?
    /// A new wallpaper was picked: its still is made now (`ScreenSaverLiveController.renderPickStill`).
    var onPicked: ((WEWallpaper) -> Void)?

    /// Whether `wallpaper` is the screen saver.
    func isSelected(_ wallpaper: WEWallpaper) -> Bool {
        livePick?.wallpaperDirectory == wallpaper.wallpaperDirectory.standardizedFileURL.path(percentEncoded: false)
    }

    /// Makes `wallpaper` the screen saver, drawn live with `values` (its user properties and
    /// layer edits), which become the screen saver's own choices for it (a video plays as it is,
    /// so it keeps none); turns the plugin on when it is off. Nothing is recorded. Its preview (a
    /// video's first frame) is the still until the live draw keeps a frame.
    func pick(_ wallpaper: WEWallpaper, values: [String: String]) {
        let folder = wallpaper.wallpaperDirectory.standardizedFileURL.path(percentEncoded: false)
        if !ScreenSaverVideoSource.isEligible(wallpaper) {
            store.setValues(values, for: WallpaperSettingsIdentity.resolve(wallpaper, defaults: store.defaults))
        }
        let isNew = store.livePick?.wallpaperDirectory != folder
        store.livePick = ScreenSaverSettingsStore.LivePick(wallpaperDirectory: folder, picked: Date())
        if isNew { onPicked?(wallpaper) }
        OWELog.info(.app, "Screen saver: \(wallpaper.wallpaperDirectory.lastPathComponent) is the screen saver, drawn live")
        if !environment.isPluginEnabled() { environment.enablePlugin() }
        plugin.update(enabled: environment.isPluginEnabled(), wallpaper: environment.desktopWallpaper())
        objectWillChange.send()
    }

    /// Sets `wallpaper` as the screen saver with `values` (the Screen Saver mode's, else the
    /// wallpaper's), drawn live (`pick`). `completion` gets whether it was set.
    func set(_ wallpaper: WEWallpaper, values: [String: String], completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        pick(wallpaper, values: values)
        completion(true)
    }

    /// Goes back to the desktop's wallpapers.
    func stopUsingSelection() {
        guard store.livePick != nil else { return }
        store.livePick = nil
        stills?.clearPick()
        OWELog.info(.app, "Screen saver: back to the desktop's wallpaper")
        plugin.update(enabled: environment.isPluginEnabled(), wallpaper: environment.desktopWallpaper())
        objectWillChange.send()
    }
}
