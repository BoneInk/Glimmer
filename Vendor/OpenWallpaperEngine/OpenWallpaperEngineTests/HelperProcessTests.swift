import XCTest
@testable import OpenWallpaperEngine

/// `HelperProcess` starts this app's helper runs the way each caller did by hand.
final class HelperProcessTests: XCTestCase {
    func testMakeRunsThisExecutableInThisIsolatedState() throws {
        let process = try XCTUnwrap(HelperProcess.make(["--prepare-wallpapers", "/tmp/a"], qos: .background))
        XCTAssertEqual(process.executableURL, AppRelauncher.helperExecutable)
        XCTAssertEqual(process.arguments, ["--prepare-wallpapers", "/tmp/a"])
        XCTAssertEqual(process.qualityOfService, .background)
        XCTAssertEqual(process.environment?[AppStorageLocation.environmentKey], AppStorageLocation.current.isolationTag)
        XCTAssertTrue((process.standardError as? FileHandle) === FileHandle.nullDevice)
    }

    func testRunReturnsTheExitStatusAfterExited() async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "exit 3"]
        let flag = ExitedFlag()
        let status: Int32 = try await HelperProcess.run(process) { flag.set() }
        XCTAssertEqual(status, 3)
        XCTAssertTrue(flag.value)
    }

    func testRunThrowsWhenItCantStart() async {
        let process = Process()
        process.executableURL = URL(filePath: "/nonexistent/owe-helper")
        do {
            _ = try await HelperProcess.run(process)
            XCTFail("a missing executable starts")
        } catch {}
    }

    func testCancellingTerminates() async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sleep")
        process.arguments = ["30"]
        let task = Task { try await HelperProcess.run(process) }
        while !process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        task.cancel()
        let status: Int32 = try await task.value
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(status, SIGTERM)
    }
}

private final class ExitedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
