//
//  WallpaperViewModel.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/14.
//

import SwiftUI
import AVKit
import Combine

extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Provide Wallpaper Database for WallpaperView and ContentView etc.
@MainActor
class WallpaperViewModel: ObservableObject {
    let persistsWallpapers: Bool

    /// A web or application wallpaper waiting for the user's answer to the trust prompt
    /// (`apply(_:)`); nil once it is answered or dismissed.
    @Published internal(set) var trustRequest: WallpaperTrustRequest?
    /// The trusted wallpapers (`WallpaperTrustStore`).
    var trustStore = WallpaperTrustStore()
    /// Shows the trust prompt for `trustRequest`. Tests replace it.
    var askToTrust: (WEWallpaper) -> Void = { AppDelegate.shared.contentViewModel.warningUnsafeWallpaperModal(which: $0) }
    /// Reads a trusted wallpaper's folder before it is applied, to see whether it changed.
    internal(set) var trustCheck: Task<Void, Never>?
    /// The fingerprint of `trustRequest`'s folder, recorded when the user trusts it.
    var trustRequestFingerprint: Task<String, Never>?

    /// Per-screen wallpaper selections, keyed by CGDirectDisplayID as String: each display's own,
    /// kept while it clones another (WE keeps `selectedwallpapers` per monitor under a clone).
    /// What a display shows is `wallpaper(for:)`.
    @Published var wallpapers: [String: WEWallpaper] = [:] {
        didSet {
            if persistsWallpapers {
                saveWallpapers()
            }
            refreshInstanceKeys()
        }
    }

    /// How wallpapers spread over the displays: a wallpaper per display (with clone and stretch
    /// groups of some of them, and splits), or one stretched over or cloned onto every display
    /// (docs/architecture.md "Display layouts").
    @Published var displayLayout = DisplayLayoutConfiguration() {
        didSet {
            guard displayLayout != oldValue else { return }
            if persistsWallpapers { displayLayout.save(to: .app) }
            refreshDisplayLayout()
        }
    }

    /// The display layout on the displays connected now (`refreshDisplayLayout`).
    @Published internal(set) var layoutResolution = DisplayLayoutResolution.empty

    /// The screen saver's layout: the wallpapers' ("Same as wallpaper", the default) or its own.
    @Published var screenSaverLayout = ScreenSaverDisplayLayout() {
        didSet {
            guard screenSaverLayout != oldValue, persistsWallpapers else { return }
            screenSaverLayout.save(to: .app)
        }
    }

    /// The user's display profiles (WE's "Save Profile" / "Load Profile"), applied to these displays.
    lazy var displayProfiles = DisplayProfiles(model: self, fileURL: DisplayProfiles.defaultURL)

    /// The connected displays with their identities, main display first; tests pass their own.
    var connectedDisplays: @MainActor () -> [DisplayIdentity] = { DisplayIdentity.connected() }

    /// Screens where wallpaper display is enabled.
    @Published var enabledScreens: Set<String> = [] {
        didSet {
            UserDefaults.app.set(Array(enabledScreens), forKey: "EnabledScreens")
        }
    }

    /// The displays connected before: only one never seen gets wallpapers turned on when it
    /// connects (`enableNewDisplays`).
    internal(set) var knownDisplays = KnownDisplays()

    /// Told after a display's wallpapers are turned on or off (`toggleScreen`): the app delegate
    /// adds or removes that display's window.
    var onScreenEnabledChange: ((String) -> Void)?

    /// The screen currently selected in the UI for configuration.
    @Published var selectedScreenId: String = ""

    /// Screens selected for the next wallpaper assignment.
    @Published var selectedScreenIds: Set<String> = []

    /// Wallpaper currently inspected in the sidebar or preview window.
    @Published var inspectedWallpaper: WEWallpaper?
    @Published var inspectedWorkshopItem: WorkshopItem?
    @Published var inspectedAuthor: SteamPlayer?
    /// Guards against firing a second Steam request for a lookup already in progress.
    var inFlightWorkshopId: String?
    /// The wallpaper `inspectedWorkshopItem` and `inspectedAuthor` belong to.
    var workshopDetailsDirectory: URL?

    @Published var wallpaperPlacement: WallpaperPlacement = .fill {
        didSet {
            // A preview's placement (the Wallpaper Editor's canvas) isn't the user's setting.
            guard persistsWallpapers else { return }
            UserDefaults.app.set(wallpaperPlacement.rawValue, forKey: "WallpaperPlacement")
        }
    }

    static let defaultWallpaper = WEWallpaper(using: .invalid, where: AppBundleLayout.wallpaperNotFoundURL)

    // MARK: - Screen ID helpers

    static func screenId(for screen: NSScreen) -> String {
        let displayId = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        return String(displayId)
    }

    /// The primary display's (the one with the menu bar in System Settings' arrangement), not
    /// `NSScreen.main`, which is the display with the key window.
    static func mainScreenId() -> String {
        guard let primary = NSScreen.screens.first else { return "0" }
        return screenId(for: primary)
    }

    static func screenName(for screen: NSScreen) -> String {
        screen.localizedName
    }

    // MARK: - Recent wallpapers

    @Published var recentWallpapers: [WEWallpaper] = []

    /// Each display's wallpapers, for Previous Wallpaper outside a playlist.
    @Published var wallpaperHistory = WallpaperHistory() {
        didSet { if persistsWallpapers { wallpaperHistory.save(to: .app) } }
    }

    @Published var playlists: [WallpaperPlaylist] = [] {
        didSet { savePlaylists() }
    }

    @Published var activePlaylistID: UUID? {
        didSet {
            // Each playlist continues where it left off when it becomes active again.
            if oldValue != activePlaylistID {
                if let oldValue { playlistPositions[oldValue] = playlistIndex }
                playlistIndex = activePlaylistID.flatMap { playlistPositions[$0] } ?? 0
            }
            savePlaylistSettings(); restartPlaylistTimer()
            if oldValue != activePlaylistID { applyPlaylistSchedule(force: true) }
        }
    }

    /// Where each playlist that isn't active stopped, for when it is chosen again.
    private var playlistPositions: [UUID: Int] = [:]

    /// The connected displays' ids; a playlist's shortcut starts it on those it last used.
    var connectedScreenIds: @MainActor () -> Set<String> = { Set(NSScreen.screens.map(WallpaperViewModel.screenId(for:))) }

    @Published var playlistShuffle = false {
        didSet { savePlaylistSettings() }
    }

    @Published var playlistRepeats = true {
        didSet { savePlaylistSettings() }
    }

    @Published var playlistEnabled = false {
        didSet {
            savePlaylistSettings(); restartPlaylistTimer()
            if playlistEnabled && !oldValue { applyPlaylistSchedule(force: true) }
        }
    }

    /// The timer's next change, or a scheduled playlist's next slot (`restartPlaylistTimer`).
    var playlistTimer: Timer?

    /// A timer playlist's time left, which stands still while the wallpaper is paused.
    var playlistCountdown: PlaylistCountdown?

    /// Looks at a scheduled playlist again after sleep and clock changes.
    var playlistClockObserver: PlaylistClockObserver?

    /// The item a scheduled playlist last showed for its slot: Next and Previous stay until the
    /// slot changes.
    var playlistScheduledIndex: Int?

    /// The clock and calendar a scheduled playlist reads (tests set their own).
    var playlistClock: () -> Date = { Date() }

    var playlistCalendar: () -> Calendar = { Calendar.autoupdatingCurrent }

    /// Plays transitions between wallpapers on the displays; nil (previews, tests): none.
    var transitions: WallpaperTransitionPerforming?

    /// WE's "Stop wallpapers" (`ui_settings_hotkeys_action_stop`), set by the user: every
    /// display's wallpaper is unloaded and the desktop shows the macOS desktop picture, until Resume
    /// or Play. Each display keeps its wallpaper here, so resuming shows exactly what was shown.
    /// For this session only. The playlist holds still meanwhile; the playback and application
    /// rules keep evaluating and apply again on resume.
    @Published internal(set) var isStopped = false {
        didSet {
            guard oldValue != isStopped else { return }
            restartPlaylistTimer()
            onStoppedChange?(isStopped)
        }
    }

    /// Told after `isStopped` changes: the app delegate closes or rebuilds the wallpaper windows.
    var onStoppedChange: ((Bool) -> Void)?

    /// Holds the playlist still after safe restart stopped a wallpaper; the setting is untouched.
    var isPlaylistSuspended = false {
        didSet { restartPlaylistTimer() }
    }

    /// Asked before a wallpaper is applied; returning false cancels it. Set by `SafeRestart`.
    var confirmApply: ((WEWallpaper) -> Bool)?

    /// Set by `SafeRestart`: whether a wallpaper is flagged, so auto-advance can pass it over.
    var isFlaggedBySafeRestart: ((WEWallpaper) -> Bool)?

    /// Moves a Workshop preview being applied into the storage folder and returns it there; nil
    /// when the wallpaper isn't a preview. Set by the app delegate.
    var keepWorkshopPreview: ((WEWallpaper) throws -> WEWallpaper?)?

    /// Receives wallpaper frame times. Set by `SafeRestart`.
    var renderWatchdog: RenderWatchdog?

    /// The settings and script services this model's scenes run with; nil: Open Wallpaper
    /// Engine's. Set by the Wallpaper Editor's process for its canvas.
    var sceneHost: SceneWallpaperHost?

    /// Lets the displays that show the same web wallpaper share one WebContent process.
    let webProcessGroup = WebProcessGroup()

    /// The web pages a clone's or stretch's other displays mirror (`WebPageMirrorView`).
    let webPageMirrors = WebPageMirrorRegistry()

    /// The scenes (and Metal videos) running on this model's displays, one per wallpaper however
    /// many displays show it (docs/architecture.md "Wallpaper instances").
    let sceneInstances = WallpaperInstanceRegistry<WallpaperInstanceKey, SceneWallpaperInstance>(teardown: { $0.shutdown() })

    /// The scenes' loading snapshots refreshed this launch (`SceneLoadingSnapshotCapture`).
    let loadingSnapshots = SceneLoadingSnapshotSession(store: .current)

    /// The AVKit videos running on this model's displays, one player per video.
    let videoInstances = WallpaperInstanceRegistry<WallpaperInstanceKey, VideoWallpaperViewModel>(teardown: { $0.stop() })

    /// The active playlist's current item.
    var playlistIndex = 0

    // MARK: - Wallpaper access

    /// The app's "Audio Output" setting; off silences every wallpaper. Set by the app delegate.
    @Published var audioOutputEnabled = true

    /// WE's "Video loading" (`GlobalSettings.videoReadMode`): video wallpapers play from their
    /// file or from memory (`VideoFileSource`).
    @Published var videoReadMode = GSVideoReadMode.fromDisk

    // MARK: - Playback rules per display

    /// Each display's playback under Settings › Performance › Playback (`PlaybackRules`), set by the
    /// app delegate's `DisplayPlaybackMonitor`.
    var rulePlayback: [String: DisplayPlayback] = [:] {
        didSet { refreshDisplayPlayback(); updatePlaylistPause() }
    }

    /// The displays applications' windows hide (`DesktopWindowLayout.coveredDisplays`), set by the
    /// app delegate's `DisplayPlaybackMonitor`. Their scenes keep their last frame, as a display
    /// whose window the window server reports covered does, until a window moves away. Not
    /// published: the scenes follow `coveredScreensDidChange`, and the library doesn't redraw.
    var coveredScreens: Set<String> = [] {
        didSet {
            guard coveredScreens != oldValue else { return }
            NotificationCenter.default.post(name: .coveredScreensDidChange, object: self)
        }
    }

    /// Each display's playback: the playback rules', and muted where the display is muted
    /// (`DisplayLayoutConfiguration.muted`). Empty in the Workshop preview: every display plays.
    @Published internal(set) var displayPlayback: [String: DisplayPlayback] = [:]

    // MARK: - User properties per display

    /// "Sync properties across displays" (Settings → General); set by the app delegate.
    @Published var syncsPropertiesAcrossDisplays = GlobalSettings().syncPropertiesAcrossDisplays {
        didSet {
            guard oldValue != syncsPropertiesAcrossDisplays else { return }
            if syncsPropertiesAcrossDisplays, persistsWallpapers { shareDisplayedProperties() }
            refreshInstanceKeys()
        }
    }

    /// Each display's running instance: its wallpaper and the user properties it runs with
    /// (`WallpaperPropertyGroups`). Refreshed when a display's wallpaper, the sync setting or saved
    /// properties change; `WallpaperView` keys a display's view by it.
    @Published internal(set) var instanceKeys: [String: WallpaperInstanceKey] = [:]

    var settingsIdentities: [String: WallpaperSettingsIdentity] = [:]

    private var propertiesSavedObserver: NSObjectProtocol?

    /// The store a preview runs and edits instead of the displays' rule (the Wallpaper Editor's
    /// canvas: `WallpaperPropertyScope.editorDraft`); nil for the app's displays and the Workshop
    /// preview.
    var previewPropertyScope: WallpaperPropertyScope?

    // MARK: - Display options

    /// WE's per-wallpaper display options (offset, zoom, flip, playback rate), per display.
    let displayOptions: WallpaperDisplayOptionsStore

    /// Republishes the options' changes as this model's, so views showing wallpapers follow them.
    private var displayOptionsForwarding: AnyCancellable?

    var lastPlayRate: Float = 1.0

    @Published public var playRate: Float = 1.0 {
        didSet {
            self.lastPlayRate = oldValue
            if arePlaybackRatesLinked {
                audioPlayRate = playRate
            }
            if (oldValue == 0) != (playRate == 0) { updatePlaylistPause() }
        }
    }

    @Published var audioPlayRate: Float = 1.0

    @Published var arePlaybackRatesLinked = true {
        didSet {
            if arePlaybackRatesLinked {
                audioPlayRate = playRate
            }
        }
    }

    var lastPlayVolume: Float = 1.0

    @Published public var playVolume: Float = 1.0 {
        didSet {
            self.lastPlayVolume = oldValue
        }
    }

    init(persistsWallpapers: Bool = true) {
        self.persistsWallpapers = persistsWallpapers
        // A preview's options aren't the user's: kept in memory only.
        displayOptions = WallpaperDisplayOptionsStore(defaults: persistsWallpapers ? .app : nil)
        displayOptionsForwarding = displayOptions.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
        if let storedPlacement = UserDefaults.app.string(forKey: "WallpaperPlacement"),
           let placement = WallpaperPlacement(rawValue: storedPlacement) {
            wallpaperPlacement = placement
        }
        propertiesSavedObserver = NotificationCenter.default.addObserver(
            forName: .wallpaperPropertiesDidSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInstanceKeys() }
        }
        guard persistsWallpapers else {
            self.selectedScreenId = "preview"
            self.selectedScreenIds = [selectedScreenId]
            refreshInstanceKeys()
            return
        }

        if let data = UserDefaults.app.data(forKey: "WallpaperPlaylists"),
           let saved = OWELog.attempt(.library, "Saved playlists", { try JSONDecoder().decode([WallpaperPlaylist].self, from: data) }) {
            self.playlists = saved
        }
        // Into the storage, not through the setters: their observers save all four, which would
        // overwrite the saved ones not read yet, and start the playlist before the app does
        // (`startPlaylistAtLaunch`).
        let activePlaylistID = UserDefaults.app.string(forKey: "ActiveWallpaperPlaylist").flatMap(UUID.init(uuidString:))
        _activePlaylistID = Published(initialValue: activePlaylistID ?? self.playlists.first?.id)
        _playlistShuffle = Published(initialValue: UserDefaults.app.bool(forKey: "WallpaperPlaylistShuffle"))
        _playlistRepeats = Published(initialValue: UserDefaults.app.object(forKey: "WallpaperPlaylistRepeats") == nil
            ? true : UserDefaults.app.bool(forKey: "WallpaperPlaylistRepeats"))
        _playlistEnabled = Published(initialValue: UserDefaults.app.bool(forKey: "WallpaperPlaylistEnabled"))

        // Load per-screen wallpapers. They stay as they are: without a saved display layout every
        // display shows its own.
        if let data = UserDefaults.app.data(forKey: "ScreenWallpapers"),
           let saved = OWELog.attempt(.library, "Saved display wallpapers", { try JSONDecoder().decode([String: WEWallpaper].self, from: data) }) {
            self.wallpapers = saved
        }
        // Migrate legacy single wallpaper
        else if let json = UserDefaults.app.data(forKey: "CurrentWallpaper"),
                let wallpaper = OWELog.attempt(.library, "Saved wallpaper", { try JSONDecoder().decode(WEWallpaper.self, from: json) }) {
            let mainId = Self.mainScreenId()
            self.wallpapers = [mainId: wallpaper]
        }

        // Load enabled screens (default: all connected screens enabled)
        if let saved = UserDefaults.app.array(forKey: "EnabledScreens") as? [String] {
            self.enabledScreens = Set(saved)
        } else {
            self.enabledScreens = Set(NSScreen.screens.map { Self.screenId(for: $0) })
        }
        // Before the list was kept, every display enabled or connected now counts as known.
        if let known = KnownDisplays.load(from: .app) {
            knownDisplays = known
        } else {
            knownDisplays = KnownDisplays(enabledScreens.union(NSScreen.screens.map { Self.screenId(for: $0) }))
            knownDisplays.save(to: .app)
        }

        // Default the active screen to main while assigning wallpapers to all desktops.
        self.selectedScreenId = Self.mainScreenId()
        self.selectedScreenIds = Set(NSScreen.screens.map { Self.screenId(for: $0) })

        displayLayout = DisplayLayoutConfiguration.load(from: .app)
        screenSaverLayout = ScreenSaverDisplayLayout.load(from: .app)
        refreshDisplayLayout()

        // Load recent wallpapers
        loadRecents()
        wallpaperHistory = WallpaperHistory.load(from: .app)
        restartPlaylistTimer()
        refreshInstanceKeys()
    }
}

extension Notification.Name {
    /// `WallpaperViewModel.coveredScreens` changed.
    static let coveredScreensDidChange = Notification.Name("OWECoveredScreensDidChange")
}
