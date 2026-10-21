import Foundation

/// Starts a helper run of this app itself (`HelperRunCommand`): this app's executable
/// (`AppRelauncher.helperExecutable`) with the run's arguments, in this process's isolated state
/// (`OWE_ISOLATED_STATE`, `AppStorageLocation`), its standard error discarded. Callers attach the
/// standard input and output they read.
enum HelperProcess {
    /// A process for the helper run `arguments` name at `qos`, not yet started; nil when this
    /// app's executable is unknown.
    static func make(_ arguments: [String], qos: QualityOfService) -> Process? {
        guard let executable = AppRelauncher.helperExecutable else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        if let tag = AppStorageLocation.current.isolationTag { environment[AppStorageLocation.environmentKey] = tag }
        process.environment = environment
        process.qualityOfService = qos
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// Starts `process` and returns its exit status once it exited, after `exited` ran (on the
    /// process's termination thread); cancelling the task terminates it. Throws when it can't start.
    static func run(_ process: Process, isolation: isolated (any Actor)? = #isolation,
                    exited: @escaping @Sendable () -> Void = {}) async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in
                    exited()
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
