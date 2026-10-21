import AppKit
import Combine
import Metal
import notify

/// The live screen saver, the app's side: while the screen saver runs and an Open Wallpaper Engine
/// saver shows (`ScreenSaverLiveState`), the loops of the screen saver's layout
/// (`ScreenSaverPlugin.liveLoops`) are drawn live (scenes by `ScreenSaverLiveScene`, video
/// wallpapers by `ScreenSaverLiveVideo`, web pages and WebM videos through Chromium by
/// `ScreenSaverLiveWeb`) into rings of surfaces
/// published for the `.saver` (`live.json`, Darwin notifications) and the extension (XPC,
/// `ScreenSaverFrameService`) by `ScreenSaverFramePublisher`. Nothing is drawn at any other time:
/// drawing stops on `willstop`/`didstop`, an unlock, or when no saver has said it is there for
/// `ScreenSaverLiveState.saverTimeout`. The savers show their stills whenever frames stop.
///
/// Only the user's own copy draws (an isolated copy, like the tests, never installs the saver
/// and never publishes), and only while the Screen Saver plugin is on.
@MainActor
final class ScreenSaverLiveController {
    /// What the drawing reads from the app.
    struct Environment {
        var settings: () -> GlobalSettings
        var placement: () -> WallpaperPlacement
        var scriptServices: () -> SceneScriptServices?
        /// The desktop's Chromium page on a display, while it shows the wallpaper.
        var pageSharing: (_ screenId: String, _ wallpaper: WEWallpaper) -> ScreenSaverPageSharing? = { _, _ in nil }
        /// The desktop's running scene on a display, loaded, while it shows the wallpaper with
        /// `scope`'s values.
        var sceneSharing: (_ screenId: String, _ wallpaper: WEWallpaper, _ scope: WallpaperPropertyScope) -> SceneRenderLoop? = { _, _, _ in nil }
        /// The desktop's player of a video wallpaper on a display, or its running scene on the
        /// Metal path, while it shows the video.
        var videoSharing: (_ screenId: String, _ wallpaper: WEWallpaper) -> VideoSharing? = { _, _ in nil }
        /// The speed a video plays at in a player of its own: the app's (its last while paused)
        /// times the wallpaper's own.
        var videoSpeed: (_ wallpaper: WEWallpaper) -> Float = { _ in 1 }
    }

    /// Where a video loop's frames come from on the desktop.
    enum VideoSharing {
        /// The AVKit path's player.
        case player(ScreenSaverVideoSharing)
        /// The Metal path's scene, which draws the video with its effects.
        case scene(SceneRenderLoop)
    }

    /// How often the frames each ring drew are logged while drawing.
    static let countsInterval: TimeInterval = 10

    private let plugin: ScreenSaverPlugin
    private let environment: Environment
    private let store: ScreenSaverVideoStore
    private let mayPublish: Bool
    private var state = ScreenSaverLiveState()
    private var enabledSubscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var aliveToken: Int32 = NOTIFY_TOKEN_INVALID
    private var previewAliveToken: Int32 = NOTIFY_TOKEN_INVALID
    private var timer: Timer?
    private var publisher: ScreenSaverFramePublisher?
    private var service: ScreenSaverFrameService?
    private var scenes: [(key: WarmKey, scene: ScreenSaverLiveScene)] = []
    /// Scenes of the last sessions, paused and still loaded, for `warmGrace` (`WarmKey`).
    private var warm: [WarmKey: ScreenSaverLiveScene] = [:]
    private var warmTimer: Timer?
    /// The picked wallpaper's still being rendered (`renderPickStill`).
    private var pickStill: (scene: ScreenSaverLiveScene, timer: Timer)?
    /// Counts `renderPickStill`s: a still drawn for an earlier pick is dropped.
    private var pickStillGeneration = 0
    private var pages: [ScreenSaverLiveWeb] = []
    private var videos: [ScreenSaverLiveVideo] = []
    /// Loops drawn from the desktop's own running scene (`ScreenSaverSharedScene`).
    private var sharedScenes: [ScreenSaverSharedScene] = []
    private var countsSince: TimeInterval = 0
    /// Launched for a saver (`launchedForScreenSaver`), heard once the plugin is observed.
    private var launchedForSaver = false
    /// The picked wallpaper's still, kept from its live draw (`ScreenSaverStillPublisher`).
    var stills: ScreenSaverStillPublisher?
    /// How long the picked wallpaper draws before a frame is kept as its still.
    static let pickStillDelay: TimeInterval = 3
    /// A screen saver session started (true) or ended (false).
    var onSessionChanged: ((Bool) -> Void)?
    private var sessionRuns = false

    /// How long a session's scenes stay loaded after it ends, so the next one (the Mac locked
    /// again, the screen saver back after a moment) draws at once instead of loading them again
    /// (about 2.4 s for a large scene). Cost: the scene's memory meanwhile (about 1.3 GB for
    /// 3810943704 at 1920×1080, measured), so it is short.
    static let warmGrace: TimeInterval = 120

    /// A scene loop as a warm scene matches it: the wallpaper, its property scope, size and rate.
    struct WarmKey: Hashable {
        var wallpaper: String
        var scope: String
        var pixels: SIMD2<Int>
        var points: SIMD2<Int>
        var frameRate: Int
    }
    private var frameRate = 0

    init(plugin: ScreenSaverPlugin, environment: Environment, store: ScreenSaverVideoStore = .current,
         mayPublish: Bool = ScreenSaverInstaller.current.mayInstall) {
        self.plugin = plugin
        self.environment = environment
        self.store = store
        self.mayPublish = mayPublish
    }

    /// Follows the Screen Saver plugin: observing the screen saver while it is on.
    func start() {
        guard mayPublish, enabledSubscription == nil else { return }
        enabledSubscription = plugin.$isEnabled.removeDuplicates().sink { [weak self] enabled in
            MainActor.assumeIsolated { self?.setObserving(enabled) }
        }
    }

    /// The broker launched the app for a saver showing (`ScreenSaverLiveNames.launchArgument`):
    /// the screen saver runs, and its `didstart` came before the app.
    func launchedForScreenSaver() {
        launchedForSaver = true
        if !observers.isEmpty { handle(.launchedForScreenSaver) }
    }

    private func setObserving(_ observing: Bool) {
        if observing, observers.isEmpty {
            observeLifecycle()
            defer { if launchedForSaver { handle(.launchedForScreenSaver) } }
            if publisher == nil, let device = MTLCreateSystemDefaultDevice() {
                let publisher = ScreenSaverFramePublisher(
                    manifestURL: store.directory.appending(path: ScreenSaverLiveManifest.fileName, directoryHint: .notDirectory),
                    notifier: DarwinFrameNotifier(), device: device)
                let service = ScreenSaverFrameService()
                service.onAlive = { [weak self] in self?.handle(.saverAlive) }
                service.isDrawing = { [weak publisher] in publisher?.current.isLive ?? false }
                publisher.onRings = { [weak service] in service?.use($0) }
                publisher.onStamp = { [weak service] in service?.show(ring: $0, stamp: $1) }
                service.registerWithBroker()
                self.publisher = publisher
                self.service = service
                // Nothing is drawn yet: a manifest left by an earlier run lists nothing.
                publisher.clear()
            }
        } else if !observing, !observers.isEmpty {
            stopDrawing()
            releaseWarm()
            cancelPickStill()
            let center = DistributedNotificationCenter.default()
            for observer in observers { center.removeObserver(observer) }
            observers.removeAll()
            if aliveToken != NOTIFY_TOKEN_INVALID { notify_cancel(aliveToken) }
            if previewAliveToken != NOTIFY_TOKEN_INVALID { notify_cancel(previewAliveToken) }
            aliveToken = NOTIFY_TOKEN_INVALID
            previewAliveToken = NOTIFY_TOKEN_INVALID
            timer?.invalidate()
            timer = nil
            service?.invalidate()
            service = nil
            publisher = nil
            state = ScreenSaverLiveState()
        }
    }

    private func observeLifecycle() {
        let center = DistributedNotificationCenter.default()
        let events: [(Notification.Name, ScreenSaverLiveState.Event)] = [
            (ScreenSaverLiveNames.didStart, .didStart), (ScreenSaverLiveNames.willStop, .willStop),
            (ScreenSaverLiveNames.didStop, .didStop), (ScreenSaverLiveNames.screenLocked, .screenLocked),
            (ScreenSaverLiveNames.screenUnlocked, .screenUnlocked),
        ]
        for (name, event) in events {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    OWELog.info(.app, "Live screen saver: \(name.rawValue)")
                    self?.handle(event)
                }
            })
        }
        let status = notify_register_dispatch(ScreenSaverLiveNames.saverAlive, &aliveToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(.saverAlive) }
        }
        // A Preview run's saver: drawn for while the app runs (the broker never launches it for one).
        notify_register_dispatch(ScreenSaverLiveNames.saverPreviewAlive, &previewAliveToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(.saverAlive) }
        }
        if status != UInt32(NOTIFY_STATUS_OK) {
            OWELog.error(.app, "Live screen saver: can't observe the savers (\(status))")
        }
    }

    private func handle(_ event: ScreenSaverLiveState.Event) {
        let now = ProcessInfo.processInfo.systemUptime
        if state.handle(event, at: now) {
            if state.isDrawing { startDrawing() } else { stopDrawing() }
        }
        if state.isDrawing, now - countsSince >= Self.countsInterval { logCounts(at: now) }
        // Timeouts need a clock only while the screen saver runs.
        if state.screenSaverRuns, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.handle(.tick) }
            }
            timer?.tolerance = 0.2
        } else if !state.screenSaverRuns {
            timer?.invalidate()
            timer = nil
            launchedForSaver = false
        }
        if state.screenSaverRuns != sessionRuns {
            sessionRuns = state.screenSaverRuns
            onSessionChanged?(sessionRuns)
        }
    }

    private func startDrawing() {
        guard let publisher, scenes.isEmpty, pages.isEmpty, videos.isEmpty, sharedScenes.isEmpty else { return }
        let (loops, displays) = plugin.liveLoops()
        guard !loops.isEmpty else {
            OWELog.info(.app, "Live screen saver: nothing to draw live; the savers show their stills")
            return
        }
        let placement = environment.placement()
        let settings = environment.settings()
        let limits = FramePacing.Limits(settings, power: PowerPolicyMonitor.shared.policy)
        let screens = Dictionary(NSScreen.screens.map { (WallpaperViewModel.screenId(for: $0), $0) }, uniquingKeysWith: { first, _ in first })
        // As the desktop paces scenes: the user's rate, capped by the power policy, rounded down to
        // a whole divisor of the display's refresh so every frame lasts as long (55 for 60 on a
        // 165 Hz display, `FramePacing.cadence`).
        func rate(for screen: NSScreen?) -> Int {
            let refresh = screen?.maximumFramesPerSecond ?? 60
            let target = max(1, min(limits.userLimit, limits.powerCap ?? .max))
            return FramePacing.cadence(target, refreshRate: refresh > 0 ? refresh : 60)
        }
        // A video at its own frame rate (`ScreenSaverLiveVideo.frameRate`), read ahead of time
        // (`ScreenSaverVideoSource.prefetchInfo`); at the display's while it isn't known yet.
        func videoInfo(_ loop: ScreenSaverPlugin.LiveLoop) -> ScreenSaverVideoSource.Info? {
            loop.kind == .video ? ScreenSaverVideoSource.cachedInfo(of: loop.wallpaper.mediaURL) : nil
        }
        func loopRate(_ loop: ScreenSaverPlugin.LiveLoop) -> Int {
            let screen = loop.screenId.flatMap { screens[$0] }
            guard let info = videoInfo(loop) else { return rate(for: screen) }
            let refresh = screen?.maximumFramesPerSecond ?? 60
            return ScreenSaverLiveVideo.frameRate(videoRate: info.frameRate, refresh: refresh > 0 ? refresh : 60, limit: rate(for: screen))
        }
        let frameRate = loops.map(loopRate).max() ?? 30
        // A page's ring is the page's own pixels (Web Standard Resolution and Texture Resolution
        // may draw it below the display's); a scene's the loop's.
        func pagePixelsPerPoint(_ loop: ScreenSaverPlugin.LiveLoop) -> CGFloat {
            ScreenSaverLiveWeb.pixelsPerPoint(settings, backingScale: CGFloat(loop.pixels.x) / CGFloat(max(loop.points.x, 1)))
        }
        let sizes = loops.map { loop in
            switch loop.kind {
            case .scene: loop.pixels
            case .video: ScreenSaverLiveVideo.ringPixels(loop: loop.pixels, video: videoInfo(loop)?.size, placement: placement)
            case .page: ScreenSaverLiveWeb.pixels(points: loop.points, pixelsPerPoint: pagePixelsPerPoint(loop))
            }
        }
        do {
            try publisher.publish(sizes: sizes,
                                  displays: ScreenSaverPlugin.liveDisplayEntries(loops.map(\.loop), pixels: sizes,
                                                                                 displays: displays),
                                  frameRate: frameRate)
        } catch {
            OWELog.error(.app, "Live screen saver: can't allocate the frames: \(error)")
            return
        }
        self.frameRate = frameRate
        countsSince = ProcessInfo.processInfo.systemUptime
        _ = publisher.takeCounts()
        for (ring, loop) in loops.enumerated() {
            let screen = loop.screenId.flatMap { screens[$0] }
            if case .page(let kind) = loop.kind {
                let sharing = loop.screenId.flatMap { environment.pageSharing($0, loop.wallpaper) }
                if let page = ScreenSaverLiveWeb(kind: kind, wallpaper: loop.wallpaper, propertyScope: loop.propertyScope,
                                                 ring: ring, points: loop.points, pixelsPerPoint: pagePixelsPerPoint(loop),
                                                 frameRate: rate(for: screen), placement: environment.placement(),
                                                 sharing: sharing, publisher: publisher) {
                    pages.append(page)
                }
                continue
            }
            if loop.kind == .video {
                startVideo(loop, ring: ring, pixels: sizes[ring], frameRate: loopRate(loop), screen: screen,
                           placement: placement, publisher: publisher)
                continue
            }
            let target = ScreenSaverLiveScene.Target(ring: ring, pixels: loop.pixels, points: loop.points, frameRate: rate(for: screen))
            // The desktop's own scene, already loaded: drawn from it, no second load.
            if !loop.isPick, let screenId = loop.screenId, let paceScreen = screen ?? NSScreen.main,
               let renderLoop = environment.sceneSharing(screenId, loop.wallpaper, loop.propertyScope),
               let shared = ScreenSaverSharedScene(renderLoop: renderLoop, target: target, screen: paceScreen, publisher: publisher,
                                                   name: loop.wallpaper.wallpaperDirectory.lastPathComponent) {
                sharedScenes.append(shared)
                continue
            }
            let key = WarmKey(wallpaper: loop.wallpaper.wallpaperDirectory.standardizedFileURL.path(percentEncoded: false),
                              scope: "\(loop.propertyScope)", pixels: loop.pixels, points: loop.points, frameRate: target.frameRate)
            let scene: ScreenSaverLiveScene
            if let warmScene = warm.removeValue(forKey: key) {
                warmScene.resume(ring: ring, publisher: publisher, screen: screen)
                scene = warmScene
            } else if let newScene = ScreenSaverLiveScene(wallpaper: loop.wallpaper, propertyScope: loop.propertyScope, target: target,
                                                          screen: screen, settings: settings, placement: environment.placement(),
                                                          scriptServices: environment.scriptServices(), publisher: publisher) {
                scene = newScene
            } else {
                continue
            }
            scenes.append((key, scene))
            if loop.isPick { keepPickStill(of: scene) }
        }
    }

    /// A video loop: from the desktop's running video on its display (its scene on the Metal path,
    /// its player on the AVKit path), else from a player of its own.
    private func startVideo(_ loop: ScreenSaverPlugin.LiveLoop, ring: Int, pixels: SIMD2<Int>, frameRate: Int, screen: NSScreen?,
                            placement: WallpaperPlacement, publisher: ScreenSaverFramePublisher) {
        let name = loop.wallpaper.wallpaperDirectory.lastPathComponent
        let sharing = loop.screenId.flatMap { environment.videoSharing($0, loop.wallpaper) }
        if case .scene(let renderLoop) = sharing, let paceScreen = screen ?? NSScreen.main {
            let target = ScreenSaverLiveScene.Target(ring: ring, pixels: pixels, points: loop.points, frameRate: frameRate)
            if let shared = ScreenSaverSharedScene(renderLoop: renderLoop, target: target, screen: paceScreen,
                                                   publisher: publisher, name: name) {
                sharedScenes.append(shared)
                return
            }
        }
        var player: ScreenSaverVideoSharing?
        if case .player(let shared) = sharing { player = shared }
        if let video = ScreenSaverLiveVideo(url: loop.wallpaper.mediaURL, name: name, ring: ring, pixels: pixels,
                                            frameRate: frameRate, rate: environment.videoSpeed(loop.wallpaper),
                                            placement: placement, screen: screen, sharing: player, publisher: publisher) {
            videos.append(video)
        }
    }

    private func stopDrawing() {
        let drew = !scenes.isEmpty || !pages.isEmpty || !sharedScenes.isEmpty || !videos.isEmpty
        videos.forEach { $0.shutdown() }
        videos.removeAll()
        sharedScenes.forEach { $0.shutdown() }
        sharedScenes.removeAll()
        // Kept loaded for a while: the next session draws them at once.
        for (key, scene) in scenes {
            scene.pause()
            warm[key]?.shutdown()
            warm[key] = scene
        }
        scenes.removeAll()
        if !warm.isEmpty { armWarmTimer() }
        pages.forEach { $0.shutdown() }
        pages.removeAll()
        if drew {
            publisher?.clear()
            OWELog.info(.app, "Live screen saver: stopped drawing")
        }
    }

    /// Where frames are lost: each ring's ticks (a scene's display link, a page's frames) and
    /// frames drawn, against the rate asked for.
    private func logCounts(at now: TimeInterval) {
        guard let publisher else { return }
        let seconds = now - countsSince
        countsSince = now
        for (ring, counts) in publisher.takeCounts().sorted(by: { $0.key < $1.key }) {
            OWELog.info(.app, String(format: "Live screen saver: ring %d ticks %.1f/s drawn %.1f/s (asked %d) over %.0f s",
                                     ring, Double(counts.ticks) / seconds, Double(counts.drawn) / seconds, frameRate, seconds))
        }
    }

    /// Keeps a still of the picked wallpaper's live draw, once it has drawn a while: the next
    /// screen saver shows it until the live frames come. A still frame drawn for it, without its
    /// text and clock hands (`ScreenSaverLiveScene.captureStill`); a page's frames can't leave
    /// them out, so a page keeps the still it has.
    private func keepPickStill(of scene: ScreenSaverLiveScene) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pickStillDelay) { [weak self, weak scene] in
            MainActor.assumeIsolated {
                guard let self, let scene, self.state.isDrawing, !scene.isPaused, let stills = self.stills else { return }
                scene.captureStill { image in
                    guard let image else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { stills.publishPick(image) } }
                }
            }
        }
    }

    private func armWarmTimer() {
        warmTimer?.invalidate()
        warmTimer = Timer.scheduledTimer(withTimeInterval: Self.warmGrace, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseWarm() }
        }
        warmTimer?.tolerance = 10
    }

    /// Lets the warm scenes go (the grace is over, or the plugin is off).
    private func releaseWarm() {
        warmTimer?.invalidate()
        warmTimer = nil
        guard !warm.isEmpty else { return }
        warm.values.forEach { $0.shutdown() }
        warm.removeAll()
        OWELog.info(.app, "Live screen saver: let the warm scenes go")
    }

    /// The picked wallpaper's still, rendered now instead of at its first screen saver: one live
    /// draw of it, with the screen saver's values, at the largest display's pixels, into a ring of
    /// its own that no saver sees; once it has drawn for `pickStillDelay`, a still frame of it, without
    /// its text and clock hands (`ScreenSaverLiveScene.captureStill`), is kept. Until
    /// then, and for what can't be drawn here (a page without the Chromium engine), the preview
    /// fills the screen, blurred (`ScreenSaverStillPublisher.publishPreview`).
    func renderPickStill(_ wallpaper: WEWallpaper) {
        guard mayPublish, let stills else { return }
        let screens = NSScreen.screens
        guard let screen = screens.max(by: { $0.frame.width * $0.backingScaleFactor * $0.frame.height
                                             < $1.frame.width * $1.backingScaleFactor * $1.frame.height }) else { return }
        let pixels = SIMD2(Int(screen.frame.width * screen.backingScaleFactor), Int(screen.frame.height * screen.backingScaleFactor))
        let points = SIMD2(Int(screen.frame.width), Int(screen.frame.height))
        cancelPickStill()
        pickStillGeneration += 1
        let generation = pickStillGeneration
        // A video's still is its first frame, filling the screen (a video has no text or clock to
        // leave out); its preview when that can't be read.
        if ScreenSaverVideoSource.isEligible(wallpaper) {
            stills.publishFirstFrame(of: wallpaper, filling: pixels) { [weak self] in self?.pickStillGeneration == generation }
            return
        }
        stills.publishPreview(of: wallpaper, filling: pixels)
        guard ScreenSaverPlugin.isScene(wallpaper), let device = MTLCreateSystemDefaultDevice() else { return }
        let ring = ScreenSaverFramePublisher(manifestURL: nil, notifier: SilentFrameNotifier(), device: device)
        do {
            try ring.publish(sizes: [pixels], displays: [.init(display: nil, ring: 0)], frameRate: 30)
        } catch {
            OWELog.error(.app, "Screen saver: can't allocate the picked wallpaper's still: \(error)")
            return
        }
        ScreenSaverPlugin.publishPickValues(for: wallpaper, store: plugin.settingsStore)
        let target = ScreenSaverLiveScene.Target(ring: 0, pixels: pixels, points: points, frameRate: 30)
        guard let scene = ScreenSaverLiveScene(wallpaper: wallpaper, propertyScope: ScreenSaverPlugin.pickScope, target: target,
                                               screen: screen, settings: environment.settings(), placement: environment.placement(),
                                               scriptServices: environment.scriptServices(), publisher: ring) else { return }
        var firstFrame: TimeInterval?
        let started = ProcessInfo.processInfo.systemUptime
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if firstFrame == nil, (ring.takeCounts()[0]?.drawn ?? 0) > 0 { firstFrame = now }
                if let first = firstFrame, now - first >= Self.pickStillDelay {
                    // Shut down once the still is drawn (the capture runs on its render thread).
                    self.pickStill?.timer.invalidate()
                    self.pickStill = nil
                    scene.captureStill { image in
                        DispatchQueue.main.async { [weak self] in
                            MainActor.assumeIsolated {
                                scene.shutdown()
                                guard let image, self?.pickStillGeneration == generation else { return }
                                stills.publishPick(image)
                                OWELog.info(.app, "Screen saver: drew the still of \(wallpaper.wallpaperDirectory.lastPathComponent)")
                            }
                        }
                    }
                } else if now - started > 60 {
                    OWELog.error(.app, "Screen saver: \(wallpaper.wallpaperDirectory.lastPathComponent) drew nothing for its still in 60 s")
                    self.cancelPickStill()
                }
            }
        }
        pickStill = (scene, timer)
    }

    private func cancelPickStill() {
        guard let pickStill else { return }
        pickStill.timer.invalidate()
        // Shut down after the capture that may be reading its ring has its surface (it holds it).
        pickStill.scene.shutdown()
        self.pickStill = nil
    }
}

/// Posts nothing: a ring no saver reads (the picked wallpaper's still).
private final class SilentFrameNotifier: ScreenSaverFrameNotifier, @unchecked Sendable {
    func post(_ name: String, state: UInt64) {}
}
