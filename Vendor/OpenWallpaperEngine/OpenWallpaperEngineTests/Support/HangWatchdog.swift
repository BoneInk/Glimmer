import Foundation
import QuartzCore
import XCTest

/// Detects main-thread hangs and render-thread stalls while a test runs.
///
/// A background thread posts a ping to the main queue every `pingInterval`; a hang is the main
/// thread going longer than `mainThreshold` without answering. The render thread reports each
/// frame through `noteRenderFrame()`; after the first frame, a gap longer than `renderThreshold`
/// is a stall. Tests must wait by spinning the run loop (`wait(for:)`, `XCTWaiter`), not by
/// blocking the main thread, or the watchdog will rightly report the block.
final class HangWatchdog: @unchecked Sendable {
    struct Event: Equatable, CustomStringConvertible {
        enum Kind: Equatable { case mainThreadHang, renderStall }
        let kind: Kind
        let milliseconds: Double
        var description: String {
            let what = kind == .mainThreadHang ? "main thread did not answer for" : "render thread went without a frame for"
            return String(format: "%@ %.0f ms", what, milliseconds)
        }
    }

    let pingInterval: TimeInterval
    let mainThreshold: TimeInterval
    let renderThreshold: TimeInterval

    private let lock = NSLock()
    private var running = false
    private var suspended = 0
    private var pendingSince: CFTimeInterval?
    private var worstPending: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval?
    private var recorded: [Event] = []
    private var thread: Thread?

    init(pingInterval: TimeInterval = 0.050, mainThreshold: TimeInterval = 0.250, renderThreshold: TimeInterval = 0.100) {
        self.pingInterval = pingInterval
        self.mainThreshold = mainThreshold
        self.renderThreshold = renderThreshold
    }

    var events: [Event] { lock.withLock { recorded } }

    func start() {
        let shouldStart: Bool = lock.withLock {
            guard !running else { return false }
            running = true
            recorded = []
            pendingSince = nil
            lastFrame = nil
            return true
        }
        guard shouldStart else { return }
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "OWE.HangWatchdog"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// Stops watching and returns everything recorded, including a hang still in progress.
    @discardableResult
    func stop() -> [Event] {
        lock.withLock {
            running = false
            closePendingIfHung(now: CACurrentMediaTime())
            return recorded
        }
    }

    /// Call from the render thread once per presented frame.
    func noteRenderFrame() {
        let now = CACurrentMediaTime()
        lock.withLock {
            guard running, suspended == 0 else { lastFrame = now; return }
            if let last = lastFrame, now - last > renderThreshold {
                recorded.append(Event(kind: .renderStall, milliseconds: (now - last) * 1000))
            }
            lastFrame = now
        }
    }

    /// Runs `body` without watching: for deliberate synchronous work a test does itself.
    /// The render gap restarts afterwards, so the paused time is not counted as a stall.
    func paused<T>(_ body: () throws -> T) rethrows -> T {
        lock.withLock { suspended += 1 }
        defer {
            lock.withLock {
                suspended -= 1
                pendingSince = nil
                lastFrame = nil
            }
        }
        return try body()
    }

    private func closePendingIfHung(now: CFTimeInterval) {
        guard let since = pendingSince else { return }
        let waited = now - since
        if waited > mainThreshold, suspended == 0 {
            recorded.append(Event(kind: .mainThreadHang, milliseconds: waited * 1000))
        }
        pendingSince = nil
    }

    private func loop() {
        while true {
            let now = CACurrentMediaTime()
            let sendPing: Bool = lock.withLock {
                guard running else { return false }
                if suspended > 0 { pendingSince = nil; return false }
                // A ping is outstanding: keep waiting for its answer, one hang per episode.
                return pendingSince == nil
            }
            if !lock.withLock({ running }) { return }
            if sendPing {
                lock.withLock { pendingSince = now }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.lock.withLock { self.closePendingIfHung(now: CACurrentMediaTime()) }
                }
            }
            Thread.sleep(forTimeInterval: pingInterval)
        }
    }
}

/// Base class for render and benchmark tests: watches for hangs through each test and fails it
/// when one happens. Set `watchesForHangs = false` in `setUp` (before `super.setUp()` returns
/// is fine) to opt out, or wrap deliberate synchronous work in `hangWatchdog.paused { }`.
class HangWatchdogTestCase: XCTestCase {
    var watchesForHangs = true
    private(set) var hangWatchdog = HangWatchdog()

    override func setUp() {
        super.setUp()
        hangWatchdog = HangWatchdog()
        hangWatchdog.start()
    }

    override func tearDown() {
        let events = hangWatchdog.stop()
        if watchesForHangs {
            for event in events { XCTFail("Hang: \(event)") }
        }
        super.tearDown()
    }
}
