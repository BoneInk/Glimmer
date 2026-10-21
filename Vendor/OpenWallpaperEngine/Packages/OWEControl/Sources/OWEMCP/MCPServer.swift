import Foundation
import OWEControlProtocol

/// Where tool calls go: the running app's control channel (`SocketControlChannel`), or a fake in
/// tests. Throws `ControlError` for what the app refused, anything else when it couldn't be reached.
public protocol ControlChannel: AnyObject {
    func call(_ method: String, params: [String: JSONValue]) async throws -> JSONValue
    /// A call the app may take minutes to answer (`MCPTool.isLongRunning`).
    func call(_ method: String, params: [String: JSONValue], longRunning: Bool) async throws -> JSONValue
}

extension ControlChannel {
    public func call(_ method: String, params: [String: JSONValue], longRunning: Bool) async throws -> JSONValue {
        try await call(method, params: params)
    }
}

/// The Model Context Protocol server: JSON-RPC 2.0 messages in, responses out, one line each
/// (MCP's stdio transport). It answers `initialize`, `ping`, `tools/list`, `tools/call`,
/// `resources/list`, `resources/templates/list` and `resources/read`; notifications get no answer.
///
/// - A tool call checks its arguments against the tool's schema, then becomes the control request
///   of the same name. Its result comes back as structured content, with a one-line summary and
///   the JSON as text for clients without structured content; a snapshot's PNG as image content.
/// - A long-running tool call (`MCPTool.isLongRunning`) whose request carries
///   `_meta.progressToken` gets `notifications/progress` every `progressInterval` until it is
///   answered, so a client that resets its timeout on progress keeps waiting.
/// - What the app refuses, and an app that can't be reached, are tool errors (`isError`) with a
///   message saying why and what to do. An unknown tool or method is a JSON-RPC error.
public final class MCPServer {
    public static let protocolVersion = MCPProtocolVersion.latest
    public static let libraryResource = "owe://library"
    public static let statusResource = "owe://status"

    enum ErrorCode {
        static let parse = -32700
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let invalidParams = -32602
        static let internalError = -32603
        static let resourceNotFound = -32002
    }

    private let channel: ControlChannel
    private let version: String
    /// The revision agreed in `initialize`; what the messages may contain follows it.
    public private(set) var negotiatedVersion = MCPProtocolVersion.latest
    /// Requests the client cancelled before they were read (`notifications/cancelled`): answered
    /// with nothing. Requests run one at a time, so one already answered can't be cancelled.
    private var cancelled: Set<JSONValue> = []
    /// Where `snapshot` with `format: "path"` saves its PNGs.
    private let snapshotDirectory: URL
    /// Writes a notification line (without its newline) to the client, between responses.
    public var sendNotification: (@Sendable (Data) -> Void)?
    /// How often a long-running call with a progress token reports that it is still working.
    let progressInterval: TimeInterval

    public init(channel: ControlChannel, version: String,
                snapshotDirectory: URL = FileManager.default.temporaryDirectory.appending(path: "owe-mcp-snapshots", directoryHint: .isDirectory),
                progressInterval: TimeInterval = 5) {
        self.channel = channel
        self.version = version
        self.snapshotDirectory = snapshotDirectory
        self.progressInterval = progressInterval
    }

    /// The response line (without its newline) to one line read from the client; nil when the
    /// line needs no answer (a notification, a response, a blank line).
    public func handle(line: Data) async -> Data? {
        guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) else { return nil }
        let message: JSONValue
        do {
            message = try JSONValue.decode(line)
        } catch {
            return Self.encode(Self.error(id: .null, code: ErrorCode.parse, message: "Parse error: the line isn't JSON."))
        }
        return await handle(message: message).map(Self.encode)
    }

    /// The response to one JSON-RPC message, or nil for a notification or a response.
    public func handle(message: JSONValue) async -> JSONValue? {
        if case .array(let batch) = message, MCPProtocolVersion.allowsBatches(negotiatedVersion), !batch.isEmpty {
            // 2024-11-05 and 2025-03-26 allow JSON-RPC batches: one array of the answers.
            var responses: [JSONValue] = []
            for item in batch {
                if let response = await handle(message: item), response.arrayValue == nil { responses.append(response) }
            }
            return responses.isEmpty ? nil : .array(responses)
        }
        guard case .object(let object) = message else {
            // Batches were removed from MCP in 2025-06-18.
            return Self.error(id: .null, code: ErrorCode.invalidRequest, message: "Invalid request: expected one JSON-RPC object.")
        }
        let id = object["id"]
        guard object["jsonrpc"]?.stringValue == "2.0", let method = object["method"]?.stringValue else {
            // A response to something we never sent, or not JSON-RPC at all.
            if object["result"] != nil || object["error"] != nil { return nil }
            return Self.error(id: id ?? .null, code: ErrorCode.invalidRequest,
                              message: "Invalid request: expected \"jsonrpc\": \"2.0\" and a method.")
        }
        guard let id, Self.isValidID(id) else {
            if object["id"] != nil {
                return Self.error(id: .null, code: ErrorCode.invalidRequest, message: "Invalid request: the id must be a string or a number.")
            }
            notify(method, params: object["params"])
            return nil
        }
        if cancelled.remove(id) != nil { return nil }
        let params = object["params"] ?? .object([:])
        guard case .object(let parameters) = params else {
            return Self.error(id: id, code: ErrorCode.invalidParams, message: "Invalid params: expected an object.")
        }
        switch method {
        case "initialize": return Self.result(id: id, initialize(parameters))
        case "ping": return Self.result(id: id, .object([:]))
        case "tools/list":
            let version = negotiatedVersion
            return Self.result(id: id, ["tools": .array(MCPToolCatalog.tools.map { $0.definition(protocolVersion: version) })])
        case "tools/call": return await callTool(id: id, parameters)
        case "resources/list": return Self.result(id: id, ["resources": .array(Self.resources(protocolVersion: negotiatedVersion))])
        case "resources/templates/list": return Self.result(id: id, ["resourceTemplates": []])
        case "resources/read": return await readResource(id: id, parameters)
        default:
            return Self.error(id: id, code: ErrorCode.methodNotFound, message: "Method not found: \(method)")
        }
    }

    // MARK: - Lifecycle

    /// A notification: none is answered. `notifications/initialized` needs nothing more,
    /// `notifications/cancelled` drops a request not read yet, and any other is ignored.
    private func notify(_ method: String, params: JSONValue?) {
        switch method {
        case "notifications/cancelled":
            if let requestID = params?["requestId"], Self.isValidID(requestID) { cancelled.insert(requestID) }
        default:
            break // `notifications/initialized`, and notifications this server doesn't use.
        }
    }

    private func initialize(_ params: [String: JSONValue]) -> JSONValue {
        let agreed = MCPProtocolVersion.negotiate(params["protocolVersion"]?.stringValue)
        negotiatedVersion = agreed
        var serverInfo: [String: JSONValue] = ["name": "open-wallpaper-engine", "version": .string(version)]
        if MCPProtocolVersion.hasTitles(agreed) { serverInfo["title"] = "Open Wallpaper Engine" }
        return [
            "protocolVersion": .string(agreed),
            "capabilities": [
                "tools": ["listChanged": false],
                "resources": ["listChanged": false, "subscribe": false],
            ],
            "serverInfo": .object(serverInfo),
            "instructions": """
            Controls Open Wallpaper Engine, the wallpaper player on this Mac: its displays, library, \
            playback, user properties, playlists, settings and editors. Ids come from list_wallpapers and \
            list_displays; get_wallpaper lists a wallpaper's user properties. A scene wallpaper is edited \
            as its editors edit it: scene_get lists its layers, scene_apply_edits changes them in the \
            Wallpaper Editor's draft (one undo step, shown in its open window), scene_undo takes it back, \
            and wallpaper_editor_save saves the draft so the displays show it. Tools that delete need \
            confirm: true; ask the user first. The app's MCP Server plugin must be installed \
            (Settings › Plugins); owe-mcp starts the app when it isn't running.
            """,
        ]
    }

    // MARK: - Tools

    private func callTool(id: JSONValue, _ params: [String: JSONValue]) async -> JSONValue {
        guard let name = params["name"]?.stringValue else {
            return Self.error(id: id, code: ErrorCode.invalidParams, message: "Invalid params: tools/call needs the tool's name.")
        }
        guard let tool = MCPToolCatalog.tool(named: name) else {
            return Self.error(id: id, code: ErrorCode.invalidParams, message: "Unknown tool: \(name)")
        }
        let arguments = Self.coercingScalarsToStrings(params["arguments"] ?? .object([:]), schema: tool.inputSchema)
        let problems = JSONSchema.problems(arguments, against: tool.inputSchema)
        guard problems.isEmpty, case .object(let values) = arguments else {
            return Self.result(id: id, Self.toolError("Invalid arguments for \(name): " + problems.joined(separator: "; ") + "."))
        }
        var forwarded = values
        // How the client takes the picture is owe-mcp's business, not the app's.
        let savesToFile = tool.returnsImage && forwarded.removeValue(forKey: "format")?.stringValue == "path"
        let progress = tool.isLongRunning ? reportProgress(token: params["_meta"]?["progressToken"], tool: name) : nil
        // Stopped before the answer is returned: no report may follow it.
        defer { progress?.stop() }
        do {
            var result = try await channel.call(name, params: forwarded, longRunning: tool.isLongRunning)
            if savesToFile { result = try savingPicture(result) }
            return Self.result(id: id, Self.toolResult(tool, result, protocolVersion: negotiatedVersion))
        } catch let error as ControlError {
            return Self.result(id: id, Self.toolError(error.message))
        } catch {
            return Self.result(id: id, Self.toolError(Self.unreachableMessage(error)))
        }
    }

    /// Reports every `progressInterval` that the call is still running, until cancelled: the app
    /// doesn't say how far a render or a recording is, so the progress counts the reports and has
    /// no total. Nil without a token or a way to send.
    private func reportProgress(token: JSONValue?, tool: String) -> ProgressReporter? {
        guard let token, Self.isValidID(token), let send = sendNotification else { return nil }
        let interval = progressInterval, withMessage = MCPProtocolVersion.hasProgressMessages(negotiatedVersion)
        let reporter = ProgressReporter()
        reporter.task = Task {
            var reports = 0
            while true {
                do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) } catch { return }
                reports += 1
                var params: [String: JSONValue] = ["progressToken": token, "progress": .number(Double(reports))]
                if withMessage {
                    params["message"] = .string("\(tool) is still running (\(Int((Double(reports) * interval).rounded())) s).")
                }
                let line: Data = Self.encode(["jsonrpc": "2.0", "method": "notifications/progress", "params": .object(params)])
                guard reporter.sendUnlessStopped({ send(line) }) else { return }
            }
        }
        return reporter
    }

    /// `result` with its PNG saved to a file of its own (owner-only) instead: `path` replaces
    /// `png_base64`, for clients that can't show image content.
    private func savingPicture(_ result: JSONValue) throws -> JSONValue {
        guard case .object(var object) = result, let encoded = object.removeValue(forKey: "png_base64")?.stringValue,
              let png = Data(base64Encoded: encoded) else { return result }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let url = snapshotDirectory.appending(path: "snapshot-\(UUID().uuidString).png", directoryHint: .notDirectory)
        guard fileManager.createFile(atPath: url.path, contents: png, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        object["path"] = .string(url.path)
        return .object(object)
    }

    /// `arguments` with a number or boolean given for a string property as its text, and a list of
    /// numbers as WE writes a vector (`[1, 0.5, 0]` is `"1 0.5 0"`): strict clients only see string
    /// properties, and some models still send `2` for `"2"`. Objects inside the arguments
    /// (`scene_apply_edits`' edits) are read the same way.
    static func coercingScalarsToStrings(_ arguments: JSONValue, schema: JSONValue) -> JSONValue {
        guard case .object(var object) = arguments, let properties = schema["properties"]?.objectValue else { return arguments }
        for (key, value) in object {
            guard let property = properties[key] else { continue }
            switch (property["type"]?.stringValue, value) {
            case ("string", .bool(let flag)): object[key] = .string(flag ? "true" : "false")
            case ("string", .number(let number)): object[key] = .string(text(of: number))
            case ("string", .array(let items)) where !items.isEmpty && items.allSatisfy({ $0.doubleValue != nil }):
                object[key] = .string(items.compactMap(\.doubleValue).map(text(of:)).joined(separator: " "))
            case ("object", .object):
                object[key] = coercingScalarsToStrings(value, schema: property)
            case ("array", .array(let items)) where property["items"]?["type"]?.stringValue == "object":
                let item = property["items"] ?? .null
                object[key] = .array(items.map { coercingScalarsToStrings($0, schema: item) })
            default: break
            }
        }
        return .object(object)
    }

    private static func text(of number: Double) -> String {
        number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
    }

    static func toolResult(_ tool: MCPTool, _ result: JSONValue,
                           protocolVersion: String = MCPProtocolVersion.latest) -> JSONValue {
        var structured = result
        var content: [JSONValue] = []
        if tool.returnsImage, case .object(var object) = result, let png = object.removeValue(forKey: "png_base64") {
            structured = .object(object)
            content.append(["type": "image", "data": png, "mimeType": "image/png"])
        }
        var summary = tool.summary(result)
        if tool.returnsImage, let path = result["path"]?.stringValue { summary += " The PNG is at \(path)." }
        content.insert(["type": "text", "text": .string(summary)], at: 0)
        // Clients from before structured content read the result as text.
        if let json = try? structured.encodedLine(), let text = String(data: json, encoding: .utf8) { // Encoding a decoded value can't fail.
            content.append(["type": "text", "text": .string(text)])
        }
        guard MCPProtocolVersion.hasStructuredContent(protocolVersion) else {
            return ["content": .array(content), "isError": false]
        }
        return ["content": .array(content), "structuredContent": structured, "isError": false]
    }

    static func toolError(_ message: String) -> JSONValue {
        ["content": [["type": "text", "text": .string(message)]], "isError": true]
    }

    /// What to tell the client when the app couldn't be reached.
    static func unreachableMessage(_ error: Error) -> String {
        if let error = error as? AppConnectionError { return error.message }
        return "Open Wallpaper Engine couldn't be reached (\(error)). Make sure it is running with the MCP Server plugin installed (Settings › Plugins)."
    }

    // MARK: - Resources

    static func resources(protocolVersion: String) -> [JSONValue] {
        guard !MCPProtocolVersion.hasTitles(protocolVersion) else { return resources }
        return resources.map { resource in
            guard case .object(var object) = resource else { return resource }
            object.removeValue(forKey: "title")
            return .object(object)
        }
    }

    static let resources: [JSONValue] = [
        [
            "uri": .string(libraryResource), "name": "library", "title": "Wallpaper library",
            "description": "Every wallpaper in the library: id, title, type, tags, folder and Workshop id.",
            "mimeType": "application/json",
        ],
        [
            "uri": .string(statusResource), "name": "status", "title": "Playback status",
            "description": "What each display shows, playback, volume and the active playlist.",
            "mimeType": "application/json",
        ],
    ]

    private func readResource(id: JSONValue, _ params: [String: JSONValue]) async -> JSONValue {
        guard let uri = params["uri"]?.stringValue else {
            return Self.error(id: id, code: ErrorCode.invalidParams, message: "Invalid params: resources/read needs a uri.")
        }
        do {
            let value: JSONValue
            switch uri {
            case Self.libraryResource: value = try await wholeLibrary()
            case Self.statusResource: value = try await channel.call("get_status", params: [:])
            default:
                return Self.error(id: id, code: ErrorCode.resourceNotFound, message: "Resource not found: \(uri)")
            }
            let text = String(decoding: try value.encodedLine(), as: UTF8.self)
            return Self.result(id: id, ["contents": [["uri": .string(uri), "mimeType": "application/json", "text": .string(text)]]])
        } catch let error as ControlError {
            return Self.error(id: id, code: ErrorCode.internalError, message: error.message)
        } catch {
            return Self.error(id: id, code: ErrorCode.internalError, message: Self.unreachableMessage(error))
        }
    }

    /// Every page of `list_wallpapers`.
    private func wholeLibrary() async throws -> JSONValue {
        var wallpapers: [JSONValue] = []
        while true {
            let page = try await channel.call("list_wallpapers", params: ["limit": 500, "offset": .number(Double(wallpapers.count))])
            let items = page["wallpapers"]?.arrayValue ?? []
            wallpapers += items
            let total = page["total"]?.intValue ?? wallpapers.count
            if items.isEmpty || wallpapers.count >= total { break }
        }
        return ["total": .number(Double(wallpapers.count)), "wallpapers": .array(wallpapers)]
    }

    // MARK: - JSON-RPC

    private static func isValidID(_ id: JSONValue) -> Bool {
        switch id {
        case .string, .number: return true
        default: return false
        }
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    private static func encode(_ value: JSONValue) -> Data {
        // A value built from decoded JSON and strings always encodes.
        (try? value.encodedLine()) ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
    }
}

/// A call's progress reports: `stop()` returns only once no report is being sent, and none is
/// sent after it, so the call's answer is always the last line about it.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var task: Task<Void, Never>?

    /// Runs `send` while not stopped; false once stopped.
    func sendUnlessStopped(_ send: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return false }
        send()
        return true
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        task?.cancel()
    }
}
