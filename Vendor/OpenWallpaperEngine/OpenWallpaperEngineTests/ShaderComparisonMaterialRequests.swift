import Foundation
@testable import OpenWallpaperEngine

/// The shader requests WE's own files make, for `ShaderComparisonSuiteTests`: every material
/// pass (`passes[].shader`, its `combos` and the slots its `textures` fill), every effect pass
/// (`effect.json`: its material's first pass, plus the slots its `bind`s fill) and every effect
/// instance of a scene (`scene.json`: the effect pass under the instance pass's `combos` and
/// `textures`, as `SceneEffectPlanBuilder` pairs instance pass n with effect pass n). The suite
/// resolves each with `ShaderVariantTranslator.resolveCombos` and the engine's combos, as the
/// loaders do, so the corpus holds the variants real materials build.
struct ShaderComparisonMaterialRequests {
    struct Request {
        /// WE's shader name (`effects/blur`), as the material pass names it.
        var shader: String
        /// The effect's folder for a Workshop effect's own `shaders/` and textures, or "".
        var directory: String
        /// The material file, for its textures.
        var materialPath: String
        /// Combo layers, lowest first: material pass, effect pass, instance pass.
        var overrides: [[String: Int]]
        /// Texture name per filled slot (render targets and binds included).
        var textures: [Int: String]
    }

    let readFile: (String) -> Data?

    /// Requests of every JSON file under `root` (hidden files skipped), in path order.
    func requests(under root: URL) -> [Request] {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else { return [] }
        let base = root.standardizedFileURL.path
        var paths: [String] = []
        for case let url as URL in files where url.pathExtension == "json" {
            paths.append(String(url.standardizedFileURL.path.dropFirst(base.count + 1)))
        }
        var result: [Request] = []
        for path in paths.sorted() {
            guard let object = Self.json(readFile(path) ?? Data()) else { continue }
            if let objects = object["objects"] as? [[String: Any]] {
                for object in objects {
                    for instance in object["effects"] as? [[String: Any]] ?? [] {
                        guard let file = instance["file"] as? String else { continue }
                        result += effectRequests(file, instancePasses: instance["passes"] as? [[String: Any]] ?? [])
                    }
                }
            } else if let passes = object["passes"] as? [[String: Any]] {
                if passes.contains(where: { $0["shader"] is String }) {
                    result += materialRequests(path, passes: passes, directory: "", extra: [], textures: [:])
                } else if (path as NSString).lastPathComponent == "effect.json" {
                    result += effectRequests(path, instancePasses: [])
                }
            }
        }
        return result
    }

    /// The effect's material passes under the instance's passes (by index).
    private func effectRequests(_ file: String, instancePasses: [[String: Any]]) -> [Request] {
        guard let effect = Self.json(readFile(file) ?? Data()),
              let passes = effect["passes"] as? [[String: Any]] else { return [] }
        let directory = (file as NSString).deletingLastPathComponent
        var result: [Request] = []
        for (index, pass) in passes.enumerated() {
            guard let material = pass["material"] as? String else { continue }
            let instance = index < instancePasses.count ? instancePasses[index] : [:]
            var textures: [Int: String] = [:]
            for (slot, name) in (instance["textures"] as? [Any] ?? []).enumerated() {
                if let name = name as? String, !name.isEmpty { textures[slot] = name }
            }
            for bind in pass["bind"] as? [[String: Any]] ?? [] {
                if let name = bind["name"] as? String, let slot = (bind["index"] as? NSNumber)?.intValue { textures[slot] = name }
            }
            let extra = [Self.combos(pass["combos"]), Self.combos(instance["combos"])]
            for path in ["\(directory)/\(material)", material] {
                guard let data = readFile(path), let document = Self.json(data),
                      let materialPasses = document["passes"] as? [[String: Any]] else { continue }
                result += materialRequests(path, passes: Array(materialPasses.prefix(1)),
                                           directory: path == material ? "" : directory, extra: extra, textures: textures)
                break
            }
        }
        return result
    }

    private func materialRequests(_ path: String, passes: [[String: Any]], directory: String,
                                  extra: [[String: Int]], textures: [Int: String]) -> [Request] {
        passes.compactMap { pass in
            guard let shader = pass["shader"] as? String else { return nil }
            var filled: [Int: String] = [:]
            for (slot, name) in (pass["textures"] as? [Any] ?? []).enumerated() {
                if let name = name as? String, !name.isEmpty { filled[slot] = name }
            }
            filled.merge(textures) { _, later in later }
            return Request(shader: shader, directory: directory, materialPath: path,
                           overrides: [Self.combos(pass["combos"])] + extra, textures: filled)
        }
    }

    /// A `combos` object's values as integers (numbers, numeric strings and booleans).
    static func combos(_ value: Any?) -> [String: Int] {
        var result: [String: Int] = [:]
        for (name, value) in value as? [String: Any] ?? [:] {
            if let number = value as? NSNumber {
                result[name.uppercased()] = number.intValue
            } else if let text = value as? String, let number = Int(text) {
                result[name.uppercased()] = number
            }
        }
        return result
    }

    static func json(_ data: Data) -> [String: Any]? {
        // Optional: a file that isn't a JSON object makes no request.
        try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any]
    }
}
