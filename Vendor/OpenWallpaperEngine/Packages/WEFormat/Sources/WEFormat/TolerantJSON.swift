import Foundation

/// Collects the elements that element-wise decoding skipped. Pass one to `decodeTolerant` (or put
/// it in `JSONDecoder.userInfo[.decodeFailureLog]`) to inspect failures, e.g. in tests.
public final class DecodeFailureLog {
    private var storage: [String] = []
    private let lock = NSLock()

    public init() {}

    public var messages: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    public func record(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(message)
    }
}

extension CodingUserInfoKey {
    public static let decodeFailureLog = CodingUserInfoKey(rawValue: "owe.decodeFailureLog")!
}

/// Reads WE's JSON text as WE's own reader does. What WE's text files may start with is a UTF-8
/// byte order mark, which WE's readers skip and Foundation's don't; this is the one place that
/// skips it. `//` and `/* */` comments and trailing commas are allowed too: WE ships such files
/// (the `water` preset's `preset.json` has trailing commas, and its editor lists it).
public enum TolerantJSON {
    public static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Whether `bytes` start with a UTF-8 byte order mark.
    public static func hasBOM<Bytes: Collection>(_ bytes: Bytes) -> Bool where Bytes.Element == UInt8 {
        bytes.starts(with: byteOrderMark)
    }

    /// `data` without a leading UTF-8 byte order mark.
    public static func withoutBOM(_ data: Data) -> Data {
        hasBOM(data) ? Data(data.dropFirst(byteOrderMark.count)) : data
    }

    /// The file's value as `JSONSerialization` reads it.
    public static func object(from data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: cleaned(data), options: [.fragmentsAllowed])
    }

    /// `data` without its byte order mark, comments and trailing commas; strings are kept as
    /// they are.
    static func cleaned(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        if hasBOM(bytes) { bytes.removeFirst(byteOrderMark.count) }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        let slash = UInt8(ascii: "/"), star = UInt8(ascii: "*"), quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
        let newline = UInt8(ascii: "\n"), comma = UInt8(ascii: ",")
        while index < bytes.count {
            let byte = bytes[index]
            if byte == quote {
                // A string, copied whole with its escapes.
                output.append(byte)
                index += 1
                while index < bytes.count {
                    let inner = bytes[index]
                    output.append(inner)
                    index += 1
                    if inner == backslash, index < bytes.count {
                        output.append(bytes[index])
                        index += 1
                    } else if inner == quote {
                        break
                    }
                }
                continue
            }
            if byte == slash, index + 1 < bytes.count, bytes[index + 1] == slash {
                while index < bytes.count, bytes[index] != newline { index += 1 }
                continue
            }
            if byte == slash, index + 1 < bytes.count, bytes[index + 1] == star {
                index += 2
                while index + 1 < bytes.count, !(bytes[index] == star && bytes[index + 1] == slash) { index += 1 }
                index = min(index + 2, bytes.count)
                continue
            }
            if byte == comma, closesAfter(bytes, from: index + 1) {
                index += 1
                continue
            }
            output.append(byte)
            index += 1
        }
        return Data(output)
    }

    /// Whether the next token after `start` (past white space and comments) closes an object or array.
    private static func closesAfter(_ bytes: [UInt8], from start: Int) -> Bool {
        var index = start
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                index += 1
            case UInt8(ascii: "/") where index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "/"):
                while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { index += 1 }
            case UInt8(ascii: "/") where index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "*"):
                index += 2
                while index + 1 < bytes.count, !(bytes[index] == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/")) {
                    index += 1
                }
                index += 2
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                return true
            default:
                return false
            }
        }
        return false
    }
}

/// Decodes WE JSON, which may contain trailing commas, comments or a UTF-8 BOM
/// (the stock fluidsimulation effect.json has a trailing comma).
public func decodeTolerant<T: Decodable>(_ type: T.Type, from data: Data, failures: DecodeFailureLog? = nil) throws -> T {
    let decoder = JSONDecoder()
    decoder.allowsJSON5 = true
    if let failures { decoder.userInfo[.decodeFailureLog] = failures }
    return try decoder.decode(T.self, from: TolerantJSON.withoutBOM(data))
}

/// A coding key for dictionaries with arbitrary keys.
public struct AnyCodingKey: CodingKey {
    public let stringValue: String
    public let intValue: Int?
    public init(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    public init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}
