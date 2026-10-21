import Combine
import Foundation

/// A line the running scripts wrote (`console.log`, `console.error`) or an error the runtime
/// reported for one of them.
public struct SceneScriptConsoleEntry: Hashable, Sendable, Identifiable {
    public enum Level: String, Sendable { case log, error }

    public let id: Int
    public let date: Date
    public let level: Level
    public let message: String
    /// The runtime's id of the script (`<wallpaper>/<name>#<id>/<field>`); empty for the runtime.
    public let scriptID: String
    /// 1-based line in the script's source, when the runtime knows it.
    public let line: Int?
    /// The layer (its overlay key: id, else index) and field the script is attached to.
    public let layerID: Int?
    public let path: SceneFieldPath?

    public init(id: Int, date: Date = Date(), level: Level, message: String, scriptID: String, line: Int? = nil,
                wallpaperID: String) {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
        self.scriptID = scriptID
        self.line = line
        let site = Self.site(of: scriptID, wallpaperID: wallpaperID)
        layerID = site?.layerID
        path = site?.path
    }

    /// The layer and field a runtime script id names: `wp/Clock#11/text` is layer 11's `text`,
    /// `wp/#i2/origin` the third object's (it has no id), `wp/scene/general.bloom` no layer.
    /// A duplicate site's `~2` suffix is dropped.
    public static func site(of scriptID: String, wallpaperID: String) -> (layerID: Int?, path: SceneFieldPath)? {
        let prefix = wallpaperID + "/"
        guard scriptID.hasPrefix(prefix) else { return nil }
        var rest = String(scriptID.dropFirst(prefix.count))
        if let tilde = rest.lastIndex(of: "~"), rest[rest.index(after: tilde)...].allSatisfy(\.isNumber) {
            rest = String(rest[..<tilde])
        }
        guard let slash = rest.lastIndex(of: "/") else { return nil }
        let label = rest[..<slash]
        let path = SceneFieldPath(String(rest[rest.index(after: slash)...]))
        guard let hash = label.lastIndex(of: "#") else { return (nil, path) }
        var key = label[label.index(after: hash)...]
        if key.hasPrefix("i") { key = key.dropFirst() }
        return (Int(key), path)
    }
}

/// The console of the editor: what the wallpaper's scripts wrote and the errors they raised, as
/// the app's runtime reports them, newest last and bounded.
@MainActor
public final class SceneScriptConsoleFeed: ObservableObject {
    public static let limit = 500

    @Published public private(set) var entries: [SceneScriptConsoleEntry] = []
    public let wallpaperID: String
    private var nextID = 0

    public init(wallpaperID: String) {
        self.wallpaperID = wallpaperID
    }

    public func append(level: SceneScriptConsoleEntry.Level, message: String, scriptID: String, line: Int?,
                       date: Date = Date()) {
        let entry = SceneScriptConsoleEntry(id: nextID, date: date, level: level, message: message, scriptID: scriptID,
                                            line: line, wallpaperID: wallpaperID)
        nextID += 1
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    public func clear() {
        entries.removeAll()
    }

    /// The entries of the script on `path` of `layerID`.
    public func entries(of layerID: Int, _ path: SceneFieldPath) -> [SceneScriptConsoleEntry] {
        entries.filter { (entry: SceneScriptConsoleEntry) -> Bool in entry.layerID == layerID && entry.path == path }
    }

    /// The latest error of each line of the script on `path` of `layerID`, for inline marks.
    public func diagnostics(of layerID: Int, _ path: SceneFieldPath, since date: Date? = nil) -> [SceneScriptDiagnostic] {
        var byLine: [Int: SceneScriptDiagnostic] = [:]
        var unplaced: SceneScriptDiagnostic?
        for entry in entries(of: layerID, path) where entry.level == .error && (date.map { entry.date >= $0 } ?? true) {
            let diagnostic = SceneScriptDiagnostic(line: entry.line, message: entry.message)
            if let line = entry.line { byLine[line] = diagnostic } else { unplaced = diagnostic }
        }
        return byLine.keys.sorted().compactMap { byLine[$0] } + (unplaced.map { [$0] } ?? [])
    }
}
