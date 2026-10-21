import Foundation

/// Whether an update needs its shader caches rebuilt before it installs: only when the new
/// build's cache key differs from this one's. When the new key can't be learned, nothing is
/// prewarmed and the update installs as it would without this (the new build then compiles
/// what it needs as it draws, as any launch does).
enum ShaderPrewarmDecision: Equatable {
    case notNeeded
    case needed(ShaderCacheKey)
    case unknown(reason: String)

    static func decide(current: ShaderCacheKey, newBuildOutput: Result<Data, Error>) -> ShaderPrewarmDecision {
        let output: Data
        switch newBuildOutput {
        case .success(let data): output = data
        case .failure(let error): return .unknown(reason: "the new build didn't print its shader cache key: \(error)")
        }
        let key: ShaderCacheKey
        do {
            key = try ShaderCacheKey.parse(output)
        } catch {
            return .unknown(reason: "the new build's shader cache key is unreadable: \(error)")
        }
        return key == current ? .notNeeded : .needed(key)
    }
}
