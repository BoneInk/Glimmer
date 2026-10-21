import XCTest
import OWEControlProtocol
@testable import OWEMCP

/// What every major MCP client needs: each protocol revision answered in its own terms, and tool
/// schemas plain enough for the strictest (Gemini CLI, OpenAI-backed clients).
final class MCPCompatibilityTests: XCTestCase {
    private var channel: FakeControlChannel!
    private var server: MCPServer!
    private var snapshots: URL!

    override func setUp() {
        reset()
    }

    private func reset() {
        channel = FakeControlChannel()
        snapshots = FileManager.default.temporaryDirectory.appending(path: "owe-mcp-tests-\(UUID().uuidString)")
        server = MCPServer(channel: channel, version: "1.2.3", snapshotDirectory: snapshots)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: snapshots)
    }

    private func request(_ method: String, id: JSONValue = 1, params: JSONValue? = nil) async -> JSONValue? {
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "id": id, "method": .string(method)]
        if let params { message["params"] = params }
        return await server.handle(message: .object(message))
    }

    private func initialize(_ version: String) async -> JSONValue? {
        await request("initialize", params: [
            "protocolVersion": .string(version), "capabilities": [:], "clientInfo": ["name": "conformance", "version": "1"],
        ])?["result"]
    }

    // MARK: - Conformance per revision

    func testEachRevisionGetsItsOwnShape() async throws {
        channel.answers["get_status"] = ["displays": [], "paused": false, "volume": 0.5, "muted": false, "playlist": nil]
        for version in ["2024-11-05", "2025-03-26", "2025-06-18"] {
            reset()
            channel.answers["get_status"] = ["displays": [], "paused": false, "volume": 0.5, "muted": false, "playlist": nil]
            let modern = version == "2025-06-18"
            let result = await initialize(version)
            XCTAssertEqual(result?["protocolVersion"], .string(version), version)
            XCTAssertEqual(result?["serverInfo"]?["name"], "open-wallpaper-engine", version)
            XCTAssertEqual(result?["serverInfo"]?["title"] != nil, modern, "\(version): serverInfo.title")
            XCTAssertNotNil(result?["capabilities"]?["tools"], version)
            let initialized = await server.handle(message: ["jsonrpc": "2.0", "method": "notifications/initialized"])
            XCTAssertNil(initialized)

            let tools = await request("tools/list", id: 2)?["result"]?["tools"]?.arrayValue ?? []
            XCTAssertEqual(tools.count, MCPToolCatalog.tools.count, version)
            for tool in tools {
                let name = tool["name"]?.stringValue ?? "?"
                XCTAssertEqual(tool["title"] != nil, modern, "\(version) \(name): title")
                XCTAssertEqual(tool["annotations"] != nil, version != "2024-11-05", "\(version) \(name): annotations")
                XCTAssertNil(tool["outputSchema"], "\(version) \(name)")
            }

            let resources = await request("resources/list", id: 3)?["result"]?["resources"]?.arrayValue ?? []
            XCTAssertEqual(resources.count, 2, version)
            XCTAssertEqual(resources.allSatisfy { $0["title"] != nil }, modern, "\(version): resource titles")

            let response = await request("tools/call", id: 4, params: ["name": "get_status"])
            let call = try XCTUnwrap(response?["result"], version)
            XCTAssertEqual(call["isError"], false, version)
            XCTAssertEqual(call["structuredContent"] != nil, modern, "\(version): structuredContent")
            let texts = call["content"]?.arrayValue?.filter { $0["type"] == "text" } ?? []
            XCTAssertGreaterThanOrEqual(texts.count, 2, "\(version): a summary and the JSON as text")
            let json = try XCTUnwrap(texts.last?["text"]?.stringValue)
            XCTAssertEqual(try JSONValue.decode(Data(json.utf8)), channel.answers["get_status"], version)
        }
    }

    func testUnsupportedRevisionGetsTheLatest() async {
        let result = await initialize("2023-01-01")
        XCTAssertEqual(result?["protocolVersion"], .string(MCPProtocolVersion.latest))
    }

    func testPingCancellationAndUnknownMessages() async throws {
        _ = await initialize("2025-06-18")
        let ping = await request("ping", id: 7)
        XCTAssertEqual(ping?["result"], .object([:]))
        let unknown = await server.handle(message: ["jsonrpc": "2.0", "method": "notifications/somethingNew", "params": ["x": 1]])
        XCTAssertNil(unknown)
        let cancel = await server.handle(message: ["jsonrpc": "2.0", "method": "notifications/cancelled",
                                                   "params": ["requestId": 8, "reason": "user"]])
        XCTAssertNil(cancel)
        let cancelled = await request("tools/call", id: 8, params: ["name": "get_status"])
        XCTAssertNil(cancelled, "a cancelled request isn't answered")
        XCTAssertTrue(channel.calls.isEmpty, "nor run")
        let reused = await request("ping", id: 8)
        XCTAssertNotNil(reused, "the id can be used again afterwards")
        let prompts = await request("prompts/list", id: 9)
        XCTAssertEqual(prompts?["error"]?["code"], -32601)
        let bogus = await request("bogus/method", id: 10)
        XCTAssertEqual(bogus?["error"]?["code"], -32601)
    }

    func testBatchesOnlyBeforeTheyWereRemoved() async throws {
        _ = await initialize("2025-03-26")
        let answers = await server.handle(message: [
            ["jsonrpc": "2.0", "id": 1, "method": "ping"],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "ping"],
        ])
        XCTAssertEqual(answers?.arrayValue?.compactMap { $0["id"] }, [1, 2])
        _ = await initialize("2025-06-18")
        let refused = await server.handle(message: [["jsonrpc": "2.0", "id": 1, "method": "ping"]])
        XCTAssertEqual(refused?["error"]?["code"], -32600)
    }

    // MARK: - Schemas

    /// Plain JSON Schema: no `$ref`, `oneOf`, `anyOf`, `allOf`, type unions or
    /// `additionalProperties`; every property typed and described; names a client keeps as they are.
    func testSchemasArePortable() throws {
        for tool in MCPToolCatalog.tools {
            let name = tool.name
            XCTAssertNotNil(name.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression), name)
            XCTAssertLessThan(name.count, 64, name)
            let schema = MCPTool.portable(tool.inputSchema)
            XCTAssertEqual(schema["type"], "object", name)
            XCTAssertNotNil(schema["properties"]?.objectValue, "\(name) lists its properties, even none")
            for key in Self.keys(in: schema) {
                XCTAssertFalse(["$ref", "$defs", "definitions", "oneOf", "anyOf", "allOf", "not", "additionalProperties", "$schema"].contains(key),
                               "\(name) uses \(key)")
            }
            Self.checkProperties(of: schema, at: name)
        }
    }

    /// Clients ask before what may destroy: a read-only tool is idempotent and never destructive, and
    /// every tool that deletes, removes or reverts says it may destroy.
    func testAnnotationsTellClientsWhatToAskAbout() {
        for tool in MCPToolCatalog.tools {
            let hints = tool.annotations
            if hints.readOnly { XCTAssertTrue(hints.idempotent && !hints.destructive, tool.name) }
            if ["delete", "remove", "revert"].contains(where: { tool.name.contains($0) }) {
                XCTAssertTrue(hints.destructive, "\(tool.name) is destructive")
            }
            if tool.name.hasSuffix("_get") || tool.name.hasPrefix("list_") || tool.name.hasSuffix("_catalog") {
                XCTAssertTrue(hints.readOnly, "\(tool.name) only reads")
            }
        }
    }

    /// A render, a video set as the screen saver or a depth map may take minutes: those calls wait longer for the app.
    func testLongCallsWaitLonger() {
        let long = Set(MCPToolCatalog.tools.filter(\.isLongRunning).map(\.name))
        XCTAssertEqual(long, ["export_live_photo", "export_android", "android_send_wifi", "screensaver_set", "depth_generate"])
    }

    /// Every property, and every property of an object inside one (a list of edits' items), has one
    /// simple type, a description and a snake_case name.
    private static func checkProperties(of schema: JSONValue, at path: String) {
        for (key, property) in schema["properties"]?.objectValue ?? [:] {
            let name = "\(path).\(key)"
            XCTAssertNotNil(key.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression), "\(name): snake_case")
            XCTAssertNotNil(property["type"]?.stringValue, "\(name): one simple type")
            XCTAssertFalse(property["description"]?.stringValue?.isEmpty ?? true, "\(name) is described")
            if let choices = property["enum"]?.arrayValue {
                XCTAssertTrue(choices.allSatisfy { $0.stringValue != nil }, "\(name): string enum")
            }
            if property["type"] == "array" {
                XCTAssertNotNil(property["items"]?["type"], "\(name) items")
                if property["items"]?["type"] == "object" { checkProperties(of: property["items"] ?? .null, at: name + "[]") }
            }
            if property["type"] == "object" { checkProperties(of: property, at: name) }
        }
    }

    private static func keys(in value: JSONValue) -> [String] {
        switch value {
        case .object(let object):
            // Property names are the tool's own words, not schema keywords.
            return object.flatMap { key, item in
                [key] + (key == "properties" ? (item.objectValue ?? [:]).values.flatMap(keys) : keys(in: item))
            }
        case .array(let items): return items.flatMap(keys)
        default: return []
        }
    }

    func testNumbersAndBooleansForStringPropertiesAreText() async throws {
        _ = await initialize("2025-06-18")
        _ = await request("tools/call", params: ["name": "set_user_property", "arguments": ["id": "42", "key": "rain", "value": 0.5]])
        _ = await request("tools/call", id: 2, params: ["name": "set_user_property", "arguments": ["id": 42, "key": "on", "value": true]])
        XCTAssertEqual(channel.calls.map { $0.params["value"] }, ["0.5", "true"])
        XCTAssertEqual(channel.calls.last?.params["id"], "42")
    }

    /// scene_apply_edits' edits are objects inside the arguments: checked against their schema
    /// (unknown keys and ops refused) and coerced like top-level arguments (a vector as numbers).
    func testEditsInsideArgumentsAreCheckedAndCoerced() async throws {
        _ = await initialize("2025-06-18")
        channel.answers["scene_apply_edits"] = ["message": "Applied."]
        let ok = await request("tools/call", params: ["name": "scene_apply_edits", "arguments": [
            "wallpaper_id": "42",
            "edits": [["op": "set_origin", "layer": 4, "value": [1, 2.5, 0]], ["op": "set_text", "layer": 5, "text": 12]],
        ]])
        XCTAssertEqual(ok?["result"]?["isError"], false)
        let edits = channel.calls.last?.params["edits"]?.arrayValue ?? []
        XCTAssertEqual(edits.first?["value"], "1 2.5 0", "a vector as WE writes it")
        XCTAssertEqual(edits.last?["text"], "12")

        let unknown = await request("tools/call", id: 2, params: ["name": "scene_apply_edits", "arguments": [
            "wallpaper_id": "42", "edits": [["op": "set_origin", "layer": 4, "bogus": 1]],
        ]])
        XCTAssertEqual(unknown?["result"]?["isError"], true)
        XCTAssertTrue(unknown?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("edits[0].bogus") ?? false)
        let badOp = await request("tools/call", id: 3, params: ["name": "scene_apply_edits", "arguments": [
            "wallpaper_id": "42", "edits": [["op": "explode"]],
        ]])
        XCTAssertEqual(badOp?["result"]?["isError"], true)
        XCTAssertEqual(channel.calls.count, 1, "neither reached the app")
        let description = MCPToolCatalog.tool(named: "scene_apply_edits")?.description ?? ""
        for operation in ControlSceneEdits.operations {
            XCTAssertTrue(description.contains("- \(operation.name) ("), "\(operation.name) is described")
        }
    }

    // MARK: - Pictures for clients without image content

    func testSnapshotCanBeAFile() async throws {
        _ = await initialize("2024-11-05")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        channel.answers["snapshot"] = [
            "display": "1", "source": "frame", "width": 2, "height": 2,
            "wallpaper": ["id": "42", "title": "Rain", "type": "scene"], "png_base64": .string(png.base64EncodedString()),
        ]
        let response = await request("tools/call", params: ["name": "snapshot", "arguments": ["format": "path"]])
        let result = try XCTUnwrap(response?["result"])
        XCTAssertNil(channel.calls.last?.params["format"], "the app isn't asked about it")
        let content = try XCTUnwrap(result["content"]?.arrayValue)
        XCTAssertFalse(content.contains { $0["type"] == "image" })
        XCTAssertNil(result["structuredContent"], "2024-11-05 has no structured content")
        let json = try JSONValue.decode(Data(try XCTUnwrap(content.last?["text"]?.stringValue).utf8))
        let path = try XCTUnwrap(json["path"]?.stringValue)
        XCTAssertNil(json["png_base64"])
        XCTAssertTrue(content.first?["text"]?.stringValue?.contains(path) ?? false, "the summary names the file")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), png)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        let imageResponse = await request("tools/call", id: 2, params: ["name": "snapshot"])
        let image = try XCTUnwrap(imageResponse?["result"])
        XCTAssertTrue(image["content"]?.arrayValue?.contains { $0["type"] == "image" } ?? false, "image content stays the default")
    }
}
