import Foundation

extension UserPropertyBindingTable {
    /// The scene as its parsers read scene.json (`document`, recorded as `.scene`) with
    /// `properties`: every bound value resolved. The authored `scene` when nothing is bound.
    func resolvedScene(_ scene: WEScene, document: SceneJSON, properties: (String) -> String?) throws -> WEScene {
        guard hasBindings(in: .scene) else { return scene }
        return try Self.decode(WEScene.self, from: resolvedDocument(document, document: .scene, properties: properties))
    }

    /// A document no load records (an object a script creates) resolved with `properties`.
    static func resolving(_ json: SceneJSON, properties: (String) -> String?) -> SceneJSON {
        let table = UserPropertyBindingTable()
        table.record(.asset(""), json: json)
        return table.resolvedDocument(json, document: .asset(""), properties: properties)
    }

    /// `T` decoded from `json` the way the loader decodes files.
    static func decode<T: Decodable>(_ type: T.Type, from json: SceneJSON) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: json.foundationObject))
    }
}
