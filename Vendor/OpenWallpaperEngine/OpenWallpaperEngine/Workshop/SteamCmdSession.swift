//
//  SteamCmdSession.swift
//  Open Wallpaper Engine
//
//  One steamcmd kept running and logged in between Workshop downloads, so only the first of a run
//  of downloads pays for starting steamcmd and logging in. Commands go to its stdin one at a time;
//  each ends when steamcmd prints its `Steam>` prompt again. The session quits after five idle
//  minutes, when its owner ends it (logout, another account, other steamcmd work, app quit), and
//  when steamcmd dies, loses its connection or stops answering; the item it was on then gets one
//  more try in a new steamcmd.
//

import Foundation

/// A running steamcmd whose stdin stays open.
protocol SteamCmdProcess: AnyObject {
    /// Writes `data` to steamcmd's stdin; false once steamcmd no longer reads it.
    func write(_ data: Data) -> Bool
    /// Closes stdin, after `quit`.
    func closeInput()
    func terminate()
}

protocol SteamCmdProcessLaunching {
    /// Starts the steamcmd at `executable` with no arguments. `onOutput` receives its output as it
    /// arrives and `onExit` runs once it exited, both on a background queue.
    func launch(executable: URL, onOutput: @escaping (String) -> Void,
                onExit: @escaping () -> Void) throws -> SteamCmdProcess
}

/// Runs the session's delayed work (the idle quit, the wait before terminating a steamcmd that
/// didn't quit); tests run it by hand.
protocol SteamCmdSessionTimer {
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void)
}

struct DispatchSteamCmdSessionTimer: SteamCmdSessionTimer {
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: action)
    }
}

protocol SteamCmdSessionRunning: AnyObject {
    /// Downloads one Workshop item with `command` in the steamcmd that ran `setup` (the commands up
    /// to and including `login`), starting one first when none runs or the running one had another
    /// setup. Blocks until steamcmd reports the item, or until `timeout` passes (nil: a long
    /// backstop). `onOutput` receives the output as it arrives, on a background queue.
    func download(workshopId: String, command: SteamCmdScript, setup: SteamCmdScript, executable: URL,
                  timeout: TimeInterval?, onOutput: @escaping (String) -> Void) -> SteamCmdRun

    /// Quits the kept steamcmd, if one runs. `waitingForExit` blocks until it exited (or was
    /// terminated), so the next steamcmd never starts beside it.
    func end(waitingForExit: Bool)
}

final class SteamCmdSession: SteamCmdSessionRunning, @unchecked Sendable {
    /// What steamcmd said about one `workshop_download_item`.
    enum DownloadOutcome: Equatable {
        case downloaded
        /// steamcmd refused or failed the item (removed, private, no access); the session is fine.
        case failed
        /// The session can't download any more: not logged on, no connection, or no word on the item.
        case sessionLost
    }

    static let prompt = "Steam>"
    static let idleTimeout: TimeInterval = 5 * 60
    /// The first prompt can wait for steamcmd updating itself.
    static let startTimeout: TimeInterval = 10 * 60
    static let loginTimeout: TimeInterval = 2 * 60
    /// One item when the caller gives no timeout; an item taking longer counts as stuck.
    static let itemTimeout: TimeInterval = 2 * 60 * 60
    /// How long `quit` gets before steamcmd is terminated.
    static let quitGrace: TimeInterval = 5

    /// Reasons in steamcmd's `ERROR! Download item <id> failed (<reason>)` that mean the session,
    /// not the item, is the problem.
    private static let sessionLostReasons = ["No Connection", "Not Logged On", "NoConnection", "NotLoggedOn",
                                             "Service Unavailable", "ServiceUnavailable"]

    private let launcher: SteamCmdProcessLaunching
    private let timer: SteamCmdSessionTimer
    private let idleTimeout: TimeInterval

    /// Held for a whole download, so one command runs at a time. Taken before `lock`.
    private let commandLock = NSLock()
    // `lock` owns `live`, `uses` and `endedDuringDownload`.
    private let lock = NSLock()
    private var live: LiveSteamCmd?
    /// Counts finished downloads; an idle quit scheduled after one runs only if no other followed.
    private var uses = 0
    /// Set by `end`: the download running then fails rather than retrying in a new steamcmd.
    private var endedDuringDownload = false

    init(launcher: SteamCmdProcessLaunching = ProcessSteamCmdLauncher(),
         timer: SteamCmdSessionTimer = DispatchSteamCmdSessionTimer(),
         idleTimeout: TimeInterval = SteamCmdSession.idleTimeout) {
        self.launcher = launcher
        self.timer = timer
        self.idleTimeout = idleTimeout
    }

    /// Whether a steamcmd is kept running.
    var isRunning: Bool { lock.withLock { live.map { !$0.hasExited } ?? false } }

    func download(workshopId: String, command: SteamCmdScript, setup: SteamCmdScript, executable: URL,
                  timeout: TimeInterval?, onOutput: @escaping (String) -> Void) -> SteamCmdRun {
        commandLock.lock()
        defer { commandLock.unlock() }
        lock.withLock { endedDuringDownload = false }
        let key = LiveSteamCmd.Key(executable: executable.path, setup: setup.lines)
        var isRetry = false
        while true {
            switch attempt(workshopId: workshopId, command: command, key: key, executable: executable,
                           timeout: timeout ?? Self.itemTimeout, onOutput: onOutput) {
            case .finished(let run):
                scheduleIdleQuit()
                return run
            case .lost(let run):
                tearDown(waitingForExit: true)
                if isRetry || lock.withLock({ endedDuringDownload }) { return run }
                OWELog.info(.workshop, "steamcmd session lost on Workshop item \(workshopId); retrying in a new session")
                isRetry = true
            }
        }
    }

    func end(waitingForExit: Bool) {
        lock.withLock { endedDuringDownload = true }
        tearDown(waitingForExit: waitingForExit)
    }

    /// What steamcmd printed for `workshop_download_item` on `workshopId`, up to its next prompt.
    static func downloadOutcome(output: String, workshopId: String) -> DownloadOutcome {
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines {
            if line.hasPrefix("Success. Downloaded item \(workshopId) ") { return .downloaded }
            if line.hasPrefix("ERROR! Download item \(workshopId) failed") {
                return sessionLostReasons.contains(where: line.contains) ? .sessionLost : .failed
            }
        }
        // The prompt came back with no word on the item: steamcmd isn't logged on or connected.
        return .sessionLost
    }

    // MARK: - Running commands

    private enum Attempt {
        case finished(SteamCmdRun)
        /// The session broke; the output so far, for the error when no retry follows.
        case lost(SteamCmdRun)
    }

    private func attempt(workshopId: String, command: SteamCmdScript, key: LiveSteamCmd.Key, executable: URL,
                         timeout: TimeInterval, onOutput: @escaping (String) -> Void) -> Attempt {
        var output = ""
        let steamCmd: LiveSteamCmd
        if let running = lock.withLock({ live }), running.key == key, !running.hasExited {
            steamCmd = running
        } else {
            // A steamcmd with another account, install folder or executable quits first.
            tearDown(waitingForExit: true)
            switch start(key: key, executable: executable, onOutput: onOutput) {
            case .started(let started, let startOutput):
                steamCmd = started
                output = startOutput
            case .finished(let run):
                return .finished(run)
            case .lost(let run):
                return .lost(run)
            }
        }
        for line in command.lines {
            switch steamCmd.send(line, timeout: timeout, onOutput: onOutput) {
            case .prompt(let text):
                output += text
            case .exited(let text):
                return .lost(SteamCmdRun(output: output + text, exitCode: -1))
            case .timedOut(let text):
                return .lost(SteamCmdRun(output: output + text + "\nsteamcmd timed out after \(Int(timeout))s",
                                         exitCode: -1))
            }
        }
        let run = SteamCmdRun(output: output, exitCode: 0)
        return Self.downloadOutcome(output: output, workshopId: workshopId) == .sessionLost ? .lost(run) : .finished(run)
    }

    private enum Start {
        case started(LiveSteamCmd, output: String)
        /// steamcmd ran but didn't log in (no cached login); not worth another try.
        case finished(SteamCmdRun)
        case lost(SteamCmdRun)
    }

    /// Launches steamcmd and runs `key.setup` in it, one command per prompt.
    private func start(key: LiveSteamCmd.Key, executable: URL, onOutput: @escaping (String) -> Void) -> Start {
        let steamCmd = LiveSteamCmd(key: key)
        do {
            steamCmd.process = try launcher.launch(executable: executable,
                                                   onOutput: { [weak steamCmd] in steamCmd?.received($0) },
                                                   onExit: { [weak steamCmd] in steamCmd?.didExit() })
        } catch {
            return .finished(SteamCmdRun(output: String(localized: "Failed to run steamcmd: \(error.localizedDescription)",
                                                        comment: "steamcmd is a program name; %@ is the system's reason"),
                                         exitCode: -1))
        }
        // Kept before the login, so `end` reaches a steamcmd still starting.
        lock.withLock { live = steamCmd }
        var output = ""
        let steps: [(line: String?, timeout: TimeInterval)] = [(nil, Self.startTimeout)]
            + key.setup.map { ($0, $0.hasPrefix("login") ? Self.loginTimeout : Self.startTimeout) }
        for step in steps {
            switch steamCmd.send(step.line, timeout: step.timeout, onOutput: onOutput) {
            case .prompt(let text):
                output += text
            case .exited(let text):
                return .lost(SteamCmdRun(output: output + text, exitCode: -1))
            case .timedOut(let text):
                return .lost(SteamCmdRun(output: output + text + "\nsteamcmd timed out after \(Int(step.timeout))s",
                                         exitCode: -1))
            }
        }
        guard SteamCmdService.loginOutcome(output: output) == .loggedIn else {
            tearDown(waitingForExit: true)
            return .finished(SteamCmdRun(output: output, exitCode: 0))
        }
        OWELog.info(.workshop, "steamcmd session started")
        return .started(steamCmd, output: output)
    }

    // MARK: - Quitting

    private func scheduleIdleQuit() {
        let use: Int = lock.withLock {
            uses += 1
            return uses
        }
        timer.schedule(after: idleTimeout) { [weak self] in
            guard let self, self.commandLock.try() else { return } // A download runs; it schedules its own.
            defer { self.commandLock.unlock() }
            guard self.lock.withLock({ self.uses == use && self.live != nil }) else { return }
            OWELog.info(.workshop, "steamcmd session idle for \(Int(self.idleTimeout))s; quitting")
            self.tearDown(waitingForExit: false)
        }
    }

    /// Sends `quit` to the kept steamcmd and terminates it if it doesn't exit within `quitGrace`.
    private func tearDown(waitingForExit: Bool) {
        let steamCmd: LiveSteamCmd? = lock.withLock {
            defer { live = nil }
            return live
        }
        guard let steamCmd else { return }
        if !steamCmd.hasExited {
            _ = steamCmd.process?.write(Data("quit\n".utf8))
        }
        steamCmd.process?.closeInput()
        if waitingForExit {
            if !steamCmd.waitForExit(timeout: Self.quitGrace) { steamCmd.process?.terminate() }
        } else {
            timer.schedule(after: Self.quitGrace) {
                if !steamCmd.hasExited { steamCmd.process?.terminate() }
            }
        }
    }
}

/// One launched steamcmd and the output of the command it is on.
private final class LiveSteamCmd: @unchecked Sendable {
    struct Key: Equatable {
        let executable: String
        /// The setup commands, account name included; kept in memory only.
        let setup: [String]
    }

    enum Reply {
        /// The output up to the prompt.
        case prompt(String)
        case exited(String)
        case timedOut(String)
    }

    let key: Key
    /// Set once right after launch, before any command.
    var process: SteamCmdProcess?
    // `lock` owns `buffer`, `exited` and `listener`.
    private let lock = NSLock()
    private var buffer = ""
    private var exited = false
    private var listener: ((String) -> Void)?
    /// Signalled on every chunk of output and on exit.
    private let changed = DispatchSemaphore(value: 0)

    init(key: Key) {
        self.key = key
    }

    var hasExited: Bool { lock.withLock { exited } }

    func received(_ chunk: String) {
        let listener: ((String) -> Void)? = lock.withLock {
            buffer += chunk
            return self.listener
        }
        listener?(chunk)
        changed.signal()
    }

    func didExit() {
        lock.withLock { exited = true }
        changed.signal()
    }

    /// Sends `line` (nil: nothing, for the first prompt) and waits for the prompt after its output.
    func send(_ line: String?, timeout: TimeInterval, onOutput: @escaping (String) -> Void) -> Reply {
        // steamcmd waits at a prompt, so nothing arrives between the last one and this command.
        lock.withLock {
            if line != nil { buffer = "" }
            listener = onOutput
        }
        defer { lock.withLock { listener = nil } }
        if let line, process?.write(Data((line + "\n").utf8)) != true {
            return .exited(lock.withLock { buffer })
        }
        let deadline = DispatchTime.now() + timeout
        while true {
            let (reply, text, hasExited): (String?, String, Bool) = lock.withLock {
                guard let prompt = buffer.range(of: SteamCmdSession.prompt) else { return (nil, buffer, exited) }
                defer { buffer = String(buffer[prompt.upperBound...]) }
                return (String(buffer[..<prompt.lowerBound]), buffer, exited)
            }
            if let reply { return .prompt(reply) }
            if hasExited { return .exited(text) }
            if changed.wait(timeout: deadline) == .timedOut { return .timedOut(lock.withLock { buffer }) }
        }
    }

    /// Whether steamcmd exited within `timeout`.
    func waitForExit(timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        while !hasExited {
            if changed.wait(timeout: deadline) == .timedOut { return hasExited }
        }
        return true
    }
}

/// Launches the real steamcmd as a subprocess with pipes for stdin and output.
struct ProcessSteamCmdLauncher: SteamCmdProcessLaunching {
    func launch(executable: URL, onOutput: @escaping (String) -> Void,
                onExit: @escaping () -> Void) throws -> SteamCmdProcess {
        let process = Process()
        let outputPipe = Pipe()
        let inputPipe = Pipe()
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.arguments = []
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let handle = outputPipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }
            onOutput(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { _ in onExit() }
        do {
            try process.run()
        } catch {
            handle.readabilityHandler = nil
            throw error
        }
        // If steamcmd already exited, a write must fail with EPIPE rather than kill the app.
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        return RunningSteamCmd(process: process, input: inputPipe.fileHandleForWriting)
    }
}

private final class RunningSteamCmd: SteamCmdProcess, @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    // `lock` owns `inputClosed`.
    private let lock = NSLock()
    private var inputClosed = false

    init(process: Process, input: FileHandle) {
        self.process = process
        self.input = input
    }

    func write(_ data: Data) -> Bool {
        lock.withLock {
            guard !inputClosed else { return false }
            do {
                try input.write(contentsOf: data)
                return true
            } catch {
                return false
            }
        }
    }

    func closeInput() {
        lock.withLock {
            guard !inputClosed else { return }
            inputClosed = true
            try? input.close() // Already closed when steamcmd exited first; nothing to undo.
        }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
