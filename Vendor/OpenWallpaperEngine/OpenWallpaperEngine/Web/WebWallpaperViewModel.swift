//
//  WebWallpaperViewModel.swift
//  Open Wallpaper Engine
//
//  Created by Toby on 2023/8/28.
//

import WebKit
import SwiftUI
import Combine

/// One web wallpaper page on one display: WE's web API (user and general properties, audio,
/// media, pause), mute, scheduling and the watchdog's heartbeat. It talks to the page through
/// `WebWallpaperPage`, so a WKWebView and a Chromium browser get exactly the same treatment.
class WebWallpaperViewModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var currentWallpaper: WEWallpaper

    var fileUrl: URL {
        currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file)
    }

    var readAccessURL: URL {
        currentWallpaper.wallpaperDirectory
    }

    /// The page the bridge talks to (a WKWebView or a `ChromiumBrowserPage`).
    weak var page: WebWallpaperPage?

    /// The page when WebKit renders it.
    var webView: WKWebView? {
        get { page as? WKWebView }
        set { page = newValue }
    }

    /// Serves the wallpaper's folder, with WE's patches (`assets/zcompat/web`) applied.
    let schemeHandler = WebWallpaperSchemeHandler()
    /// The files the page's `file` and `directory` properties let it read, in both engines.
    let userFiles = WebUserFiles()
    /// The page's `directory` properties: their folders' files, delivered or picked at random.
    private(set) lazy var directoryFeed: WebDirectoryFeed = MainActor.assumeIsolated {
        let feed = WebDirectoryFeed()
        feed.send = { [weak self] script in self?.page?.evaluate(script) }
        feed.onFoldersChange = { [weak self] folders in
            self?.userFolders = folders
            self?.allowUserFiles()
        }
        return feed
    }
    /// Values changed since the page loaded: the panel announces a change before it stores it.
    private var changedValues: [String: String] = [:]
    /// The folders `directoryFeed` watches, with their file types.
    private var userFolders: [(path: String, type: WebDirectoryProperty.FileType)] = []

    /// WE's compatibility patches for the current wallpaper, if it has any.
    var compatPatches: WebCompatPatches? {
        WebCompatPatches(workshopId: Self.compatWorkshopId(of: currentWallpaper),
                         assetsDirectory: WallpaperEngineAssets.directory)
    }

    /// The Workshop id that picks a wallpaper's zcompat entry: the numeric name Steam gives the
    /// item's folder. project.json's `workshopid` is the author's own text, so it doesn't choose.
    static func compatWorkshopId(of wallpaper: WEWallpaper) -> String? {
        let folder = wallpaper.wallpaperDirectory.standardizedFileURL.lastPathComponent
        return !folder.isEmpty && folder.allSatisfy({ $0.isASCII && $0.isNumber }) ? folder : nil
    }
    /// Receives the page's frame intervals and heartbeats (a page that stops beating is hung).
    weak var renderWatchdog: RenderWatchdog?
    /// The windows of the displays mirroring this page (a clone's or stretch's other members): the
    /// page counts as seen while any of them, or its own, is uncovered.
    var mirrorWindows: () -> [NSWindow] = { [] }
    private(set) var heartbeatGate = WebHeartbeatGate()
    /// Whether the current page has beaten yet: one that never runs the bridge (a load error
    /// page) is not judged.
    private var pageHasBeaten = false
    private var visibilityObservers: [NSObjectProtocol] = []
    private var audioTimer: Timer?
    /// The page's own smoothing of the captured spectrum, stepped by `audioTimer`, so the page
    /// hears audio whether or not a scene is running next to it.
    private var audioClock: AudioSpectrumClock?
    private var propertyObserver: NSObjectProtocol?
    /// Resends WE's general properties when the user's FPS changes.
    private var fpsObserver: AnyCancellable?

    /// Whose user properties the page gets: its display's, or the shared ones while synced.
    let propertyScope: WallpaperPropertyScope

    /// The now-playing session the page's media listeners hear (`WebWallpaperMediaBridge`).
    private let media: MediaSessionSource?
    private var mediaSubscription: Int?
    /// The media state the current page has been sent; nil until its first delivery.
    private var mediaSent: MediaSessionState?
    /// Which page a delivery is for; a new page (`pageWillLoad`) invalidates older deliveries.
    private var mediaPage = 0

    /// The user's FPS setting (WE's `applyGeneralProperties({fps})`) and its changes.
    private let settings: GlobalSettingsViewModel
    /// Called with the frame rate whenever it changes, for an engine that can cap it (Chromium).
    var onFrameRateChange: ((Int) -> Void)?

    init(wallpaper: WEWallpaper, propertyScope: WallpaperPropertyScope = .shared, media: MediaSessionSource? = nil,
         settings: GlobalSettingsViewModel? = nil) {
        self.currentWallpaper = wallpaper
        self.propertyScope = propertyScope
        self.media = media
        self.settings = settings ?? AppDelegate.shared.globalSettingsViewModel
        super.init()
        propertyObserver = NotificationCenter.default.addObserver(
            forName: .wallpaperUserPropertyChanged, object: nil, queue: .main
        ) { [weak self] notification in
            self?.propertyChanged(notification)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemWillSleep(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        observeVisibility()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let propertyObserver { NotificationCenter.default.removeObserver(propertyObserver) }
        for observer in visibilityObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        audioTimer?.invalidate()
        if let mediaSubscription { media?.unsubscribe(mediaSubscription) }
        renderWatchdog?.endHeartbeat(from: ObjectIdentifier(self))
    }

    /// The user's frame rate.
    var frameRate: Int { Int(settings.effectiveSettings.fps) }

    // MARK: Heartbeat

    /// Tracks what makes WebKit stop the page's timers: an occluded window and sleeping displays
    /// (system sleep also sleeps the displays).
    private func observeVisibility() {
        let workspace = NSWorkspace.shared.notificationCenter
        let displays: [(Notification.Name, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, false), (NSWorkspace.screensDidWakeNotification, true),
            (NSWorkspace.willSleepNotification, false), (NSWorkspace.didWakeNotification, true),
            (NSWorkspace.sessionDidResignActiveNotification, false), (NSWorkspace.sessionDidBecomeActiveNotification, true),
        ]
        for (name, awake) in displays {
            visibilityObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.heartbeatGate.displaysAwake = awake
                self?.reportHeartbeatGate()
            })
        }
        visibilityObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow else { return }
            let windows = [self.page?.hostWindow].compactMap { $0 } + self.mirrorWindows()
            guard windows.contains(where: { $0 === window }) else { return }
            self.windowOcclusionChanged(visible: windows.contains { $0.occlusionState.contains(.visible) })
        })
    }

    /// The page's window was covered or uncovered.
    func windowOcclusionChanged(visible: Bool) {
        heartbeatGate.windowVisible = visible
        reportHeartbeatGate()
    }

    /// A new page is loading; it is judged from its first heartbeat on.
    func pageWillLoad() {
        stopMedia()
        changedValues = [:]
        MainActor.assumeIsolated {
            directoryFeed.pageWillLoad()
            updateUserFiles()
        }
        pageHasBeaten = false
        renderWatchdog?.recordHeartbeat(from: ObjectIdentifier(self), expectingMore: false)
    }

    /// Restarts the heartbeat clock when the gate opens and stops it when it closes.
    private func reportHeartbeatGate() {
        updateAudioTimer()
        applySchedulingPolicy()
        guard pageHasBeaten else { return }
        renderWatchdog?.recordHeartbeat(from: ObjectIdentifier(self), expectingMore: heartbeatGate.expectsHeartbeats)
    }

    func heartbeatReceived(_ heartbeat: WebWallpaperPropertyBridge.Heartbeat) {
        heartbeat.intervals.forEach { renderWatchdog?.recordFrame(duration: $0) }
        heartbeatGate.pageVisible = heartbeat.visible
        pageHasBeaten = true
        reportHeartbeatGate()
    }

    // MARK: Wallpaper Engine web API

    /// The scripts every page gets at document start, in order: WE's pause hooks, the audio and
    /// heartbeat bridge, the media bridge. Chromium runs the same ones (`ChromiumPageScripts`).
    static let documentStartScripts = [
        WebWallpaperPropertyBridge.pauseScript,
        WebWallpaperPropertyBridge.bootstrapScript,
        WebWallpaperMediaBridge.bootstrapScript,
        WebDirectoryFeed.bootstrapScript,
        WebUserFiles.userFileScript,
    ]

    /// The messages the bridge posts.
    static let messageNames = [
        WebWallpaperPropertyBridge.audioMessageName,
        WebWallpaperPropertyBridge.frameMessageName,
        WebWallpaperMediaBridge.messageName,
        WebDirectoryFeed.randomFileMessageName,
    ]

    func installBridge(on controller: WKUserContentController) {
        for script in Self.documentStartScripts {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        for name in Self.messageNames {
            controller.add(WeakScriptMessageHandler(self), name: name)
        }
        // Runtime detection of Chromium-only APIs: only WebKit needs it.
        controller.addUserScript(WKUserScript(source: ChromiumFeatureProbe.script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        controller.add(WeakScriptMessageHandler(self), name: ChromiumFeatureProbe.messageName)
    }

    /// A message the page posted through the bridge, from either engine.
    func receivePageMessage(name: String, body: Any) {
        switch name {
        case WebWallpaperPropertyBridge.audioMessageName:
            audioListenerRegistered()
        case WebWallpaperMediaBridge.messageName:
            mediaListenerRegistered()
        case WebDirectoryFeed.randomFileMessageName:
            MainActor.assumeIsolated { directoryFeed.receiveRequest(body) }
        case WebWallpaperPropertyBridge.frameMessageName:
            guard let heartbeat = WebWallpaperPropertyBridge.heartbeat(from: body) else {
                OWELog.debug(.web, "Ignoring a malformed heartbeat message")
                return
            }
            heartbeatReceived(heartbeat)
        case ChromiumFeatureProbe.messageName:
            let features = ChromiumFeatureProbe.features(fromMessage: body)
            guard !features.isEmpty else { return }
            let wallpaper = currentWallpaper
            Task { @MainActor in ChromiumFeatureAdvisor.shared.recordRuntime(features, for: wallpaper) }
        default:
            break
        }
    }

    // MARK: Media integration

    /// The page registered a media listener: the first one subscribes it to the session.
    func mediaListenerRegistered() {
        guard mediaSubscription == nil, let media else { return }
        let page = mediaPage
        mediaSubscription = media.subscribe { [weak self] state in
            DispatchQueue.main.async { self?.mediaChanged(state, page: page) }
        }
    }

    /// Sends the page what changed: everything that isn't empty the first time, as WE does for a
    /// newly registered page, then each change.
    private func mediaChanged(_ state: MediaSessionState, page: Int) {
        guard page == mediaPage, let target = self.page else { return }
        let changes = mediaSent.map { state.changes(since: $0) } ?? state.initialChanges
        mediaSent = state
        for change in changes {
            if let script = WebWallpaperMediaBridge.deliveryScript(change) {
                target.evaluate(script)
            }
        }
    }

    private func stopMedia() {
        if let mediaSubscription { media?.unsubscribe(mediaSubscription) }
        mediaSubscription = nil
        mediaSent = nil
        mediaPage += 1
    }

    private var declaredProperties: [String: WebWallpaperPropertyBridge.Property] {
        var properties = WebWallpaperPropertyBridge.declaredProperties(wallpaperDirectory: currentWallpaper.wallpaperDirectory)
        // A Workshop preset item's values are its defaults.
        for (key, value) in WorkshopPresetItem.defaultValues(for: currentWallpaper) where properties[key] != nil {
            properties[key]?.defaultValue = value
        }
        return properties
    }

    /// Every declared property's current value: the user's, else project.json's.
    private func currentPropertyValues(_ properties: [String: WebWallpaperPropertyBridge.Property]) -> [String: String] {
        let stored = WallpaperSettingsIdentity.resolve(currentWallpaper)
            .userSetValues(scope: propertyScope)
            .merging(changedValues) { _, changed in changed }
        return WebWallpaperPropertyBridge.currentValues(properties: properties, stored: stored)
    }

    /// Points the directory feed at the folders the properties are set to now; the files the
    /// page may read follow (`allowUserFiles`).
    @MainActor
    private func updateUserFiles() {
        directoryFeed.update(properties: WebDirectoryProperty.declared(wallpaperDirectory: currentWallpaper.wallpaperDirectory),
                             values: currentPropertyValues(declaredProperties))
    }

    /// Lets the page read its `file` properties' files and its watched folders' files.
    private func allowUserFiles() {
        let properties = declaredProperties
        let values = currentPropertyValues(properties)
        let files = properties.filter { $0.value.type == "file" }.compactMap { values[$0.key] }.filter { !$0.isEmpty }
        userFiles.allow(filePaths: files, folders: userFolders)
    }

    /// Sends every declared property, as WE does once the page has loaded; the bootstrap holds
    /// them for a listener the page assigns later.
    private func applyAllProperties(to page: WebWallpaperPage) {
        let properties = declaredProperties
        let values = currentPropertyValues(properties)
        if let script = WebWallpaperPropertyBridge.applyUserPropertiesScript(
            WebWallpaperPropertyBridge.payload(properties: properties, values: values), full: true) {
            page.evaluate(script)
        }
        page.evaluate(WebWallpaperPropertyBridge.applyGeneralPropertiesScript(fps: frameRate))
        if fpsObserver == nil {
            fpsObserver = settings.$effectiveSettings.map { Int($0.fps) }.removeDuplicates().dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] fps in
                    self?.page?.evaluate(WebWallpaperPropertyBridge.applyGeneralPropertiesScript(fps: fps))
                    self?.onFrameRateChange?(fps)
                }
        }
    }

    private func propertyChanged(_ notification: Notification) {
        guard let path = notification.object as? String, path == currentWallpaper.settingsDirectory.path,
              // An edit of another display's properties doesn't reach this page.
              (notification.userInfo?["stores"] as? [String])?
                .contains(propertyScope.runtimeKey(directory: currentWallpaper.settingsDirectory)) ?? true,
              let key = notification.userInfo?["key"] as? String,
              let value = notification.userInfo?["value"] as? String,
              let page else { return }
        let properties = declaredProperties
        changedValues[key] = value
        let payload = WebWallpaperPropertyBridge.payload(properties: properties, values: [key: value])
        // The new file or folder is readable before the page hears of it.
        if ["file", "directory"].contains(properties[key]?.type) { MainActor.assumeIsolated { updateUserFiles() } }
        if let script = WebWallpaperPropertyBridge.applyUserPropertiesScript(payload) {
            page.evaluate(script)
        }
    }

    func audioListenerRegistered() {
        audioRegistered = true
        updateAudioTimer()
    }

    /// Whether the page registered an audio listener; the timer runs only while it can be seen.
    private var audioRegistered = false
    /// Keeps system audio capture on while the audio delivery runs.
    private var audioCaptureLease: AudioCaptureLease?

    /// Whether the 30 Hz audio delivery is running.
    var isDeliveringAudio: Bool { audioTimer != nil }

    /// Runs the 30 Hz delivery only while the page is registered, playing and visible: a paused,
    /// covered or sleeping page would drop the values, so the timer and its IPC stop too.
    private func updateAudioTimer() {
        guard audioRegistered, heartbeatGate.expectsHeartbeats else {
            audioTimer?.invalidate()
            audioTimer = nil
            audioCaptureLease = nil
            return
        }
        guard audioTimer == nil else { return }
        audioCaptureLease = WallpaperServices.shared.acquireAudioCapture()
        let clock = audioClock ?? WallpaperServices.shared.makeAudioSpectrumClock(publishes: false)
        audioClock = clock
        // WE delivers 64 left and 64 right values to web listeners 30 times a second.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, !self.isPaused, let page = self.page else { return }
            let snapshot = clock.advanceFrame()
            let samples = WebWallpaperPropertyBridge.audioArray(left: snapshot.left64, right: snapshot.right64)
            page.evaluate(WebWallpaperPropertyBridge.audioDeliveryScript(samples))
        }
        RunLoop.main.add(timer, forMode: .common)
        audioTimer = timer
    }

    /// Whether this display's page is silent: it isn't on the wallpaper's audible display, audio
    /// output is off, or the volume is 0 (`WallpaperAudioRouting`).
    private(set) var isMuted = false

    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        page?.setPageMuted(isSilent)
        applySchedulingPolicy()
    }

    /// Muted, or drawn for the screen saver, which is silent.
    private var isSilent: Bool { isMuted || heldForScreenSaver }

    /// The live screen saver draws this page (`ScreenSaverPageSharing`): it plays, silent, and
    /// counts as seen, whatever the playback rules and the windows covering it say.
    private(set) var heldForScreenSaver = false

    func holdForScreenSaver(_ hold: Bool) {
        guard hold != heldForScreenSaver else { return }
        heldForScreenSaver = hold
        heartbeatGate.heldForScreenSaver = hold
        page?.setPageMuted(isSilent)
        updatePaused()
        reportHeartbeatGate()
    }

    /// What the engine does with the page while it can't be seen: a muted page is suspended (no
    /// JS, timers or frames), an audible one only throttled, because a suspended page falls silent
    /// and Wallpaper Engine keeps a covered wallpaper's sound. The heartbeat gate and the audio
    /// timer already expect nothing from a covered window (`WebHeartbeatGate.windowVisible`).
    func applySchedulingPolicy() {
        page?.applySchedulingPolicy(muted: isSilent, visible: isVisibleOnScreen)
    }

    /// Whether anyone can see the page: its window is uncovered, the displays are awake and the
    /// playback rules don't pause it.
    var isVisibleOnScreen: Bool {
        heldForScreenSaver || (heartbeatGate.windowVisible && heartbeatGate.displaysAwake && !isPaused)
    }

    /// Whether the playback rules pause this display's page: its media is suspended and the page
    /// hears WE's `setPaused(true)`. WebKit has no public way to stop a page's animation frames,
    /// so a page that ignores `setPaused` keeps drawing there; Chromium stops drawing it.
    private(set) var isPaused = false
    /// What the playback rules ask; the screen saver's hold overrides it.
    private var pausedByRules = false

    func setPaused(_ paused: Bool) {
        pausedByRules = paused
        updatePaused()
    }

    private func updatePaused() {
        let paused = pausedByRules && !heldForScreenSaver
        guard paused != isPaused else { return }
        isPaused = paused
        heartbeatGate.playing = !paused
        reportHeartbeatGate()
        if let page { applyPaused(to: page) }
    }

    private func applyPaused(to page: WebWallpaperPage) {
        page.setPagePaused(isPaused)
        // WE's order: the page hears setPaused, then its callbacks and media are held.
        page.evaluate(WebWallpaperPropertyBridge.setPausedScript(isPaused) +
                      WebWallpaperPropertyBridge.wpxPauseScript(isPaused))
    }

    func stopAudio() {
        audioRegistered = false
        audioTimer?.invalidate()
        audioTimer = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Allow navigation to external URLs (e.g. YouTube embeds from URL-based web wallpapers)
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageDidFinishLoading()
    }

    /// The page loaded (WebKit's `didFinish`, Chromium's load end): WE hands it its properties
    /// now, and the page picks up the current mute and pause.
    func pageDidFinishLoading() {
        guard let page else { return }
        let javascriptStyle = "var css = '*{-webkit-touch-callout:none;-webkit-user-select:none}'; var head = document.head || document.getElementsByTagName('head')[0]; var style = document.createElement('style'); style.type = 'text/css'; style.appendChild(document.createTextNode(css)); head.appendChild(style);"
        page.evaluate(javascriptStyle)
        applyAllProperties(to: page)
        // A fetchall directory's files follow the properties, as WE sends them.
        MainActor.assumeIsolated { directoryFeed.pageDidLoad() }
        // A new page starts unmuted by script, and playing.
        if isSilent { page.setPageMuted(true) }
        if isPaused { applyPaused(to: page) }

        if settings.settings.adjustMenuBarTint || settings.settings.lockScreenPicture {
            // The displays showing this page get its snapshot as their desktop picture
            // (`DesktopPictureController`), once the page has drawn: at load it is often still
            // blank (white), which would tint the menu bar white.
            let directory = currentWallpaper.wallpaperDirectory
            DispatchQueue.main.asyncAfter(deadline: .now() + SceneLoadingSnapshotCapture.delay) { [weak self, weak page] in
                guard let page, self?.page === page else { return }
                page.snapshot { image in
                    guard let image else { return }
                    NotificationCenter.default.post(name: .webWallpaperPageSnapshot,
                                                    object: WebWallpaperPageSnapshot(wallpaperDirectory: directory, image: image))
                }
            }
        }
    }

    @objc func systemWillSleep(_ notification: Notification) {
        // Handle going to sleep
        OWELog.info(.web, "System is going to sleep")
        // Update your SwiftUI state here if needed
    }

    @objc func systemDidWake(_ notification: Notification) {
        // Handle waking up
        OWELog.info(.web, "System woke up from sleep")
        // Update your SwiftUI state here if needed
    }
}

/// Breaks the WKUserContentController → handler retain cycle.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var owner: WebWallpaperViewModel?

    init(_ owner: WebWallpaperViewModel) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receivePageMessage(name: message.name, body: message.body)
    }
}
