import XCTest
import OWEControlProtocol
@testable import OpenWallpaperEngine

/// The owe-mcp the app ships (`Contents/Helpers/owe-mcp`), run as an MCP client runs it: JSON-RPC
/// over its stdin and stdout. It never starts the app here (`--no-launch`, and a socket nobody serves).
final class MCPServerProcessTests: XCTestCase {
    private var process: Process!
    private var input: FileHandle!
    private let lines = LineCollector()

    override func setUpWithError() throws {
        // The test host is the app, which embeds the server.
        let executable = AppBundleLayout.mcpServerURL(inApp: Bundle.main.bundleURL)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return XCTFail("owe-mcp is missing from \(executable.path)")
        }
        let stdin = Pipe()
        let stdout = Pipe()
        process = Process()
        process.executableURL = executable
        process.arguments = ["--no-launch", "--socket", "/tmp/owe-mcp-test-\(UUID().uuidString.prefix(8)).sock"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        input = stdin.fileHandleForWriting
        stdout.fileHandleForReading.readabilityHandler = { [lines] handle in lines.append(handle.availableData) }
    }

    override func tearDown() {
        try? input?.close() // Closing stdin ends the server; it may have exited already.
        if let process, process.isRunning {
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline { usleep(20_000) }
            if process.isRunning { process.terminate() }
        }
    }

    private func send(_ message: JSONValue) throws {
        try input.write(contentsOf: message.encodedLine() + Data([0x0A]))
    }

    /// The next line the server writes, as JSON.
    private func readMessage(timeout: TimeInterval = 10) throws -> JSONValue {
        let line = try XCTUnwrap(lines.next(timeout: timeout), "owe-mcp didn't answer within \(timeout) s")
        return try JSONValue.decode(line)
    }

    func testInitializeAndListToolsOverStdio() throws {
        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "tests", "version": "1"],
        ]])
        let initialized = try readMessage()
        XCTAssertEqual(initialized["id"], 1)
        XCTAssertEqual(initialized["result"]?["protocolVersion"], "2025-06-18")
        XCTAssertEqual(initialized["result"]?["serverInfo"]?["name"], "open-wallpaper-engine")

        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let list = try readMessage()
        XCTAssertEqual(list["id"], 2, "the notification got no answer")
        let tools = list["result"]?["tools"]?.arrayValue ?? []
        XCTAssertGreaterThanOrEqual(tools.count, 18)
        XCTAssertTrue(tools.contains { $0["name"] == "set_wallpaper" })
        XCTAssertTrue(tools.allSatisfy { $0["inputSchema"]?["type"] == "object" })

        // With no app to talk to, a call is a tool error that says what to do.
        try send(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "pause", "arguments": [:]]])
        let call = try readMessage()
        XCTAssertEqual(call["result"]?["isError"], true)
        XCTAssertTrue(call["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("MCP Server plugin") ?? false)

        input.closeFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

/// An isolated copy (`OWE_ISOLATED_STATE`, here a plugin installed under a tag of its own) and an
/// `owe-mcp` run with the same tag meet at one short socket, `/private/tmp/owe-<uid>/isolated-<hash>.sock`,
/// whatever temporary folder either process has.
@MainActor
final class MCPIsolatedCopySocketTests: XCTestCase {
    func testOweMCPWithTheTagReachesTheIsolatedCopy() throws {
        let tag = "socket-tests-\(UUID().uuidString.prefix(8))"
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "owe-isolated-\(tag)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) } // Test scratch; may be gone.
        let bundled = AppBundleLayout.mcpServerURL(inApp: Bundle.main.bundleURL)
        let layout = MCPServerPlugin.Layout(
            supportDirectory: ControlSocketLocation.supportDirectory(
                isolationTag: tag, applicationSupport: scratch.appending(path: String(repeating: "deep/", count: 12))),
            bundledExecutable: bundled,
            manifest: MCPPluginLayout.Manifest(app: Bundle.main.bundleURL.path, isolationTag: tag, version: "9.9"))
        XCTAssertGreaterThan(layout.supportDirectory.path.utf8.count, ControlSocketLocation.maxPathBytes,
                             "a support folder too deep for a socket address")
        XCTAssertEqual(layout.socket.deletingLastPathComponent().path, "/private/tmp/owe-\(getuid())")
        XCTAssertEqual(layout.socket, ControlSocketLocation.socketURL(
            supportDirectory: ControlSocketLocation.supportDirectory(isolationTag: tag), isolationTag: tag),
                       "the same for every support folder of the tag")
        XCTAssertLessThanOrEqual(layout.socket.path.utf8.count, ControlSocketLocation.maxPathBytes)

        let received = ReceivedMethods()
        let plugin = MCPServerPlugin(layout: layout) { request in
            received.append(request.method)
            return ControlResponse(id: request.id, result: ["playing": true, "volume": 0])
        }
        try plugin.install()
        defer { try? plugin.remove() } // Removes the socket and the plugin folder.
        func mode(_ url: URL) throws -> Int {
            try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        XCTAssertEqual(try mode(layout.socket) & 0o777, 0o600)
        XCTAssertEqual(try mode(layout.socket.deletingLastPathComponent()) & 0o777, 0o700)

        // The app's own owe-mcp, told only the tag, with a temporary folder of its own.
        let lines = LineCollector()
        let stdin = Pipe(), stdout = Pipe()
        let process = Process()
        process.executableURL = bundled
        process.arguments = ["--no-launch"]
        var environment = ProcessInfo.processInfo.environment
        environment["OWE_ISOLATED_STATE"] = tag
        environment["TMPDIR"] = scratch.path + "/"
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdout.fileHandleForReading.readabilityHandler = { [lines] handle in lines.append(handle.availableData) }
        defer { if process.isRunning { process.terminate() } }
        let input = stdin.fileHandleForWriting
        let call: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "get_status", "arguments": [:]]]
        try input.write(contentsOf: call.encodedLine() + Data([0x0A]))
        let line = try XCTUnwrap(lines.next(timeout: 10), "owe-mcp didn't answer")
        let answer = try JSONValue.decode(line)
        XCTAssertNotEqual(answer["result"]?["isError"], true, "\(answer)")
        XCTAssertEqual(received.methods, ["get_status"], "the isolated copy answered")
        input.closeFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

/// The control methods a handler received, from its connection's thread.
private final class ReceivedMethods: @unchecked Sendable { // `list` is guarded by `lock`.
    private let lock = NSLock()
    private var list: [String] = []

    func append(_ method: String) { lock.withLock { list.append(method) } }
    var methods: [String] { lock.withLock { list } }
}

/// Lines read from a pipe on its own queue, waited for with a timeout.
private final class LineCollector: @unchecked Sendable { // `buffer` is guarded by `lock`.
    private let lock = NSLock()
    private let arrived = DispatchSemaphore(value: 0)
    private var buffer = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock { buffer.append(data) }
        arrived.signal()
    }

    func next(timeout: TimeInterval) -> Data? {
        let deadline = DispatchTime.now() + timeout
        while true {
            let line: Data? = lock.withLock {
                guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            if let line { return line }
            guard arrived.wait(timeout: deadline) == .success else { return nil }
        }
    }
}
