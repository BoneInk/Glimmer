import AppKit
import Darwin

/// Settings › Restart after crashing: a small watcher process that opens the app again when it
/// crashes (`CrashRelaunchPolicy`).
///
/// The watcher is a copy of the app's own executable run with `--crash-watcher`, handled in
/// `AppMain` before any app lifecycle: no Dock icon, no windows, no playback. The app holds the
/// write end of a pipe to the watcher's standard input and writes a line before it goes away
/// cleanly: `quit` (from `applicationWillTerminate`, which a normal quit, SIGTERM, a logout and an
/// update relaunch all reach) or `stop` (the setting turned off). If the pipe closes with no line,
/// the app crashed or was killed, and the watcher opens it again once the rate limit allows.
/// Each launch starts its own watcher; the old one exits after relaunching.
///
/// Only the user's own launch has a watcher (`AppHostContext.shouldWatchForCrashes`): a test host,
/// a preview, a run under a debugger and an isolated copy never start one. The watcher inherits
/// the app's environment and checks it again before relaunching, and the relaunch carries the
/// app's isolated state (`AppRelauncher.configuration`), so it can't open a copy that runs on
/// other state than the app it watched.
///
/// `SafeRestart` still decides what comes back: after an unclean exit the wallpapers that were
/// showing stay unloaded, so a crashing wallpaper is never replayed by the relaunch.
@MainActor
final class CrashWatcher {
    static let argument = "--crash-watcher"
    static let quitMessage = "quit"
    static let stopMessage = "stop"

    private var process: Process?
    private var pipe: Pipe?
    private let host: AppHostContext

    init(host: AppHostContext = .current) {
        self.host = host
    }

    var isRunning: Bool { process?.isRunning ?? false }

    /// Starts or stops the watcher for the setting's value: at launch, and on every change.
    func update(enabled: Bool) {
        if CrashRelaunchPolicy.shouldWatch(enabled: enabled, host: host) {
            start()
        } else {
            send(Self.stopMessage)
        }
    }

    /// Call from `applicationWillTerminate`: the app is quitting on purpose.
    func applicationWillTerminate() {
        send(Self.quitMessage)
    }

    private func start() {
        guard !isRunning, let executable = AppRelauncher.helperExecutable else { return }
        let pipe = Pipe()
        // The watcher may be gone (killed): a write then fails instead of raising SIGPIPE here.
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let process = Process()
        process.executableURL = executable
        process.arguments = [Self.argument, Bundle.main.bundleURL.path(percentEncoded: false),
                             AppStorageLocation.current.supportDirectory.path(percentEncoded: false)]
        var environment = ProcessInfo.processInfo.environment
        environment[AppStorageLocation.environmentKey] = host.isolationTag
        process.environment = environment
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            OWELog.error(.app, "Can't start the crash watcher: \(error)")
            return
        }
        // Only the app holds the write end; the watcher sees EOF when the app goes away.
        try? pipe.fileHandleForReading.close() // Optional: the child has its own copy.
        self.pipe = pipe
        self.process = process
        OWELog.info(.app, "Crash watcher started (pid \(process.processIdentifier))")
    }

    private func send(_ message: String) {
        guard let pipe else { return }
        let fd = pipe.fileHandleForWriting.fileDescriptor
        let line = Array((message + "\n").utf8)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } // Optional: the watcher may be gone.
        try? pipe.fileHandleForWriting.close() // Optional: already closed if the watcher is gone.
        self.pipe = nil
        process = nil
    }

    // MARK: - The watcher process

    /// Runs the watcher when `arguments` ask for it and returns its exit status, or nil otherwise.
    /// Blocks until the app says it quits or goes away.
    nonisolated static func runIfRequested(arguments: [String]) -> Int32? {
        guard let index = arguments.firstIndex(of: argument), arguments.count > index + 2 else { return nil }
        let bundle = URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
        let history = CrashRelaunchHistory(directory: URL(filePath: arguments[index + 2], directoryHint: .isDirectory))
        setpriority(PRIO_PROCESS, 0, 10)
        // A terminated watcher (logout, shutdown) ends with the default SIGTERM action: no relaunch.
        let ending = readEnding(from: FileHandle.standardInput)
        // The watcher's own context: the app's environment, which it inherits.
        let host = AppHostContext.detect(environment: ProcessInfo.processInfo.environment, arguments: arguments,
                                         xcTestLoaded: NSClassFromString("XCTestCase") != nil,
                                         loadedBundlePaths: Bundle.allBundles.map(\.bundlePath), isDebugged: false)
        let decision = CrashRelaunchPolicy.decide(ending, host: host, history: history.load(), now: Date())
        switch decision {
        case .stay:
            return 0
        case .rateLimited:
            OWELog.error(.app, "Open Wallpaper Engine crashed again; not restarting it (\(CrashRelaunchPolicy.maxRelaunches) restarts in 5 minutes)")
            return 0
        case .relaunch(let dates):
            history.save(dates)
            OWELog.info(.app, "Open Wallpaper Engine crashed; restarting it")
            // Lets the crashed process finish going away so the new one isn't refused as a duplicate.
            Thread.sleep(forTimeInterval: 1)
            return relaunch(bundle, host: host) ? 0 : 1
        }
    }

    /// Opens the app at `bundle` through LaunchServices in `host`'s isolated state, and waits.
    private nonisolated static func relaunch(_ bundle: URL, host: AppHostContext) -> Bool {
        let configuration = AppRelauncher.configuration(arguments: [], host: host, newInstance: false)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error? // Written by the completion before `done` is signalled.
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, error in
            failure = error
            done.signal()
        }
        done.wait()
        if let failure {
            OWELog.error(.app, "Can't restart Open Wallpaper Engine: \(failure)")
            return false
        }
        return true
    }

    /// Reads the app's lines until it says it quits, says stop, or the pipe closes.
    nonisolated static func readEnding(from handle: FileHandle) -> CrashRelaunchPolicy.Ending {
        var buffer = Data()
        while true {
            let chunk = handle.availableData // Blocks; empty at EOF.
            if chunk.isEmpty { return ending(for: buffer) }
            buffer.append(chunk)
            let ended = ending(for: buffer)
            if ended != .vanished { return ended }
        }
    }

    /// The ending the lines received so far mean; `.vanished` while nothing decisive arrived.
    nonisolated static func ending(for data: Data) -> CrashRelaunchPolicy.Ending {
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        if lines.contains(quitMessage) { return .quit }
        if lines.contains(stopMessage) { return .stopWatching }
        return .vanished
    }
}
