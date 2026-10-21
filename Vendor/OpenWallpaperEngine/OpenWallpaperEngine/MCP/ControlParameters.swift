import Foundation
import OWEControlProtocol

/// A request's parameters, read with their expected types. A value of the wrong type is a
/// `ControlError` naming the parameter (`invalid_params`), so a client learns what to send.
struct ControlParameters {
    let raw: [String: JSONValue]

    init(_ raw: [String: JSONValue]) { self.raw = raw }

    /// Whether the parameter was given (and isn't null).
    func has(_ key: String) -> Bool {
        guard let value = raw[key] else { return false }
        return !value.isNull
    }

    func string(_ key: String) throws -> String? {
        guard let value = raw[key], !value.isNull else { return nil }
        guard let text = value.stringValue else { throw ControlError(.invalidParams, "\(key) must be a string.") }
        return text
    }

    func required(_ key: String) throws -> String {
        guard let text = try string(key), !text.isEmpty else { throw ControlError(.invalidParams, "\(key) is required.") }
        return text
    }

    func strings(_ key: String) throws -> [String] {
        guard let value = raw[key], !value.isNull else { return [] }
        guard let items = value.arrayValue?.compactMap(\.stringValue), items.count == value.arrayValue?.count else {
            throw ControlError(.invalidParams, "\(key) must be a list of strings.")
        }
        return items
    }

    func int(_ key: String) throws -> Int? {
        guard let value = raw[key], !value.isNull else { return nil }
        guard let number = value.intValue else { throw ControlError(.invalidParams, "\(key) must be a whole number.") }
        return number
    }

    func requiredInt(_ key: String) throws -> Int {
        guard let number = try int(key) else { throw ControlError(.invalidParams, "\(key) is required.") }
        return number
    }

    func ints(_ key: String) throws -> [Int] {
        guard let value = raw[key], !value.isNull else { return [] }
        guard let items = value.arrayValue?.compactMap(\.intValue), items.count == value.arrayValue?.count else {
            throw ControlError(.invalidParams, "\(key) must be a list of whole numbers.")
        }
        return items
    }

    func double(_ key: String) throws -> Double? {
        guard let value = raw[key], !value.isNull else { return nil }
        guard let number = value.doubleValue else { throw ControlError(.invalidParams, "\(key) must be a number.") }
        return number
    }

    func requiredDouble(_ key: String) throws -> Double {
        guard let number = try double(key) else { throw ControlError(.invalidParams, "\(key) is required.") }
        return number
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = raw[key], !value.isNull else { return nil }
        guard let flag = value.boolValue else { throw ControlError(.invalidParams, "\(key) must be true or false.") }
        return flag
    }

    func requiredBool(_ key: String) throws -> Bool {
        guard let flag = try bool(key) else { throw ControlError(.invalidParams, "\(key) is required: true or false.") }
        return flag
    }

    /// A list of objects (`scene_apply_edits`' `edits`), each read as parameters of its own.
    func objects(_ key: String) throws -> [ControlParameters] {
        guard let value = raw[key], !value.isNull else { return [] }
        guard let items = value.arrayValue else { throw ControlError(.invalidParams, "\(key) must be a list of objects.") }
        return try items.enumerated().map { index, item in
            guard let object = item.objectValue else {
                throw ControlError(.invalidParams, "\(key)[\(index)] must be an object.")
            }
            return ControlParameters(object)
        }
    }
}
