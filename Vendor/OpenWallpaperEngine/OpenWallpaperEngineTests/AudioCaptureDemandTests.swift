import XCTest
@testable import OpenWallpaperEngine

final class AudioCaptureDemandTests: XCTestCase {
    /// Runs scheduled work only when `advance` reaches it.
    private final class ManualClock: @unchecked Sendable {
        var now: TimeInterval = 0
        var pending: [(TimeInterval, () -> Void)] = []

        func schedule(_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
            pending.append((now + delay, work))
        }

        func advance(by seconds: TimeInterval) {
            now += seconds
            while let index = pending.firstIndex(where: { $0.0 <= now }) {
                let work = pending.remove(at: index).1
                work()
            }
        }
    }

    private func makeDemand(_ clock: ManualClock) -> (AudioCaptureDemand, () -> [Bool]) {
        let demand = AudioCaptureDemand(idleGrace: 5, schedule: { clock.schedule($0, $1) })
        var changes: [Bool] = []
        demand.observe { changes.append($0) }
        return (demand, { changes })
    }

    func testFirstLeaseTurnsCaptureOn() {
        let clock = ManualClock()
        let (demand, changes) = makeDemand(clock)
        XCTAssertFalse(demand.isDemanded)
        let lease = demand.acquire()
        clock.advance(by: 0)
        XCTAssertTrue(demand.isDemanded)
        XCTAssertEqual(changes(), [true])
        withExtendedLifetime(lease) {}
    }

    func testCaptureStopsOnlyAfterGraceOnceLastLeaseIsGone() {
        let clock = ManualClock()
        let (demand, changes) = makeDemand(clock)
        var first: AudioCaptureLease? = demand.acquire()
        var second: AudioCaptureLease? = demand.acquire()
        clock.advance(by: 0)
        first = nil
        clock.advance(by: 10)
        XCTAssertTrue(demand.isDemanded, "one consumer is still there")
        second = nil
        clock.advance(by: 4)
        XCTAssertTrue(demand.isDemanded, "still inside the grace period")
        clock.advance(by: 2)
        XCTAssertFalse(demand.isDemanded)
        XCTAssertEqual(changes(), [true, false])
        XCTAssertNil(first)
        XCTAssertNil(second)
    }

    func testReacquireInsideGraceKeepsCaptureRunning() {
        let clock = ManualClock()
        let (demand, changes) = makeDemand(clock)
        var lease: AudioCaptureLease? = demand.acquire()
        clock.advance(by: 0)
        lease = nil
        clock.advance(by: 3)
        lease = demand.acquire()
        clock.advance(by: 10)
        XCTAssertTrue(demand.isDemanded)
        XCTAssertEqual(changes(), [true])
        XCTAssertNotNil(lease)
    }

    /// Switching to an audio wallpaper after capture stopped starts it again.
    func testReacquireAfterStopRestartsCapture() {
        let clock = ManualClock()
        let (demand, changes) = makeDemand(clock)
        var lease: AudioCaptureLease? = demand.acquire()
        clock.advance(by: 0)
        lease = nil
        clock.advance(by: 6)
        XCTAssertFalse(demand.isDemanded)
        lease = demand.acquire()
        clock.advance(by: 0)
        XCTAssertTrue(demand.isDemanded)
        XCTAssertEqual(changes(), [true, false, true])
        XCTAssertNotNil(lease)
    }

    func testExplicitReleaseIsIdempotent() {
        let clock = ManualClock()
        let (demand, _) = makeDemand(clock)
        let a = demand.acquire()
        let b = demand.acquire()
        a.release()
        a.release()
        XCTAssertEqual(demand.consumerCount, 1)
        withExtendedLifetime(b) {}
    }
}
