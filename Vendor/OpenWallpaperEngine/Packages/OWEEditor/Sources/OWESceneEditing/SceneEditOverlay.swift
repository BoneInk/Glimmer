import CryptoKit
import Foundation
import WEFormat

/// The Wallpaper Editor's edits of one wallpaper: object fields and effect changes kept beside the
/// wallpaper, never written into its files (editor-plan notes §3). The scene loader applies them
/// on top of scene.json (`applied(to:)`) wherever the wallpaper runs; Revert drops them; Save as
/// Local Wallpaper bakes them into a copy.
///
/// Objects are keyed by their scene.json `id` (their index when they have none), effects by their
/// index in the object's `effects`, as Scene Edit / Export's edits are.
public struct SceneEditOverlay: Codable, Hashable, Sendable {
    /// The newest version this app reads. A file is written as version 1 while it holds only what
    /// version 1 knew (field, effect visibility and constant edits), so an older app still reads it.
    public static let currentVersion = 2

    public struct EffectEdit: Codable, Hashable, Sendable {
        /// The effect's `visible`; nil keeps the authored one.
        public var visible: Bool?
        /// Values of its first pass's `constants`, by the material key.
        public var constants: [String: SceneJSONValue] = [:]
        /// Values of its first pass's `combos`, by the combo name (version 2).
        public var combos: [String: Int]?
        /// Its passes' `textures` by slot (`textureKey`: `"1"` for the first pass's `g_Texture1`,
        /// `"3:1"` for the fourth's): a texture path, or null for the shader's default (version 2).
        public var textures: [String: SceneJSONValue]?
        /// Constants a user property sets, by the material key: the property's name, or `""` for a
        /// constant the scene binds that the editor set free again (version 2).
        public var bindings: [String: String]?

        public init(visible: Bool? = nil, constants: [String: SceneJSONValue] = [:]) {
            self.visible = visible
            self.constants = constants
        }

        public var isEmpty: Bool {
            visible == nil && constants.isEmpty && (combos ?? [:]).isEmpty && (textures ?? [:]).isEmpty
                && (bindings ?? [:]).isEmpty
        }

        /// The `textures` key of `slot` in pass `pass` (0, the first, keeps the plain slot number).
        public static func textureKey(pass: Int, slot: Int) -> String {
            pass == 0 ? String(slot) : "\(pass):\(slot)"
        }

        /// The pass and slot a `textures` key names; nil for one that names neither.
        static func passAndSlot(_ key: String) -> (pass: Int, slot: Int)? {
            let parts = key.split(separator: ":", omittingEmptySubsequences: false)
            switch parts.count {
            case 1: return Int(parts[0]).map { (0, $0) }
            case 2:
                guard let pass = Int(parts[0]), let slot = Int(parts[1]), pass >= 0 else { return nil }
                return (pass, slot)
            default: return nil
            }
        }

        var needsVersion2: Bool { !(combos ?? [:]).isEmpty || !(textures ?? [:]).isEmpty || !(bindings ?? [:]).isEmpty }
    }

    public struct ObjectEdit: Codable, Hashable, Sendable {
        /// Object fields by scene.json name (`origin`, `scale`, `angles`, `alpha`, `color`,
        /// `colorBlendMode`, `visible`, …), each replacing the authored value.
        public var fields: [String: SceneJSONValue] = [:]
        /// Effect edits by the effect's index.
        public var effects: [String: EffectEdit] = [:]
        /// Editor state, not a scene edit: the layer can't be picked or moved on the canvas.
        public var locked: Bool?
        /// The effects in order, by key: an authored effect's index (`"0"`), an added one's `"+1"`.
        /// One the list leaves out is removed. Nil keeps the authored list (version 2).
        public var effectOrder: [String]?
        /// Effects added from the catalog, by key (`"+1"`): the effect's scene.json object (version 2).
        public var addedEffects: [String: SceneJSONValue]?

        public init(fields: [String: SceneJSONValue] = [:], effects: [String: EffectEdit] = [:], locked: Bool? = nil) {
            self.fields = fields
            self.effects = effects
            self.locked = locked
        }

        public var hasSceneEdits: Bool {
            !fields.isEmpty || effects.values.contains { !$0.isEmpty } || effectOrder != nil || !(addedEffects ?? [:]).isEmpty
        }
        var isEmpty: Bool { !hasSceneEdits && locked != true }

        var needsVersion2: Bool {
            effectOrder != nil || !(addedEffects ?? [:]).isEmpty || effects.values.contains(where: \.needsVersion2)
        }
    }

    /// A layer the editor added: its scene.json object, given `id` when applied.
    public struct AddedObject: Codable, Hashable, Sendable {
        public var id: Int
        public var object: SceneJSONValue

        public init(id: Int, object: SceneJSONValue) {
            self.id = id
            self.object = object
        }
    }

    public var version = SceneEditOverlay.currentVersion
    public var objects: [String: ObjectEdit] = [:]
    /// Layers added in the editor, in the order they were added (version 2).
    public var added: [AddedObject]?
    /// Layers deleted in the editor, by id (version 2).
    public var removed: [Int]?
    /// Every layer's id in draw order (first drawn first) once the editor reordered them; nil keeps
    /// the scene's order with added layers on top (version 2).
    public var order: [Int]?
    /// Property timelines the editor made, changed or removed (`SceneTimelineEdits`); nil for none
    /// (version 2).
    public var timelines: SceneTimelineEdits?
    /// Scripts, user-property bindings and the user properties themselves (`SceneAuthoring`);
    /// nil when none were authored (version 2).
    public var authoring: SceneAuthoring?
    /// Puppet Warp rigs made or edited in the editor, by the image layer's key
    /// (`SceneEditOverlay+Puppets`). They don't change the running scene; Save as Local
    /// Wallpaper writes them as `.mdl` files (`PuppetSceneBake`) (version 2).
    public var puppets: [String: PuppetDocument]?
    /// The particle editor's systems and documents (`SceneParticleOverlay`); nil without any
    /// (version 2).
    public var particles: SceneParticleOverlay?
    /// Scene settings (scene.json's `general`) by name, each replacing the authored value; nil
    /// for none (version 2).
    public var general: [String: SceneJSONValue]?
    /// The files of the effects made in the editor (New / Duplicate Effect, the shader editor's
    /// edits) by their path in the wallpaper (`effects/<name>/effect.json`, its materials and
    /// shaders), as text (`SceneEditOverlay+EffectFiles`); nil for none (version 2).
    public var effectFiles: [String: String]?
    /// project.json edits besides the user properties (the title, `SceneProjectEdits`); nil for
    /// none (version 2).
    public var project: SceneProjectEdits?
    /// JSON documents the scene's own layers read that the editor changed (an image layer's
    /// material), by path (`SceneEditOverlay+Documents`); nil for none (version 2).
    public var documents: [String: SceneJSONValue]?

    public init(objects: [String: ObjectEdit] = [:]) {
        self.objects = objects
    }

    /// Nothing to save: no edits and no locked layers.
    public var isEmpty: Bool {
        objects.values.allSatisfy(\.isEmpty) && !hasStructureEdits && timelines?.isEmpty != false
            && authoring?.isEmpty != false && !hasPuppetEdits && particles?.isEmpty != false && !hasGeneralEdits
            && !hasEffectFiles && project?.isEmpty != false && !hasDocumentEdits
    }

    /// Something changes the scene (locks don't). Authored properties count: they are edits of
    /// the wallpaper, and Save as New Wallpaper writes them.
    public var hasSceneEdits: Bool {
        objects.values.contains(where: \.hasSceneEdits) || hasStructureEdits || timelines?.isEmpty == false
            || authoring?.isEmpty == false || particles?.isEmpty == false || hasGeneralEdits || hasEffectFiles
            || project?.isEmpty == false || hasDocumentEdits
    }

    /// Scene settings changed.
    public var hasGeneralEdits: Bool { !(general ?? [:]).isEmpty }

    /// Layers added, deleted or reordered.
    public var hasStructureEdits: Bool { !(added ?? []).isEmpty || !(removed ?? []).isEmpty || order != nil }

    /// Holds something version 1 can't apply.
    var needsVersion2: Bool {
        hasStructureEdits || timelines?.isEmpty == false || authoring?.isEmpty == false || hasPuppetEdits
            || particles?.isEmpty == false || hasGeneralEdits || hasEffectFiles || project?.isEmpty == false
            || hasDocumentEdits
            || objects.values.contains(where: \.needsVersion2)
    }

    // MARK: Reading

    public func field(_ name: String, of objectID: Int) -> SceneJSONValue? {
        objects[String(objectID)]?.fields[name]
    }

    public func effectVisible(_ effectIndex: Int, of objectID: Int) -> Bool? {
        objects[String(objectID)]?.effects[String(effectIndex)]?.visible
    }

    public func effectConstant(_ key: String, effect effectIndex: Int, of objectID: Int) -> SceneJSONValue? {
        objects[String(objectID)]?.effects[String(effectIndex)]?.constants[key]
    }

    /// The edit of the scene setting `general.<name>`.
    public func generalSetting(_ name: String) -> SceneJSONValue? { general?[name] }

    public func isLocked(_ objectID: Int) -> Bool { objects[String(objectID)]?.locked == true }

    public func hasEdits(_ objectID: Int) -> Bool {
        objects[String(objectID)]?.hasSceneEdits == true || timelines?.touches(layer: objectID) == true
    }

    // MARK: Changing

    /// Sets field `name` of the object; nil drops the edit (the authored value again).
    public mutating func setField(_ name: String, to value: SceneJSONValue?, of objectID: Int) {
        update(objectID) { $0.fields[name] = value }
    }

    /// Sets the scene setting `general.<name>`; nil drops the edit (the authored value again).
    public mutating func setGeneralSetting(_ name: String, to value: SceneJSONValue?) {
        var settings = general ?? [:]
        settings[name] = value
        general = settings.isEmpty ? nil : settings
    }

    public mutating func setEffectVisible(_ visible: Bool?, effect effectIndex: Int, of objectID: Int) {
        updateEffect(effectIndex, of: objectID) { $0.visible = visible }
    }

    public mutating func setEffectConstant(_ key: String, to value: SceneJSONValue?, effect effectIndex: Int, of objectID: Int) {
        updateEffect(effectIndex, of: objectID) { $0.constants[key] = value }
    }

    public mutating func setLocked(_ locked: Bool, _ objectID: Int) {
        update(objectID) { $0.locked = locked ? true : nil }
    }

    mutating func update(_ objectID: Int, _ change: (inout ObjectEdit) -> Void) {
        let key = String(objectID)
        var edit = objects[key] ?? ObjectEdit()
        change(&edit)
        objects[key] = edit.isEmpty ? nil : edit
    }

    private mutating func updateEffect(_ effectIndex: Int, of objectID: Int, _ change: (inout EffectEdit) -> Void) {
        updateEffect(key: String(effectIndex), of: objectID, change)
    }

    /// Changes the edit of the effect with `key` (`"0"`, `"+1"`; `SceneLayerEffect.key`).
    mutating func updateEffect(key: String, of objectID: Int, _ change: (inout EffectEdit) -> Void) {
        update(objectID) { edit in
            var effect = edit.effects[key] ?? EffectEdit()
            change(&effect)
            edit.effects[key] = effect.isEmpty ? nil : effect
        }
    }

    // MARK: Files

    /// Sorted, so the same edits always write the same bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var written = self
        written.version = needsVersion2 ? 2 : 1
        return try encoder.encode(written)
    }

    public static func decoded(from data: Data) throws -> SceneEditOverlay {
        var overlay = try JSONDecoder().decode(SceneEditOverlay.self, from: data)
        guard overlay.version <= currentVersion else { throw SceneEditOverlayError.newerVersion(overlay.version) }
        // In memory every overlay is the current version; `encoded()` writes the one it needs.
        overlay.version = currentVersion
        return overlay
    }

    /// Names the scene edits (not the locks, nor the user properties and project settings, which
    /// change project.json only) for the scene cache key: a parse is only reused for the edits it
    /// was made with.
    public var digest: String {
        var sceneEdits = self
        sceneEdits.project = nil
        sceneEdits.authoring?.properties = nil
        if sceneEdits.authoring?.isEmpty == true { sceneEdits.authoring = nil }
        sceneEdits.puppets = nil
        for (key, edit) in sceneEdits.objects {
            sceneEdits.objects[key]?.locked = nil
            if !edit.hasSceneEdits { sceneEdits.objects[key] = nil }
        }
        guard let data = EditorLog.attempt("Scene edits: digest", { try sceneEdits.encoded() }) else { return "" }
        return Digest.hex(SHA256.hash(data: data).prefix(12))
    }
}

public enum SceneEditOverlayError: Error, Equatable, LocalizedError {
    /// Written by a newer app, whose edits this one might apply wrong.
    case newerVersion(Int)
    /// scene.json isn't an object with an `objects` array.
    case notAScene

    public var errorDescription: String? {
        switch self {
        case .newerVersion(let version): return "The editor overlay is version \(version), newer than this app reads."
        case .notAScene: return "scene.json has no objects."
        }
    }
}
