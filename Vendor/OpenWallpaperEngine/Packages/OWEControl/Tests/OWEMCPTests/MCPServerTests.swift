import XCTest
import OWEControlProtocol
@testable import OWEMCP

/// A control channel that records calls and answers from a table.
final class FakeControlChannel: ControlChannel {
    var calls: [(method: String, params: [String: JSONValue])] = []
    var answers: [String: JSONValue] = [:]
    var failure: Error?

    func call(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        calls.append((method, params))
        if let failure { throw failure }
        return answers[method] ?? .object([:])
    }
}

final class MCPServerTests: XCTestCase {
    private var channel: FakeControlChannel!
    private var server: MCPServer!

    override func setUp() {
        channel = FakeControlChannel()
        server = MCPServer(channel: channel, version: "1.2.3")
    }

    private func request(_ method: String, id: JSONValue = 1, params: JSONValue? = nil) async -> JSONValue? {
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "id": id, "method": .string(method)]
        if let params { message["params"] = params }
        return await server.handle(message: .object(message))
    }

    /// `XCTUnwrap` for a value an awaited expression gives (its autoclosure can't await).
    private func unwrapped<Value>(_ value: Value?, file: StaticString = #filePath, line: UInt = #line) throws -> Value {
        try XCTUnwrap(value, file: file, line: line)
    }

    private func respond(toLine text: String) async throws -> JSONValue? {
        guard let data = await server.handle(line: Data(text.utf8)) else { return nil }
        XCTAssertFalse(data.contains(0x0A), "one line")
        return try JSONValue.decode(data)
    }

    // MARK: - Lifecycle

    func testInitialize() async throws {
        let response = try await unwrapped(request("initialize", params: [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"],
        ]))
        XCTAssertEqual(response["jsonrpc"], "2.0")
        XCTAssertEqual(response["id"], 1)
        let result = try XCTUnwrap(response["result"])
        XCTAssertEqual(result["protocolVersion"], "2025-06-18")
        XCTAssertEqual(result["serverInfo"]?["name"], "open-wallpaper-engine")
        XCTAssertEqual(result["serverInfo"]?["version"], "1.2.3")
        XCTAssertNotNil(result["capabilities"]?["tools"])
        XCTAssertNotNil(result["capabilities"]?["resources"])
        XCTAssertTrue(channel.calls.isEmpty, "initialize never reaches the app")
    }

    func testInitializeNegotiatesTheVersion() async throws {
        let older = await request("initialize", params: ["protocolVersion": "2025-03-26"])
        XCTAssertEqual(older?["result"]?["protocolVersion"], "2025-03-26")
        let unknown = await request("initialize", params: ["protocolVersion": "1999-01-01"])
        XCTAssertEqual(unknown?["result"]?["protocolVersion"], .string(MCPServer.protocolVersion))
    }

    func testPingAndNotifications() async throws {
        let ping = await request("ping", id: "a")
        XCTAssertEqual(ping?["id"], "a")
        XCTAssertEqual(ping?["result"], .object([:]))
        let notification = await server.handle(message: ["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertNil(notification)
        // A response to something the server never sent is ignored too.
        let stray = await server.handle(message: ["jsonrpc": "2.0", "id": 9, "result": [:]])
        XCTAssertNil(stray)
    }

    // MARK: - tools/list

    func testToolsListHasEveryToolWithValidSchemas() async throws {
        let tools = try await unwrapped(request("tools/list")?["result"]?["tools"]?.arrayValue)
        let names = tools.compactMap { $0["name"]?.stringValue }
        XCTAssertTrue(Set(names).isSuperset(of: [
            "list_displays", "get_status", "list_wallpapers", "get_wallpaper", "set_wallpaper",
            "pause", "resume", "stop", "toggle_playback", "set_volume", "set_muted", "set_user_property",
            "list_playlists", "play_playlist", "next_wallpaper", "previous_wallpaper",
            "import_wallpaper", "open_editor", "snapshot",
        ]), "the basic tools stay")
        XCTAssertTrue(Set(names).isSuperset(of: [
            "scene_get", "scene_apply_edits", "scene_undo", "scene_redo", "wallpaper_editor_save", "wallpaper_editor_save_as_new", "scene_save", "scene_save_as_local_wallpaper",
            "scene_revert", "effects_catalog", "particles_catalog", "particles_get", "particles_restart", "puppets_list",
            "timeline_get", "timeline_preview", "script_get", "script_set", "script_check", "user_properties_get",
            "depth_generate", "depth_apply", "depth_remove", "use_depth_map_as_mask", "editor_close", "editor_set_tab",
        ]), "the scene and editors' tools")
        XCTAssertTrue(Set(names).isSuperset(of: [
            "playlist_create", "playlist_update", "playlist_add_items", "playlist_remove_items", "playlist_move_item",
            "playlist_delete", "wallpaper_set_favorite", "wallpaper_delete", "display_settings_get", "display_settings_set",
            "settings_get", "settings_set", "plugin_status", "folders_list", "folder_create", "wallpaper_move_to_folder",
            "caches_get", "caches_clear",
        ]), "the library and app's tools")
        XCTAssertTrue(Set(names).isSuperset(of: [
            "devices_list", "export_settings_get", "export_live_photo", "export_android", "android_send_wifi", "screensaver_get", "screensaver_set_layers",
            "screensaver_set", "screensaver_stop_using",
            "lock_screen_get", "lock_screen_set", "lock_screen_refresh",
        ]), "the system features' tools")
        XCTAssertEqual(names, MCPToolCatalog.tools.map(\.name))
        XCTAssertEqual(names.count, Set(names).count, "names are unique")
        for tool in tools {
            let name = tool["name"]?.stringValue ?? "?"
            XCTAssertNotNil(name.range(of: "^[a-z_]+$", options: .regularExpression), name)
            XCTAssertFalse(tool["description"]?.stringValue?.isEmpty ?? true, name)
            XCTAssertNotNil(tool["title"]?.stringValue, name)
            let schema = try XCTUnwrap(tool["inputSchema"], name)
            XCTAssertEqual(schema["type"], "object", name)
            XCTAssertNil(schema["additionalProperties"], "\(name): strict clients reject or strip it")
            let properties = try XCTUnwrap(schema["properties"]?.objectValue, name)
            for required in schema["required"]?.arrayValue ?? [] {
                XCTAssertNotNil(properties[required.stringValue ?? ""], "\(name) requires an undeclared \(required)")
            }
            for (key, property) in properties {
                XCTAssertNotNil(property["type"], "\(name).\(key) has a type")
                XCTAssertFalse(property["description"]?.stringValue?.isEmpty ?? true, "\(name).\(key) is described")
            }
            XCTAssertNotNil(tool["annotations"]?["readOnlyHint"]?.boolValue, name)
        }
        XCTAssertTrue(channel.calls.isEmpty, "tools/list never reaches the app")
    }

    // MARK: - tools/call

    func testToolCallRoundTrip() async throws {
        channel.answers["get_status"] = [
            "displays": [["id": "1", "name": "Studio Display", "wallpaper": ["id": "42", "title": "Rain", "type": "scene"]]],
            "paused": false, "volume": 0.5, "muted": false, "playlist": nil,
        ]
        let response = try await unwrapped(request("tools/call", id: 5, params: ["name": "get_status", "arguments": ["display": "1"]]))
        XCTAssertEqual(channel.calls.count, 1)
        XCTAssertEqual(channel.calls.first?.method, "get_status")
        XCTAssertEqual(channel.calls.first?.params, ["display": "1"])
        let result = try XCTUnwrap(response["result"])
        XCTAssertEqual(result["isError"], false)
        XCTAssertEqual(result["structuredContent"], channel.answers["get_status"])
        let content = try XCTUnwrap(result["content"]?.arrayValue)
        XCTAssertEqual(content.first?["type"], "text")
        XCTAssertEqual(content.first?["text"], "Wallpapers are playing, volume 50%. Studio Display: \"Rain\" (scene).")
        // The JSON as text for clients without structured content.
        let json = try XCTUnwrap(content.last?["text"]?.stringValue)
        XCTAssertEqual(try JSONValue.decode(Data(json.utf8)), channel.answers["get_status"])
    }

    func testToolCallWithoutArguments() async throws {
        channel.answers["pause"] = ["paused": true]
        let result = await request("tools/call", params: ["name": "pause"])?["result"]
        XCTAssertEqual(result?["isError"], false)
        XCTAssertEqual(channel.calls.first?.params, [:])
    }

    func testInvalidArgumentsAreToolErrors() async throws {
        let result = try await unwrapped(request("tools/call", params: [
            "name": "set_volume", "arguments": ["level": 2, "loud": true],
        ])?["result"])
        XCTAssertEqual(result["isError"], true)
        let message = try XCTUnwrap(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertTrue(message.contains("level: must be at most 1"), message)
        XCTAssertTrue(message.contains("loud: unknown argument"), message)
        XCTAssertTrue(channel.calls.isEmpty, "invalid arguments never reach the app")

        let missing = await request("tools/call", params: ["name": "set_wallpaper", "arguments": [:]])?["result"]
        XCTAssertEqual(missing?["isError"], true)
        XCTAssertTrue(missing?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("id: required") ?? false)
    }

    func testAppErrorsAreToolErrors() async throws {
        channel.failure = ControlError(.notFound, "No wallpaper with the id \"x\". list_wallpapers lists them.")
        let result = try await unwrapped(request("tools/call", params: ["name": "get_wallpaper", "arguments": ["id": "x"]])?["result"])
        XCTAssertEqual(result["isError"], true)
        XCTAssertEqual(result["content"]?.arrayValue?.first?["text"], "No wallpaper with the id \"x\". list_wallpapers lists them.")

        channel.failure = AppConnectionError.controlOff
        let off = await request("tools/call", params: ["name": "pause"])?["result"]
        XCTAssertEqual(off?["isError"], true)
        XCTAssertTrue(off?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("Settings › Plugins") ?? false)
    }

    func testUnknownToolAndMethodAreProtocolErrors() async throws {
        let tool = await request("tools/call", params: ["name": "delete_everything"])
        XCTAssertEqual(tool?["error"]?["code"], -32602)
        let method = await request("wallpapers/delete")
        XCTAssertEqual(method?["error"]?["code"], -32601)
        XCTAssertTrue(channel.calls.isEmpty)
    }

    func testSnapshotIsImageContent() async throws {
        channel.answers["snapshot"] = [
            "display": "1", "source": "loading_snapshot", "width": 960, "height": 540,
            "wallpaper": ["id": "42", "title": "Rain", "type": "scene"], "png_base64": "iVBORw0KGgo=",
        ]
        let result = try await unwrapped(request("tools/call", params: ["name": "snapshot"])?["result"])
        let content = try XCTUnwrap(result["content"]?.arrayValue)
        let image = try XCTUnwrap(content.first { $0["type"] == "image" })
        XCTAssertEqual(image["data"], "iVBORw0KGgo=")
        XCTAssertEqual(image["mimeType"], "image/png")
        XCTAssertNil(result["structuredContent"]?["png_base64"], "the picture isn't repeated as text")
        XCTAssertEqual(result["structuredContent"]?["width"], 960)
    }

    // MARK: - Malformed input

    func testMalformedInput() async throws {
        let notJSON = try await respond(toLine: "{nope")
        XCTAssertEqual(notJSON?["error"]?["code"], -32700)
        XCTAssertEqual(notJSON?["id"], .null)

        let batch = try await respond(toLine: #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
        XCTAssertEqual(batch?["error"]?["code"], -32600)

        let noVersion = try await respond(toLine: #"{"id":1,"method":"ping"}"#)
        XCTAssertEqual(noVersion?["error"]?["code"], -32600)
        XCTAssertEqual(noVersion?["id"], 1)

        let badID = try await respond(toLine: #"{"jsonrpc":"2.0","id":{"x":1},"method":"ping"}"#)
        XCTAssertEqual(badID?["error"]?["code"], -32600)

        let badParams = try await respond(toLine: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":[1]}"#)
        XCTAssertEqual(badParams?["error"]?["code"], -32602)

        let blank = try await respond(toLine: "   ")
        XCTAssertNil(blank)
        XCTAssertTrue(channel.calls.isEmpty)
    }

    // MARK: - Resources

    func testLibraryResourceReadsEveryPage() async throws {
        let list = try await unwrapped(request("resources/list")?["result"]?["resources"]?.arrayValue)
        XCTAssertTrue(list.contains { $0["uri"] == "owe://library" })

        final class PagedChannel: ControlChannel {
            func call(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
                let offset = params["offset"]?.intValue ?? 0
                let items: [JSONValue] = offset == 0 ? Array(repeating: ["id": "a"], count: 500) : [["id": "b"]]
                return ["total": 501, "offset": .number(Double(offset)), "wallpapers": .array(items)]
            }
        }
        let server = MCPServer(channel: PagedChannel(), version: "1")
        let response = await server.handle(message: ["jsonrpc": "2.0", "id": 1, "method": "resources/read", "params": ["uri": "owe://library"]])
        let text = try XCTUnwrap(response?["result"]?["contents"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertEqual(try JSONValue.decode(Data(text.utf8))["wallpapers"]?.arrayValue?.count, 501)

        let missing = await request("resources/read", params: ["uri": "owe://nothing"])
        XCTAssertEqual(missing?["error"]?["code"], -32002)
    }

    func testLongCallsReportProgressWhenAskedTo() async throws {
        final class Lines: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [JSONValue] = []
            func append(_ data: Data) { lock.lock(); values.append((try? JSONValue.decode(data)) ?? .null); lock.unlock() }
            var all: [JSONValue] { lock.lock(); defer { lock.unlock() }; return values }
        }
        // Stays busy until two progress reports went out (5 s cap), so a loaded machine can't starve the ticker.
        final class SlowChannel: ControlChannel {
            let lines: Lines
            init(lines: Lines) { self.lines = lines }
            func call(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
                let deadline = Date().addingTimeInterval(5)
                while lines.all.count < 2, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
                return ["photo": "/tmp/a.heic", "movie": "/tmp/a.mov"]
            }
        }
        let lines = Lines()
        let server = MCPServer(channel: SlowChannel(lines: lines), version: "1", progressInterval: 0.05)
        server.sendNotification = { lines.append($0) }
        _ = await server.handle(message: ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        let call: JSONValue = ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                               "params": ["name": "export_live_photo", "arguments": ["wallpaper_id": "42"], "_meta": ["progressToken": "t1"]]]
        let response = await server.handle(message: call)
        XCTAssertEqual(response?["result"]?["isError"], false)
        let reports = lines.all
        XCTAssertGreaterThanOrEqual(reports.count, 2)
        XCTAssertTrue(reports.allSatisfy { $0["method"] == "notifications/progress" && $0["params"]?["progressToken"] == "t1" && $0["id"] == nil })
        XCTAssertEqual(reports.compactMap { $0["params"]?["progress"]?.doubleValue }, (1...reports.count).map(Double.init))
        XCTAssertNotNil(reports.first?["params"]?["message"]?.stringValue)
        // Nothing after the answer, and nothing without a token or for a quick tool.
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(lines.all.count, reports.count)
        var plain = call
        if case .object(var object) = plain, case .object(var params) = object["params"] {
            params.removeValue(forKey: "_meta"); object["params"] = .object(params); plain = .object(object)
        }
        _ = await server.handle(message: plain)
        XCTAssertEqual(lines.all.count, reports.count)
    }
}
