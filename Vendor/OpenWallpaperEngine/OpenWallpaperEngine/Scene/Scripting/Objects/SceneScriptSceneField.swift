import Foundation

/// The scene's own script-visible values (lib.sceneScript.d.ts `IScene` settings and
/// `get/setCameraTransforms`), laid out in the one-slot scene buffer of `SceneScriptObjectModel`.
/// `objects-scene.js` generates `thisScene`'s accessors from this list.
enum SceneScriptSceneField: String, CaseIterable {
    case bloom, bloomstrength, bloomthreshold, clearenabled, clearcolor, ambientcolor, skylightcolor
    case fov, nearz, farz, camerafade
    case camerashake, camerashakespeed, camerashakeamplitude, camerashakeroughness
    case cameraparallax, cameraparallaxamount, cameraparallaxdelay, cameraparallaxmouseinfluence
    /// `CameraTransforms`: not members of `thisScene`, read and written through
    /// `getCameraTransforms()`/`setCameraTransforms()`.
    case cameraEye, cameraCenter, cameraUp, cameraZoom
    /// The HDR bloom's `general` fields (docs/lighting-plan.md §1.2). `IScene` doesn't declare them,
    /// so they aren't members, but a script bound to one sets it (2350874185 binds one to
    /// `bloomhdrstrength`), and WE recomputes the bloom's constants whenever the scene changes
    /// (0x140184020).
    case bloomhdrstrength, bloomhdrthreshold, bloomhdrfeather, bloomhdrscatter, bloomhdriterations
    /// The distance and height fog (`SceneFogSettings`). WE registers them in the scene's property
    /// table with the other `general` settings (0x14019a312…, beside `skylightcolor`), each with the
    /// fog's writer 0x140186440 as its change handler, so a script's write moves `g_Fog*` at once.
    /// scenescript64.dll resolves `thisScene` members by name through that table (it holds no
    /// member names), so they are members although `IScene` doesn't declare them.
    case fogdistance, fogheight, fogdistancecolor, fogheightcolor
    case fogdistancestart, fogdistanceend, fogdistancestartdensity, fogdistanceenddensity
    case fogheightstart, fogheightend, fogheightstartdensity, fogheightenddensity

    enum Layout {
        static let stride = 56  // 56 used
        /// Dirty flags: one for the settings, one for the camera transforms.
        static let settingsDirty = 0
        static let cameraDirty = 1
        static let dirtyCount = 2
    }

    var type: SceneScriptObjectField.ValueType {
        switch self {
        case .bloom, .clearenabled, .camerafade, .camerashake, .cameraparallax, .fogdistance, .fogheight: return .bool
        case .clearcolor, .ambientcolor, .skylightcolor, .cameraEye, .cameraCenter, .cameraUp, .fogdistancecolor,
             .fogheightcolor:
            return .vec3
        default: return .number
        }
    }

    var components: Int { type == .vec3 ? 3 : 1 }

    var offset: Int {
        var offset = 0
        for field in Self.allCases {
            if field == self { return offset }
            offset += field.components
        }
        return offset
    }

    var isCamera: Bool { [.cameraEye, .cameraCenter, .cameraUp, .cameraZoom].contains(self) }

    /// Whether `thisScene` has the field as a member; the others only a bound script sets.
    var isMember: Bool {
        switch self {
        case .bloomhdrstrength, .bloomhdrthreshold, .bloomhdrfeather, .bloomhdrscatter, .bloomhdriterations: return false
        default: return true
        }
    }

    /// The defaults of scene.json's `general` for a value the scene leaves out, the engine's own
    /// (`SceneGeneralDefaults`, `SceneCameraDefaults`; the constructor's flags 0x26 turn `bloom`
    /// and `camerafade` on), and a camera at the origin looking down -z.
    var defaultValue: [Float] {
        switch self {
        case .clearcolor, .ambientcolor, .skylightcolor: return [0, 0, 0]
        case .cameraEye: return [0, 0, 1]
        case .cameraCenter: return [0, 0, 0]
        case .cameraUp: return [0, 1, 0]
        case .cameraZoom, .clearenabled, .bloom, .camerafade: return [1]
        case .bloomstrength: return [SceneGeneralDefaults.bloomStrength]
        case .bloomthreshold: return [SceneGeneralDefaults.bloomThreshold]
        case .fov: return [Float(SceneCameraDefaults.fov)]
        case .nearz: return [Float(SceneCameraDefaults.nearZ)]
        case .farz: return [Float(SceneCameraDefaults.farZ)]
        case .camerashakespeed: return [SceneGeneralDefaults.cameraShakeSpeed]
        case .camerashakeamplitude: return [SceneGeneralDefaults.cameraShakeAmplitude]
        case .camerashakeroughness: return [SceneGeneralDefaults.cameraShakeRoughness]
        case .cameraparallaxamount: return [SceneGeneralDefaults.cameraParallaxAmount]
        case .cameraparallaxdelay: return [SceneGeneralDefaults.cameraParallaxDelay]
        case .cameraparallaxmouseinfluence: return [SceneGeneralDefaults.cameraParallaxMouseInfluence]
        case .bloomhdrstrength: return [SceneGeneralDefaults.bloomHDRStrength]
        case .bloomhdrthreshold: return [SceneGeneralDefaults.bloomHDRThreshold]
        case .bloomhdrfeather: return [SceneGeneralDefaults.bloomHDRFeather]
        case .bloomhdrscatter: return [SceneGeneralDefaults.bloomHDRScatter]
        case .bloomhdriterations: return [Float(SceneGeneralDefaults.bloomHDRIterations)]
        case .fogdistancecolor, .fogheightcolor: return Array(repeating: 0, count: 3)
        case .fogdistancestart: return [SceneFogDefaults.distanceStart]
        case .fogdistanceend: return [SceneFogDefaults.distanceEnd]
        case .fogheightstart: return [SceneFogDefaults.heightStart]
        case .fogheightend: return [SceneFogDefaults.heightEnd]
        case .fogdistancestartdensity, .fogheightstartdensity: return [SceneFogDefaults.startDensity]
        case .fogdistanceenddensity, .fogheightenddensity: return [SceneFogDefaults.endDensity]
        default: return Array(repeating: 0, count: components)
        }
    }

    /// The list `objects-scene.js` builds accessors from; camera fields are not members.
    static var javaScriptObject: [[String: Any]] {
        allCases.map {
            ["name": $0.rawValue, "offset": $0.offset, "type": $0.type.rawValue, "camera": $0.isCamera,
             "member": $0.isMember]
        }
    }
}
