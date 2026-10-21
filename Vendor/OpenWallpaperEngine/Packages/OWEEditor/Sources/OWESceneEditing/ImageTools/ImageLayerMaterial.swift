import CoreGraphics
import Foundation
import WEFormat

/// An image layer's picture as its files say: the model (`image`), the model's material and the
/// material's first pass, which the image tools read and write copies of.
public struct ImageLayerMaterial {
    /// The layer's `image`.
    public var modelPath: String
    public var model: [String: Any]
    /// The model's `material`.
    public var materialPath: String
    public var material: [String: Any]

    /// The first pass's textures (`g_Texture0`, `g_Texture1` …); a missing slot is `NSNull`.
    public var textures: [Any] {
        (MaterialPassDocument.firstPass(of: material)?["textures"] as? [Any]) ?? []
    }

    /// The picture (`g_Texture0`).
    public var texture: String? {
        guard let texture = textures.first as? String, !texture.isEmpty, !texture.hasPrefix("_rt") else { return nil }
        return texture
    }

    /// The normal map (`g_Texture1`, WE's genericimage shaders' `NORMALMAP`).
    public var normalMap: String? {
        guard textures.count > 1, let texture = textures[1] as? String, !texture.isEmpty else { return nil }
        return texture
    }

    /// The first pass's `combos`.
    public var combos: [String: Int] {
        let raw = MaterialPassDocument.firstPass(of: material)?["combos"] as? [String: Any] ?? [:]
        return raw.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    /// The layer's files, read with `readFile` (the wallpaper's, then the edits' own); nil for a
    /// layer that isn't a picture or whose files can't be read (the scene's load reports those).
    public init?(layer: SceneLayer, readFile: (String) -> Data?) {
        guard layer.imageRole == .picture, let modelPath = layer.fields["image"]?.stringValue else { return nil }
        self.init(modelPath: modelPath, readFile: readFile)
    }

    public init?(modelPath: String, readFile: (String) -> Data?) {
        // Optional: a file that is missing or isn't JSON means there is no material to change.
        guard let modelData = readFile(modelPath),
              let model = (try? TolerantJSON.object(from: modelData)) as? [String: Any],
              let materialPath = model["material"] as? String, let materialData = readFile(materialPath),
              let material = (try? TolerantJSON.object(from: materialData)) as? [String: Any],
              material["passes"] is [[String: Any]] else { return nil }
        self.modelPath = modelPath
        self.model = model
        self.materialPath = materialPath
        self.material = material
    }

    /// The material with the first pass changed by `change`.
    func changingFirstPass(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
        MaterialPassDocument.changingFirstPass(of: material, change)
    }

    /// The material drawing `normalMap` as its normal map (nil removes it), with lighting on when
    /// neither WE's Lighting nor Reflection is (the normal map only draws with one of them,
    /// `genericimage2`'s `require`), as an author turns Lighting on before Generate shows.
    public func materialWithNormalMap(_ normalMap: String?) -> [String: Any] {
        changingFirstPass { pass in
            var textures = pass["textures"] as? [Any] ?? []
            if let normalMap {
                while textures.count < 2 { textures.append(textures.isEmpty ? "" : NSNull()) }
                textures[1] = normalMap
                var combos = pass["combos"] as? [String: Any] ?? [:]
                let lighting = (combos["LIGHTING"] as? NSNumber)?.intValue ?? 0
                let reflection = (combos["REFLECTION"] as? NSNumber)?.intValue ?? 0
                if lighting == 0 && reflection == 0 { combos["LIGHTING"] = 1 }
                pass["combos"] = combos
            } else if textures.count > 1 {
                textures[1] = NSNull()
                while let last = textures.last, last is NSNull { textures.removeLast() }
            }
            pass["textures"] = textures
        }
    }

    /// The material drawing `texture` as its picture.
    public func materialWithTexture(_ texture: String) -> [String: Any] {
        changingFirstPass { pass in
            var textures = pass["textures"] as? [Any] ?? []
            if textures.isEmpty { textures.append(texture) } else { textures[0] = texture }
            pass["textures"] = textures
        }
    }

    /// The name the picture's texture is known by (its last path component).
    public static func baseName(of texture: String) -> String {
        (texture as NSString).lastPathComponent
    }
}

extension EditorAssetStore {
    /// Writes `material` and a copy of the layer's model drawing it into the edits' files, named
    /// by their content; returns the new model's path, the layer's next `image`.
    public func writeLayerMaterial(_ material: [String: Any], basedOn source: ImageLayerMaterial) throws -> String {
        let materialData = try JSONSerialization.data(withJSONObject: material, options: [.prettyPrinted, .sortedKeys])
        let materialTitle = ((source.materialPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let materialPath = "materials/editor/\(Self.assetName(materialTitle, data: materialData)).json"
        try write(materialData, to: materialPath)
        var model = source.model
        model["material"] = materialPath
        let modelData = try JSONSerialization.data(withJSONObject: model, options: [.prettyPrinted, .sortedKeys])
        let modelTitle = ((source.modelPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let modelPath = "models/editor/\(Self.assetName(modelTitle, data: modelData)).json"
        try write(modelData, to: modelPath)
        return modelPath
    }

    /// Writes a generated normal map as WE writes one (RG88, `rg88`): `materials/editor/<name>_normal.tex`
    /// after the picture's texture, as WE names it `<texture>_normal`. Returns its texture path.
    public func writeNormalMap(_ image: CGImage, forTexture texture: String) throws -> String {
        guard let encoder else { throw ImportError.needsEncoder(ImageLayerMaterial.baseName(of: texture)) }
        let data = try encoder.normalMap(image)
        let name = Self.assetName(ImageLayerMaterial.baseName(of: texture), data: data) + "_normal"
        try write(data, to: "materials/editor/\(name).tex")
        return "editor/\(name)"
    }
}
