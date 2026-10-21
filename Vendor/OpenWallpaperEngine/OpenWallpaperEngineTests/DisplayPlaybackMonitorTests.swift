import Combine
import XCTest
@testable import OpenWallpaperEngine

/// `DisplayPlaybackMonitor` over injected windows and displays: it evaluates the rules per display,
/// hands on only changes, and looks at the desktop on a timer only while a rule needs it.
@MainActor
final class DisplayPlaybackMonitorTests: XCTestCase {
    private final class Desktop {
        var windows: [DesktopWindow] = []
        var frontmost: pid_t?
        var audio = false
        var battery = false
        var windowReads = 0
        var evaluations = 0
        let displays = [
            DesktopDisplay(id: "1", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                           visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055)),
            DesktopDisplay(id: "2", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
                           visibleFrame: CGRect(x: 1920, y: 25, width: 1920, height: 1055)),
        ]
    }

    private var desktop = Desktop()
    private var applied: [[String: DisplayPlayback]] = []
    private var monitor: DisplayPlaybackMonitor!

    override func setUp() {
        super.setUp()
        desktop = Desktop()
        applied = []
        monitor = makeMonitor(scanQueue: nil)
    }

    private func makeSources() -> DisplayPlaybackSources {
        let desktop = desktop
        return DisplayPlaybackSources(
            windows: { desktop.windowReads += 1; return desktop.windows },
            displays: { desktop.evaluations += 1; return desktop.displays },
            frontmostPID: { desktop.frontmost },
            ownPID: 1,
            otherApplicationPlayingAudio: { _ in desktop.audio },
            onBattery: { desktop.battery })
    }

    private func makeMonitor(scanQueue: DispatchQueue?) -> DisplayPlaybackMonitor {
        DisplayPlaybackMonitor(sources: makeSources(), scanQueue: scanQueue) { [weak self] in self?.applied.append($0) }
    }

    /// Runs the main run loop until `condition` holds or `timeout` passes.
    override func tearDown() {
        monitor.stop()
        monitor = nil
        super.tearDown()
    }

    func testAFocusedAppOnTheRightDisplayPausesOnlyThatDisplay() {
        monitor.setRules(PlaybackRules(focused: .pause))
        XCTAssertEqual(applied.last, ["1": .run, "2": .run])
        desktop.frontmost = 100
        desktop.windows = [DesktopWindow(ownerPID: 100, bounds: CGRect(x: 2200, y: 200, width: 800, height: 600))]
        monitor.evaluate()
        XCTAssertEqual(applied.last, ["1": .run, "2": .pause])
        // The window moves to the left display.
        desktop.windows[0].bounds.origin.x = 200
        monitor.evaluate()
        XCTAssertEqual(applied.last, ["1": .pause, "2": .run])
    }

    func testUnchangedStatesAreNotHandedOnAgain() {
        monitor.setRules(PlaybackRules(focused: .pause))
        monitor.evaluate()
        monitor.evaluate()
        XCTAssertEqual(applied.count, 1)
    }

    func testWindowsAreReadOnlyWhileAWindowRuleIsOn() {
        monitor.setRules(PlaybackRules(onBattery: .pause))
        XCTAssertEqual(desktop.windowReads, 0)
        XCTAssertFalse(monitor.isPolling, "the battery rule follows IOKit's notification, not a timer")
        monitor.setRules(PlaybackRules(fullscreen: .stop))
        XCTAssertGreaterThan(desktop.windowReads, 0)
        XCTAssertTrue(monitor.isPolling)
        monitor.setRules(PlaybackRules())
        XCTAssertFalse(monitor.isPolling)
    }

    func testNoPollingWhileTheDisplaysSleep() {
        monitor.setRules(PlaybackRules(playingAudio: .mute, displayAsleep: .stop))
        XCTAssertTrue(monitor.isPolling)
        monitor.setDisplaysAsleep(true)
        XCTAssertFalse(monitor.isPolling)
        XCTAssertEqual(applied.last, ["1": .stop, "2": .stop])
        monitor.setDisplaysAsleep(false)
        XCTAssertTrue(monitor.isPolling)
        XCTAssertEqual(applied.last, ["1": .run, "2": .run])
    }

    // MARK: - Lock and fast user switching

    /// A monitor following its own centers, where the test posts the system's notifications: the
    /// distributed ones would otherwise reach every process on the Mac.
    private final class SessionBox { var state = DesktopSessionState() }

    private func startSessionMonitor(session: SessionBox = SessionBox())
        -> (monitor: DisplayPlaybackMonitor, workspace: NotificationCenter, distributed: NotificationCenter) {
        monitor.stop()
        let workspace = NotificationCenter(), distributed = NotificationCenter()
        var sources = makeSources()
        sources.workspaceNotifications = workspace
        sources.distributedNotifications = distributed
        sources.session = { session.state }
        let sessionMonitor = DisplayPlaybackMonitor(sources: sources, scanQueue: nil) { [weak self] in self?.applied.append($0) }
        sessionMonitor.start(settings: Just(GlobalSettings()))
        monitor = sessionMonitor
        return (sessionMonitor, workspace, distributed)
    }

    func testLockingTheScreenPausesEveryDisplayUntilItUnlocks() {
        let (monitor, _, distributed) = startSessionMonitor()
        XCTAssertEqual(applied.last, ["1": .run, "2": .run])
        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        spin { applied.last == ["1": .pause, "2": .pause] }
        XCTAssertEqual(applied.last, ["1": .pause, "2": .pause])
        XCTAssertTrue(monitor.sessionInactive)
        XCTAssertFalse(monitor.isPolling, "nobody sees the desktop, so the windows aren't looked at")
        distributed.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        spin { applied.last == ["1": .run, "2": .run] }
        XCTAssertEqual(applied.last, ["1": .run, "2": .run])
    }

    func testSwitchingToAnotherUserPausesEveryDisplayUntilSwitchingBack() {
        let (monitor, workspace, _) = startSessionMonitor()
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        spin { applied.last == ["1": .pause, "2": .pause] }
        XCTAssertEqual(applied.last, ["1": .pause, "2": .pause])
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        spin { applied.last == ["1": .run, "2": .run] }
        XCTAssertEqual(applied.last, ["1": .run, "2": .run])
        XCTAssertFalse(monitor.sessionInactive)
    }

    /// Lock and session combine: switching back to a still-locked screen stays paused, and the
    /// lock's pause combines with the rules as any other (the stricter wins, and they come back).
    func testLockAndSessionCombineWithTheRules() {
        let session = SessionBox()
        let (monitor, workspace, distributed) = startSessionMonitor(session: session)
        monitor.setRules(PlaybackRules(displayAsleep: .stop))
        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        spin { applied.last == ["1": .pause, "2": .pause] }
        monitor.setDisplaysAsleep(true)
        XCTAssertEqual(applied.last, ["1": .stop, "2": .stop])
        monitor.setDisplaysAsleep(false)
        XCTAssertEqual(applied.last, ["1": .pause, "2": .pause])
        // Back to this session; the window server says the screen is still locked.
        session.state = DesktopSessionState(screenLocked: true, active: true)
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        spin { monitor.session.active }
        XCTAssertTrue(monitor.session.screenLocked)
        XCTAssertEqual(applied.last, ["1": .pause, "2": .pause])
        distributed.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        spin { applied.last == ["1": .run, "2": .run] }
        XCTAssertEqual(applied.last, ["1": .run, "2": .run])
    }

    /// Started while the screen is locked (the app launched at login before unlocking): paused.
    func testStartingOnALockedScreenPauses() {
        let session = SessionBox()
        session.state = DesktopSessionState(screenLocked: true, active: true)
        _ = startSessionMonitor(session: session)
        XCTAssertEqual(applied.last, ["1": .pause, "2": .pause])
    }

    func testAudioAndBatteryActOnEveryDisplay() {
        desktop.audio = true
        desktop.battery = true
        monitor.setRules(PlaybackRules(playingAudio: .mute))
        XCTAssertEqual(applied.last, ["1": .mute, "2": .mute])
        monitor.setRules(PlaybackRules(onBattery: .pause))
        XCTAssertEqual(applied.last, ["1": .pause, "2": .pause])
    }

    func testBurstsOfEventsEvaluateOnce() {
        monitor.setRules(PlaybackRules(onBattery: .pause))  // no polling to interfere
        let evaluations = desktop.evaluations
        for _ in 0..<20 { monitor.setNeedsEvaluation() }
        let done = expectation(description: "evaluated")
        DispatchQueue.main.asyncAfter(deadline: .now() + DisplayPlaybackMonitor.throttle * 3) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(desktop.evaluations, evaluations + 1)
    }

    // MARK: - Off the main thread

    func testTheWindowListIsReadOffTheMainThread() {
        monitor.stop()
        let desktop = desktop
        var sources = makeSources()
        let readOnMain = LockedFlag()
        sources.windows = {
            if Thread.isMainThread { readOnMain.set() }
            return desktop.windows
        }
        monitor = DisplayPlaybackMonitor(sources: sources, scanQueue: DispatchQueue(label: "test.scan")) { [weak self] in
            self?.applied.append($0)
        }
        desktop.frontmost = 100
        desktop.windows = [DesktopWindow(ownerPID: 100, bounds: CGRect(x: 2200, y: 200, width: 800, height: 600))]
        monitor.setRules(PlaybackRules(focused: .pause))
        spin { !applied.isEmpty }
        XCTAssertEqual(applied.last, ["1": .run, "2": .pause])
        XCTAssertFalse(readOnMain.value, "the window list must be read on the scan queue")
    }

    func testAMovedWindowIsNoticedByThePollWithoutAnEvent() {
        monitor.stop()
        monitor = makeMonitor(scanQueue: DispatchQueue(label: "test.scan"))
        desktop.frontmost = 100
        desktop.windows = [DesktopWindow(ownerPID: 100, bounds: CGRect(x: 2200, y: 200, width: 800, height: 600))]
        monitor.setRules(PlaybackRules(focused: .pause))
        spin { applied.last == ["1": .run, "2": .pause] }
        XCTAssertTrue(monitor.isPolling)
        // No notification: only the timer on the scan queue can see the window move.
        desktop.windows = [DesktopWindow(ownerPID: 100, bounds: CGRect(x: 200, y: 200, width: 800, height: 600))]
        spin { applied.last == ["1": .pause, "2": .run] }
        XCTAssertEqual(applied.last, ["1": .pause, "2": .run])
    }

    func testAnUnchangedDesktopDoesNotWakeTheMainThread() {
        monitor.stop()
        monitor = makeMonitor(scanQueue: DispatchQueue(label: "test.scan"))
        monitor.setRules(PlaybackRules(fullscreen: .stop))
        spin { !applied.isEmpty }
        let evaluations: Int = desktop.evaluations
        let reads: Int = desktop.windowReads
        // Several poll intervals: the scan queue keeps reading, the main thread evaluates nothing.
        spin(for: DisplayPlaybackMonitor.pollInterval * 4)
        XCTAssertEqual(desktop.evaluations, evaluations)
        XCTAssertGreaterThan(desktop.windowReads, reads)
        XCTAssertEqual(applied.count, 1)
    }

    func testAStaleScanDoesNotOverwriteANewerAnswer() {
        monitor.stop()
        let gate = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "test.scan")
        monitor = makeMonitor(scanQueue: queue)
        queue.async { gate.wait() }  // holds the first scan back
        desktop.audio = true
        monitor.setRules(PlaybackRules(playingAudio: .mute))
        monitor.setRules(PlaybackRules(onBattery: .pause))
        gate.signal()
        spin { !applied.isEmpty }
        spin(for: 0.2)
        XCTAssertEqual(applied, [["1": .run, "2": .run]], "only the latest rules' answer is applied")
    }

    /// With coverage followed, the displays windows tile are handed on, and the monitor polls
    /// for windows moving away even with every rule off.
    func testCoveredDisplaysAreHandedOn() {
        var covered: [Set<String>] = []
        monitor = DisplayPlaybackMonitor(sources: makeSources(), scanQueue: nil,
                                         onCoverage: { covered.append($0) }, apply: { [weak self] in self?.applied.append($0) })
        monitor.setRules(PlaybackRules())
        XCTAssertFalse(monitor.isPolling)
        desktop.windows = [DesktopWindow(ownerPID: 100, bounds: CGRect(x: 1920, y: 25, width: 960, height: 1055)),
                           DesktopWindow(ownerPID: 200, bounds: CGRect(x: 2880, y: 25, width: 960, height: 1055))]
        monitor.watchesCoverage = true
        XCTAssertTrue(monitor.isPolling)
        XCTAssertEqual(covered, [["2"]])
        XCTAssertEqual(applied.last, ["1": .run, "2": .run], "covering isn't a playback rule")
        desktop.windows.removeLast()
        monitor.evaluate()
        XCTAssertEqual(covered, [["2"], []])
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set() { lock.lock(); _value = true; lock.unlock() }
}
