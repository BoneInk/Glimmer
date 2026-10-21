//
//  AppDelegate.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/6/6.
//

import Cocoa
import Combine
import SwiftUI
import AVKit
import WebKit
import OWEInspectorKit
import OWETheming

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow!
    
    var mainWindowController: MainWindowController!
    
    var wallpaperWindows: [String: NSWindow] = [:]
    var workshopPreviewWindow: NSWindow?
    var workshopPreviewViewModel: WallpaperViewModel?
    var sceneInspectorWindow: NSWindow?
    /// The Wallpaper Editor, a process of its own (`WallpaperEditorAppDelegate`): opening a
    /// wallpaper in it, and its edits reaching the wallpapers running here.
    private(set) lazy var wallpaperEditorLauncher: WallpaperEditorLauncher = {
        let launcher = WallpaperEditorLauncher(dependencies: .init(messaging: processMessaging, channel: .current))
        launcher.onLaunchFailure = { error in
            let alert = NSAlert()
            alert.messageText = String(localized: "The Wallpaper Editor couldn’t be opened.")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        return launcher
    }()
    private(set) lazy var editorChangeSync: WallpaperEditorChangeSync = {
        let sync = WallpaperEditorChangeSync(role: .app, dependencies: .init(messaging: processMessaging, channel: .current))
        sync.onLibraryChange = { [weak self] in self?.contentViewModel.refresh() }
        sync.onOpenSettings = { [weak self] in self?.openSettings(for: $0) }
        return sync
    }()
    private lazy var processMessaging: AppProcessMessaging = DistributedAppProcessMessaging()

    var contentViewModel = ContentViewModel()
    var wallpaperViewModel = WallpaperViewModel()
    var globalSettingsViewModel = GlobalSettingsViewModel()
    /// The settings window's tab and the setting a link or search result opens.
    let settingsNavigation = SettingsNavigation()
    lazy var safeRestart = SafeRestart()
    /// Each playlist's system-wide shortcut (`App/GlobalShortcuts`).
    lazy var playlistShortcuts = PlaylistShortcutController(viewModel: wallpaperViewModel)
    /// Playlist transitions, and Settings' transition for wallpapers chosen by hand, on the
    /// wallpaper windows.
    private(set) lazy var wallpaperTransitions = WallpaperTransitionCoordinator(
        wallpapers: wallpaperViewModel,
        settings: { [unowned self] in globalSettingsViewModel.settings.browseTransition },
        windows: { [unowned self] in wallpaperWindows })
    /// The hotkey actions' system-wide shortcuts (Settings › General › Hotkeys).
    lazy var globalHotKeys: GlobalHotKeyController = {
        let controller = GlobalHotKeyController(viewModel: wallpaperViewModel)
        controller.playlistShortcuts = playlistShortcuts
        playlistShortcuts.hotKeys = controller
        controller.userHotKeys = userHotKeys
        userHotKeys.actionHotKeys = controller
        controller.perform = { [weak self] in self?.performHotKey($0) }
        return controller
    }()
    /// The wallpapers' and display profiles' system-wide hotkeys (`UserHotKey`).
    lazy var userHotKeys: UserHotKeyController = {
        let profiles = wallpaperViewModel.displayProfiles
        let controller = UserHotKeyController(viewModel: wallpaperViewModel,
                                              profileNames: profiles.$profiles.map { $0.map(\.name) }.eraseToAnyPublisher())
        playlistShortcuts.userHotKeys = controller
        controller.perform = { [weak self] in self?.performUserHotKey($0) }
        return controller
    }()
    /// Play in Window: wallpapers in windows of their own beside the desktop (`App/PlayInWindow`).
    lazy var playInWindow = PlayInWindowController(desktop: wallpaperViewModel)
    /// Wallpaper Engine's command line: `--control` commands from the app's executable
    /// (`App/Launch/CommandLineControlCommand`, docs/command-line.md) run here.
    lazy var commandLineControl = CommandLineControlListener { [unowned self] request in
        CommandLineControlPerformer(app: self, control: AppControlModel(app: self)).perform(request)
    }
    /// The wallpaper windows sit above the desktop icons, hiding them (`toggleDesktopIcons`).
    var hidesDesktopIcons = false
    lazy var crashWatcher = CrashWatcher()
    private var processPriorityCancellable: AnyCancellable?
    private var crashWatcherCancellable: AnyCancellable?
    /// Hides the Dock icon while no window is open (`DockPresence`).
    let dockPresence = DockPresence()
    /// Launched by the screen saver's broker for a saver showing while the app wasn't running
    /// (`ScreenSaverLiveNames.launchArgument`): no window and no Dock icon until that screen saver
    /// session ends or a window opens.
    internal(set) var launchedForScreenSaver = ProcessInfo.processInfo.arguments.contains(ScreenSaverLiveNames.launchArgument)
    /// Sparkle, off in builds without an update signing key (`Core/Updates`).
    lazy var updater = AppUpdater(configuration: .main)
    /// The system's now-playing session, one for the process (MediaRemote registers per process):
    /// SceneScript's `media*` callbacks and web wallpapers' media listeners hear it.
    lazy var mediaSession = MacMediaSessionSource()
    /// What every scene's SceneScripts share: WE's prelude, `localStorage`, the one media session and
    /// the desktop's left clicks.
    /// Settings › Plugins › Screen Saver: the loop videos and the bundled saver.
    lazy var screenSaver = ScreenSaverPlugin()
    /// The Chromium engine's installer that Settings › Plugins and the screen saver's install
    /// offer share, so an install started from either shows its progress in both.
    lazy var chromiumEngine = ChromiumEngineInstaller()
    /// Settings › Optimizations › Developer Tools: web wallpaper devtools for this session only.
    lazy var webDevtools = WebDevtools(chromium: ChromiumBrowserHost.shared)
    /// The live screen saver's broker, a launch agent registered while the Screen Saver plugin is on.
    lazy var screenSaverBroker = ScreenSaverBrokerAgent()
    private var screenSaverBrokerCancellable: AnyCancellable?
    /// The screen saver drawn live while it runs, the savers showing the frames.
    lazy var liveScreenSaver = ScreenSaverLiveController(plugin: screenSaver, environment: .init(
        settings: { [unowned self] in globalSettingsViewModel.effectiveSettings },
        placement: { [unowned self] in wallpaperViewModel.wallpaperPlacement },
        scriptServices: { [unowned self] in sceneScriptServices },
        pageSharing: { [unowned self] screenId, wallpaper in
            wallpaperViewModel.webPageMirrors.sharing(for: screenId, showing: wallpaper)
        },
        sceneSharing: { [unowned self] screenId, wallpaper, scope in
            let key = wallpaperViewModel.instanceKey(for: screenId)
            guard key == WallpaperInstanceKey(wallpaper, properties: scope),
                  let instance = wallpaperViewModel.sceneInstances.instance(for: key), instance.hasContent else { return nil }
            return instance.renderLoop
        },
        videoSharing: { [unowned self] screenId, wallpaper in
            // The video the display shows, whatever the screen saver's own values: a video has none.
            let key = wallpaperViewModel.instanceKey(for: screenId)
            guard key.wallpaper == WallpaperInstanceKey(wallpaper) else { return nil }
            if let instance = wallpaperViewModel.sceneInstances.instance(for: key), instance.hasContent {
                return .scene(instance.renderLoop)
            }
            if let video = wallpaperViewModel.videoInstances.instance(for: key.wallpaper), video.player.currentItem != nil {
                return .player(video)
            }
            return nil
        },
        videoSpeed: { [unowned self] wallpaper in
            let speed = wallpaperViewModel.playRate > 0 ? wallpaperViewModel.playRate : wallpaperViewModel.lastPlayRate
            return (speed > 0 ? speed : 1) * wallpaperViewModel.displayPlaybackRate(of: wallpaper)
        }))
    /// Settings › General › Theming: macOS follows the wallpaper's scheme colour.
    private(set) lazy var theming = ThemingController.make { [unowned self] in
        applyMenuBarStrips()
        desktopPictures.refresh()
    }
    /// Theming's tint of the app's own windows, here and in the Wallpaper Editor's process.
    lazy var themeTint = ThemeTintSync(messaging: DistributedAppProcessMessaging())
    var themeTintCancellable: AnyCancellable?
    /// Each display's desktop picture, which the lock screen and the menu bar's tint show.
    lazy var desktopPictures = DesktopPictureController.system()
    /// Settings › Plugins › MCP Server: MCP clients' control of the app while installed (`MCP/`).
    private(set) lazy var mcpServerPlugin: MCPServerPlugin = {
        let model = AppControlModel(app: self)
        let router = ControlRequestRouter(model: model, groups: [
            SceneControlRequests.make(app: self, model: model),
            LibraryControlRequests.make(app: self, model: model),
            SystemControlRequests.make(app: self, model: model),
        ])
        return MCPServerPlugin(handler: { request in await router.handle(request) })
    }()
    /// What is set as the screen saver (Scene Edit / Export's Screen Saver mode, Set as Screen Saver).
    lazy var screenSaverSelection = ScreenSaverSelectionService(plugin: screenSaver, environment: .init(
        isPluginEnabled: { [unowned self] in globalSettingsViewModel.settings.screenSaver },
        enablePlugin: { [unowned self] in globalSettingsViewModel.settings.screenSaver = true },
        desktopWallpaper: { [unowned self] in wallpaperViewModel.currentWallpaper },
        mainDisplayWallpaper: { [unowned self] in
            guard let main = NSScreen.screens.first else { return nil }
            let wallpaper = wallpaperViewModel.wallpaper(for: WallpaperViewModel.screenId(for: main))
            return wallpaper.project == .invalid ? nil : wallpaper
        }))
    /// Renders the Wallpaper Editor's browser previews in the background once WE's assets are there.
    private(set) lazy var editorPreviewPrewarm = EditorPreviewPrewarm(environment: .live)
    /// Expires cache entries unused for 60 days, at launch and daily.
    let cacheMaintenance = CacheMaintenance()
    lazy var sceneScriptServices: SceneScriptServices = {
        if !SceneScriptJIT.isEnabled {
            OWELog.info(.script, "JavaScriptCore runs without its JIT (no \(SceneScriptJIT.entitlement)): scripts run several times slower")
        }
        let clicks = DesktopClickMonitor()
        clicks.start()
        return SceneScriptServices(
            prelude: SceneScriptPrelude.load(),
            storage: SceneScriptStorage(directory: SceneScriptStorage.defaultDirectory),
            media: mediaSession,
            spectrum: { WallpaperServices.shared.audioSpectrumSnapshot },
            clicks: clicks,
            userShortcuts: UserShortcutLauncher(opener: WorkspaceUserShortcutOpener(),
                                                systemHash: UserShortcutSystemHash.current()))
    }()
    /// The Wallpaper Engine assets scenes need, from the user's own Steam copy (Settings › Assets).
    lazy var assets = WallpaperEngineAssetsService(steamCmd: contentViewModel.steamCmd)
    /// Installs Valve's SteamCMD when none is found; the new copy is picked up by detection.
    lazy var steamCmdInstaller = SteamCmdInstaller(onInstalled: { [weak contentViewModel] in
        contentViewModel?.steamCmd.detectSteamCmd()
    })
    private var assetsCancellable: AnyCancellable?
    /// Lists wallpapers added to or removed from the library folders as they change.
    lazy var libraryFolderWatcher: LibraryFolderWatcher = {
        let watcher = LibraryFolderWatcher()
        watcher.onChange = { [weak self] in self?.contentViewModel.refresh() }
        return watcher
    }()
    /// Fetches the Workshop items shown wallpapers borrow assets from.
    lazy var workshopDependencies = WorkshopDependencyService(steamCmd: contentViewModel.steamCmd)
    private var workshopDependencyCancellable: AnyCancellable?
    /// The collection, subscription and Steam library imports, shared by the setup assistant and
    /// the Installed and Workshop tabs.
    lazy var onboardingImports = OnboardingImports(contentViewModel: contentViewModel,
                                                   wallpaperViewModel: wallpaperViewModel)
    private var audioOutputCancellable: AnyCancellable?
    private var syncPropertiesCancellable: AnyCancellable?
    private var displayFlipCancellable: AnyCancellable?
    private var stretchCanvasCancellable: AnyCancellable?
    private var mediaIntegrationCancellable: AnyCancellable?
    private var mediaBlocklistCancellable: AnyCancellable?
    private var videoReadModeCancellable: AnyCancellable?
    private var recordingThresholdCancellable: AnyCancellable?
    private var recordingVolumeCancellable: AnyCancellable?
    private var recordingDeviceCancellable: AnyCancellable?
    /// Follows the default output device: capture always restarts, wallpapers reload when the
    /// setting is on. `rebuildWallpaperWindows` is the same reload an asset change uses.
    private lazy var outputDeviceMonitor = OutputDeviceChangeMonitor(
        source: CoreAudioOutputDeviceSource(),
        schedule: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) },
        reloadEnabled: { [weak self] in self?.globalSettingsViewModel.settings.reloadWhenChangingOutputDevice ?? false },
        restartCapture: { MainActor.assumeIsolated { WallpaperServices.shared.audioCapture.outputDeviceDidChange() } },
        reloadWallpapers: { [weak self] in MainActor.assumeIsolated { self?.rebuildWallpaperWindows() } })
    /// Settings › Performance › Playback, per display (`App/Playback`).
    private(set) lazy var displayPlaybackMonitor = makeDisplayPlaybackMonitor()
    /// Saved display profiles, which application rules' "Load profile" loads.
    var displayProfiles: any DisplayProfileLoading { wallpaperViewModel.displayProfiles }
    /// Application rules' load actions, and the restore when no rule matches any more.
    private(set) lazy var applicationRuleLoader = makeApplicationRuleLoader()
    /// Advanced › "Pause when VRAM is exhausted", fed to `displayPlaybackMonitor`.
    private(set) lazy var videoMemoryWatch = makeVideoMemoryWatch()
    var videoMemorySettingCancellable: AnyCancellable?
    
    /// Passes the mouse to web wallpapers while one is shown.
    lazy var webMouseForwarder = WebWallpaperMouseForwarder(windows: { [unowned self] in
        Array(wallpaperWindows.values)
    })
    var webMouseCancellable: AnyCancellable?
    
    private static let instance = AppDelegate()
    /// Open Wallpaper Engine's delegate, made on first use. Never in the Wallpaper Editor's process
    /// (`AppLaunchPlan`), whose code reaches the app through `WallpaperEditorChangeSync` instead.
    static var shared: AppDelegate {
        sharedAccessProbe?()
        return instance
    }
    /// Told of every use of `shared` (tests: the editor's services never reach the app's delegate).
    static var sharedAccessProbe: (() -> Void)?

    override init() {
        super.init()
        OWELog.info(.app, "AppDelegate created (pid \(ProcessInfo.processInfo.processIdentifier))")
        if AppLaunchMode.parse(CommandLine.arguments).isWallpaperEditor {
            let caller = Thread.callStackSymbols.prefix(12).joined(separator: "\n")
            OWELog.error(.app, "AppDelegate created in the Wallpaper Editor's process: something there reached AppDelegate.shared from\n\(caller)")
            // Debug builds stop here; a release keeps running with the app's delegate made.
            assertionFailure("AppDelegate.shared reached in the Wallpaper Editor's process")
        }
    }
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Behind the screen saver: no Dock icon from the start.
        if launchedForScreenSaver { NSApp.setActivationPolicy(.accessory) }
        // Animated previews are built in now; the old plugin's on/off is dropped.
        ThumbnailAnimation.removeRetiredPreference(from: .app)

        workshopDependencyCancellable = wallpaperViewModel.$wallpapers.sink { [weak self] wallpapers in
            for wallpaper in wallpapers.values {
                self?.workshopDependencies.ensureDependencies(for: wallpaper)
            }
            // After the change is applied, so the old wallpaper counts as no longer shown.
            DispatchQueue.main.async { self?.staleBundleRefresher?.shownWallpapersChanged() }
        }

        libraryFolderWatcher.watch(LibraryFolders().folders)

        // New or removed assets: scripts, the library (default wallpapers) and every scene reload.
        assetsCancellable = assets.assetsChanged.sink { [weak self] in
            guard let self else { return }
            self.sceneScriptServices.reloadPrelude()
            self.contentViewModel.refresh()
            self.rebuildWallpaperWindows()
            self.editorPreviewPrewarm.start(reason: "assets changed")
        }

        wallpaperViewModel.keepWorkshopPreview = { [steamCmd = contentViewModel.steamCmd] in try steamCmd.keepPreview($0) }

        // Settings › Optimizations › Audio Output silences every wallpaper (`WallpaperAudioRouting`).
        audioOutputCancellable = globalSettingsViewModel.$settings.map(\.audioOutput).removeDuplicates()
            .sink { [weak self] enabled in self?.wallpaperViewModel.audioOutputEnabled = enabled }
        // Settings › Optimizations: one set of user properties for every display, or each display's own.
        syncPropertiesCancellable = globalSettingsViewModel.$settings.map(\.syncPropertiesAcrossDisplays).removeDuplicates()
            .sink { [weak self] synced in self?.wallpaperViewModel.syncsPropertiesAcrossDisplays = synced }
        // Settings › Optimizations › Recording threshold: quieter captured audio reads as silence.
        recordingThresholdCancellable = globalSettingsViewModel.$settings.map(\.audioRecordingThreshold).removeDuplicates()
            .sink { WallpaperServices.shared.audioCapture.recordingThreshold = $0 }
        // Settings › Optimizations › Recording volume and Audio recording device: the spectrum's
        // boost, and the device it is recorded from.
        recordingVolumeCancellable = globalSettingsViewModel.$settings.map(\.audioRecordingVolume).removeDuplicates()
            .sink { WallpaperServices.shared.audioCapture.recordingVolume = $0 }
        recordingDeviceCancellable = globalSettingsViewModel.$settings.map(\.audioRecordingDevice).removeDuplicates()
            .sink { device in MainActor.assumeIsolated { WallpaperServices.shared.audioCapture.recordingDevice = device } }
        // Flipped clone displays mirror their window's content (`WallpaperWindowContentView`).
        displayFlipCancellable = wallpaperViewModel.$layoutResolution.map(\.flipped).removeDuplicates()
            .sink { [weak self] flipped in self?.applyDisplayFlips(flipped) }
        // Stretched displays name their canvas to the scene views in their windows.
        stretchCanvasCancellable = wallpaperViewModel.$layoutResolution.map(\.canvases).removeDuplicates()
            .sink { [weak self] canvases in self?.applyStretchCanvases(canvases) }
        migrateScreenSaverRecording()
        // The screen saver's loops follow the displays' wallpapers and layouts.
        screenSaver.observe(wallpaperViewModel)
        liveScreenSaver.onSessionChanged = { [weak self] running in self?.screenSaverSessionChanged(running) }
        screenSaverSelection.onPicked = { [weak self] wallpaper in self?.liveScreenSaver.renderPickStill(wallpaper) }
        quitsAfterScreenSaver = launchedForScreenSaver
        if launchedForScreenSaver { observeWindowsOpenedAfterScreenSaverLaunch() }
        if launchedForScreenSaver {
            OWELog.info(.app, "Live screen saver: launched for a saver showing")
            liveScreenSaver.launchedForScreenSaver()
        }
        liveScreenSaver.start()
        screenSaverBrokerCancellable = screenSaver.$isEnabled.removeDuplicates().sink { [weak self] enabled in
            MainActor.assumeIsolated { self?.screenSaverBroker.update(enabled: enabled) }
        }
        // Settings › Optimizations › Media integration support: whether wallpapers hear Now Playing.
        mediaIntegrationCancellable = globalSettingsViewModel.$settings.map(\.mediaIntegration).removeDuplicates()
            .sink { [weak self] enabled in self?.mediaSession.setIntegrationEnabled(enabled) }
        // Settings › Optimizations › Media blocklist: apps whose sessions wallpapers don't see.
        mediaBlocklistCancellable = globalSettingsViewModel.$settings.map(\.mediaBlocklist).removeDuplicates()
            .sink { [weak self] blocked in self?.mediaSession.setBlocklist(blocked) }
        // Settings › Optimizations › Video loading: videos opened from now on read their file this way.
        videoReadModeCancellable = globalSettingsViewModel.$settings.map(\.videoReadMode).removeDuplicates()
            .sink { [weak self] mode in self?.wallpaperViewModel.videoReadMode = mode }

        // Settings → Audio → Reload when changing output device (`OutputDeviceChangeMonitor`).
        outputDeviceMonitor.start()

        // Before the wallpaper windows exist, so a wallpaper behind an unclean exit never loads.
        safeRestart.attach(to: wallpaperViewModel)

        // The Wallpaper Editor's process: what it saves reaches the wallpapers running here.
        wallpaperEditorLauncher.start()
        editorChangeSync.start(watch: true) { [weak self] in
            guard let self else { return [] }
            var folders = self.wallpaperViewModel.wallpapers.values.map(\.wallpaperDirectory)
            if let preview = self.workshopPreviewViewModel { folders.append(preview.currentWallpaper.wallpaperDirectory) }
            return folders
        }

        // Settings › Process Priority: at launch, before any render thread starts, and on change.
        processPriorityCancellable = globalSettingsViewModel.$settings.map(\.processPiority).removeDuplicates()
            .sink { ProcessPriority.apply($0) }
        // Settings › Restart after crashing: the watcher that reopens the app after a crash.
        crashWatcherCancellable = globalSettingsViewModel.$settings.map(\.restartAfterCrashing).removeDuplicates()
            .sink { [weak self] enabled in self?.crashWatcher.update(enabled: enabled) }

        // 创建设置视窗
        setSettingsWindow()
        // Launched by the Wallpaper Editor on a Settings page (WE's assets, the depth map model).
        if let request = AppSettingsRequest.requested(by: CommandLine.arguments) {
            DispatchQueue.main.async { [weak self] in self?.openSettings(for: request) }
        }
        
        // 创建桌面壁纸视窗
        setWallpaperWindows()
        // Changes show their transitions from now; the playlist starts as its settings say.
        wallpaperViewModel.transitions = wallpaperTransitions
        wallpaperViewModel.startPlaylistAtLaunch()
        // Stop Wallpapers closes them, Resume makes them again.
        observeStoppedState()
        // A display turned on or off in the Displays sheet: only its window comes or goes.
        wallpaperViewModel.onScreenEnabledChange = { [weak self] screenId in self?.updateWallpaperWindow(for: screenId) }

        // 监听显示器连接/断开
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(audioCapturePermissionMissing),
            name: .audioCapturePermissionMissing, object: nil
        )
        
        // 创建化左上角菜单栏
        setMainMenu()
        
        // 创建化右上角常驻菜单栏
        setStatusMenu()
        statusItem.isVisible = globalSettingsViewModel.settings.showInMenuBar
        
        // 创建主视窗
        self.mainWindowController = MainWindowController()
        
        // 将外部输入传递到壁纸窗口
        observeWebWallpapers()

        observeMainWindowForWhatsNew()
    }
    
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let dockMenu = statusItem?.menu?.copy() as? NSMenu else { return nil }
        // The Dock has its own Quit.
        for item in dockMenu.items where item.action == #selector(AppTermination.quit(_:)) {
            dockMenu.removeItem(item)
        }
        return dockMenu
    }

    // MARK: - Lifecycle state (AppDelegate+Lifecycle)

    /// A copy the broker launched for a screen saver (`launchedForScreenSaver`) quits once its
    /// sessions are over, after `ScreenSaverLiveController.warmGrace` (another session may follow),
    /// unless the user opened one of its windows meanwhile: the user had quit the app, and it
    /// shouldn't stay, with its desktop wallpapers, because a screen saver ran.
    var quitsAfterScreenSaver = false

    var screenSaverQuitTimer: Timer?

    var windowOpenedObserver: NSObjectProtocol?

    lazy var identityNotice = AppIdentityNotice()

    var staleBundleRefresher: StaleBundleRefresher?

    var staleBundleNotice: SafeRestartNotice?
}
