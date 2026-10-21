import Foundation
import OWEControlProtocol

/// One MCP tool: its schema for `tools/list`, and how its result reads. A call is the control
/// request of the same name with the tool's arguments as its parameters (`docs/mcp.md`).
public struct MCPTool: Sendable {
    public struct Annotations: Sendable {
        public var readOnly = false
        public var destructive = false
        public var idempotent = false
    }

    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: JSONValue
    public let annotations: Annotations
    /// The result has a PNG (`png_base64`), returned as image content.
    let returnsImage: Bool
    /// The app may take minutes to answer (a render, a recording, a depth map): the call waits
    /// the channel's long-call time (`SocketControlChannel`, 15 minutes) instead of the usual one.
    let isLongRunning: Bool
    /// A sentence saying what happened, from the app's result.
    let summary: @Sendable (JSONValue) -> String

    init(_ name: String, title: String, description: String, input: JSONValue = JSONSchema.object([:]),
         annotations: Annotations = Annotations(), returnsImage: Bool = false, longRunning: Bool = false,
         summary: @escaping @Sendable (JSONValue) -> String) {
        self.name = name
        self.title = title
        self.description = description
        inputSchema = input
        self.annotations = annotations
        self.returnsImage = returnsImage
        isLongRunning = longRunning
        self.summary = summary
    }

    /// The tool as `tools/list` lists it to a client of `protocolVersion`: `title` from
    /// 2025-06-18, `annotations` from 2025-03-26, and the input schema as plain JSON Schema that
    /// strict clients accept (no `additionalProperties`; unknown arguments are still refused).
    func definition(protocolVersion: String = MCPProtocolVersion.latest) -> JSONValue {
        var definition: [String: JSONValue] = [
            "name": .string(name),
            "description": .string(description),
            "inputSchema": Self.portable(inputSchema),
        ]
        if MCPProtocolVersion.hasTitles(protocolVersion) { definition["title"] = .string(title) }
        if MCPProtocolVersion.hasToolAnnotations(protocolVersion) {
            definition["annotations"] = [
                "title": .string(title),
                "readOnlyHint": .bool(annotations.readOnly),
                "destructiveHint": .bool(annotations.destructive),
                "idempotentHint": .bool(annotations.idempotent),
                // Everything happens in the app on this Mac.
                "openWorldHint": false,
            ]
        }
        return .object(definition)
    }

    /// `schema` without `additionalProperties`, which some clients reject or strip.
    static func portable(_ schema: JSONValue) -> JSONValue {
        switch schema {
        case .object(var object):
            object.removeValue(forKey: "additionalProperties")
            return .object(object.mapValues(portable))
        case .array(let items):
            return .array(items.map(portable))
        default:
            return schema
        }
    }
}

extension MCPTool.Annotations {
    static let readOnly = MCPTool.Annotations(readOnly: true, destructive: false, idempotent: true)
    static let idempotent = MCPTool.Annotations(readOnly: false, destructive: false, idempotent: true)
    static let change = MCPTool.Annotations(readOnly: false, destructive: false, idempotent: false)
    /// Removes or replaces something the user made (a playlist, a wallpaper, edits): clients ask first.
    static let destructive = MCPTool.Annotations(readOnly: false, destructive: true, idempotent: false)
}

/// The MCP revisions `owe-mcp` speaks, and what each allows in its messages.
public enum MCPProtocolVersion {
    public static let latest = "2025-06-18"
    /// Newest first; a client asking for another gets `latest`.
    public static let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// The version to answer a client's `initialize` with.
    public static func negotiate(_ requested: String?) -> String {
        requested.flatMap { supported.contains($0) ? $0 : nil } ?? latest
    }

    /// `title` on tools, resources and `serverInfo`; structured tool results; `outputSchema`.
    public static func hasTitles(_ version: String) -> Bool { version >= "2025-06-18" }
    public static func hasStructuredContent(_ version: String) -> Bool { version >= "2025-06-18" }
    /// Tool annotations (`readOnlyHint`…).
    public static func hasToolAnnotations(_ version: String) -> Bool { version >= "2025-03-26" }
    /// A `message` in `notifications/progress`.
    public static func hasProgressMessages(_ version: String) -> Bool { version >= "2025-03-26" }
    /// JSON-RPC batches: allowed before 2025-06-18, which removed them.
    public static func allowsBatches(_ version: String) -> Bool { version < "2025-06-18" }
}
