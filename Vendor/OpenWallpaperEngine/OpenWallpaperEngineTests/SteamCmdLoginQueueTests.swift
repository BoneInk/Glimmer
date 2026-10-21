import XCTest
@testable import OpenWallpaperEngine

/// A cached login waits for other steamcmd work instead of running beside it.
final class SteamCmdLoginQueueTests: XCTestCase {
    @MainActor
    func testCachedLoginRunsAfterQueuedSteamCmdWork() throws {
        let storage = FileManager.default.temporaryDirectory.appending(path: "SteamCmdLoginQueue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storage) } // Test scratch.
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SteamCmdLoginQueueTests-\(UUID().uuidString)"))
        let runner = OverlapRecordingRunner()
        let steamCmd = SteamCmdService(dependencyIndex: WorkshopDependencyIndex(libraryDirectory: { storage }),
                                       runner: runner, storageDirectory: { storage },
                                       previewCacheRoot: storage.appending(path: "previews"),
                                       downloadedIndex: DownloadedWallpaperIndex(defaults: defaults,
                                                                                 libraryDirectory: { storage }),
                                       presentPreview: { _ in },
                                       account: SteamCmdAccountMemory(load: { nil }, save: { _ in }),
                                       restoresSession: false)
        steamCmd.steamCmdPath = "/usr/bin/false"

        steamCmd.enqueueSteamCmdWork {
            runner.setBusy(true)
            Thread.sleep(forTimeInterval: 0.3)
            runner.setBusy(false)
        }
        let loggedIn = expectation(description: "login finished")
        steamCmd.loginWithCachedSession(username: "someone") { _ in loggedIn.fulfill() }
        wait(for: [loggedIn], timeout: 10)
        XCTAssertEqual(runner.runs, 1)
        XCTAssertFalse(runner.overlapped, "the login ran while other steamcmd work was running")
    }
}

/// Records whether steamcmd was started while other steamcmd work was marked busy.
private final class OverlapRecordingRunner: SteamCmdRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false // Owned by `lock`.
    private var overlap = false // Owned by `lock`.
    private var count = 0 // Owned by `lock`.

    var overlapped: Bool { lock.withLock { overlap } }
    var runs: Int { lock.withLock { count } }
    func setBusy(_ value: Bool) { lock.withLock { busy = value } }

    func run(executable: URL, script: SteamCmdScript, timeout: TimeInterval?,
             onOutput: @escaping (String) -> Void) -> SteamCmdRun {
        lock.withLock {
            count += 1
            if busy { overlap = true }
        }
        return SteamCmdRun(output: "Logging in user 'someone' [U:1:1] to Steam Public...OK", exitCode: 0)
    }
}
