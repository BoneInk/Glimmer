import XCTest
import OWEControlProtocol
@testable import OpenWallpaperEngine

/// Settings › Plugins › MCP Server: the control socket exists only while the plugin is installed,
/// owner-only; installing puts owe-mcp in place, removing takes it and the socket away.
@MainActor
final class MCPServerPluginTests: XCTestCase {
    private var scratch: URL!
    private var layout: MCPServerPlugin.Layout!

    override func setUp() async throws {
        // Short, so the socket's path fits a socket address.
        let id = UUID().uuidString.prefix(8)
        scratch = URL(fileURLWithPath: "/tmp/owe-plugin-\(id)", isDirectory: true)
        let bundled = scratch.appending(path: "App.app/Contents/Helpers/owe-mcp")
        try FileManager.default.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho owe-mcp\n".utf8).write(to: bundled)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
        layout = MCPServerPlugin.Layout(
            supportDirectory: scratch.appending(path: "Support", directoryHint: .isDirectory), bundledExecutable: bundled,
            manifest: MCPPluginLayout.Manifest(app: scratch.appending(path: "App.app").path, isolationTag: "plugin-tests-\(id)", version: "9.9"))
    }

    override func tearDown() async throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) } // Test scratch; may be gone.
    }

    private func makePlugin() -> MCPServerPlugin {
        MCPServerPlugin(layout: layout) { request in ControlResponse(id: request.id, result: ["method": .string(request.method)]) }
    }

    private var socketExists: Bool { FileManager.default.fileExists(atPath: layout.socket.path) }

    private func mode(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testNoSocketUntilInstalled() {
        let plugin = makePlugin()
        XCTAssertFalse(plugin.isInstalled)
        XCTAssertTrue(plugin.canInstall)
        plugin.start()
        XCTAssertFalse(plugin.isServing)
        XCTAssertFalse(socketExists, "not installed: no socket")
        plugin.stop()
    }

    func testInstallServesOwnerOnlyAndRemoveTakesItAway() throws {
        let plugin = makePlugin()
        try plugin.install()
        defer { plugin.stop() }

        XCTAssertTrue(plugin.isInstalled)
        XCTAssertEqual(try Data(contentsOf: layout.executable), try Data(contentsOf: XCTUnwrap(layout.bundledExecutable)))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: layout.executable.path))
        XCTAssertEqual(MCPPluginLayout.manifest(supportDirectory: layout.supportDirectory), layout.manifest)
        XCTAssertTrue(socketExists)
        XCTAssertEqual(try mode(layout.socket) & 0o777, 0o600)
        XCTAssertEqual(try mode(layout.socket.deletingLastPathComponent()) & 0o777, 0o700)
        let response = try ControlSocketClient(url: layout.socket, timeout: 5).send(ControlRequest(id: 1, method: "get_status"))
        XCTAssertEqual(response.result?["method"], "get_status")

        // The configuration points at the installed copy.
        let configuration = try JSONValue.decode(Data(plugin.clientConfiguration.utf8))
        XCTAssertEqual(configuration["mcpServers"]?["open-wallpaper-engine"]?["command"], .string(layout.executable.path))
        XCTAssertTrue(plugin.addCommand.hasPrefix("claude mcp add open-wallpaper-engine -- '"))
        for client in MCPClientConfiguration.allCases {
            XCTAssertTrue(plugin.configuration(for: client).contains(layout.executable.path), "\(client)")
        }

        try plugin.remove()
        XCTAssertFalse(plugin.isInstalled)
        XCTAssertFalse(plugin.isServing)
        XCTAssertFalse(socketExists, "removed: no socket")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.root.path), "removed: no plugin folder")
        XCTAssertThrowsError(try ControlSocketClient(url: layout.socket, timeout: 1).connect())
    }

    /// The next launch serves again, and brings an installed copy up to the app's.
    func testInstalledPluginServesAtLaunchAndIsRefreshed() throws {
        let first = makePlugin()
        try first.install()
        first.stop()
        XCTAssertFalse(socketExists, "quitting removes the socket")

        try Data("old".utf8).write(to: layout.executable)
        XCTAssertTrue(try MCPServerPlugin.copyIsStale(bundled: XCTUnwrap(layout.bundledExecutable), layout: layout))
        try MCPServerPlugin.place(XCTUnwrap(layout.bundledExecutable), layout: layout)
        XCTAssertFalse(try MCPServerPlugin.copyIsStale(bundled: XCTUnwrap(layout.bundledExecutable), layout: layout))

        let relaunched = makePlugin()
        XCTAssertTrue(relaunched.isInstalled)
        relaunched.start()
        defer { relaunched.stop() }
        XCTAssertTrue(relaunched.isServing)
        XCTAssertTrue(socketExists)
    }

    func testABuildWithoutOweMCPCantInstall() {
        layout.bundledExecutable = nil
        let plugin = makePlugin()
        XCTAssertFalse(plugin.canInstall)
        XCTAssertThrowsError(try plugin.install())
        XCTAssertFalse(socketExists)
    }
}
