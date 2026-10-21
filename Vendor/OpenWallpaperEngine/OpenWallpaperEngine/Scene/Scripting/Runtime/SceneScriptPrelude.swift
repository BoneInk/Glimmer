import Foundation

/// WE's JavaScript prelude, read unmodified from the assets directory: `baseclasses.js` (Vec2/3/4,
/// Mat3/4, `_Internal`, `createScriptProperties`, `shared`) and the importable `jsmodules`
/// (`WEMath`, `WEVector`, `WEColor`).
struct SceneScriptPrelude {
    struct Module {
        /// Lower-cased file name without extension; imports resolve case-insensitively.
        var name: String
        var source: String
    }

    var baseClasses: String?
    var modules: [Module]

    static let empty = SceneScriptPrelude(baseClasses: nil, modules: [])

    /// Reads the prelude from the first assets directory that has it.
    static func load(from directories: [URL] = WallpaperEngineAssets.searchDirectories) -> SceneScriptPrelude {
        guard let base = WallpaperEngineAssets.locate(["scripts/jsclasses/baseclasses.js"], in: directories) else {
            OWELog.error(.script, "WE script prelude (scripts/jsclasses/baseclasses.js) not found in the assets directory")
            return .empty
        }
        let scripts = base.deletingLastPathComponent().deletingLastPathComponent()
        var prelude = SceneScriptPrelude.empty
        do {
            prelude.baseClasses = try String(contentsOf: base, encoding: .utf8)
        } catch {
            OWELog.error(.script, "Reading \(base.path) failed: \(error.localizedDescription)")
        }
        let moduleDirectory = scripts.appending(path: "jsmodules")
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: moduleDirectory, includingPropertiesForKeys: nil)
        } catch {
            OWELog.error(.script, "Listing \(moduleDirectory.path) failed: \(error.localizedDescription)")
            return prelude
        }
        let scriptFiles = files.filter { $0.pathExtension.lowercased() == "js" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in scriptFiles {
            do {
                let source = try String(contentsOf: file, encoding: .utf8)
                let name = file.deletingPathExtension().lastPathComponent.lowercased()
                prelude.modules.append(Module(name: name, source: source))
            } catch {
                OWELog.error(.script, "Reading \(file.path) failed: \(error.localizedDescription)")
            }
        }
        return prelude
    }
}
