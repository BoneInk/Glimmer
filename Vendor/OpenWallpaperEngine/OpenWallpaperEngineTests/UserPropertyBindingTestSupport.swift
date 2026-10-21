import Foundation
@testable import OpenWallpaperEngine

/// Decodes a document the way the loader does: its user bindings resolved with `properties`
/// through a `UserPropertyBindingTable`.
enum BoundDocument {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, properties: [String: String] = [:]) throws -> T {
        let document = try decodeTolerant(SceneJSON.self, from: data)
        let table = UserPropertyBindingTable()
        table.record(.scene, json: document)
        let resolved = table.resolvedDocument(document, document: .scene, properties: { properties[$0] })
        return try decodeTolerant(type, from: JSONSerialization.data(withJSONObject: resolved.foundationObject))
    }
}
