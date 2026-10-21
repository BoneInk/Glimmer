import XCTest
@testable import OpenWallpaperEngine

/// The steamcmd kept logged in between Workshop downloads: one launch and login for a run of
/// downloads, completion read from its output, idle quit, and a new steamcmd (with one retry)
/// when the kept one dies, loses its connection or stops answering.
final class SteamCmdSessionTests: XCTestCase {
    private let executable = URL(fileURLWithPath: "/fake/steamcmd")

    private func setup(account: String = "tester", installDirectory: String = "/fake/staging") throws -> SteamCmdScript {
        try SteamCmdService.workshopSessionSetup(installDirectory: URL(fileURLWithPath: installDirectory), username: account)
    }

    private func download(_ id: String, in session: SteamCmdSession, account: String = "tester",
                          timeout: TimeInterval? = 5) throws -> SteamCmdRun {
        session.download(workshopId: id, command: try SteamCmdService.workshopDownloadCommand(workshopId: id, validate: true),
                         setup: try setup(account: account), executable: executable, timeout: timeout,
                         onOutput: { _ in })
    }

    // MARK: - Completion

    func testDownloadOutcomeReadsSteamCmdsResultLines() {
        XCTAssertEqual(SteamCmdSession.downloadOutcome(
            output: "Downloading item 42 ...\nSuccess. Downloaded item 42 to \"/x/42\" (1024 bytes)\n", workshopId: "42"),
                       .downloaded)
        XCTAssertEqual(SteamCmdSession.downloadOutcome(
            output: "Downloading item 42 ...\nERROR! Download item 42 failed (File Not Found).\n", workshopId: "42"),
                       .failed)
        XCTAssertEqual(SteamCmdSession.downloadOutcome(
            output: "ERROR! Download item 42 failed (No Connection).\n", workshopId: "42"), .sessionLost)
        XCTAssertEqual(SteamCmdSession.downloadOutcome(output: "ERROR! Not logged on.\n", workshopId: "42"), .sessionLost)
        // Another item's result says nothing about this one.
        XCTAssertEqual(SteamCmdSession.downloadOutcome(
            output: "Success. Downloaded item 420 to \"/x/420\" (1 bytes)\n", workshopId: "42"), .sessionLost)
    }

    func testDownloadsShareOneSteamCmdAndLogin() throws {
        let launcher = FakeSteamCmdLauncher()
        let session = SteamCmdSession(launcher: launcher, timer: FakeSessionTimer())

        let first = try download("1", in: session)
        let second = try download("2", in: session)
        let third = try download("3", in: session)

        XCTAssertEqual(launcher.launches, 1)
        XCTAssertEqual(launcher.processes[0].lines.filter { $0.hasPrefix("login") }, [#"login "tester""#])
        XCTAssertEqual(launcher.processes[0].lines.first, "@NoPromptForPassword 1")
        XCTAssertTrue(first.output.contains("Logging in user"), "the first download carries the login's output")
        XCTAssertFalse(second.output.contains("Logging in user"))
        for (id, run) in [("1", first), ("2", second), ("3", third)] {
            XCTAssertEqual(SteamCmdSession.downloadOutcome(output: run.output, workshopId: id), .downloaded)
            XCTAssertEqual(run.exitCode, 0)
        }
        XCTAssertTrue(session.isRunning)
    }

    func testItemFailureKeepsTheSession() throws {
        let launcher = FakeSteamCmdLauncher()
        launcher.missingItems = ["9"]
        let session = SteamCmdSession(launcher: launcher, timer: FakeSessionTimer())

        let missing = try download("9", in: session)
        XCTAssertTrue(WorkshopItemAvailability.steamCmdReportsNotFound(missing.output))
        let next = try download("1", in: session)

        XCTAssertEqual(launcher.launches, 1, "a refused item is no reason for a new steamcmd")
        XCTAssertEqual(SteamCmdSession.downloadOutcome(output: next.output, workshopId: "1"), .downloaded)
    }

    func testLoginFailureEndsTheSessionWithoutRetrying() throws {
        let launcher = FakeSteamCmdLauncher()
        launcher.loginReply = "Logging in user 'tester' [U:1:1] to Steam Public...FAILED (No cached credentials)\n"
        let session = SteamCmdSession(launcher: launcher, timer: FakeSessionTimer())

        let run = try download("1", in: session)

        XCTAssertEqual(launcher.launches, 1)
        XCTAssertEqual(SteamCmdService.loginOutcome(output: run.output), .failed)
        XCTAssertFalse(launcher.processes[0].lines.contains { $0.hasPrefix("workshop_download_item") })
        XCTAssertEqual(launcher.processes[0].lines.last, "quit")
        XCTAssertFalse(session.isRunning)
    }

    // MARK: - Restarts

    func testTimeoutRetriesOnceInANewSteamCmd() throws {
        let launcher = FakeSteamCmdLauncher()
        launcher.behaviour = { launch in launch == 0 ? .hangsOnDownload : .normal }
        let session = SteamCmdSession(launcher: launcher, timer: FakeSessionTimer())

        let run = try download("1", in: session, timeout: 0.3)

        XCTAssertEqual(launcher.launches, 2)
        XCTAssertEqual(SteamCmdSession.downloadOutcome(output: run.output, workshopId: "1"), .downloaded)
        XCTAssertTrue(launcher.processes[0].lines.contains("quit"), "the stuck steamcmd is told to quit")
    }

    func testCrashMidDownloadRetriesOnceThenGivesUp() throws {
        let launcher = FakeSteamCmdLauncher()
        launcher.behaviour = { _ in .diesOnDownload }
        let session = SteamCmdSession(launcher: launcher, timer: FakeSessionTimer())

        let run = try download("1", in: session)

        XCTAssertEqual(launcher.launches, 2, "one retry, no more")
        XCTAssertEqual(run.exitCode, -1)
        XCTAssertFalse(session.isRunning)
    }

    func testCrashMidDownloadSucceedsOnTheRetry() throws {
        let launcher = FakeSteamCmdLauncher()
        launcher.behaviour = { launch in launch == 0 ? .diesOnDownload : .normal }
        let session = SteamCmdSession(launcher: launcher, timer: FakeSessionTimer())

        let run = try download("1", in: session)

        XCTAssertEqual(launcher.launches, 2)
        XCTAssertEqual(SteamCmdSession.downloadOutcome(output: run.output, workshopId: "1"), .downloaded)
    }

    func testSteamCmdThatDiedWhileIdleIsReplaced() throws {
        let launcher = FakeSteamCmdLauncher()
        let session = SteamCmdSession(launcher: launcher, timer: FakeSessionTimer())
        _ = try download("1", in: session)

        launcher.processes[0].crash()
        let run = try download("2", in: session)

        XCTAssertEqual(launcher.launches, 2)
        XCTAssertEqual(SteamCmdSession.downloadOutcome(output: run.output, workshopId: "2"), .downloaded)
    }

    func testAnotherAccountQuitsTheSessionFirst() throws {
        let launcher = FakeSteamCmdLauncher()
        let session = SteamCmdSession(launcher: launcher, timer: FakeSessionTimer())
        _ = try download("1", in: session)

        _ = try download("2", in: session, account: "someone else")

        XCTAssertEqual(launcher.launches, 2)
        XCTAssertEqual(launcher.processes[0].lines.last, "quit")
        XCTAssertTrue(launcher.processes[0].hasExited)
        XCTAssertTrue(launcher.processes[1].lines.contains(#"login "someone else""#))
    }

    // MARK: - Quitting

    func testQuitsAfterFiveIdleMinutes() throws {
        let launcher = FakeSteamCmdLauncher()
        let timer = FakeSessionTimer()
        let session = SteamCmdSession(launcher: launcher, timer: timer)
        _ = try download("1", in: session)
        _ = try download("2", in: session)
        XCTAssertEqual(timer.delays, [300, 300])

        timer.fire(0) // Scheduled after the first download; the second one came since.
        XCTAssertTrue(session.isRunning)
        timer.fire(1)

        XCTAssertEqual(launcher.processes[0].lines.last, "quit")
        XCTAssertFalse(session.isRunning)
        _ = try download("3", in: session)
        XCTAssertEqual(launcher.launches, 2, "the next download starts a new steamcmd")
    }

    func testEndTerminatesASteamCmdThatIgnoresQuit() throws {
        let launcher = FakeSteamCmdLauncher()
        launcher.behaviour = { _ in .ignoresQuit }
        let timer = FakeSessionTimer()
        let session = SteamCmdSession(launcher: launcher, timer: timer)
        _ = try download("1", in: session)

        session.end(waitingForExit: false)

        XCTAssertEqual(launcher.processes[0].lines.last, "quit")
        XCTAssertFalse(launcher.processes[0].wasTerminated)
        XCTAssertEqual(timer.delays.last, SteamCmdSession.quitGrace)
        timer.fire(timer.delays.count - 1)
        XCTAssertTrue(launcher.processes[0].wasTerminated)
    }

    // MARK: - Service

    @MainActor
    func testServiceRunsQueuedDownloadsInOneSessionAndEndsItOnLogout() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SteamCmdSession-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) } // Test scratch.
        let storage = root.appending(path: "Storage", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let defaultsSuite = "SteamCmdSessionTests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: defaultsSuite) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        let launcher = FakeSteamCmdLauncher()
        launcher.writesItems = true
        let session = SteamCmdSession(launcher: launcher, timer: FakeSessionTimer())
        let service = SteamCmdService(dependencyIndex: WorkshopDependencyIndex(libraryDirectory: { storage }),
                                  runner: SessionKeepingRunner(session: session),
                                  storageDirectory: { storage }, previewCacheRoot: root.appending(path: "Previews"),
                                  downloadedIndex: DownloadedWallpaperIndex(defaults: defaults,
                                                                            libraryDirectory: { storage }),
                                  presentPreview: { _ in }, restoresSession: false)
        service.steamCmdPath = executable.path
        service.steamUsername = "tester"
        service.isLoggedIn = true

        let installed = await withTaskGroup(of: URL?.self) { group in
            for id in ["1", "2", "3"] {
                group.addTask { @MainActor in
                    await withCheckedContinuation { continuation in
                        service.downloadWorkshopItem(workshopId: id) { continuation.resume(returning: $0) }
                    }
                }
            }
            return await group.reduce(into: [URL?]()) { $0.append($1) }
        }

        XCTAssertEqual(Set(installed.compactMap { $0?.lastPathComponent }), ["1", "2", "3"])
        XCTAssertEqual(launcher.launches, 1)
        XCTAssertEqual(launcher.processes[0].lines.filter { $0.hasPrefix("login") }.count, 1)
        service.sessionExpired()
        XCTAssertEqual(launcher.processes[0].lines.last, "quit")
        XCTAssertFalse(session.isRunning)
    }

    /// The real launcher and pipes, with a shell script answering like steamcmd.
    func testProcessLauncherKeepsARealProcessBetweenDownloads() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SteamCmdSessionScript-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) } // Test scratch.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let launches = folder.appending(path: "launches")
        let script = folder.appending(path: "steamcmd")
        try Data("""
        #!/bin/sh
        echo started >> '\(launches.path)'
        printf 'Steam Console Client (fake)\\nSteam>'
        while IFS= read -r line; do
          case "$line" in
            quit) exit 0 ;;
            login*) printf "Logging in user 'tester' [U:1:1] to Steam Public...OK\\nWaiting for user info...OK\\n" ;;
            workshop_download_item*)
              id=$(printf '%s' "$line" | cut -d'"' -f4)
              printf 'Downloading item %s ...\\nSuccess. Downloaded item %s to "/fake" (1 bytes)\\n' "$id" "$id" ;;
          esac
          printf 'Steam>'
        done

        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let session = SteamCmdSession(timer: FakeSessionTimer())

        for id in ["11", "12", "13"] {
            let run = session.download(workshopId: id,
                                       command: try SteamCmdService.workshopDownloadCommand(workshopId: id, validate: true),
                                       setup: try setup(), executable: script, timeout: 10, onOutput: { _ in })
            XCTAssertEqual(SteamCmdSession.downloadOutcome(output: run.output, workshopId: id), .downloaded, run.output)
        }
        session.end(waitingForExit: true)

        XCTAssertEqual(try String(contentsOf: launches, encoding: .utf8), "started\n")
        XCTAssertFalse(session.isRunning)
    }
}

/// A runner that keeps `session`; nothing else runs through it in these tests.
private final class SessionKeepingRunner: SteamCmdRunning {
    let session: SteamCmdSession
    init(session: SteamCmdSession) { self.session = session }

    func makeSession() -> SteamCmdSessionRunning? { session }

    func run(executable: URL, script: SteamCmdScript, timeout: TimeInterval?,
             onOutput: @escaping (String) -> Void) -> SteamCmdRun {
        SteamCmdRun(output: "", exitCode: 1)
    }
}

/// Collects scheduled work for the test to run.
private final class FakeSessionTimer: SteamCmdSessionTimer, @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: [(delay: TimeInterval, action: () -> Void)] = [] // Owned by `lock`.

    var delays: [TimeInterval] { lock.withLock { scheduled.map(\.delay) } }

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        lock.withLock { scheduled.append((delay, action)) }
    }

    func fire(_ index: Int) {
        let action = lock.withLock { scheduled[index].action }
        action()
    }
}

private final class FakeSteamCmdLauncher: SteamCmdProcessLaunching, @unchecked Sendable {
    enum Behaviour {
        case normal
        case hangsOnDownload
        case diesOnDownload
        case ignoresQuit
    }

    private let lock = NSLock()
    private var started: [FakeSteamCmdProcess] = [] // Owned by `lock`.
    var behaviour: (Int) -> Behaviour = { _ in .normal }
    var loginReply = "Logging in user 'tester' [U:1:1] to Steam Public...OK\nWaiting for user info...OK\n"
    var missingItems: Set<String> = []
    /// Whether a download writes the item under `force_install_dir`, as steamcmd does.
    var writesItems = false

    var launches: Int { lock.withLock { started.count } }
    var processes: [FakeSteamCmdProcess] { lock.withLock { started } }

    func launch(executable: URL, onOutput: @escaping (String) -> Void,
                onExit: @escaping () -> Void) throws -> SteamCmdProcess {
        let process: FakeSteamCmdProcess = lock.withLock {
            let process = FakeSteamCmdProcess(behaviour: behaviour(started.count), loginReply: loginReply,
                                              missingItems: missingItems, writesItems: writesItems,
                                              onOutput: onOutput, onExit: onExit)
            started.append(process)
            return process
        }
        process.reply("Steam Console Client (c) Valve Corporation (fake)\n")
        return process
    }
}

/// Answers each line like steamcmd, then prints its prompt; output arrives on a background queue.
private final class FakeSteamCmdProcess: SteamCmdProcess, @unchecked Sendable {
    private let behaviour: FakeSteamCmdLauncher.Behaviour
    private let loginReply: String
    private let missingItems: Set<String>
    private let writesItems: Bool
    private let onOutput: (String) -> Void
    private let onExit: () -> Void
    private let output = DispatchQueue(label: "fake.steamcmd.output")
    private let lock = NSLock()
    // `lock` owns the rest.
    private var received: [String] = []
    private var exited = false
    private var terminated = false
    private var installDirectory: String?

    init(behaviour: FakeSteamCmdLauncher.Behaviour, loginReply: String, missingItems: Set<String>, writesItems: Bool,
         onOutput: @escaping (String) -> Void, onExit: @escaping () -> Void) {
        self.behaviour = behaviour
        self.loginReply = loginReply
        self.missingItems = missingItems
        self.writesItems = writesItems
        self.onOutput = onOutput
        self.onExit = onExit
    }

    var lines: [String] { lock.withLock { received } }
    var hasExited: Bool { lock.withLock { exited } }
    var wasTerminated: Bool { lock.withLock { terminated } }

    func reply(_ text: String) {
        output.async { self.onOutput(text + "\nSteam>") }
    }

    func crash() {
        let exits: Bool = lock.withLock {
            defer { exited = true }
            return !exited
        }
        guard exits else { return }
        let done = DispatchSemaphore(value: 0)
        output.async {
            self.onExit()
            done.signal()
        }
        done.wait()
    }

    func write(_ data: Data) -> Bool {
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard lock.withLock({ () -> Bool in
            guard !exited else { return false }
            received.append(line)
            return true
        }) else { return false }
        // Every argument is quoted, so the odd pieces between quotes are the arguments.
        let pieces = line.components(separatedBy: "\"")
        let arguments = stride(from: 1, to: pieces.count, by: 2).map { pieces[$0] }
        if line == "quit" {
            if behaviour != .ignoresQuit { crash() }
        } else if line.hasPrefix("force_install_dir") {
            lock.withLock { installDirectory = arguments.first }
            reply("")
        } else if line.hasPrefix("login") {
            reply(loginReply)
        } else if line.hasPrefix("workshop_download_item"), let id = arguments.dropFirst().first {
            switch behaviour {
            case .hangsOnDownload: break
            case .diesOnDownload: crash()
            case .normal, .ignoresQuit:
                if missingItems.contains(id) {
                    reply("Downloading item \(id) ...\nERROR! Download item \(id) failed (File Not Found).")
                } else {
                    writeItem(id)
                    reply("Downloading item \(id) ...\nSuccess. Downloaded item \(id) to \"/fake/\(id)\" (10 bytes)")
                }
            }
        } else {
            reply("")
        }
        return true
    }

    private func writeItem(_ id: String) {
        guard writesItems, let installDirectory = lock.withLock({ installDirectory }) else { return }
        let item = WorkshopItemInstaller.contentDirectory(inSteamCmdRoot: URL(fileURLWithPath: installDirectory),
                                                          workshopId: id)
        try? FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try? Data(#"{"type": "scene", "title": "Item \#(id)", "file": "scene.json"}"#.utf8)
            .write(to: item.appending(path: "project.json"))
    }

    func closeInput() {}

    func terminate() {
        lock.withLock { terminated = true }
        crash()
    }
}
