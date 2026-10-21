import Foundation
@testable import OpenWallpaperEngine

/// Runs nothing: records what the prewarm asks for and answers as a test says.
final class FakePrewarmProcessRunner: PrewarmProcessRunner {
    final class Child: PrewarmProcess {
        let processIdentifier: Int32 = 4242
        var terminateCount = 0
        func terminate() { terminateCount += 1 }
    }

    /// What `--print-shader-cache-key` returns.
    var keyOutput: Result<Data, Error> = .failure(FoundationPrewarmProcessRunner.RunError.exited(status: 1))
    var startError: Error?
    private(set) var outputArguments: [[String]] = []
    private(set) var startedArguments: [[String]] = []
    private(set) var startedEnvironment: [String: String]?
    private(set) var child: Child?
    private(set) var exited: (@MainActor (Int32, Process.TerminationReason) -> Void)?

    func output(of executable: URL, arguments: [String], environment: [String: String],
                timeout: TimeInterval, completion: @escaping @MainActor (Result<Data, Error>) -> Void) {
        outputArguments.append(arguments)
        let result = keyOutput
        DispatchQueue.main.async { completion(result) }
    }

    func start(_ executable: URL, arguments: [String], environment: [String: String],
               exited: @escaping @MainActor (Int32, Process.TerminationReason) -> Void) throws -> PrewarmProcess {
        if let startError { throw startError }
        startedArguments.append(arguments)
        startedEnvironment = environment
        self.exited = exited
        let child = Child()
        self.child = child
        return child
    }
}
