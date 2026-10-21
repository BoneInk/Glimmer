//
//  SteamCmdRunner.swift
//  Open Wallpaper Engine
//
//  Runs one steamcmd session: the script goes to its stdin, and its output is collected (and
//  streamed to the caller, for download progress) until it exits. `SteamCmdService` takes the
//  runner as a dependency, so tests can stand in a fake steamcmd.
//

import Foundation

struct SteamCmdRun {
    let output: String
    let exitCode: Int32
}

/// Stops a running steamcmd from another thread. One token per run.
final class SteamCmdCancellation: @unchecked Sendable {
    // `lock` owns `isCancelled` and `onCancel`.
    private let lock = NSLock()
    private var cancelled = false
    private var onCancel: (() -> Void)?

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        let action: (() -> Void)? = lock.withLock {
            cancelled = true
            defer { onCancel = nil }
            return onCancel
        }
        action?()
    }

    /// Runs `action` on cancellation, or right away when already cancelled.
    func setCancelAction(_ action: (() -> Void)?) {
        let runNow: Bool = lock.withLock {
            onCancel = cancelled ? nil : action
            return cancelled
        }
        if runNow { action?() }
    }
}

protocol SteamCmdRunning {
    /// Runs the steamcmd at `executable` with `script` on its stdin and blocks until it exits, or
    /// until `timeout` passes (nil waits for as long as it takes). `onOutput` receives the output as
    /// it arrives, on a background queue.
    func run(executable: URL, script: SteamCmdScript, timeout: TimeInterval?,
             onOutput: @escaping (String) -> Void) -> SteamCmdRun

    /// As above; `cancellation` terminates steamcmd.
    func run(executable: URL, script: SteamCmdScript, timeout: TimeInterval?, cancellation: SteamCmdCancellation,
             onOutput: @escaping (String) -> Void) -> SteamCmdRun

    /// A steamcmd kept running between Workshop downloads, or nil to run each download alone.
    func makeSession() -> SteamCmdSessionRunning?
}

extension SteamCmdRunning {
    func makeSession() -> SteamCmdSessionRunning? { nil }

    /// A runner that can't stop steamcmd early runs it to the end.
    func run(executable: URL, script: SteamCmdScript, timeout: TimeInterval?, cancellation: SteamCmdCancellation,
             onOutput: @escaping (String) -> Void) -> SteamCmdRun {
        run(executable: executable, script: script, timeout: timeout, onOutput: onOutput)
    }

    func run(executable: URL, script: SteamCmdScript, timeout: TimeInterval?) -> SteamCmdRun {
        run(executable: executable, script: script, timeout: timeout, onOutput: { _ in })
    }
}

/// Runs the real steamcmd as a subprocess.
struct ProcessSteamCmdRunner: SteamCmdRunning {
    func makeSession() -> SteamCmdSessionRunning? { SteamCmdSession() }

    func run(executable: URL, script: SteamCmdScript, timeout: TimeInterval?,
             onOutput: @escaping (String) -> Void) -> SteamCmdRun {
        run(executable: executable, script: script, timeout: timeout, cancellation: SteamCmdCancellation(),
            onOutput: onOutput)
    }

    func run(executable: URL, script: SteamCmdScript, timeout: TimeInterval?, cancellation: SteamCmdCancellation,
             onOutput: @escaping (String) -> Void) -> SteamCmdRun {
        let process = Process()
        let outputPipe = Pipe()
        let inputPipe = Pipe()
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.arguments = []
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        // Read the pipe while steamcmd runs, so a full pipe buffer can't block it.
        var outputData = Data()
        let readQueue = DispatchQueue(label: "steamcmd.pipe.read")
        let handle = outputPipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else { return }
            readQueue.sync { outputData.append(data) }
            onOutput(String(decoding: data, as: UTF8.self))
        }

        do {
            try process.run()
        } catch {
            handle.readabilityHandler = nil
            return SteamCmdRun(output: String(localized: "Failed to run steamcmd: \(error.localizedDescription)",
                                                comment: "steamcmd is a program name; %@ is the system's reason"),
                               exitCode: -1)
        }
        cancellation.setCancelAction { process.terminate() }
        defer { cancellation.setCancelAction(nil) }
        Self.write(script, to: inputPipe)

        let exited = DispatchGroup()
        exited.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            exited.leave()
        }
        if let timeout, exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            handle.readabilityHandler = nil
            return SteamCmdRun(output: "steamcmd timed out after \(Int(timeout))s", exitCode: -1)
        }
        exited.wait()

        handle.readabilityHandler = nil
        let remaining = handle.readDataToEndOfFile()
        if !remaining.isEmpty { onOutput(String(decoding: remaining, as: UTF8.self)) }
        return readQueue.sync {
            outputData.append(remaining)
            return SteamCmdRun(output: String(decoding: outputData, as: UTF8.self), exitCode: process.terminationStatus)
        }
    }

    /// Writes the whole script and closes stdin, so steamcmd reads EOF after `quit`.
    private static func write(_ script: SteamCmdScript, to pipe: Pipe) {
        let handle = pipe.fileHandleForWriting
        // If steamcmd already exited, the write must fail with EPIPE rather than kill the app.
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try handle.write(contentsOf: script.standardInput)
            try handle.close()
        } catch {
            // steamcmd exited before reading its input; its output says why.
            OWELog.error(.workshop, "Can't write the steamcmd script: \(error)")
        }
    }
}
