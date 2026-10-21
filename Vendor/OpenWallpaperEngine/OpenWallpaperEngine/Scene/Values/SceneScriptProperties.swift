import Foundation

/// A script's `scriptproperties` object, kept as canonical JSON so it is Equatable and Sendable.
struct SceneScriptProperties: Equatable {
    /// Canonical (sorted-key) JSON of the properties object.
    let json: Data

    static let empty = SceneScriptProperties(json: [:])

    init(json dictionary: [String: Any]) {
        do {
            json = try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
        } catch {
            OWELog.error(.scene, "SceneScriptProperties: cannot encode \(dictionary.keys.sorted()): \(error)")
            json = Data("{}".utf8)
        }
    }

    /// The properties as JSONSerialization objects.
    var dictionary: [String: Any] {
        do {
            return try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        } catch {
            OWELog.error(.scene, "SceneScriptProperties: cannot decode stored JSON: \(error)")
            return [:]
        }
    }
}
