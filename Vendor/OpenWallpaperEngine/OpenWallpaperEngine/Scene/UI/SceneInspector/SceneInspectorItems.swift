import SwiftUI
import AVFoundation
import OWEInspectorKit
import OWESceneEditing

struct SceneInspectorItem: Identifiable {
    let id: String
    let name: String
    let kind: String
    let sourcePath: String
    let materialPath: String?
    let texturePaths: [String]
    let shaderPaths: [String]
    var rawObject: String
    var rawMaterial: String?
    var rawParticle: String?
    /// Drawn, as far as its own switch and authored `visible` say (dims the row and its children).
    var visible: Bool
    /// The alternative version the layer is (`SceneLayerVersion`), with its title.
    let version: (choice: SceneLayerVersion, title: String)?
    let effects: [SceneInspectorEffect]
    /// Video wallpapers have no authored object behind the layer, so it is description-only.
    var isSynthetic = false
    /// The object's visibility switch; nil for a synthetic layer.
    var visibility: SceneObjectVisibilitySwitch?
    /// The switch is on: shown, or, on an object a user property shows, not hidden by hand.
    var isSwitchedOn = true

    var isVersion: Bool { version != nil }
    var versionName: String? { version?.title }
}

/// A combo user property that switches whole layers (`SceneLayerVersion`): one Versions row in the
/// sidebar, with the property's options, as WE's properties sidebar shows it.
struct SceneVersionProperty: Identifiable {
    /// The property's key.
    let id: String
    let title: String
    let options: [(value: String, title: String)]
    /// project.json `condition`: the row shows only while it holds (a property for one language).
    let condition: UserPropertyConditionExpression?
}

struct SceneInspectorEffect: Identifiable {
    let id: String
    let name: String
    let title: String
    let maskPath: String?
    let controls: [SceneInspectorEffectControl]
    var combos: [SceneInspectorEffectCombo] = []
}

/// A `// [COMBO]` switch of the effect's shaders that WE's editor shows.
struct SceneInspectorEffectCombo: Identifiable {
    let id: String
    let effectID: String
    /// The preprocessor name, which the override is stored under.
    let combo: String
    let title: String
    /// WE's options as (title, value, the editor's group heading); an on/off switch when empty.
    let options: [(title: String, value: Int, group: String?)]
    /// Other combos' values this one is shown for, as WE's `require`.
    var requirements: [String: Int] = [:]
}

struct SceneInspectorEffectControl: Identifiable {
    let id: String
    let effectID: String
    let key: String
    let component: Int
    let title: String
    let minimum: Double
    let maximum: Double
    let defaultValue: Double
    let displaysDegrees: Bool
    /// From the uniform's annotation (`int`, `"type":"color"`, `linked`).
    var isInteger = false
    var isColor = false
    var isLinked = false
    var componentCount = 1
}

struct SceneInspectorTexture: Identifiable {
    let id: String
    let path: String
    let image: NSImage
}

enum SceneHorizontalSnap {
    case left, center, right
}

enum SceneVerticalSnap {
    case top, center, bottom
}
