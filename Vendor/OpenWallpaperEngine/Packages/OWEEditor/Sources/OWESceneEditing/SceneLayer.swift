import Foundation

/// One effect of a layer, as scene.json lists it.
public struct SceneLayerEffect: Identifiable, Hashable, Sendable {
    /// Its index in the object's `effects`, which edits name it by.
    public let id: Int
    /// `effects/<name>/effect.json`.
    public let file: String
    /// The authored `name`, when the author gave one.
    public let name: String?
    public let visible: SceneJSONValue?
    /// The key its edits are stored under (`SceneEditOverlay.EffectEdit`): its authored index
    /// (`"0"`), or `"+1"` for one added in the editor.
    public var key: String
    /// Its first pass's `constantshadervalues`, `combos` and `textures` as the scene has them.
    public var constants: [String: SceneJSONValue] = [:]
    public var combos: [String: Int] = [:]
    public var textures: [SceneJSONValue] = []
    /// Every pass's `textures` as the scene has them (the first is `textures`): a multi-pass
    /// effect's mask is named in the pass that samples it (Blur's in its fourth).
    public var passTextures: [[SceneJSONValue]] = []
    /// How many passes the scene lists for it.
    public var passCount = 0

    public init(id: Int, file: String, name: String?, visible: SceneJSONValue?, key: String? = nil) {
        self.id = id
        self.file = file
        self.name = name
        self.visible = visible
        self.key = key ?? String(id)
    }

    /// Whether the editor added it (it isn't in the wallpaper's scene).
    public var isAdded: Bool { key.hasPrefix("+") }

    /// The effect's folder, which names WE's built-in effects (`blur`, `waterripple`, …).
    public var folderName: String {
        ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent.lowercased()
    }

    /// The authored name, else the folder's, as Scene Edit / Export titles it.
    public var title: String {
        if let name, !name.isEmpty { return name }
        return folderName.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// One scene object of scene.json, with what the editor reads of it.
public struct SceneLayer: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case image, text, particle, sound, light, model, group, other

        /// The SF Symbol the layer lists show for the kind.
        public var symbol: String {
            switch self {
            case .image: return "photo"
            case .text: return "textformat"
            case .particle: return "sparkles"
            case .sound: return "speaker.wave.2"
            case .light: return "lightbulb"
            case .model: return "cube"
            case .group: return "folder"
            case .other: return "square.dashed"
            }
        }
    }

    /// Its `id`, or its index when it has none (as Scene Edit / Export and the overlay key it).
    public let id: Int
    /// Its position in scene.json's `objects`: the draw order, later on top.
    public let index: Int
    public let name: String?
    public let kind: Kind
    public let parentID: Int?
    /// The authored fields, except `effects`.
    public let fields: [String: SceneJSONValue]
    public let effects: [SceneLayerEffect]

    /// The file the layer draws: its model, particle system or sound.
    public var sourcePath: String? {
        for key in ["image", "particle", "model"] {
            if let path = fields[key]?.stringValue { return path }
        }
        if case .array(let sounds)? = fields["sound"] { return sounds.first?.stringValue }
        return nil
    }

    /// A flat layer the canvas can select and transform with the gizmo.
    public var isPlanar: Bool { (kind == .image && !fillsScene) || kind == .text }

    /// What the layer is called in the list.
    public func displayName(fallback: (Kind, Int) -> String) -> String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return fallback(kind, index + 1)
    }
}
