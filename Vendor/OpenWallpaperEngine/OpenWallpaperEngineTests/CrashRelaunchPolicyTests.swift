import XCTest
@testable import OpenWallpaperEngine

final class CrashRelaunchPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let user = AppHostContext(isTestHost: false, isPreviewHost: false, isDebugged: false, isolationTag: nil)

    func testCrashRelaunchesAndIsRecorded() {
        XCTAssertEqual(CrashRelaunchPolicy.decide(.vanished, host: user, history: [], now: now),
                       .relaunch(history: [now]))
    }

    func testCleanEndingsNeverRelaunch() {
        for ending in [CrashRelaunchPolicy.Ending.quit, .stopWatching, .watcherTerminated] {
            XCTAssertEqual(CrashRelaunchPolicy.decide(ending, host: user, history: [], now: now), .stay, "\(ending)")
        }
    }

    func testAtMostThreeRelaunchesInFiveMinutes() {
        let three = [now - 240, now - 120, now - 10]
        XCTAssertEqual(CrashRelaunchPolicy.decide(.vanished, host: user, history: three, now: now), .rateLimited)
        let two = [now - 120, now - 10]
        XCTAssertEqual(CrashRelaunchPolicy.decide(.vanished, host: user, history: two, now: now),
                       .relaunch(history: two + [now]))
    }

    func testOldRelaunchesFallOutOfTheWindow() {
        let history = [now - 400, now - 301, now - 10]
        XCTAssertEqual(CrashRelaunchPolicy.decide(.vanished, host: user, history: history, now: now),
                       .relaunch(history: [now - 10, now]))
    }

    func testOnlyTheUsersOwnLaunchWatches() {
        XCTAssertTrue(CrashRelaunchPolicy.shouldWatch(enabled: true, host: user))
        XCTAssertFalse(CrashRelaunchPolicy.shouldWatch(enabled: false, host: user))
        var host = user
        host.isolationTag = "shots"
        XCTAssertFalse(CrashRelaunchPolicy.shouldWatch(enabled: true, host: host), "an isolated copy")
        host = user
        host.isTestHost = true
        XCTAssertFalse(CrashRelaunchPolicy.shouldWatch(enabled: true, host: host), "a test host")
        host = user
        host.isPreviewHost = true
        XCTAssertFalse(CrashRelaunchPolicy.shouldWatch(enabled: true, host: host), "a preview host")
        host = user
        host.isDebugged = true
        XCTAssertFalse(CrashRelaunchPolicy.shouldWatch(enabled: true, host: host), "a run under a debugger")
    }

    /// The watcher checks its own (inherited) context again: one in a test host or an isolated
    /// copy never relaunches, whoever started it.
    func testWatcherInATestHostOrIsolatedCopyNeverRelaunches() {
        let test = AppHostContext.detect(environment: ["XCTestSessionIdentifier": "1"], arguments: [], xcTestLoaded: false,
                                         loadedBundlePaths: [], isDebugged: false)
        XCTAssertEqual(CrashRelaunchPolicy.decide(.vanished, host: test, history: [], now: now), .stay)
        let isolated = AppHostContext.detect(environment: [AppStorageLocation.environmentKey: "shots"], arguments: [],
                                             xcTestLoaded: false, loadedBundlePaths: [], isDebugged: false)
        XCTAssertEqual(CrashRelaunchPolicy.decide(.vanished, host: isolated, history: [], now: now), .stay)
        let normal = AppHostContext.detect(environment: [:], arguments: [], xcTestLoaded: false, loadedBundlePaths: [],
                                           isDebugged: false)
        XCTAssertEqual(CrashRelaunchPolicy.decide(.vanished, host: normal, history: [], now: now), .relaunch(history: [now]))
    }

    @MainActor
    func testIsolatedAppNeverStartsTheWatcher() {
        var host = user
        host.isolationTag = "shots"
        let watcher = CrashWatcher(host: host)
        watcher.update(enabled: true)
        XCTAssertFalse(watcher.isRunning)
    }

    /// This process is the test host: the watcher is off with the setting on.
    @MainActor
    func testTheTestHostReportsTheWatcherDisabled() {
        XCTAssertTrue(AppHostContext.current.isTestHost)
        XCTAssertFalse(AppHostContext.current.mayRelaunch)
        XCTAssertFalse(CrashRelaunchPolicy.shouldWatch(enabled: true, host: .current))
        let watcher = CrashWatcher()
        watcher.update(enabled: true)
        XCTAssertFalse(watcher.isRunning, "a test host never starts the crash watcher")
    }

    func testWatcherReadsTheAppsEnding() {
        XCTAssertEqual(CrashWatcher.ending(for: Data("quit\n".utf8)), .quit)
        XCTAssertEqual(CrashWatcher.ending(for: Data("stop\n".utf8)), .stopWatching)
        XCTAssertEqual(CrashWatcher.ending(for: Data()), .vanished, "the pipe closed with no word: a crash")
        XCTAssertEqual(CrashWatcher.ending(for: Data("qu".utf8)), .vanished)
    }

    func testWatcherSeesEOFAsACrashAndQuitAsClean() throws {
        let crashed = Pipe()
        try crashed.fileHandleForWriting.close()
        XCTAssertEqual(CrashWatcher.readEnding(from: crashed.fileHandleForReading), .vanished)

        let quit = Pipe()
        quit.fileHandleForWriting.write(Data("quit\n".utf8))
        XCTAssertEqual(CrashWatcher.readEnding(from: quit.fileHandleForReading), .quit)
    }

    func testHistoryRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = CrashRelaunchHistory(directory: directory)
        XCTAssertEqual(history.load(), [])
        history.save([now])
        XCTAssertEqual(history.load(), [now])
    }
}
