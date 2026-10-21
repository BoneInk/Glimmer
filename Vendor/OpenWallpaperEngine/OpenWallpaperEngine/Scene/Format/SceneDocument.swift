//
//  SceneModels.swift
//  Open Wallpaper Engine
//
//  Data models for Wallpaper Engine scene.json structure.
//  Decoded from scene.pkg → scene.json and referenced JSON files.
//

import Foundation

func sceneUserPropertyString(_ value: Any) -> String {
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        return number.stringValue
    }
    return String(describing: value)
}

func sceneAuthoredEffectOverrideKey(objectID: Int, effectIndex: Int, parameter: String) -> String {
    "_owe_authored_effect_\(objectID)_\(effectIndex)_\(parameter.lowercased())"
}

func sceneAuthoredEffectEnabledKey(objectID: Int, effectIndex: Int) -> String {
    "_owe_authored_effect_\(objectID)_\(effectIndex)_enabled"
}

/// How much work a changed user-property key actually requires from the renderer.
/// Most sliders are sampled live every frame and need no rebuild at all; only overrides that are
/// baked into the decoded scene JSON justify re-parsing the package.
enum SceneChangeImpact: Int, Comparable {
    case none = 0
    case rebuildContent = 1
    case reloadScene = 2

    static func < (lhs: SceneChangeImpact, rhs: SceneChangeImpact) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func impact(of key: String) -> SceneChangeImpact {
        // Syncing an effect parameter turns its baked literal into a live binding.
        if key.hasPrefix("_owe_authored_effect_"), key.hasSuffix("_musicSync") { return .rebuildContent }
        // Music-sync companions only modulate values that are already sampled live.
        if key.hasSuffix("_musicSync") || key.hasSuffix("_musicAmount") { return .none }

        if key.hasPrefix("_owe_scene_object_") {
            // Visibility and material blending are resolved while building content; JSON/origin
            // edits are baked in decodeScene.
            return key.hasSuffix("_visible") || key.hasSuffix("_blending") ? .rebuildContent : .reloadScene
        }
        if key.hasPrefix("_owe_scene_asset_") { return .reloadScene }

        if key.hasPrefix("_owe_authored_effect_") {
            // Per-object constants are captured when effects are built.
            return .rebuildContent
        }
        // Mouse parallax (the only remaining "_owe_effect_" keys) is read by the renderer every frame.
        if key.hasPrefix("_owe_effect_") { return .none }

        if key.hasPrefix("_owe_text_") {
            // Font, size, style, colour and opacity are all resampled per frame.
            return key.hasSuffix("_enabled") ? .rebuildContent : .none
        }

        // WE's image filter and colour options are read by the post-processing every frame.
        if WEColorCorrectionProperty.contains(key) { return .none }

        switch key {
        case "_owe_hue", "_owe_saturation", "_owe_bloom", "_owe_blur", "_owe_speed":
            return .none
        default:
            // Authored properties can gate layer/effect visibility, so rebuild to be safe.
            return .rebuildContent
        }
    }

    static func aggregate(_ keys: [String]) -> SceneChangeImpact {
        keys.reduce(.none) { Swift.max($0, impact(of: $1)) }
    }
}

func sceneObjectVisibilityKey(objectID: Int) -> String {
    "_owe_scene_object_\(objectID)_visible"
}

/// Scene Edit / Export's material blending for an object's image or particle system
/// (`WEMaterialBlending`), in place of its material's first pass's.
func sceneObjectBlendingKey(objectID: Int) -> String {
    "_owe_scene_object_\(objectID)_blending"
}

/// Scene Edit / Export's replacement for a package file's JSON (`path` as the package names it,
/// e.g. `materials/a.json`): the whole file's text.
func sceneAssetOverrideKey(path: String) -> String {
    "\(sceneAssetOverridePrefix)\(path)\(sceneAssetOverrideSuffix)"
}

/// The package path a `sceneAssetOverrideKey` names; nil for any other key.
func sceneAssetOverridePath(fromKey key: String) -> String? {
    guard key.hasPrefix(sceneAssetOverridePrefix), key.hasSuffix(sceneAssetOverrideSuffix),
          key.count > sceneAssetOverridePrefix.count + sceneAssetOverrideSuffix.count else { return nil }
    return String(key.dropFirst(sceneAssetOverridePrefix.count).dropLast(sceneAssetOverrideSuffix.count))
}

private let sceneAssetOverridePrefix = "_owe_scene_asset_"
private let sceneAssetOverrideSuffix = "_json"

// MARK: - Top-level Scene

struct WEScene: Decodable {
    var camera: WECamera
    var general: WESceneGeneral
    var objects: [WESceneObject]
    var effects: [String]?
    var version: Int?
}

/// scene.json's `camera` block (0x1401881fc): the static camera of a scene without camera layers
/// or paths. WE's defaults for a missing vector are `SceneCameraDefaults`.
struct WECamera: Decodable {
    var center: String?
    var eye: String?
    var up: String?
    /// `paths`: camera-path files (`WESceneCameraPathFile`), played in order and looped.
    var paths: [String]?

    init(center: String? = nil, eye: String? = nil, up: String? = nil, paths: [String]? = nil) {
        self.center = center
        self.eye = eye
        self.up = up
        self.paths = paths
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let info = decoder.userInfo
        center = c.decodeLogged(String.self, forKey: AnyCodingKey(stringValue: "center"), userInfo: info)
        eye = c.decodeLogged(String.self, forKey: AnyCodingKey(stringValue: "eye"), userInfo: info)
        up = c.decodeLogged(String.self, forKey: AnyCodingKey(stringValue: "up"), userInfo: info)
        paths = c.decodeElements(String.self, forKey: AnyCodingKey(stringValue: "paths"), userInfo: info)
    }
}

struct WESceneGeneral: Decodable {
    /// `orthogonalprojection` as WE reads it (docs/models-plan.md §2.1).
    var projection = WESceneProjection.perspective
    var bloomtint: String?
    /// The light budget; nil when the scene has none, which leaves every new-style light unused.
    var lightconfig: WELightConfig?
    /// Every bindable field in its full authored form (literal, `user`, `script`, `animation`).
    var values: [SceneGeneralValueField: SceneRawValue] = [:]

    // Literal fallbacks of the bindable fields.
    var clearcolor: String? { values[.clearcolor]?.literalString }
    var ambientcolor: String? { values[.ambientcolor]?.literalString }
    var skylightcolor: String? { values[.skylightcolor]?.literalString }
    var bloom: Bool? { values[.bloom]?.literalBool }
    var bloomstrength: Double? { values[.bloomstrength]?.literalDouble }
    var bloomthreshold: Double? { values[.bloomthreshold]?.literalDouble }
    var hdr: Bool? { values[.hdr]?.literalBool }
    var fov: Double? { values[.fov]?.literalDouble }
    var nearz: Double? { values[.nearz]?.literalDouble }
    var farz: Double? { values[.farz]?.literalDouble }
    var zoom: Double? { values[.zoom]?.literalDouble }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let info = decoder.userInfo
        for field in SceneGeneralValueField.allCases {
            if let raw = container.decodeLogged(SceneRawValue.self, forKey: AnyCodingKey(stringValue: field.rawValue), userInfo: info) {
                values[field] = raw
            }
        }
        let projectionKey = AnyCodingKey(stringValue: "orthogonalprojection")
        projection = WESceneProjection(json: container.decodeLogged(SceneJSON.self, forKey: projectionKey, userInfo: info))
        bloomtint = container.decodeLogged(SceneRawValue.self, forKey: AnyCodingKey(stringValue: "bloomtint"), userInfo: info)?.literalString
        lightconfig = container.decodeLogged(WELightConfig.self, forKey: AnyCodingKey(stringValue: "lightconfig"), userInfo: info)
    }
}

// MARK: - Scene Objects
