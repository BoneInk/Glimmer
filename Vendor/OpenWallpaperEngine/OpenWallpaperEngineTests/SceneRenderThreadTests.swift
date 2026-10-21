import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// A scene renders on its own render thread (`SceneRenderLoop`): its displays' links draw there,
/// not on the main thread, so a main-thread stall doesn't hold back frames.
@MainActor
final class SceneRenderThreadTests: XCTestCase {
    /// What the frames saw, written on the render thread.
    private final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [CFTimeInterval] = []
        private var offMain = true
        private var onRenderThread = true

        func record() {
            let main = Thread.isMainThread, render = ThreadGuards.isRenderThread
            lock.withLock {
                times.append(CACurrentMediaTime())
                offMain = offMain && !main
                onRenderThread = onRenderThread && render
            }
        }

        var count: Int { lock.withLock { times.count } }
        func count(between start: CFTimeInterval, and end: CFTimeInterval) -> Int {
            lock.withLock { times.filter { $0 >= start && $0 <= end }.count }
        }
        var allOffMain: Bool { lock.withLock { offMain } }
        var allOnRenderThread: Bool { lock.withLock { onRenderThread } }
    }

    private var window: NSWindow?
    private var loop: SceneRenderLoop?
    /// The view holds its delegate weakly.
    private var delegate: Delegate?

    override func tearDown() {
        loop?.shutdown()
        loop = nil
        delegate = nil
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    /// A render loop drawing one on-screen view, its frames recorded in `frames`.
    /// `prepare` sets the renderer up before the render thread takes it.
    private func startLoop(_ frames: Frames, prepare: (SceneMetalRenderer) throws -> Void = { _ in }) throws -> SceneRenderLoop {
        let screen = try XCTUnwrap(NSScreen.main, "needs a display")
        let renderer = try XCTUnwrap(SceneMetalRenderer(pixelFormat: .bgra8Unorm))
        renderer.frameTimeObserver = { _ in frames.record() }
        try prepare(renderer)
        let loop = SceneRenderLoop(renderer: renderer, name: "test render")
        self.loop = loop
        let window = NSWindow(contentRect: CGRect(x: screen.frame.minX, y: screen.frame.minY, width: 64, height: 64),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = SceneRenderLoop.makeView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        renderer.configure(view)
        let delegate = Delegate(loop: loop)
        self.delegate = delegate
        let id = ObjectIdentifier(delegate)
        // As the instance does: the link takes over (the view's own timer stops) before the view
        // gets its delegate and goes on screen.
        loop.attach(id, view: view, state: SceneRenderLoop.DisplayState(refresh: screen.maximumFramesPerSecond))
        view.delegate = delegate
        window.contentView = view
        window.orderFrontRegardless()
        self.window = window
        var playback = SceneRenderLoop.Playback()
        playback.displays[id] = SceneRenderLoop.DisplayState(refresh: screen.maximumFramesPerSecond)
        loop.update(playback)
        return loop
    }

    /// Forwards the view's draws to the loop, as `SceneWallpaperPresenter` does.
    private final class Delegate: NSObject, MTKViewDelegate {
        let loop: SceneRenderLoop
        init(loop: SceneRenderLoop) { self.loop = loop }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) { loop.draw(ObjectIdentifier(self), in: view) }
    }

    private func waitForFrames(_ frames: Frames, atLeast count: Int, timeout: TimeInterval = 5,
                               onMain: () -> Void = {}) {
        let deadline = Date().addingTimeInterval(timeout)
        while frames.count < count, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            onMain()
        }
    }

    /// Startup with WE's MSAA ×2: the scene pass's multisampled pipelines are made on first use,
    /// so a frame drawn on the main thread beside the render thread's raced to make them. The
    /// view's own timer never runs, and a stray main-thread draw is dropped and reported.
    func testStartupWithMSAADrawsOnlyOnTheRenderThread() throws {
        _ = try Fixtures.assets()
        let directory = Fixtures.url("Scenes/msaa")
        defer { Fixtures.removeStoredSettings(for: directory) }
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/msaa/project.json"))
        let content = try XCTUnwrap(SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory)).metalContent())
        let frames = Frames()
        _ = try startLoop(frames) { renderer in
            renderer.renderSettings.antiAliasing = .msaa_x2
            renderer.setPlacement(.stretch)
            renderer.setContent(content)
        }
        let view = try XCTUnwrap(window?.contentView as? MTKView)
        XCTAssertTrue(view.isPaused, "the view's own timer never draws")
        waitForFrames(frames, atLeast: 20, timeout: 30)
        XCTAssertGreaterThanOrEqual(frames.count, 20, "the display link draws")
        XCTAssertTrue(frames.allOffMain, "every frame draws off the main thread")
        // Startup draws only on the render thread: any guard hit fails the test through
        // `ThreadGuardTestObserver`.

        // A stray main-thread draw while the link draws: dropped, and a guard hit.
        let before = frames.count
        let violations = expectThreadGuardViolations {
            waitForFrames(frames, atLeast: before + 20, timeout: 10) { view.draw() }
        }
        XCTAssertTrue(frames.allOffMain, "no frame drew on the main thread")
        XCTAssertTrue(violations.contains { $0.kind == .offRenderThread && $0.what == "A scene view's draw" })
        XCTAssertFalse(violations.contains { $0.what.contains("scene frame") }, "the renderer never ran it")
    }

    func testDrawRunsOffTheMainThread() throws {
        let frames = Frames()
        _ = try startLoop(frames)
        waitForFrames(frames, atLeast: 3)
        XCTAssertGreaterThanOrEqual(frames.count, 3, "the display link draws")
        XCTAssertTrue(frames.allOffMain, "every frame draws off the main thread")
        #if DEBUG
        XCTAssertTrue(frames.allOnRenderThread, "the thread guards see the render thread")
        #endif
    }

    func testMainThreadStallDoesNotDelayFrames() throws {
        let frames = Frames()
        _ = try startLoop(frames)
        waitForFrames(frames, atLeast: 2)
        XCTAssertGreaterThanOrEqual(frames.count, 2, "the display link draws")
        // The pace the link draws at while main is free. A CI runner's virtual display can tick
        // about once a second rather than at its refresh rate (every test of this class then
        // takes seconds per frame), so a fixed half-second stall can see no frame at all there.
        let paceStart = CACurrentMediaTime(), before = frames.count
        waitForFrames(frames, atLeast: before + 3, timeout: 10)
        let drawn = frames.count - before
        XCTAssertGreaterThanOrEqual(drawn, 3, "the display link keeps drawing")
        let interval = (CACurrentMediaTime() - paceStart) / Double(max(drawn, 1))
        // The main thread stalls for about six frames at that pace (at least half a second); the
        // render thread keeps drawing. A draw that waited on main would see none.
        let start = CACurrentMediaTime()
        Thread.sleep(forTimeInterval: min(max(0.5, interval * 6), 10))
        let end = CACurrentMediaTime()
        XCTAssertGreaterThanOrEqual(frames.count(between: start, and: end), 3, "frames kept coming while main stalled")
    }

    /// The scene pass's MSAA pipelines are made once, whichever threads ask for them at once.
    func testMSAAPipelinesAreMadeOnceUnderConcurrentAccess() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try XCTUnwrap(SceneMetalLibrary.make(device: device))
        let pipelines = try SceneLayerPipelines(
            device: device, vertex: try XCTUnwrap(library.makeFunction(name: "sceneVertex")),
            fragment: try XCTUnwrap(library.makeFunction(name: "sceneFragment")),
            copyFragment: try XCTUnwrap(library.makeFunction(name: "sceneCopyFragment")), formats: [.bgra8Unorm])
        let lock = NSLock()
        var made: [ObjectIdentifier] = []
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let normal = pipelines.pipelines(for: .bgra8Unorm, sampleCount: 2)?.normal
            lock.withLock { made.append(normal.map { ObjectIdentifier($0 as AnyObject) } ?? ObjectIdentifier(NSNull())) }
        }
        XCTAssertEqual(made.count, 8)
        XCTAssertEqual(Set(made).count, 1, "one set of ×2 pipelines")
    }

    /// A view the render thread drew is read directly again once it's detached: its snapshot,
    /// which holds a cursor and screen position, doesn't outlive the display.
    func testShutdownDropsTheViewsSnapshot() throws {
        let loop = try startLoop(Frames())
        let view = try XCTUnwrap(window?.contentView as? MTKView)
        XCTAssertNotNil(SceneViewSnapshots.snapshot(of: view))
        loop.shutdown()
        self.loop = nil
        let deadline = Date().addingTimeInterval(2)
        while SceneViewSnapshots.snapshot(of: view) != nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNil(SceneViewSnapshots.snapshot(of: view))
    }

    /// A `sync` sent to a thread that has stopped (its instance shut down) runs on the caller
    /// instead of waiting forever for a run loop that is gone.
    func testSyncAfterStopDoesNotHang() {
        let thread = SceneRenderThread(name: "OWE render test")
        thread.stop()
        XCTAssertEqual(thread.sync { 42 }, 42)
    }
}
