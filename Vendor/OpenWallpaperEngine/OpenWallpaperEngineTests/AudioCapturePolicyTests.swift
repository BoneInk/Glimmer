import XCTest
@testable import OpenWallpaperEngine

@MainActor
final class AudioCapturePolicyTests: XCTestCase {
    // MARK: Permission gate

    func testDeniedPermissionNeverAllowsCapture() {
        let gate = AudioCapturePermissionGate(preflight: { false }, isAlertDismissed: { false })
        XCTAssertFalse(gate.canCapture())
        XCTAssertFalse(gate.becameGranted())
    }

    func testMissingPermissionAlertsOncePerLaunch() {
        let gate = AudioCapturePermissionGate(preflight: { false }, isAlertDismissed: { false })
        XCTAssertTrue(gate.shouldAlertMissingPermission())
        XCTAssertFalse(gate.shouldAlertMissingPermission())
        XCTAssertFalse(gate.shouldAlertMissingPermission())
    }

    func testDismissedOrGrantedPermissionNeverAlerts() {
        XCTAssertFalse(AudioCapturePermissionGate(preflight: { false }, isAlertDismissed: { true })
            .shouldAlertMissingPermission())
        XCTAssertFalse(AudioCapturePermissionGate(preflight: { true }, isAlertDismissed: { false })
            .shouldAlertMissingPermission())
    }

    func testGrantChangeIsReportedOnce() {
        var granted = false
        let gate = AudioCapturePermissionGate(preflight: { granted }, isAlertDismissed: { false })
        XCTAssertFalse(gate.canCapture())
        XCTAssertFalse(gate.becameGranted())
        granted = true
        XCTAssertTrue(gate.becameGranted())
        XCTAssertFalse(gate.becameGranted())
    }

    // MARK: Restart scheduler

    private final class FakeTimers {
        var pending: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
        @MainActor func fireAll() {
            let due = pending
            pending = []
            due.forEach { $0.work() }
        }
    }

    private func makeScheduler(maxFailures: Int = 3) -> (CaptureRestartScheduler, FakeTimers, () -> Int) {
        let timers = FakeTimers()
        var starts = 0
        let scheduler = CaptureRestartScheduler(
            debounce: 1.5, baseBackoff: 2, maxFailures: maxFailures,
            schedule: { delay, work in timers.pending.append((delay, work)) },
            start: { starts += 1 })
        return (scheduler, timers, { starts })
    }

    func testBurstOfRequestsIsDebouncedIntoOneStart() {
        let (scheduler, timers, starts) = makeScheduler()
        for _ in 0..<5 { scheduler.requestRestart() }
        XCTAssertEqual(timers.pending.map(\.delay), Array(repeating: 1.5, count: 5))
        timers.fireAll()
        XCTAssertEqual(starts(), 1)
    }

    func testRequestWhileInFlightRunsOnceAfterward() {
        let (scheduler, timers, starts) = makeScheduler()
        scheduler.requestRestart()
        timers.fireAll()
        scheduler.requestRestart()
        scheduler.requestRestart()
        timers.fireAll()
        XCTAssertEqual(starts(), 1, "never more than one start in flight")
        scheduler.finished(success: true)
        timers.fireAll()
        XCTAssertEqual(starts(), 2)
    }

    func testFailuresBackOffExponentiallyThenGiveUpOnce() {
        let (scheduler, timers, starts) = makeScheduler(maxFailures: 3)
        scheduler.requestRestart()
        timers.fireAll()
        XCTAssertFalse(scheduler.finished(success: false))
        XCTAssertEqual(timers.pending.map(\.delay), [2])
        timers.fireAll()
        XCTAssertFalse(scheduler.finished(success: false))
        XCTAssertEqual(timers.pending.map(\.delay), [4])
        timers.fireAll()
        XCTAssertTrue(scheduler.finished(success: false))
        XCTAssertTrue(timers.pending.isEmpty)
        XCTAssertEqual(starts(), 3)

        scheduler.requestRestart()
        timers.fireAll()
        XCTAssertEqual(starts(), 3, "no restarts after giving up")

        scheduler.reset()
        scheduler.requestRestart()
        timers.fireAll()
        XCTAssertEqual(starts(), 4)
    }

    func testSuccessClearsFailureCount() {
        let (scheduler, timers, _) = makeScheduler()
        scheduler.requestRestart()
        timers.fireAll()
        scheduler.finished(success: false)
        timers.fireAll()
        scheduler.finished(success: true)
        XCTAssertEqual(scheduler.consecutiveFailures, 0)
        XCTAssertTrue(timers.pending.isEmpty)
    }
}
