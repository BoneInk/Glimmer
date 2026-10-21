import Foundation

/// Starts the helper processes of an update's shader prewarm. A protocol so tests drive the
/// prewarm without running anything.
protocol PrewarmProcessRunner: AnyObject {
    /// Runs `executable` to completion, at most `timeout`, and returns its standard output.
    /// Throws when it can't start, exits unsuccessfully or runs over (it is then terminated).
    /// `completion` runs on the main queue.
    func output(of executable: URL, arguments: [String], environment: [String: String],
                timeout: TimeInterval, completion: @escaping @MainActor (Result<Data, Error>) -> Void)

    /// Starts `executable` in the background; `exited` runs on the main queue with its exit
    /// status (a crash or termination included).
    func start(_ executable: URL, arguments: [String], environment: [String: String],
               exited: @escaping @MainActor (_ status: Int32, _ reason: Process.TerminationReason) -> Void) throws -> PrewarmProcess
}

/// A started helper process.
protocol PrewarmProcess: AnyObject {
    var processIdentifier: Int32 { get }
    /// Terminates exactly this process (SIGTERM).
    func terminate()
}
