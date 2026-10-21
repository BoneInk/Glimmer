import Foundation
import Metal

/// Retries a Metal library or pipeline compile that failed for a transient reason: the system's
/// Metal compiler service was interrupted or reported an internal error. A shader that doesn't
/// compile fails at once, as before.
enum PipelineCompileRetry {
    static let attempts = 3
    /// Waits before the 2nd and 3rd attempts: `initialBackoff`, then doubled.
    static let initialBackoff: TimeInterval = 0.05

    static func run<T>(attempts: Int = PipelineCompileRetry.attempts,
                       initialBackoff: TimeInterval = PipelineCompileRetry.initialBackoff,
                       isTransient: (Error) -> Bool = PipelineCompileRetry.isTransient,
                       sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                       _ body: () throws -> T) throws -> T {
        var backoff = initialBackoff
        var attempt = 1
        while true {
            do {
                return try body()
            } catch {
                guard attempt < attempts, isTransient(error) else { throw error }
                OWELog.error(.shader, "Metal compile failed transiently (attempt \(attempt) of \(attempts)), "
                             + "retrying in \(Int(backoff * 1000)) ms: \(error)")
                sleep(backoff)
                backoff *= 2
                attempt += 1
            }
        }
    }

    /// The compiler service, not the shader, failed.
    static func isTransient(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == MTLLibraryErrorDomain && error.code == MTLLibraryError.internal.rawValue { return true }
        let text = error.localizedDescription.lowercased()
        return text.contains("xpc_error_connection_interrupted") || text.contains("compiler service")
            || text.contains("connection interrupted")
    }
}
