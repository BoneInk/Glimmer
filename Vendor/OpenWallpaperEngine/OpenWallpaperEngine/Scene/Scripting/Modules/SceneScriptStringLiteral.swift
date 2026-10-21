import Foundation

/// Reads a JavaScript string literal token's value (module specifiers, string export names) and
/// writes values back as literals that fit on one line, so the factory header adds no lines.
enum SceneScriptStringLiteral {
    /// The value of a string literal token, quotes included in `text`.
    static func value(of text: String) -> String {
        var units = Array(text.utf16)
        guard units.count >= 2 else { return "" }
        units = Array(units[1..<(units.count - 1)])
        var result: [UInt16] = []
        var index = 0
        while index < units.count {
            let unit = units[index]
            index += 1
            guard unit == 0x5C, index < units.count else {
                result.append(unit)
                continue
            }
            let escaped = units[index]
            index += 1
            switch escaped {
            case 0x6E: result.append(0x0A) // n
            case 0x74: result.append(0x09) // t
            case 0x72: result.append(0x0D) // r
            case 0x62: result.append(0x08) // b
            case 0x66: result.append(0x0C) // f
            case 0x76: result.append(0x0B) // v
            case 0x30 where index >= units.count || !SceneScriptSyntax.isDigit(units[index]):
                result.append(0)
            case 0x78: // xHH
                result.append(hexValue(units, &index, count: 2))
            case 0x75: // uHHHH or u{H…}
                if index < units.count, units[index] == 0x7B {
                    var end = index + 1
                    while end < units.count, units[end] != 0x7D { end += 1 }
                    let hex = String(decoding: units[(index + 1)..<end], as: UTF16.self)
                    index = min(end + 1, units.count)
                    if let scalar = UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init) {
                        result.append(contentsOf: Array(String(Character(scalar)).utf16))
                    }
                } else {
                    result.append(hexValue(units, &index, count: 4))
                }
            case 0x0D: // line continuation, CRLF included
                if index < units.count, units[index] == 0x0A { index += 1 }
            case 0x0A, 0x2028, 0x2029:
                break
            default:
                result.append(escaped)
            }
        }
        return String(decoding: result, as: UTF16.self)
    }

    /// `value` as a double-quoted literal on one line.
    static func literal(_ value: String) -> String {
        var text = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: text += "\\\""
            case 0x5C: text += "\\\\"
            case 0x0A: text += "\\n"
            case 0x0D: text += "\\r"
            case 0x00..<0x20, 0x2028, 0x2029: text += String(format: "\\u%04x", scalar.value)
            default: text.unicodeScalars.append(scalar)
            }
        }
        return text + "\""
    }

    private static func hexValue(_ units: [UInt16], _ index: inout Int, count: Int) -> UInt16 {
        let end = min(index + count, units.count)
        let hex = String(decoding: units[index..<end], as: UTF16.self)
        index = end
        return UInt16(hex, radix: 16) ?? 0
    }
}
