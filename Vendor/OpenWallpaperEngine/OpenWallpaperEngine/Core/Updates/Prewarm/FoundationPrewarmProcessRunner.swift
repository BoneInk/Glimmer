import Foundation

/// Runs prewarm helpers with `Process`, at background priority.
final class FoundationPrewarmProcessRunner: PrewarmProcessRunner {
    enum RunError: Error, CustomStringConvertible {
        case exited(status: Int32)
        case timedOut(seconds: TimeInterval)

        var description: String {
            switch self {
            case .exited(let status): return "exited with status \(status)"
            case .timedOut(let seconds): return "didn't finish within \(Int(seconds)) s"
            }
        }
    }

    func output(of executable: URL, arguments: [String], environment: [String: String],
                timeout: TimeInterval, completion: @escaping @MainActor (Result<Data, Error>) -> Void) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.qualityOfService = .utility
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let state = OutputState()
        process.terminationHandler = { process in
            let data: Data = stdout.fileHandleForReading.readDataToEndOfFile()
            let status: Int32 = process.terminationStatus
            let timedOut: Bool = state.timedOut
            DispatchQueue.main.async {
                if timedOut {
                    completion(.failure(RunError.timedOut(seconds: timeout)))
                } else if status != 0 {
                    completion(.failure(RunError.exited(status: status)))
                } else {
                    completion(.success(data))
                }
            }
        }
        do {
            try process.run()
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
            return
        }
        let pid: Int32 = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning, process.processIdentifier == pid else { return }
            state.timedOut = true
            process.terminate()
        }
    }

    func start(_ executable: URL, arguments: [String], environment: [String: String],
               exited: @escaping @MainActor (Int32, Process.TerminationReason) -> Void) throws -> PrewarmProcess {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        // Background: the running wallpaper keeps its frame rate while the new build compiles.
        process.qualityOfService = .background
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            let status: Int32 = process.terminationStatus
            let reason: Process.TerminationReason = process.terminationReason
            DispatchQueue.main.async { exited(status, reason) }
        }
        try process.run()
        return RunningProcess(process: process)
    }

    /// Whether `output`'s timer terminated the process. `lock` owns `flag`.
    private final class OutputState: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var timedOut: Bool {
            get { lock.withLock { flag } }
            set { lock.withLock { flag = newValue } }
        }
    }

    private final class RunningProcess: PrewarmProcess {
        let process: Process
        init(process: Process) { self.process = process }
        var processIdentifier: Int32 { process.processIdentifier }
        func terminate() {
            // `Process.terminate` signals this process's own pid only.
            if process.isRunning { process.terminate() }
        }
    }
}
