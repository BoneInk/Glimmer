import Foundation
import Darwin

/// A connection to one shader compile helper (`ShaderCompileHelperServer`): sends a request frame
/// and waits for the response frame. Tests substitute an in-memory one.
protocol ShaderCompileHelperChannel: AnyObject {
    /// Sends `request` (a whole frame) and returns the response's payload. Throws
    /// `ShaderCompileHelperChannelError` when the helper is gone or doesn't answer in `timeout`;
    /// the channel is unusable after that.
    func exchange(_ request: Data, timeout: TimeInterval) throws -> Data
    /// Stops the helper; idempotent.
    func close()
}

enum ShaderCompileHelperChannelError: Error, CustomStringConvertible {
    case launchFailed(String)
    /// The helper exited or crashed (its stdout closed).
    case exited(String)
    /// No answer within the timeout; the helper was killed.
    case unresponsive(TimeInterval)
    case malformedResponse(String)

    var description: String {
        switch self {
        case .launchFailed(let reason): return "the helper could not start: \(reason)"
        case .exited(let status): return "the helper exited (\(status))"
        case .unresponsive(let seconds): return "the helper did not answer in \(Int(seconds.rounded())) s"
        case .malformedResponse(let reason): return "malformed response: \(reason)"
        }
    }
}

/// A helper process: this app's executable (`AppRelauncher.helperExecutable`) with
/// `--shader-compile-helper`, in this process's isolated state, so an isolated copy of the app
/// starts its own helper and the helper writes its crash guard into that copy's caches.
///
/// Thread-safe for one caller at a time (`HelperShaderCompiler` serializes); `lock` owns `buffer`
/// and `ended`.
final class ShaderCompileHelperProcess: ShaderCompileHelperChannel {
    private let process = Process()
    private let requests: FileHandle
    private let responses: FileHandle
    private let lock = NSLock()
    private let arrived = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var ended = false

    init(executable: URL, qos: QualityOfService,
         isolationTag: String? = AppStorageLocation.current.isolationTag) throws {
        let input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = [ShaderCompileHelperServer.argument]
        process.environment = Self.environment(ProcessInfo.processInfo.environment,
                                               isolationTag: isolationTag)
        process.qualityOfService = qos
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        requests = input.fileHandleForWriting
        responses = output.fileHandleForReading
        // A write to a helper that died fails with EPIPE instead of killing the app with SIGPIPE.
        _ = fcntl(requests.fileDescriptor, F_SETNOSIGPIPE, 1)
        responses.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            self.lock.withLock {
                if chunk.isEmpty { self.ended = true } else { self.buffer.append(chunk) }
            }
            if chunk.isEmpty { handle.readabilityHandler = nil }
            self.arrived.signal()
        }
        do {
            try process.run()
        } catch {
            responses.readabilityHandler = nil
            throw ShaderCompileHelperChannelError.launchFailed("\(error)")
        }
        OWELog.info(.shader, "Started the shader compile helper (pid \(process.processIdentifier))")
    }

    deinit { close() }

    /// The parent's environment for the helper: the isolated-state tag, and without the test
    /// runner's injection (tests are hosted in the app, and the helper is a plain app run).
    static func environment(_ parent: [String: String], isolationTag: String?) -> [String: String] {
        var environment = parent
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier",
                    "XCInjectBundleInto", "DYLD_INSERT_LIBRARIES"] {
            environment[key] = nil
        }
        environment[AppStorageLocation.environmentKey] = isolationTag
        return environment
    }

    func exchange(_ request: Data, timeout: TimeInterval) throws -> Data {
        do {
            try requests.write(contentsOf: request)
        } catch {
            throw ShaderCompileHelperChannelError.exited(exitDescription(writeError: error))
        }
        let deadline = DispatchTime.now() + timeout
        while true {
            let (payload, ended): (Data?, Bool) = try lock.withLock {
                (try ShaderCompileHelperFrame.take(from: &buffer), self.ended)
            }
            if let payload { return payload }
            if ended { throw ShaderCompileHelperChannelError.exited(exitDescription(writeError: nil)) }
            if arrived.wait(timeout: deadline) == .timedOut {
                close()
                throw ShaderCompileHelperChannelError.unresponsive(timeout)
            }
        }
    }

    func close() {
        responses.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        // Optional: closing an already-closed pipe end has nothing to report.
        try? requests.close()
    }

    private func exitDescription(writeError: Error?) -> String {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        let reason = process.terminationReason == .uncaughtSignal ? "signal" : "status"
        let suffix = writeError.map { ", write failed: \($0)" } ?? ""
        return "\(reason) \(process.terminationStatus)\(suffix)"
    }
}
