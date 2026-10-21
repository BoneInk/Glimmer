import Foundation

/// The typed field list of a scene object as scripts see it (lib.sceneScript.d.ts `ILayer` and
/// its parts): where each field sits in `SceneScriptObjectTable`, its script type and its default.
/// `objects-layers.js` generates the layer accessors from this list, so a field added here is a
/// live member without hand-written JS.
enum SceneScriptObjectField: String, CaseIterable {
    case origin, angles, scale, alpha, color, visible, parallaxDepth, size
    case pointsize, maxwidth, maxrows, padding, limitrows, limitwidth, opaquebackground, backgroundcolor
    case perspective, solid, volume, playing, fov, zoom, rootmotion
    case instanceAlpha, instanceSize, instanceCount, instanceSpeed, instanceLifetime, instanceRate, instanceColorn
    case controlpoint0, controlpoint1, controlpoint2, controlpoint3
    case controlpoint4, controlpoint5, controlpoint6, controlpoint7
    /// An image layer's `brightness` (WE's image property table, wallpaper64.exe 0x1401ee520:
    /// a float that multiplies the colour).
    case brightness
    /// A light's fields (WE's light property table, wallpaper64.exe 0x14025da80; docs/lighting-plan.md
    /// §1.1). They aren't `ILayer` members (lib.sceneScript.d.ts has no light interface), but a
    /// script bound to one sets it every frame, as WE's native property is (the Knight 2515150033
    /// flickers its legacy light by a script on `intensity`). `color` and the transform are the
    /// object's own fields.
    case intensity, radius, exponent, innercone, outercone, controlpoint

    /// Which JS object carries the member.
    enum Group: String {
        /// `ILayer` (and its parts: image, text, sound, particle system, model, camera).
        case layer
        /// `IParticleSystemInstance` (`thisLayer.instance`).
        case instance
        /// Native state behind a method (`isPlaying()`), not a member.
        case state
    }

    /// How the JS accessor converts: `degrees` is a `Vec3` stored in radians.
    enum ValueType: String {
        case number, bool, vec2, vec3, degrees
    }

    typealias Layout = SceneScriptObjectTable.Layout

    var offset: Int {
        switch self {
        case .origin: return Layout.origin
        case .angles: return Layout.angles
        case .scale: return Layout.scale
        case .alpha: return Layout.alpha
        case .color: return Layout.color
        case .visible: return Layout.visible
        case .parallaxDepth: return Layout.parallaxDepth
        case .size: return Layout.size
        case .pointsize: return Layout.pointsize
        case .maxwidth: return Layout.maxwidth
        case .maxrows: return Layout.maxrows
        case .padding: return Layout.padding
        case .limitrows: return Layout.limitrows
        case .limitwidth: return Layout.limitwidth
        case .opaquebackground: return Layout.opaquebackground
        case .backgroundcolor: return Layout.backgroundcolor
        case .perspective: return Layout.perspective
        case .solid: return Layout.solid
        case .volume: return Layout.volume
        case .playing: return Layout.playing
        case .fov: return Layout.fov
        case .zoom: return Layout.zoom
        case .rootmotion: return Layout.rootmotion
        case .instanceAlpha: return Layout.instance
        case .instanceSize: return Layout.instance + 1
        case .instanceCount: return Layout.instance + 2
        case .instanceSpeed: return Layout.instance + 3
        case .instanceLifetime: return Layout.instance + 4
        case .instanceRate: return Layout.instance + 5
        case .instanceColorn: return Layout.instance + 6
        case .controlpoint0, .controlpoint1, .controlpoint2, .controlpoint3,
             .controlpoint4, .controlpoint5, .controlpoint6, .controlpoint7:
            return Layout.controlPoints + 3 * (controlPointIndex ?? 0)
        case .brightness: return Layout.brightness
        case .intensity: return Layout.intensity
        case .radius: return Layout.radius
        case .exponent: return Layout.exponent
        case .innercone: return Layout.innercone
        case .outercone: return Layout.outercone
        case .controlpoint: return Layout.controlpoint
        }
    }

    var type: ValueType {
        switch self {
        case .origin, .scale, .color, .backgroundcolor, .controlpoint: return .vec3
        case .controlpoint0, .controlpoint1, .controlpoint2, .controlpoint3,
             .controlpoint4, .controlpoint5, .controlpoint6, .controlpoint7: return .vec3
        case .angles: return .degrees
        case .parallaxDepth, .size: return .vec2
        case .visible, .limitrows, .limitwidth, .opaquebackground, .perspective, .solid, .playing, .rootmotion:
            return .bool
        default: return .number
        }
    }

    var group: Group {
        switch self {
        case .playing: return .state
        case .instanceAlpha, .instanceSize, .instanceCount, .instanceSpeed, .instanceLifetime, .instanceRate,
             .instanceColorn, .controlpoint0, .controlpoint1, .controlpoint2, .controlpoint3,
             .controlpoint4, .controlpoint5, .controlpoint6, .controlpoint7:
            return .instance
        default: return .layer
        }
    }

    /// The member name in WE's API (`instance.alpha` is `alpha` on the instance object).
    var scriptName: String {
        switch self {
        case .instanceAlpha: return "alpha"
        case .instanceSize: return "size"
        case .instanceCount: return "count"
        case .instanceSpeed: return "speed"
        case .instanceLifetime: return "lifetime"
        case .instanceRate: return "rate"
        case .instanceColorn: return "colorn"
        default: return rawValue
        }
    }

    /// `size` is computed by the renderer (lib.sceneScript.d.ts `readonly size: Vec2`): member
    /// writes are ignored, but a script bound to it sets it (WE's property is writable natively).
    var isReadOnly: Bool { self == .size || self == .playing }

    /// Whether scripts see the field as a member of `ILayer`. The light fields aren't members: only
    /// a script bound to one reads and sets it (`objects-layers.js`, `sceneScriptBinding.js`).
    var isMember: Bool {
        switch self {
        case .intensity, .radius, .exponent, .innercone, .outercone, .controlpoint: return false
        default: return true
        }
    }

    var components: Int {
        switch type {
        case .number, .bool: return 1
        case .vec2: return 2
        case .vec3, .degrees: return 3
        }
    }

    /// WE's defaults for a field the object leaves out: unit scale, colour, alpha and instance
    /// multipliers, visible, solid, parallax depth (1, 1) (`WESceneObject.parallaxDepthValue`).
    /// WE's object constructor starts every object visible and solid (flags 0x2001 at
    /// wallpaper64.exe 0x1401ddc72).
    var defaultValue: [Float] {
        switch self {
        case .scale, .color: return [1, 1, 1]
        case .parallaxDepth: return [1, 1]
        case .alpha, .visible, .solid, .volume, .zoom, .brightness, .instanceAlpha, .instanceSize, .instanceCount, .instanceSpeed,
             .instanceLifetime, .instanceRate, .instanceColorn: return [1]
        // The light constructor's (`SceneLightDefaults`).
        case .intensity: return [SceneLightDefaults.intensity]
        case .radius: return [SceneLightDefaults.radius]
        case .exponent: return [SceneLightDefaults.exponent]
        case .innercone: return [SceneLightDefaults.innerCone]
        case .outercone: return [SceneLightDefaults.outerCone]
        case .controlpoint:
            let point = SceneLightDefaults.controlPoint
            return [point.x, point.y, point.z]
        default: return Array(repeating: 0, count: components)
        }
    }

    private var controlPointIndex: Int? {
        guard rawValue.hasPrefix("controlpoint") else { return nil }
        return Int(rawValue.dropFirst("controlpoint".count))
    }

    /// The list `objects-layers.js` builds accessors from.
    static var javaScriptObject: [[String: Any]] {
        allCases.map {
            ["field": $0.rawValue, "name": $0.scriptName, "offset": $0.offset, "type": $0.type.rawValue,
             "group": $0.group.rawValue, "readOnly": $0.isReadOnly, "member": $0.isMember]
        }
    }
}
