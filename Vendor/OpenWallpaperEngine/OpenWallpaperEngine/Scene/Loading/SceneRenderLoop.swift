import MetalKit
import QuartzCore

/// The render-thread half of a `SceneWallpaperInstance`: it owns the renderer, the displays' links
/// and the per-frame state (which display drives the frames, what each presented, the pacing), and
/// runs all of it on `thread`.
///
/// Thread boundary: the main thread only calls the entry points marked "main", which send their
/// work to `thread`; everything else runs there. Views are only drawn from their links, on the
/// render thread (`MTKView` paused, `draw()` called by the link).
final class SceneRenderLoop {
    /// What the main thread knows about a display and passes on each update.
    struct DisplayState: Equatable {
        /// The playback rules let this display draw.
        var plays = true
        /// The display is asleep or its window fully covered.
        var hidden = false
        /// Its screen's refresh rate.
        var refresh = 60
    }

    /// The main thread's playback state for every display, taken on each `update`.
    struct Playback: Equatable {
        /// The app's pause, or no display plays the wallpaper.
        var paused = false
        var displays: [ObjectIdentifier: DisplayState] = [:]
    }

    private struct Display {
        weak var view: MTKView?
        let link: CADisplayLink
        var state = DisplayState()
        /// The playback rules pause this display: it keeps its last frame.
        var frozen = false
        /// The renderer's `encodedFrames` this display last presented (shared scenes).
        var presentedFrame: UInt64 = .max
        /// The rate its link ticks at (a divisor of its refresh rate).
        var rate = 0
        /// When the main thread last refreshed its snapshot (`SceneViewSnapshots`).
        var snapshotRequested: CFTimeInterval = 0
    }

    let thread: SceneRenderThread
    /// Render thread only, after `init`.
    let renderer: SceneMetalRenderer?
    private var displays: [ObjectIdentifier: Display] = [:]
    /// Displays in the order they joined, which breaks frame-rate ties.
    private var displayOrder: [ObjectIdentifier] = []
    private var schedule = SceneFrameSchedule()
    private var playback = Playback()
    /// The pacing rate the links tick at (`FramePacing.targetRate`).
    private var pacedRate = 0
    /// The clock eased to a stop during the last draw: the displays stop once it is over.
    private var playbackStopped = false
    /// Refreshes the scene's loading snapshots; nil when it has none (a video).
    private let snapshots: SceneLoadingSnapshotCapture?
    /// When a draw first had content to show, and when to next ask `snapshots` to capture.
    private var contentSince: CFTimeInterval?
    private var nextSnapshotCheck: CFTimeInterval = 0
    /// Main: the scene is lent to the screen saver (`lend`).
    private(set) var isLent = false {
        didSet { if isLent != oldValue { onLoanChanged?() } }
    }
    /// Main: the scene was lent or given back (a video's stream plays for the screen saver meanwhile).
    var onLoanChanged: (() -> Void)?
    /// Render thread: the screen saver's link while the scene is lent, and what the renderer
    /// showed before (`lend`).
    private var loan: (link: CADisplayLink, fixedPointer: SIMD2<Float>?, rendersScreenSaver: Bool)?

    /// Main: makes the thread. `renderer` is handed to it and never touched from main again.
    init(renderer: SceneMetalRenderer?, name: String, snapshots: SceneLoadingSnapshotCapture? = nil) {
        thread = SceneRenderThread(name: name)
        self.renderer = renderer
        self.snapshots = snapshots
        guard let renderer else { return }
        renderer.performOnRenderThread = { [thread] block in thread.perform(block) }
        renderer.drawsOnRenderThreadOnly = true
        renderer.onPlaybackStopped = { [weak self] in self?.playbackStopped = true }
    }

    /// Main: runs `body` with the renderer on the render thread.
    func perform(_ body: @escaping (SceneMetalRenderer) -> Void) {
        thread.perform { [renderer] in
            guard let renderer else { return }
            body(renderer)
        }
    }

    // MARK: - Displays (main entry points)

    /// Main: a view for `attach`, its own timer stopped from the start. An `MTKView` starts its
    /// timer when it is made and draws from it on the main thread; one tick left over while the
    /// render thread already draws would draw the scene on both.
    static func makeView(frame: CGRect = .zero) -> MTKView {
        let view = MTKView(frame: frame)
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        return view
    }

    /// Main: `view` shows the scene from now on, drawn by its own display link (which follows it
    /// across screens) on the render thread. The view's own timer is stopped.
    func attach(_ id: ObjectIdentifier, view: MTKView, state: DisplayState) {
        let link = view.displayLink(target: SceneDisplayTicker(view: view), selector: #selector(SceneDisplayTicker.tick(_:)))
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        SceneViewSnapshots.refresh(view)
        thread.perform { [self] in
            link.isPaused = true
            link.add(to: thread.runLoop, forMode: .default)
            displays[id] = Display(view: view, link: link, state: state)
            if !displayOrder.contains(id) { displayOrder.append(id) }
            schedule.add(id, frameRate: state.refresh)
            applyPlayback()
        }
    }

    /// Main: stops drawing `id`'s view.
    func detach(_ id: ObjectIdentifier) {
        thread.perform { [self] in
            if let view = displays[id]?.view { SceneViewSnapshots.remove(view) }
            displays[id]?.link.invalidate()
            displays[id] = nil
            displayOrder.removeAll { $0 == id }
            schedule.remove(id)
        }
    }

    /// Main: the playback rules, pause and displays changed.
    func update(_ playback: Playback) {
        thread.perform { [self] in
            self.playback = playback
            applyPlayback()
        }
    }

    /// Main: stops the links and the thread once the work already sent has run, and returns once
    /// the thread has ended: no frame runs after it.
    func shutdown() {
        thread.perform { [self] in
            for display in displays.values {
                display.link.invalidate()
                if let view = display.view { SceneViewSnapshots.remove(view) }
            }
            displays.removeAll()
            displayOrder.removeAll()
        }
        thread.stop()
    }

    // MARK: - The screen saver (main entry points)

    /// Main: the live screen saver draws this running scene instead of loading it again
    /// (`ScreenSaverSharedScene`): from now on `screen`'s display link ticks `draw` with the
    /// renderer on the render thread, at `frameRate`, as the screen saver (the pointer held at the
    /// centre, `engine.isScreensaver()` true). The displays, hidden by the screen saver, keep their
    /// last frame and stop drawing, and the scene plays whatever their playback rules say, until
    /// `endLoan`. False when it is lent already or has no renderer.
    func lend(screen: NSScreen, frameRate: Int, draw: @escaping (SceneMetalRenderer) -> Void) -> Bool {
        guard let renderer, !isLent else { return false }
        isLent = true
        let link = screen.displayLink(target: SceneLoanTicker(renderer: renderer, draw: draw), selector: #selector(SceneLoanTicker.tick(_:)))
        let rate = Float(frameRate)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        thread.perform { [self] in
            loan = (link, renderer.fixedPointer, renderer.rendersScreenSaver)
            renderer.fixedPointer = SIMD2(0.5, 0.5)
            renderer.rendersScreenSaver = true
            applyPlayback()
            link.add(to: thread.runLoop, forMode: .default)
        }
        return true
    }

    /// Main: the screen saver is done with the scene; the displays draw it again.
    func endLoan() {
        guard isLent else { return }
        isLent = false
        thread.perform { [self] in
            guard let loan, let renderer else { return }
            self.loan = nil
            loan.link.invalidate()
            renderer.fixedPointer = loan.fixedPointer
            renderer.rendersScreenSaver = loan.rendersScreenSaver
            // One display draws straight onto its drawable: the screen saver's frame goes.
            if displays.count <= 1 { renderer.releaseSharedFrame() }
            applyPlayback()
        }
    }

    // MARK: - Frames (render thread)

    var displayCount: Int { displays.count }

    /// A display's draw, from its view's `draw()`: one display draws the scene straight onto its
    /// drawable; with several, or on a stretch (which shows a rect of a frame the canvas's size),
    /// the driving display renders the frame for all of them and each presents it. Returns
    /// whether the scene has drawn a complete frame (`SceneMetalRenderer.hasCompleteFrame`), which
    /// the loading picture waits for.
    @discardableResult
    func draw(_ id: ObjectIdentifier, in view: MTKView) -> Bool {
        guard let renderer else { return false }
        // Only the link draws: a draw from anywhere else (the view's own timer, a resize) would
        // run a frame beside the render thread's. Dropped; the next tick draws.
        guard thread.isCurrent else {
            ThreadGuards.assertRenderThread("A scene view's draw")
            return false
        }
        requestSnapshot(id, of: view)
        defer {
            if playbackStopped {
                playbackStopped = false
                applyPlayback()
            } else {
                applyPacing()
            }
        }
        let spansCanvas = SceneViewSnapshots.snapshot(of: view)?.canvas != nil
        guard displays.count > 1 || spansCanvas else {
            renderer.draw(in: view)
            captureSnapshotIfDue(view, renderer: renderer, rendersFrame: true)
            return renderer.hasCompleteFrame
        }
        let now = CACurrentMediaTime()
        if schedule.shouldRender(id, at: now) {
            renderer.renderShared(viewports())
            schedule.rendered(at: now)
        }
        // An idle frame encoded nothing: the display keeps the frame it shows.
        guard displays[id]?.presentedFrame != renderer.encodedFrames else { return renderer.hasCompleteFrame }
        displays[id]?.presentedFrame = renderer.encodedFrames
        renderer.present(in: view)
        // A stretched display's picture is its rect of the canvas, not the wallpaper's.
        if !spansCanvas { captureSnapshotIfDue(view, renderer: renderer, rendersFrame: false) }
        return renderer.hasCompleteFrame
    }

    /// Once the scene has shown its content for a while, copies what `view`'s display shows into
    /// its loading snapshot (`SceneLoadingSnapshotCapture`), at most once a second per scene and
    /// once per display size and session. With one display the scene draws onto the drawable, so
    /// `rendersFrame` redraws the frame to copy from without stepping the scene (`redrawShared`),
    /// freed right after; the readback and encoding run off this thread.
    private func captureSnapshotIfDue(_ view: MTKView, renderer: SceneMetalRenderer, rendersFrame: Bool) {
        guard let snapshots, renderer.hasContent else { return }
        let now = CACurrentMediaTime()
        guard let contentSince else {
            self.contentSince = now
            return
        }
        guard now >= nextSnapshotCheck else { return }
        nextSnapshotCheck = now + 1
        let viewport = SceneViewport(view)
        let pixelSize = SIMD2(Int(viewport.drawableSize.x), Int(viewport.drawableSize.y))
        guard pixelSize.x > 0, pixelSize.y > 0,
              snapshots.claim(pixelSize: pixelSize, contentSince: contentSince, now: now) else { return }
        // The lock screen and the screen saver show this picture: a still, without its text and
        // clock hands, which would show the capture's time (`captureStill`). With one display the
        // extra frame is freed after; with several the displays' frame is drawn again with them.
        let save: @Sendable (CGImage?) -> Void = { snapshots.save($0) }
        let started: Bool
        if rendersFrame || !renderer.stillLayerIDs.isEmpty {
            started = renderer.captureStill(pixelSize: pixelSize, pixelsPerPoint: viewport.pixelsPerPoint,
                                            viewports: [viewport], restores: !rendersFrame, completion: save)
            if rendersFrame { renderer.releaseSharedFrame() }
        } else {
            started = renderer.captureSharedFrame(pixelSize: pixelSize, pixelsPerPoint: viewport.pixelsPerPoint, completion: save)
        }
        if !started { OWELog.debug(.scene, "Loading snapshot: no frame to capture at \(pixelSize.x)×\(pixelSize.y)") }
    }

    /// Main: a screenshot of the scene's current moment at `pixelSize`
    /// (`SceneMetalRenderer.captureScreenshot`), drawn on the render thread between frames;
    /// `completion` gets the picture, or nil, on a Metal or the render thread.
    func captureScreenshot(pixelSize: SIMD2<Int>, completion: @escaping @Sendable (CGImage?) -> Void) {
        thread.perform { [self] in
            guard let renderer else { return completion(nil) }
            let restoring = displays.count > 1 ? viewports() : []
            if !renderer.captureScreenshot(pixelSize: pixelSize, restoring: restoring, completion: completion) {
                completion(nil)
            }
        }
    }

    /// Main: a transition's outgoing picture at `pixelSize`, kept on the GPU
    /// (`SceneMetalRenderer.captureTransitionFrame`), drawn on the render thread between frames;
    /// `completion` gets it, or nil, on a Metal or the render thread.
    func captureTransitionFrame(pixelSize: SIMD2<Int>, completion: @escaping @Sendable (MTLTexture?) -> Void) {
        thread.perform { [self] in
            guard let renderer else { return completion(nil) }
            if !renderer.captureTransitionFrame(pixelSize: pixelSize, live: viewports(), sharesFrame: displays.count > 1,
                                                completion: completion) {
                completion(nil)
            }
        }
    }

    /// Something that changes the picture happened: tick at `demand`'s rate from the next refresh.
    func wake(_ demand: FrameDemand) {
        guard let renderer, renderer.framePacing.level < demand else { return }
        renderer.framePacing.wake(demand, at: CACurrentMediaTime())
        applyPacing()
    }

    /// Follows `playback`: a paused wallpaper eases its clock to a stop, as WE eases a paused
    /// wallpaper's rate to 0 and stops drawing only then (`SceneClock`); its displays draw until
    /// the renderer reports the stop. A display the rules pause, or that is hidden, while others
    /// play keeps its last frame at once and stops driving the frames.
    private func applyPlayback() {
        guard let renderer else { return }
        let fps = renderer.framePacing.targetRate
        // Lent to the screen saver: the scene plays for it, the displays keep their last frame.
        let lent = loan != nil
        let paused = playback.paused && !lent
        renderer.pausesPlayback = paused
        let easing = paused && !renderer.hasStoppedPlayback
        for id in displays.keys {
            if let state = playback.displays[id] { displays[id]?.state = state }
            guard let display = displays[id] else { continue }
            let frozen = lent || (!display.state.plays || display.state.hidden) && !easing
            displays[id]?.frozen = frozen
            display.link.isPaused = frozen || (paused && !easing)
            setRate(fps, of: id)
        }
        pacedRate = fps
    }

    /// Ticks the displays at the pacing's rate (`FramePacing`), each at a divisor of its refresh
    /// rate, when the rate changed.
    private func applyPacing() {
        guard let renderer else { return }
        let target = renderer.framePacing.targetRate
        guard target != pacedRate else { return }
        pacedRate = target
        for id in displays.keys { setRate(target, of: id) }
    }

    private func setRate(_ target: Int, of id: ObjectIdentifier) {
        guard let display = displays[id] else { return }
        let refresh = display.state.refresh > 0 ? display.state.refresh : 60
        let rate = FramePacing.cadence(target, refreshRate: refresh)
        if display.rate != rate {
            displays[id]?.rate = rate
            let value = Float(rate)
            display.link.preferredFrameRateRange = CAFrameRateRange(minimum: value, maximum: value, preferred: value)
            let count = SceneWallpaperInstance.maximumDrawableCount(forRate: rate)
            if let layer = display.view.flatMap({ SceneViewSnapshots.snapshot(of: $0)?.layer }),
               layer.maximumDrawableCount != count {
                layer.maximumDrawableCount = count
            }
            // Thread boundary: the view's rate is main-thread state; frames read it as their limit
            // through its snapshot (`SceneViewport.frameRateLimit`).
            if let view = display.view {
                DispatchQueue.main.async {
                    if view.preferredFramesPerSecond != rate { view.preferredFramesPerSecond = rate }
                    // A view detached meanwhile is drawn on the main thread again: no snapshot.
                    if SceneViewSnapshots.snapshot(of: view) != nil { SceneViewSnapshots.refresh(view) }
                }
            }
        }
        schedule.setFrameRate(display.frozen ? 0 : min(rate, refresh), of: id)
    }

    /// Asks the main thread to retake `view`'s snapshot twice a second, so a moved window, a
    /// resize or a headroom change reaches the frames without the render thread reading AppKit.
    private func requestSnapshot(_ id: ObjectIdentifier, of view: MTKView) {
        let now = CACurrentMediaTime()
        guard let display = displays[id], now - display.snapshotRequested >= 0.5 else { return }
        displays[id]?.snapshotRequested = now
        DispatchQueue.main.async { [weak view] in
            guard let view, SceneViewSnapshots.snapshot(of: view) != nil else { return }
            SceneViewSnapshots.refresh(view)
        }
    }

    /// The displays as the frame needs them, the driving one first; views not yet laid out, and
    /// paused ones (they keep their last frame), are left out.
    private func viewports() -> [SceneViewport] {
        let driver = schedule.driver
        let ordered = displayOrder.filter { $0 == driver } + displayOrder.filter { $0 != driver }
        return ordered.compactMap { id -> SceneViewport? in
            guard let display = displays[id], !display.frozen, let view = display.view,
                  view.drawableSize.width > 0, view.drawableSize.height > 0 else { return nil }
            return SceneViewport(view)
        }
    }
}

/// The screen saver's display link's target while a scene is lent to it (`SceneRenderLoop.lend`).
private final class SceneLoanTicker: NSObject {
    private let renderer: SceneMetalRenderer
    private let draw: (SceneMetalRenderer) -> Void

    init(renderer: SceneMetalRenderer, draw: @escaping (SceneMetalRenderer) -> Void) {
        self.renderer = renderer
        self.draw = draw
    }

    /// Render thread.
    @objc func tick(_ link: CADisplayLink) {
        draw(renderer)
    }
}

/// A display link's target: ticks draw the view, on the render thread the link runs on. The link
/// retains it; `SceneRenderLoop` invalidates the link when the display goes.
private final class SceneDisplayTicker: NSObject {
    private weak var view: MTKView?

    init(view: MTKView) {
        self.view = view
    }

    /// Render thread: draws the view, which calls its delegate's `draw(in:)`.
    @objc func tick(_ link: CADisplayLink) {
        view?.draw()
    }
}
