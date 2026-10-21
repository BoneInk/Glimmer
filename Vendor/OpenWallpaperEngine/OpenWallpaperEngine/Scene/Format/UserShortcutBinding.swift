import Foundation

/// The value of a `usershortcut` user property (WE 2.7): what the user bound it to, in the string
/// form WE stores, `<type>:<system hash>:<path>`, with a file's arguments after the path as
/// `|<arguments>`. WE's browse UI writes and reads it (`BrowseAssignUserShortcutModalCtrl` in
/// `ui/dist/scripts/scripts.js`); wallpaper64.exe gives scripts `{isbound, commandtype, file}` from
/// it and opens it on `engine.openUserShortcut` only when the hash is this machine's
/// (`UserShortcutSystemHash`), so a copied config never runs elsewhere.
///
/// Only the user binds a shortcut: the authored `value` (and any `isbound`, `commandtype` or
/// `file` in project.json) is never used, and presets leave the property out.
struct UserShortcutBinding: Equatable {
    /// WE's four choices, by their stored names.
    enum Kind: String, CaseIterable, Identifiable {
        case file
        case directory
        case web
        case cmd

        var id: String { rawValue }

        /// WE's `commandtype` for scripts (wallpaper64.exe maps the stored type through
        /// file → file, directory → directory, web → website, cmd → command).
        var commandType: String {
            switch self {
            case .file: "file"
            case .directory: "directory"
            case .web: "website"
            case .cmd: "command"
            }
        }
    }

    /// The length of WE's system hash (`6===o[1].length` in its parser).
    static let systemHashLength = 6

    var kind: Kind
    var systemHash: String
    /// The file or folder path, the URL or the command.
    var path: String
    /// A file's arguments; empty for the other kinds.
    var arguments: String = ""

    init(kind: Kind, systemHash: String, path: String, arguments: String = "") {
        self.kind = kind
        self.systemHash = systemHash
        self.path = path
        self.arguments = kind == .file ? arguments : ""
    }

    /// WE's parse: three parts split at the first two colons (`splitTimes(":", 2)`), a known type,
    /// a six-character hash, and for a file the arguments after the first `|`. Nil for anything
    /// else (nothing bound, or a value WE wouldn't read).
    init?(storedValue: String) {
        let parts = storedValue.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let kind = Kind(rawValue: String(parts[0])),
              parts[1].count == Self.systemHashLength else { return nil }
        var path = String(parts[2])
        var arguments = ""
        if kind == .file, let bar = path.firstIndex(of: "|") {
            arguments = String(path[path.index(after: bar)...])
            path = String(path[..<bar])
        }
        guard !path.isEmpty else { return nil }
        self.init(kind: kind, systemHash: String(parts[1]), path: path, arguments: arguments)
    }

    /// The string WE stores (`d(a)` in its modal): empty when there is no path, which unbinds.
    /// A website without a scheme gets `https://`, as WE's modal adds it (it leaves `http://`,
    /// `https://`, `www.` and `steam://` alone).
    var storedValue: String {
        guard !path.isEmpty else { return "" }
        var path = path
        if kind == .web, !["http://", "https://", "www.", "steam://"].contains(where: { path.hasPrefix($0) }) {
            path = "https://" + path
        }
        var value = "\(kind.rawValue):\(systemHash):\(path)"
        if kind == .file, !arguments.isEmpty { value += "|" + arguments }
        return value
    }

    /// WE's `file` for scripts and the label its sidebar shows: a file's or folder's name (the
    /// part after the last `/`, or the whole path when it ends in one), the whole URL or command
    /// otherwise.
    var displayName: String {
        switch kind {
        case .file, .directory:
            guard let slash = path.lastIndex(of: "/"), path.index(after: slash) < path.endIndex else { return path }
            return String(path[path.index(after: slash)...])
        case .web, .cmd:
            return path
        }
    }

    /// What scripts get besides the type (`_Internal.convertUserProperties` reads `isbound`,
    /// `commandtype` and `file`): wallpaper64.exe sets only `isbound: false` for a value it can't
    /// parse, and all three for one it can, whatever machine bound it.
    static func scriptMembers(storedValue: String) -> [String: SceneJSON] {
        guard let binding = UserShortcutBinding(storedValue: storedValue) else { return ["isbound": .bool(false)] }
        return ["isbound": .bool(true), "commandtype": .string(binding.kind.commandType),
                "file": .string(binding.displayName)]
    }
}
