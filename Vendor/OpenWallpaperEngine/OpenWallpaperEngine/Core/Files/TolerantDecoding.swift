import Foundation

/// Always succeeds; used to step an unkeyed container past an element that failed to decode.
private struct SkippedElement: Decodable {
    init(from decoder: Decoder) throws {}
}

/// Logs a skipped element once and records it in the decoder's `DecodeFailureLog`, if any.
func reportSkippedElement(_ userInfo: [CodingUserInfoKey: Any], path: [CodingKey], error: Error) {
    let where_ = path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    let message = "skipped \(where_): \(error)"
    OWELog.error(.scene, message)
    (userInfo[.decodeFailureLog] as? DecodeFailureLog)?.record(message)
}

extension KeyedDecodingContainer {
    /// Decodes an array element by element: a bad element is logged and skipped, not the whole array.
    /// Returns nil when the key is absent or null; a non-array value is logged and yields nil.
    func decodeElements<T: Decodable>(_ type: T.Type, forKey key: Key,
                                      userInfo: [CodingUserInfoKey: Any]) -> [T]? {
        guard contains(key) else { return nil }
        do {
            if try decodeNil(forKey: key) { return nil }
            var array = try nestedUnkeyedContainer(forKey: key)
            var result: [T] = []
            while !array.isAtEnd {
                let index = array.currentIndex
                do {
                    result.append(try array.decode(T.self))
                } catch {
                    reportSkippedElement(userInfo, path: codingPath + [key, AnyCodingKey(intValue: index)!], error: error)
                    _ = try array.decode(SkippedElement.self)
                }
            }
            return result
        } catch {
            reportSkippedElement(userInfo, path: codingPath + [key], error: error)
            return nil
        }
    }

    /// Decodes a string-keyed dictionary entry by entry: a bad entry is logged and skipped.
    func decodeEntries<T: Decodable>(_ type: T.Type, forKey key: Key,
                                     userInfo: [CodingUserInfoKey: Any]) -> [String: T]? {
        guard contains(key) else { return nil }
        do {
            if try decodeNil(forKey: key) { return nil }
            let object = try nestedContainer(keyedBy: AnyCodingKey.self, forKey: key)
            var result: [String: T] = [:]
            for entry in object.allKeys {
                do {
                    result[entry.stringValue] = try object.decode(T.self, forKey: entry)
                } catch {
                    reportSkippedElement(userInfo, path: codingPath + [key, entry], error: error)
                }
            }
            return result
        } catch {
            reportSkippedElement(userInfo, path: codingPath + [key], error: error)
            return nil
        }
    }

    /// Decodes an optional field; a present but malformed value is logged and yields nil.
    func decodeLogged<T: Decodable>(_ type: T.Type, forKey key: Key,
                                    userInfo: [CodingUserInfoKey: Any]) -> T? {
        do {
            return try decodeIfPresent(T.self, forKey: key)
        } catch {
            reportSkippedElement(userInfo, path: codingPath + [key], error: error)
            return nil
        }
    }
}
