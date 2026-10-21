import Foundation

/// Where the MCP Server plugin is installed: `<Application Support>/Open Wallpaper Engine/Plugins/MCP`
/// (the app's support folder, or an isolated copy's), holding a copy of the signed `owe-mcp` the
/// app ships in `Contents/Helpers` and `install.json`, which says which app installed it.
///
/// `owe-mcp` run from there finds its app's control socket from its own location (the support
/// folder two levels up), so an isolated copy's plugin talks to that copy, and it starts the app
/// that installed it when the app isn't running.
public enum MCPPluginLayout {
    public static let folder = "Plugins/MCP"
    public static let executableName = "owe-mcp"
    public static let manifestName = "install.json"

    /// What the app writes beside the binary when it installs the plugin.
    public struct Manifest: Codable, Equatable, Sendable {
        /// The app's bundle, which `owe-mcp` starts when no app answers.
        public var app: String
        /// The app's isolation tag (`OWE_ISOLATED_STATE`), nil for the user's own app.
        public var isolationTag: String?
        /// The app's version that installed it.
        public var version: String

        public init(app: String, isolationTag: String?, version: String) {
            self.app = app
            self.isolationTag = isolationTag
            self.version = version
        }

        enum CodingKeys: String, CodingKey {
            case app
            case isolationTag = "isolation_tag"
            case version
        }
    }

    public static func root(supportDirectory: URL) -> URL {
        supportDirectory.appending(path: folder, directoryHint: .isDirectory)
    }

    public static func executableURL(supportDirectory: URL) -> URL {
        root(supportDirectory: supportDirectory).appending(path: executableName, directoryHint: .notDirectory)
    }

    public static func manifestURL(supportDirectory: URL) -> URL {
        root(supportDirectory: supportDirectory).appending(path: manifestName, directoryHint: .notDirectory)
    }

    /// The support folder of an installed `owe-mcp` at `executable`; nil when it isn't one.
    public static func supportDirectory(ofInstalledExecutable executable: URL) -> URL? {
        let mcp = executable.standardizedFileURL.deletingLastPathComponent()
        let plugins = mcp.deletingLastPathComponent()
        guard executable.lastPathComponent == executableName, mcp.lastPathComponent == "MCP",
              plugins.lastPathComponent == "Plugins" else { return nil }
        return plugins.deletingLastPathComponent()
    }

    /// The manifest installed in `supportDirectory`; nil when there is none or it can't be read.
    public static func manifest(supportDirectory: URL) -> Manifest? {
        // A missing manifest is the common case for a bundled `owe-mcp`.
        guard let data = try? Data(contentsOf: manifestURL(supportDirectory: supportDirectory)) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data) // Unreadable: start the app by its bundle id instead.
    }
}
