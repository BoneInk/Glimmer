import Foundation

/// A failure of one script, or of the runtime itself (`scriptID` empty). Carries the script's id,
/// the callback and the line, never the script source (docs/scenescript-plan.md §4.5).
struct SceneScriptError: Equatable, CustomStringConvertible {
    enum Kind: String {
        /// The source did not compile; the instance is disabled and its field keeps its value.
        case compile
        /// A callback threw and is not called again for that script (plan §1.9 P4), or the module
        /// body threw and the script is disabled.
        case runtime
        /// The watchdog stopped the script; the whole runtime halts (plan §1.9 P5).
        case terminated
        /// The runtime's own code or an extension failed.
        case `internal`
    }

    /// WE's own message for a script stopped by its watchdog (scenescript64.dll).
    static let terminationMessage = "Script execution has been interrupted because a dead lock was detected."

    var kind: Kind
    var scriptID: String
    var callback: String
    var message: String
    /// 1-based line in the script's source, or nil when unknown.
    var line: Int?

    var description: String {
        let owner = scriptID.isEmpty ? "runtime" : scriptID
        let location = line.map { " line \($0)" } ?? ""
        return "\(kind.rawValue) error in \(owner) \(callback)\(location): \(message)"
    }
}
