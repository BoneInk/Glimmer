import Combine
import Darwin
import Foundation
import OWEControlProtocol

/// Settings › Plugins › MCP Server: lets MCP clients control the app (`docs/mcp.md`). Off and not
/// installed until the user installs it; installed is the opt-in.
///
/// - **Install** copies the signed `owe-mcp` the app ships (`<app>/Contents/Helpers/owe-mcp`) into
///   `<support>/Plugins/MCP` (`MCPPluginLayout`), with `install.json` naming the app, and opens the
///   control socket (`<support>/Control/control.sock`, an isolated copy's under `/private/tmp`, owner-only,
///   `ControlSocketLocation`, `ControlSocketServer`). Nothing
///   is downloaded: the binary is the one signed and notarized with the app.
/// - While installed, the socket exists whenever the app runs; requests go to `ControlRequestRouter`
///   on the main actor. An app update refreshes the installed copy at launch.
/// - **Remove** closes the socket and its connections, removes the file and deletes the plugin's
///   folder.
@MainActor
final class MCPServerPlugin: ObservableObject {
    struct Layout {
        /// The app's support folder (`AppStorageLocation.supportDirectory`).
        var supportDirectory: URL
        /// The `owe-mcp` inside the app; nil when this build has none.
        var bundledExecutable: URL?
        var manifest: MCPPluginLayout.Manifest

        var root: URL { MCPPluginLayout.root(supportDirectory: supportDirectory) }
        var executable: URL { MCPPluginLayout.executableURL(supportDirectory: supportDirectory) }
        var socket: URL { ControlSocketLocation.socketURL(supportDirectory: supportDirectory, isolationTag: manifest.isolationTag) }

        /// This app's layout.
        static var current: Layout {
            let app = AppBundleLayout.appBundle.bundleURL
            let bundled = AppBundleLayout.mcpServerURL(inApp: app)
            let version = AppBundleLayout.appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            return Layout(supportDirectory: AppStorageLocation.current.supportDirectory,
                          bundledExecutable: FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil,
                          manifest: MCPPluginLayout.Manifest(app: app.path, isolationTag: AppStorageLocation.current.isolationTag,
                                                             version: version))
        }
    }

    enum Failure: LocalizedError {
        case notInBuild

        var errorDescription: String? {
            String(localized: "This build of the app doesn’t include owe-mcp.",
                   comment: "Settings › Plugins › MCP Server: the app bundle has no owe-mcp to install")
        }
    }

    @Published private(set) var isInstalled: Bool
    /// Why MCP clients can't connect although the plugin is installed (the socket couldn't open).
    @Published private(set) var serverError: String?

    let layout: Layout
    private let handler: ControlSocketServer.Handler
    private var server: ControlSocketServer?

    init(layout: Layout = .current, handler: @escaping ControlSocketServer.Handler) {
        self.layout = layout
        self.handler = handler
        isInstalled = FileManager.default.isExecutableFile(atPath: layout.executable.path)
    }

    var canInstall: Bool { layout.bundledExecutable != nil }
    var isServing: Bool { server?.isRunning ?? false }

    /// At launch: serves while installed, and brings an installed copy up to the app's own.
    func start() {
        guard isInstalled else { return }
        serve()
        guard let bundled = layout.bundledExecutable else { return }
        let layout = layout
        Task.detached(priority: .utility) {
            do {
                if try Self.copyIsStale(bundled: bundled, layout: layout) {
                    try Self.place(bundled, layout: layout)
                    OWELog.info(.app, "MCP Server plugin: owe-mcp updated to the app's \(layout.manifest.version)")
                }
            } catch {
                OWELog.error(.app, "MCP Server plugin: can't update the installed owe-mcp: \(error)")
            }
        }
    }

    /// At quit: the socket goes with the app.
    func stop() {
        server?.stop()
        server = nil
    }

    func install() throws {
        guard let bundled = layout.bundledExecutable else { throw Failure.notInBuild }
        try Self.place(bundled, layout: layout)
        isInstalled = true
        OWELog.info(.app, "MCP Server plugin installed at \(layout.executable.path)")
        serve()
    }

    func remove() throws {
        stop()
        serverError = nil
        if FileManager.default.fileExists(atPath: layout.root.path) {
            try FileManager.default.removeItem(at: layout.root)
        }
        isInstalled = false
        OWELog.info(.app, "MCP Server plugin removed")
    }

    private func serve() {
        guard server == nil else { return }
        let server = ControlSocketServer(url: layout.socket, handler: handler)
        do {
            try server.start()
            self.server = server
            serverError = nil
            OWELog.info(.app, "MCP Server plugin: accepting MCP clients at \(layout.socket.path)")
        } catch {
            OWELog.error(.app, "MCP Server plugin: can't open the control socket: \(error)")
            serverError = String(describing: error)
        }
    }

    // MARK: - Client setup

    /// What `client`'s configuration needs to start the installed server (`MCPClientConfiguration`).
    func configuration(for client: MCPClientConfiguration) -> String {
        client.snippet(executablePath: layout.executable.path)
    }

    /// The `mcpServers` entry most clients read (Claude Desktop's format).
    var clientConfiguration: String { configuration(for: .claudeDesktop) }

    /// The same for Claude Code's command line.
    var addCommand: String { configuration(for: .claudeCode) }

    // MARK: - Files

    /// Puts a copy of `bundled` in place, signature intact, and writes the manifest beside it.
    nonisolated static func place(_ bundled: URL, layout: Layout) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: layout.root, withIntermediateDirectories: true)
        let staging = layout.root.appending(path: ".owe-mcp-\(UUID().uuidString)", directoryHint: .notDirectory)
        try fileManager.copyItem(at: bundled, to: staging)
        // Copied from an app the user already opened; a quarantine flag on the copy would stop the
        // client that starts it.
        removexattr(staging.path, "com.apple.quarantine", 0)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        if fileManager.fileExists(atPath: layout.executable.path) {
            _ = try fileManager.replaceItemAt(layout.executable, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: layout.executable)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(layout.manifest).write(to: MCPPluginLayout.manifestURL(supportDirectory: layout.supportDirectory),
                                                  options: .atomic)
    }

    /// Whether the installed copy (or its manifest) differs from the app's.
    nonisolated static func copyIsStale(bundled: URL, layout: Layout) throws -> Bool {
        guard FileManager.default.fileExists(atPath: layout.executable.path) else { return false }
        if MCPPluginLayout.manifest(supportDirectory: layout.supportDirectory) != layout.manifest { return true }
        return try Data(contentsOf: bundled) != Data(contentsOf: layout.executable)
    }
}
