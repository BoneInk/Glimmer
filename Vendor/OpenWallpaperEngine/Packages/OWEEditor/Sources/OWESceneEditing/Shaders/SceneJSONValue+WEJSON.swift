import Foundation
import WEFormat

extension WEJSONDocument {
    /// `value` as JsonCpp holds it, for `WEJSONWriter`: a whole number without a fraction (WE's
    /// `"version" : 1`) is an integer, any other number a real.
    public init(_ value: SceneJSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let flag): self = .bool(flag)
        case .number(let number):
            self = number.rounded() == number && abs(number) < 1e15 ? .integer(Int64(number)) : .real(number)
        case .string(let text): self = .string(text)
        case .array(let values): self = .array(values.map(WEJSONDocument.init))
        case .object(let members): self = .object(members.mapValues(WEJSONDocument.init))
        }
    }
}

extension SceneJSONValue {
    /// The value as WE's editor writes a project's effect and material files (WE's
    /// `effects/<name>/effect.json` of a new effect): `WEJSONWriter`'s `editor` style.
    public var editorJSON: String {
        WEJSONWriter.string(WEJSONDocument(self), style: .editor)
    }
}
