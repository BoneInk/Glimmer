import Foundation

/// A number of a particle file (or another WE asset) that may be written as text or as
/// `{"value": …}`. WE reads particle files' numbers as plain JSON numbers (wallpaper64.exe
/// 0x140086220); only scene.json properties take scripts (the one reader of `"script"`, the
/// scriptable-property loader 0x1401a4db0), so a `script` here is ignored, as in WE.
@propertyWrapper
struct WEFlexibleDouble: Codable {
    var wrappedValue: Double?

    init(wrappedValue: Double? = nil) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
            let number: Double? = try? keyed.decodeIfPresent(Double.self, forKey: .value)
            let text: String? = try? keyed.decodeIfPresent(String.self, forKey: .value)
            wrappedValue = number ?? text.flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        } else {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                wrappedValue = number
            } else if let string = try? container.decode(String.self) {
                wrappedValue = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                wrappedValue = nil
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case value }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

@propertyWrapper
struct WEFlexibleInt: Codable {
    var wrappedValue: Int?

    init(wrappedValue: Int? = nil) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            wrappedValue = number
        } else if let string = try? container.decode(String.self) {
            wrappedValue = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            wrappedValue = nil
        }
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: WEFlexibleDouble.Type, forKey key: Key) throws -> WEFlexibleDouble {
        try decodeIfPresent(type, forKey: key) ?? WEFlexibleDouble()
    }

    func decode(_ type: WEFlexibleInt.Type, forKey key: Key) throws -> WEFlexibleInt {
        try decodeIfPresent(type, forKey: key) ?? WEFlexibleInt()
    }
}

/// A value that can be either a number or a string (e.g. "0 -3000 0")
enum WEFlexValue: Codable {
    case number(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let num = try? container.decode(Double.self) {
            self = .number(num)
        } else if let str = try? container.decode(String.self) {
            self = .string(str)
        } else {
            self = .number(0)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        }
    }

    var doubleValue: Double {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s) ?? 0
        }
    }

    var vectorValue: (Double, Double, Double) {
        switch self {
        case .number(let n): return (n, n, n)
        case .string(let s): return s.parseVector3()
        }
    }
}

extension String {
    /// Parse "x y z" space-separated vector string
    func parseVector3() -> (Double, Double, Double) {
        let parts = self.split(separator: " ").compactMap { Double($0) }
        return (
            parts.count > 0 ? parts[0] : 0,
            parts.count > 1 ? parts[1] : 0,
            parts.count > 2 ? parts[2] : 0
        )
    }

    /// Parse "x y" space-separated 2D vector
    func parseVector2() -> (Double, Double) {
        let parts = self.split(separator: " ").compactMap { Double($0) }
        return (
            parts.count > 0 ? parts[0] : 0,
            parts.count > 1 ? parts[1] : 0
        )
    }
}
