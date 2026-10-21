import Foundation

/// Logs each distinct script error once. A script that throws does so every frame; one line per
/// (script, callback, message) is enough to find it, and repeating it would flood the log.
struct SceneScriptErrorLog {
    /// Past this many distinct errors, further ones are dropped with one final notice.
    static let capacity = 512

    /// Names the wallpaper instance in every line.
    let prefix: String
    private var seen = Set<String>()
    private var overflowed = false

    init(prefix: String) {
        self.prefix = prefix
    }

    /// Returns true when `error` had not been logged before (and logs it).
    @discardableResult
    mutating func record(_ error: SceneScriptError) -> Bool {
        let key = "\(error.kind.rawValue)|\(error.scriptID)|\(error.callback)|\(error.message)"
        guard !seen.contains(key) else { return false }
        guard seen.count < Self.capacity else {
            if !overflowed {
                overflowed = true
                OWELog.error(.script, "[\(prefix)] More than \(Self.capacity) distinct script errors; logging no more of them")
            }
            return false
        }
        seen.insert(key)
        OWELog.error(.script, "[\(prefix)] \(error.description)")
        return true
    }
}
