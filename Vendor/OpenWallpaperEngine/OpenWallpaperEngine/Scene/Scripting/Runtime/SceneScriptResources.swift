import Foundation

/// The runtime's own JavaScript files, bundled from `Resources/SceneScript/`.
enum SceneScriptResources {
    struct Missing: Error, CustomStringConvertible {
        var name: String
        var description: String { "SceneScript resource \(name).js is missing from the app bundle" }
    }

    static func source(named name: String) throws -> String {
        let bundle = Bundle(for: SceneScriptRuntime.self)
        guard let url = bundle.url(forResource: name, withExtension: "js", subdirectory: "SceneScript")
            ?? bundle.url(forResource: name, withExtension: "js") else { throw Missing(name: name) }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
