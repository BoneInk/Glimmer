import Foundation
import XCTest

// Waiting for something the main run loop or a task delivers, shared by the tests (one copy
// instead of one per class). The run loop variants are for the main thread.

/// Runs the main run loop until `condition` holds or `timeout` passes; returns whether it held.
@discardableResult
func spin(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}

/// Runs the main run loop for `seconds`, whatever happens.
func spin(for seconds: TimeInterval) {
    spin(until: { false }, timeout: seconds)
}

/// Runs the main run loop until `condition` holds, and fails the test if it doesn't within
/// `timeout`.
func waitUntil(_ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
               _ condition: () -> Bool) {
    if !spin(until: condition, timeout: timeout) {
        XCTFail("Timed out waiting for \(what)", file: file, line: line)
    }
}

/// Sleeps the task between checks until `condition` holds, and fails the test if it doesn't
/// within `timeout`.
func sleepUntil(_ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                _ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) {
        guard Date() < deadline else { return XCTFail("Timed out waiting for \(what)", file: file, line: line) }
        try await Task.sleep(for: .milliseconds(10))
    }
}
