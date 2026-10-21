import XCTest

final class HangWatchdogTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    func testIdleRunLoopRecordsNothing() {
        let watchdog = HangWatchdog()
        watchdog.start()
        spin(0.6)
        let events = watchdog.stop()
        XCTAssertEqual(events, [])
    }

    func testBlockedMainThreadIsAHang() {
        let watchdog = HangWatchdog()
        watchdog.start()
        spin(0.1)
        Thread.sleep(forTimeInterval: 0.4)
        spin(0.1)
        let events = watchdog.stop()
        let hangs = events.filter { $0.kind == .mainThreadHang }
        XCTAssertEqual(hangs.count, 1, "\(events)")
        let ms: Double = hangs.first?.milliseconds ?? 0
        XCTAssertGreaterThan(ms, 250)
    }

    func testPausedWorkIsNotAHang() {
        let watchdog = HangWatchdog()
        watchdog.start()
        spin(0.1)
        watchdog.paused { Thread.sleep(forTimeInterval: 0.4) }
        spin(0.2)
        XCTAssertEqual(watchdog.stop(), [])
    }

    func testRenderGapAfterFirstFrameIsAStall() {
        let watchdog = HangWatchdog()
        watchdog.start()
        let done = expectation(description: "frames")
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.3) // before the first frame: loading, not a stall
            for _ in 0..<5 { watchdog.noteRenderFrame(); Thread.sleep(forTimeInterval: 0.016) }
            Thread.sleep(forTimeInterval: 0.2)
            watchdog.noteRenderFrame()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        let stalls = watchdog.stop().filter { $0.kind == .renderStall }
        XCTAssertEqual(stalls.count, 1, "\(stalls)")
    }
}
