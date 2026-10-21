import Foundation

/// The control channel's framing and version. Each message is one line of JSON: a client writes a
/// `ControlRequest` and reads the `ControlResponse` with the same id, one at a time per connection.
public enum ControlProtocol {
    /// Bumped when a request or result changes incompatibly; the app answers a request of another
    /// version with `ControlError.Code.versionMismatch`.
    public static let version = 1
    /// The longest line either side reads (a snapshot's PNG is the largest result).
    public static let maxLineBytes = 32 << 20
}

/// A request to the app: a method (an MCP tool's name, `docs/mcp.md`) and its parameters.
public struct ControlRequest: Codable, Sendable, Equatable {
    public var version: Int
    public var id: Int
    public var method: String
    public var params: [String: JSONValue]

    public init(id: Int, method: String, params: [String: JSONValue] = [:], version: Int = ControlProtocol.version) {
        self.version = version
        self.id = id
        self.method = method
        self.params = params
    }

    enum CodingKeys: String, CodingKey { case version, id, method, params }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decode(Int.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent([String: JSONValue].self, forKey: .params) ?? [:]
    }
}

/// The app's answer: a result, or an error.
public struct ControlResponse: Codable, Sendable, Equatable {
    public var version: Int
    /// The request's id; 0 when the request couldn't be read.
    public var id: Int
    public var result: JSONValue?
    public var error: ControlError?

    public init(id: Int, result: JSONValue) {
        version = ControlProtocol.version
        self.id = id
        self.result = result
        error = nil
    }

    public init(id: Int, error: ControlError) {
        version = ControlProtocol.version
        self.id = id
        result = nil
        self.error = error
    }
}

/// Why a request failed, with a message meant for the person or model that asked.
public struct ControlError: Error, Codable, Sendable, Equatable, LocalizedError {
    public enum Code: String, Codable, Sendable {
        /// The line isn't a request.
        case invalidRequest = "invalid_request"
        case unknownMethod = "unknown_method"
        /// A parameter is missing, of the wrong type or out of range.
        case invalidParams = "invalid_params"
        /// No such wallpaper, display, playlist or property.
        case notFound = "not_found"
        /// The request can't apply to this wallpaper (an editor for a video, say).
        case unsupported
        /// The app refused, so the user decides (an untrusted web wallpaper).
        case refused
        case failed
        /// The app isn't reachable: not running, or control is turned off.
        case unavailable
        case versionMismatch = "version_mismatch"
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

extension ControlRequest {
    /// The request encoded as one line, newline included.
    public func line() throws -> Data {
        try Self.encoder.encode(self) + Data([0x0A])
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension ControlResponse {
    /// The response encoded as one line, newline included.
    public func line() throws -> Data {
        try ControlRequest.encoder.encode(self) + Data([0x0A])
    }
}
