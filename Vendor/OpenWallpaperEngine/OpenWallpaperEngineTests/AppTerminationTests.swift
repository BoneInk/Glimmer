import AppKit
import XCTest
@testable import OpenWallpaperEngine

@MainActor
final class AppTerminationTests: XCTestCase {
    /// AppKit refusing to quit (a sheet is up): the app still ends cleanly within the deadline.
    func testQuitCompletesWhenAppKitRefuses() {
        let center = NotificationCenter()
        var terminateCalls = 0
        var willTerminateAt: Date?
        let exited = expectation(description: "exit")
        var exitStatus: Int32?
        let observer = center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            willTerminateAt = Date()
        }
        defer { center.removeObserver(observer) }
        let termination = AppTermination(terminate: { terminateCalls += 1 }, notificationCenter: center,
                                         exitProcess: { exitStatus = $0; exited.fulfill() })
        termination.deadline = 0.2
        let start = Date()
        termination.quit()
        wait(for: [exited], timeout: 2)
        XCTAssertEqual(terminateCalls, 1)
        XCTAssertEqual(exitStatus, 0)
        let notified = try? XCTUnwrap(willTerminateAt)
        XCTAssertNotNil(notified, "applicationWillTerminate's notification must run before exiting")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    /// Several quit requests (SIGTERM, then the Quit menu) end the app once.
    func testRepeatedQuitExitsOnce() {
        var exits = 0
        let exited = expectation(description: "exit")
        let termination = AppTermination(terminate: {}, notificationCenter: NotificationCenter(),
                                         exitProcess: { _ in exits += 1; exited.fulfill() })
        termination.deadline = 0.1
        termination.quit()
        termination.quit()
        termination.armDeadline()
        wait(for: [exited], timeout: 2)
        RunLoop.main.run(until: Date() + 0.3)
        XCTAssertEqual(exits, 1)
    }
}
