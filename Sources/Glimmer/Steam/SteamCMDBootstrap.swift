import Foundation

/// Mirrors the official steamcmd.sh restart code, with a shared deadline and attempt limit.
/// A completed update alone never means SteamCMD is ready; only a later exit zero does.
enum SteamCMDBootstrap {
    struct Result: Sendable {
        var output: String
        var updateRestarts: Int
    }

    static func run(
        totalTimeout: TimeInterval = 90,
        maximumAttempts: Int = 3,
        execute: @Sendable (TimeInterval) async throws -> WorkshopProcessResult
    ) async throws -> Result {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(totalTimeout))
        for attempt in 0..<maximumAttempts {
            try Task.checkCancellation()
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw WorkshopProcessError.timedOut(afterSeconds: Int(totalTimeout.rounded(.up)))
            }
            let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
            let result: WorkshopProcessResult
            do {
                result = try await execute(seconds)
            } catch WorkshopProcessError.nonZeroExit(let code, let tail) where code == 42 {
                // WorkshopProcessRunner throws on nonzero and retains a bounded output tail.
                result = WorkshopProcessResult(exitCode: code, output: tail, durationSeconds: 0, wasTimedOut: false, outputWasTruncated: true)
            }
            guard clock.now < deadline else {
                throw WorkshopProcessError.timedOut(afterSeconds: Int(totalTimeout.rounded(.up)))
            }
            if result.exitCode == 0 {
                return Result(output: result.output, updateRestarts: attempt)
            }
            // Code 42 is Valve's MAGIC_RESTART_EXITCODE. Require observed update completion
            // as well, so unrelated failures or malformed output never turn into retry loops.
            let completedUpdate = result.output.lowercased().contains("update complete, launching")
            guard result.exitCode == 42, completedUpdate, attempt + 1 < maximumAttempts else {
                throw WorkshopProcessError.nonZeroExit(code: result.exitCode, outputTail: result.tail(limit: 400))
            }
        }
        throw WorkshopProcessError.launchFailed("SteamCMD 更新重启次数超出限制")
    }
}
