import XCTest
import OWEControlProtocol
@testable import OWEMCP

final class MCPSupportTests: XCTestCase {
    func testSchemaProblems() {
        let schema = JSONSchema.object([
            "id": JSONSchema.string("id", minLength: 1),
            "editor": JSONSchema.string("which", oneOf: ["scene", "wallpaper"]),
            "limit": JSONSchema.integer("n", minimum: 1, maximum: 5),
            "tags": JSONSchema.stringArray("tags", maxItems: 2),
            "value": ["type": ["string", "number", "boolean"], "description": "v"],
        ], required: ["id"])
        XCTAssertEqual(JSONSchema.problems(["id": "a", "editor": "scene", "limit": 3, "tags": ["x"], "value": true], against: schema), [])
        XCTAssertEqual(JSONSchema.problems([:], against: schema), ["id: required"])
        XCTAssertEqual(JSONSchema.problems(["id": ""], against: schema), ["id: must not be empty"])
        XCTAssertEqual(JSONSchema.problems(["id": "a", "editor": "code"], against: schema), [#"editor: must be one of "scene", "wallpaper""#])
        XCTAssertEqual(JSONSchema.problems(["id": "a", "limit": 2.5], against: schema), ["limit: expected integer, got number"])
        XCTAssertEqual(JSONSchema.problems(["id": "a", "limit": 9], against: schema), ["limit: must be at most 5"])
        XCTAssertEqual(JSONSchema.problems(["id": "a", "tags": ["x", 1, "z"]], against: schema),
                       ["tags: at most 2 items", "tags[1]: expected string, got integer"])
        XCTAssertEqual(JSONSchema.problems(["id": "a", "value": nil], against: schema),
                       ["value: expected string or number or boolean, got null"])
        XCTAssertEqual(JSONSchema.problems("x", against: schema), ["arguments: expected object, got string"])
    }

    func testCommandOptions() {
        XCTAssertEqual(OWEMCPCommand.parse([], version: "1"), .run(.init()))
        var options = OWEMCPCommand.Options()
        options.socketURL = URL(fileURLWithPath: "/tmp/s.sock")
        options.launches = false
        options.launchTimeout = 5
        XCTAssertEqual(OWEMCPCommand.parse(["--socket", "/tmp/s.sock", "--no-launch", "--launch-timeout", "5"], version: "1"),
                       .run(options))
        XCTAssertEqual(OWEMCPCommand.parse(["--version"], version: "1.2"), .exit(message: "1.2", status: 0))
        guard case .exit(_, 64) = OWEMCPCommand.parse(["--bogus"], version: "1") else { return XCTFail("unknown option") }
        guard case .exit(_, 64) = OWEMCPCommand.parse(["--socket"], version: "1") else { return XCTFail("missing path") }
    }

    func testLauncherFindsItsAppAndKeepsIsolation() {
        let helper = URL(fileURLWithPath: "/Applications/Open Wallpaper Engine.app/Contents/Helpers/owe-mcp")
        XCTAssertEqual(OWEAppLauncher.containingApp(of: helper)?.path, "/Applications/Open Wallpaper Engine.app")
        XCTAssertNil(OWEAppLauncher.containingApp(of: URL(fileURLWithPath: "/usr/local/bin/owe-mcp")))

        let real = OWEAppLauncher.forCurrentProcess(executable: helper, environment: [:])
        XCTAssertEqual(real.openArguments, ["-g", "-a", "/Applications/Open Wallpaper Engine.app"])
        let isolated = OWEAppLauncher.forCurrentProcess(executable: helper, environment: ["OWE_ISOLATED_STATE": "mcp"])
        XCTAssertEqual(isolated.openArguments,
                       ["-g", "-n", "-a", "/Applications/Open Wallpaper Engine.app", "--args", "-OWEIsolatedState", "mcp"])
        XCTAssertEqual(OWEAppLauncher(appURL: nil, isolationTag: nil).openArguments, ["-g", "-b", "app.openwallpaperengine"])
    }

    /// The user's own app doesn't count as a running isolated copy, nor the other way round.
    func testRunningCopiesAreToldApartByIsolation() {
        XCTAssertNil(OWEAppLauncher.isolationTag(arguments: ["/A.app/Contents/MacOS/A", "HOME=/Users/u"]))
        XCTAssertEqual(OWEAppLauncher.isolationTag(arguments: ["/A", "-OWEIsolatedState", "shots", "OWE_ISOLATED_STATE=x"]), "shots")
        XCTAssertEqual(OWEAppLauncher.isolationTag(arguments: ["/A", "-CustomWallpapersDirectory", "/l", "OWE_ISOLATED_STATE=mcp"]), "mcp")
        // This test process reads its own arguments back.
        XCTAssertFalse(OWEAppLauncher.arguments(of: getpid()).isEmpty)
    }

    /// The channel launches a missing app and waits for its socket; a running app without one is
    /// reported as control being off.
    func testChannelLaunchesAndExplains() async throws {
        final class Launcher: AppLaunching {
            var running: Bool
            var launches = 0
            var onLaunch: () throws -> Void = {}
            init(running: Bool) { self.running = running }
            func isRunning() -> Bool { running }
            func launch() throws { launches += 1; running = true; try onLaunch() }
        }
        let folder = URL(fileURLWithPath: "/tmp/owe-mcp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) } // Already gone is fine.
        let socket = ControlSocketLocation.socketURL(supportDirectory: folder)

        let off = Launcher(running: true)
        let offChannel = SocketControlChannel(socketURL: socket, launcher: off, launchTimeout: 0.3, pollInterval: 0.05)
        do {
            _ = try await offChannel.call("pause", params: [:])
            XCTFail("no socket")
        } catch {
            XCTAssertEqual(error as? AppConnectionError, .controlOff)
            XCTAssertEqual(off.launches, 0, "a running app isn't launched again")
        }

        let server = ControlSocketServer(url: socket) { ControlResponse(id: $0.id, result: ["paused": true]) }
        defer { server.stop() }
        let missing = Launcher(running: false)
        missing.onLaunch = { try server.start() }
        let channel = SocketControlChannel(socketURL: socket, launcher: missing, launchTimeout: 5, pollInterval: 0.05)
        let result = try await channel.call("pause", params: [:])
        XCTAssertEqual(result, ["paused": true])
        XCTAssertEqual(missing.launches, 1)

        // Errors from the app arrive as `ControlError`.
        server.stop()
        let refusing = ControlSocketServer(url: socket) { ControlResponse(id: $0.id, error: ControlError(.notFound, "nope")) }
        try refusing.start()
        defer { refusing.stop() }
        let direct = SocketControlChannel(socketURL: socket, launcher: nil)
        do {
            _ = try await direct.call("get_wallpaper", params: ["id": "x"])
            XCTFail("refused")
        } catch {
            XCTAssertEqual(error as? ControlError, ControlError(.notFound, "nope"))
        }
    }
}

final class MCPPluginLocationTests: XCTestCase {
    /// An installed plugin finds its app's socket and app from where it is, isolated or not.
    func testInstalledCopyFindsItsApp() throws {
        let scratch = URL(fileURLWithPath: "/tmp/owe-plugin-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) } // Test scratch.
        let support = scratch.appending(path: "Open Wallpaper Engine (isolated x)", directoryHint: .isDirectory)
        let executable = MCPPluginLayout.executableURL(supportDirectory: support)
        XCTAssertEqual(MCPPluginLayout.supportDirectory(ofInstalledExecutable: executable)?.path, support.path)
        XCTAssertEqual(OWEMCPCommand.socketURL(option: nil, executable: executable, environment: [:]).path,
                       support.appending(path: "Control/control.sock").path)

        try FileManager.default.createDirectory(at: MCPPluginLayout.root(supportDirectory: support), withIntermediateDirectories: true)
        let manifest = MCPPluginLayout.Manifest(app: "/Applications/Dev.app", isolationTag: "x", version: "1.0")
        try JSONEncoder().encode(manifest).write(to: MCPPluginLayout.manifestURL(supportDirectory: support))
        XCTAssertEqual(MCPPluginLayout.manifest(supportDirectory: support), manifest)
        // With its manifest, an isolated copy's plugin finds the copy's socket by its tag.
        XCTAssertEqual(OWEMCPCommand.socketURL(option: nil, executable: executable, environment: [:]),
                       ControlSocketLocation.isolatedSocketURL(tag: "x"))
        let launcher = OWEAppLauncher.forCurrentProcess(executable: executable, environment: [:])
        XCTAssertEqual(launcher.openArguments, ["-g", "-n", "-a", "/Applications/Dev.app", "--args", "-OWEIsolatedState", "x"])

        // `--socket` and `OWE_ISOLATED_STATE` come first.
        XCTAssertEqual(OWEMCPCommand.socketURL(option: URL(fileURLWithPath: "/tmp/s"), executable: executable, environment: [:]).path, "/tmp/s")
        XCTAssertEqual(OWEMCPCommand.socketURL(option: nil, executable: executable, environment: ["OWE_ISOLATED_STATE": "y"]),
                       ControlSocketLocation.isolatedSocketURL(tag: "y"))
        XCTAssertNil(MCPPluginLayout.supportDirectory(ofInstalledExecutable: URL(fileURLWithPath: "/usr/local/bin/owe-mcp")))
    }
}
