import AppKit
import ImageIO
import QuartzCore

/// What a saver view shows (the `.saver`'s `OWESaverView` and the extension's view): the app's
/// live frames while they arrive (`LiveFrameSource`), faded in and out (`LiveFrameFallback`) over
/// the display's still picture (`ScreenSaverStills`), which shows until the first frames come and
/// whenever they stop. It works around the hosts' known bugs
/// (live screen saver notes §4):
///
/// - It starts on `startAnimation` whatever it heard (a new host misses `didstart`), and again on
///   `didstart` (hosts are reused); it stops on `willstop`/`didstop` and `stopAnimation`, keeping
///   its last frame, which the lock screen shows. It never exits.
/// - Each frame is shown as it comes, off the main thread (`LiveFrameDrawer`, on
///   `SaverDrawing.queue`): the host's main thread stalls for seconds while loginwindow's
///   password prompt comes in (lab run 2: the views' main-thread ticks and frames stopped
///   together for about 3 s), and a display link of its own beat against the app's.
/// - Nothing is drawn: the app's surface itself is the layer's contents (`contents` = the
///   ring's newest `IOSurface`, its crop as `contentsRect`, filled by `contentsGravity`), so no
///   drawable is waited for while the window server isn't compositing the host's window (with a
///   `CAMetalLayer`, `nextDrawable` held the frames and the notifications piled up behind it).
/// - While a session runs every view draws every frame: no view is guessed to be hidden (under
///   the password prompt none of them reports its frames presented). A view stops drawing only
///   when its display sleeps, the session ends, or it has no window or display. Only System
///   Settings' preview parks while its window isn't visible (`SaverParkPolicy`).
/// - A view that starts while the process already shows live frames (the host's new views at the
///   lock) shows them at once, with no fade from black.
/// - A small view is the System Settings preview whatever its flag says: it never makes the app draw.
/// - Every view of the process shares one frame source, and the app draws each loop once.
///
/// Main thread, except the drawing.
@MainActor
final class LiveSaverPresenter: NSObject {
    /// The rate a view checks for a stall, pings the app and reports.
    static let housekeepingRate = 4
    /// How long the switch between the still and live frames fades.
    static let crossfade: CFTimeInterval = 0.3

    private weak var view: NSView?
    private let source: LiveFrameSource
    private let still = CALayer()
    /// The still asked for last (`ScreenSaverStillChoice.key`): only its decode is shown.
    private var stillKey: String?
    /// The app's frames, as the layer's contents (`LiveFrameDrawer`).
    private let surfaceLayer = CALayer()
    private let viewID = UUID().uuidString
    private let isPreview: Bool
    private let drawer: LiveFrameDrawer
    private var link: CADisplayLink?
    private var linkRate = 0
    private var showsLive = false
    private(set) var isRunning = false
    private var lastPing: CFTimeInterval = -.infinity
    private var observers: [NSObjectProtocol] = []
    private var ticks = 0
    private var reportedAt: CFTimeInterval = 0
    /// What the lab log reports every this many seconds.
    private static let reportInterval: CFTimeInterval = 10

    init(view: NSView, isPreview flag: Bool, source: LiveFrameSource) {
        self.view = view
        self.source = source
        isPreview = SaverParkPolicy.isPreview(flag: flag, size: view.bounds.size)
        drawer = LiveFrameDrawer(layer: surfaceLayer, store: source.store, isPreview: isPreview)
        super.init()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.masksToBounds = true
        still.frame = view.bounds
        still.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        still.contentsGravity = .resizeAspectFill
        still.masksToBounds = true
        view.layer?.addSublayer(still)
        surfaceLayer.isOpaque = true
        surfaceLayer.opacity = 0
        surfaceLayer.frame = view.bounds
        surfaceLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        surfaceLayer.contentsGravity = .resizeAspectFill
        surfaceLayer.masksToBounds = true
        view.layer?.addSublayer(surfaceLayer)
        SaverLog.lifecycle.notice("view init pid=\(getpid()) view=\(self.viewID, privacy: .public) frame=\(Int(view.bounds.width))x\(Int(view.bounds.height)) previewFlag=\(flag) preview=\(self.isPreview)")
        observeLifecycle()
        // The still at once, before the host starts the view (half a second later on the classic
        // host): black otherwise. The display's own once the view is in a window.
        loadStill()
        // A still the app writes later (a new wallpaper, a pick) is shown at once, also by
        // System Settings' preview, which stays open for as long as its pane does.
        ScreenSaverFolderWatch.shared.add(self) { [weak self] in
            MainActor.assumeIsolated { self?.loadStill() }
        }
        let drawer = drawer
        source.store.addObserver(self) {
            SaverDrawing.queue.async { drawer.frameCame() }
        }
    }

    /// Stops observing; the view is going away.
    func invalidate() {
        stop(reason: "deinit")
        source.store.removeObserver(self)
        ScreenSaverFolderWatch.shared.remove(self)
        let center = DistributedNotificationCenter.default()
        for observer in observers { center.removeObserver(observer) }
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { workspace.removeObserver(observer) }
        observers.removeAll()
        workspaceObservers.removeAll()
    }

    private var workspaceObservers: [NSObjectProtocol] = []

    // MARK: Lifecycle

    func start(reason: String) {
        guard !isRunning, let view else { return }
        isRunning = true
        let now = CACurrentMediaTime()
        reportedAt = now
        ticks = 0
        loadStill()
        source.attach(viewID: viewID, display: displayIdentity, isPreview: isPreview)
        source.refresh()
        // Another view of this process shows live frames (a new host view at the lock): so does
        // this one, at once.
        let resumes = source.store.hasFreshFrame(at: LiveFrameStore.now(), within: LiveFrameFallback.staleAfter)
            && source.store.newestFrame(display: displayIdentity, pixels: pixels) != nil
        drawer.start(target: target, at: now, resumes: resumes)
        showLive(resumes, animated: false)
        if resumes { SaverDrawing.queue.async { [drawer] in drawer.frameCame() } }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        setRate(Self.housekeepingRate)
        SaverLog.lifecycle.notice("start (\(reason, privacy: .public)) view=\(self.viewID, privacy: .public) display=\(self.displayIdentity ?? "nil", privacy: .public) pixels=\(self.pixels.width)x\(self.pixels.height) live=\(resumes) window=\(view.window?.windowNumber ?? 0)")
    }

    /// Stops drawing and checking, keeping the last frame shown (the lock screen shows it).
    func stop(reason: String) {
        guard isRunning else { return }
        isRunning = false
        drawer.stop()
        link?.invalidate()
        link = nil
        linkRate = 0
        source.detach(viewID: viewID)
        SaverLog.lifecycle.notice("stop (\(reason, privacy: .public)) view=\(self.viewID, privacy: .public) live=\(self.showsLive)")
    }

    func layout() {
        guard let view else { return }
        // System Settings' preview is made at 0×0 and sized later: the still and the frames
        // follow its size here rather than through autoresizing alone.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        still.frame = view.bounds
        surfaceLayer.frame = view.bounds
        CATransaction.commit()
        drawer.retarget(target)
    }

    /// The view moved to a window (and so to a display): that display's still, and its frames.
    /// System Settings' preview runs while it has a window, whether or not its host starts it
    /// (the classic host never starts the Wallpaper pane's thumbnail): it shows live frames
    /// whenever the app draws them, and parks while its window isn't visible. It never makes the
    /// app draw (`LiveFrameSource.attach`).
    func windowChanged() {
        loadStill()
        drawer.retarget(target)
        guard isPreview else { return }
        if view?.window != nil {
            start(reason: "preview window")
        } else {
            stop(reason: "preview window gone")
        }
    }

    private func observeLifecycle() {
        let center = DistributedNotificationCenter.default()
        let events: [(Notification.Name, Bool)] = [
            (ScreenSaverLiveNames.didStart, true), (ScreenSaverLiveNames.willStop, false), (ScreenSaverLiveNames.didStop, false),
        ]
        for (name, starts) in events {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    SaverLog.lifecycle.notice("\(name.rawValue, privacy: .public) pid=\(getpid())")
                    if starts { self?.start(reason: name.rawValue) } else { self?.stop(reason: name.rawValue) }
                }
            })
        }
        for name in [ScreenSaverLiveNames.screenLocked, ScreenSaverLiveNames.screenUnlocked] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                SaverLog.lifecycle.notice("\(name.rawValue, privacy: .public) pid=\(getpid())")
            })
        }
        // The displays sleeping: nothing is shown, nothing is drawn (each frame also asks its own
        // display, `CGDisplayIsAsleep`).
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [drawer] _ in
                SaverLog.lifecycle.notice("\(asleep ? "displays asleep" : "displays awake", privacy: .public) pid=\(getpid())")
                drawer.setDisplaysAsleep(asleep)
            })
        }
    }

    // MARK: Frames

    /// A few times a second: the app is pinged, a stall falls back, the target and the report.
    @objc private func tick(_ link: CADisplayLink) {
        guard isRunning else { return }
        let now = CACurrentMediaTime()
        ticks += 1
        source.refresh()
        // Without the folder watch (no folder yet when the view was made), the still is looked
        // for as it ticks.
        if !ScreenSaverFolderWatch.shared.isWatching {
            ScreenSaverFolderWatch.shared.watch()
            loadStill()
        }
        if now - lastPing >= 1 {
            lastPing = now
            source.ping(viewID: viewID)
        }
        drawer.retarget(target)
        let state = drawer.update(at: now, windowVisible: view?.window?.occlusionState.contains(.visible) ?? false)
        if state.live != showsLive { showLive(state.live, animated: true) }
        setRate(state.parked ? SaverParkPolicy.parkedRate : Self.housekeepingRate)
        report(at: now, parked: state.parked)
    }

    private func showLive(_ live: Bool, animated: Bool) {
        showsLive = live
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? Self.crossfade : 0)
        CATransaction.setDisableActions(!animated)
        surfaceLayer.opacity = live ? 1 : 0
        CATransaction.commit()
        if animated {
            SaverLog.frames.notice("\(live ? "live frames" : "fallback to the still", privacy: .public) view=\(self.viewID, privacy: .public)")
        }
    }

    /// Shows the display's still picture, decoded off the main thread; kept when there is none.
    /// A decode that finishes after a newer still was asked for (the view moved to its display,
    /// the app wrote another) is dropped, so the newest still wins.
    private func loadStill() {
        let folder = ScreenSaverFolderWatch.shared.folder
        guard let choice = ScreenSaverStillChoice.current(in: folder, display: displayIdentity),
              choice.key != stillKey else { return }
        let key = choice.key, url = choice.url, file = url.lastPathComponent
        stillKey = key
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.stillKey == key else { return }
                    guard let image else {
                        self.stillKey = nil // Looked for again on the next change.
                        return
                    }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.still.contents = image
                    CATransaction.commit()
                    SaverLog.lifecycle.notice("still view=\(self.viewID, privacy: .public) \(file, privacy: .public)")
                }
            }
        }
    }

    private func setRate(_ rate: Int) {
        let rate = max(rate, 1)
        guard rate != linkRate, let link else { return }
        linkRate = rate
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(min(rate, 1)), maximum: Float(rate),
                                                         preferred: Float(rate))
    }

    // MARK: Lab log

    private func report(at now: CFTimeInterval, parked: Bool) {
        guard now - reportedAt >= Self.reportInterval else { return }
        let stats = drawer.takeStats()
        SaverLog.frames.notice("view=\(self.viewID, privacy: .public) live=\(self.showsLive) parked=\(parked) rate=\(self.linkRate) ticks=\(self.ticks) arrived=\(stats.arrived) drawn=\(stats.drawn) skipped=\(stats.skipped) over \(Int(now - self.reportedAt)) s")
        SaverCostMeter.report(at: now, parked: parked)
        reportedAt = now
        ticks = 0
    }

    // MARK: Display

    private var scale: CGFloat {
        view?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private var pixels: (width: Int, height: Int) {
        guard let view else { return (0, 0) }
        return (Int(view.bounds.width * scale), Int(view.bounds.height * scale))
    }

    private var displayID: CGDirectDisplayID? {
        (view?.window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The view's display's identity, as the app names displays (`DisplayIdentity`).
    private var displayIdentity: String? {
        guard let number = displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// Where the drawer draws: nil without a window or a display.
    private var target: LiveFrameDrawer.Target? {
        guard let view, view.window != nil, view.bounds.width > 0, view.bounds.height > 0, let displayID else { return nil }
        return LiveFrameDrawer.Target(display: displayIdentity, displayID: displayID, pixels: pixels)
    }
}

/// A view's drawing, on `SaverDrawing.queue`, so the host's main thread stalling (as it does
/// while the password prompt comes in) never holds a frame: each new frame in the store is drawn
/// as it comes, while the session runs, the view has a window and a display, and that display is
/// awake. Its fallback (`LiveFrameFallback`) is kept here too, so frames keep it live; the
/// presenter reads it to switch between the still and the live layer. Every field is the draw
/// queue's; the main thread reaches them through `sync`/`async` on it, which never waits on main.
final class LiveFrameDrawer: @unchecked Sendable {
    struct Target: Equatable {
        var display: String?
        var displayID: CGDirectDisplayID
        var pixels: (width: Int, height: Int)

        static func == (a: Target, b: Target) -> Bool {
            a.display == b.display && a.displayID == b.displayID && a.pixels == b.pixels
        }
    }

    struct Stats {
        var arrived = 0
        /// Frames set as the layer's contents.
        var drawn = 0
        /// Frames not drawn: no target, the display asleep, or a parked preview.
        var skipped = 0
    }

    private let layer: CALayer
    private let store: LiveFrameStore
    private let isPreview: Bool
    private let queue = SaverDrawing.queue
    private var target: Target?
    private var running = false
    private var displaysAsleep = false
    private var shown: ScreenSaverLiveStamp?
    private var fallback = LiveFrameFallback()
    private var startedAt: TimeInterval = 0
    /// The preview's window was last seen visible (the Settings window), on the main thread's tick.
    private var lastVisible: TimeInterval?
    private var lastDrawn: TimeInterval?
    private var stats = Stats()

    init(layer: CALayer, store: LiveFrameStore, isPreview: Bool) {
        self.layer = layer
        self.store = store
        self.isPreview = isPreview
    }

    // MARK: Main thread's calls

    func start(target: Target?, at now: TimeInterval, resumes: Bool) {
        queue.sync {
            self.target = target
            running = true
            shown = nil
            lastDrawn = nil
            lastVisible = nil
            startedAt = now
            fallback.reset()
            if resumes { fallback.resume(at: now) }
        }
    }

    func stop() {
        queue.sync { running = false }
    }

    func retarget(_ target: Target?) {
        queue.async { self.target = target }
    }

    func setDisplaysAsleep(_ asleep: Bool) {
        queue.async { self.displaysAsleep = asleep }
    }

    /// The fallback's mode at `now`, and whether this view is a parked preview; `windowVisible`
    /// is what the window server says of its window (true only for the preview's: the lock's
    /// windows report themselves hidden).
    func update(at now: TimeInterval, windowVisible: Bool) -> (live: Bool, parked: Bool) {
        queue.sync {
            if windowVisible { lastVisible = now }
            return (fallback.update(at: now) == .live, previewParked(at: now))
        }
    }

    func takeStats() -> Stats {
        queue.sync {
            defer { stats = Stats() }
            return stats
        }
    }

    // MARK: Draw queue

    /// A new frame may be in the store: drawn now, while live.
    func frameCame() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard running, let target, let frame = store.newestFrame(display: target.display, pixels: target.pixels),
              frame.stamp.isNewer(than: shown) else { return }
        let now = CACurrentMediaTime()
        shown = frame.stamp
        stats.arrived += 1
        fallback.frameArrived(at: now)
        guard fallback.mode == .live else { return }
        guard !displaysAsleep, CGDisplayIsAsleep(target.displayID) == 0,
              SaverParkPolicy.mayDraw(parked: previewParked(at: now), at: now, lastDrawn: lastDrawn) else {
            stats.skipped += 1
            return
        }
        lastDrawn = now
        draw(frame, pixels: target.pixels)
    }

    /// System Settings' preview parks while its window isn't visible; a session's views never do.
    private func previewParked(at now: TimeInterval) -> Bool {
        isPreview && SaverParkPolicy.previewParked(startedAt: startedAt, lastVisible: lastVisible, at: now)
    }

    /// Shows `frame`: its surface becomes the layer's contents, in one transaction committed and
    /// flushed from this queue, with no animation. The ring has three surfaces and the app writes
    /// the oldest, never the newest one a view shows.
    private func draw(_ frame: LiveFrame, pixels: (width: Int, height: Int)) {
        let rect = ScreenSaverManifest.contentsRect(for: frame.crop)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Each new frame is another surface of the ring than the one shown (a stamp is newer
        // only for a newer slot), so setting it is a change the compositor picks up.
        layer.contents = frame.surface
        if layer.contentsRect != rect { layer.contentsRect = rect }
        CATransaction.commit()
        // This queue's thread has no run loop to commit an implicit transaction the change may
        // have joined: flushed now, or a display whose window nothing else updates (the one
        // without the password prompt) kept the old frame until the next key (lab, 17:43).
        CATransaction.flush()
        stats.drawn += 1
    }
}

/// The queue every saver view of a process shows its frames on.
enum SaverDrawing {
    static let queue = DispatchQueue(label: "app.openwallpaperengine.saver.draw", qos: .userInteractive)
}

/// The process's CPU and GPU time, logged with the views' reports: what a parked or hidden host
/// costs (Phase 0).
@MainActor
enum SaverCostMeter {
    private static var last: (time: CFTimeInterval, cpu: Double, gpu: UInt64)?

    static func report(at now: CFTimeInterval, parked: Bool) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        var info = task_power_info_v2()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_v2>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &count)
            }
        }
        let gpu = status == KERN_SUCCESS ? info.gpu_energy.task_gpu_utilisation : 0
        defer { last = (now, cpu, gpu) }
        guard let last, now > last.time else { return }
        let seconds = now - last.time
        let cpuPercent = (cpu - last.cpu) / seconds * 100
        let gpuPercent = Double(gpu &- last.gpu) / 1_000_000_000 / seconds * 100
        SaverLog.cost.notice("pid=\(getpid()) parked=\(parked) cpu=\(String(format: "%.2f", cpuPercent), privacy: .public)% gpu=\(String(format: "%.2f", gpuPercent), privacy: .public)% over \(Int(seconds)) s")
    }
}
