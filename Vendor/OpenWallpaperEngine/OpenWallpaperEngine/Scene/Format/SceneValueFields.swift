import Foundation

/// Value-bearing fields of a scene object that WE lets authors bind to a user property, a script
/// or an animation. The raw forms are kept in `WESceneObject.values`.
enum SceneObjectValueField: String, CaseIterable {
    case origin, scale, angles, color, alpha, brightness, size, pointsize
}

/// Value-bearing fields of `general` in scene.json. The raw forms are kept in `WESceneGeneral.values`.
enum SceneGeneralValueField: String, CaseIterable {
    case bloom, bloomstrength, bloomthreshold, clearcolor, clearenabled
    case camerashake, camerashakeamplitude, camerashakespeed, camerashakeroughness
    case cameraparallax, cameraparallaxamount, cameraparallaxdelay, cameraparallaxmouseinfluence
    case ambientcolor, skylightcolor
    /// HDR bloom (docs/lighting-plan.md §1.2); WE turns HDR on only with `bloom` as well.
    case hdr, bloomhdrstrength, bloomhdrthreshold, bloomhdrfeather, bloomhdrscatter, bloomhdriterations
    /// The camera and draw order (docs/models-plan.md §2.1; `SceneCameraSettings`).
    case fov, perspectiveoverridefov, nearz, farz, zoom, camerafade
    case transparentsorting, customsortorder
    /// Distance and height fog (`SceneFogSettings`).
    case fogdistance, fogheight, fogdistancecolor, fogheightcolor
    case fogdistancestart, fogdistanceend, fogdistancestartdensity, fogdistanceenddensity
    case fogheightstart, fogheightend, fogheightstartdensity, fogheightenddensity
    /// The scene-wide gravity and wind (`ScenePhysicsSettings`).
    case gravitydirection, gravitystrength, windenabled, winddirection, windstrength
}

/// Fields any scene object may author that decide how it draws in a 3D scene
/// (docs/models-plan.md §2.4, §2.6). The raw forms are kept in `WESceneObject.renderValues`.
enum SceneObjectRenderField: String, CaseIterable {
    /// `sortorder`: the key of `customsortorder` (base properties 0x1401e0530).
    case sortorder
    /// `castshadow`: the object draws into the shadow atlas (flag 0x800; on by default for models,
    /// 0x1401901b1). On a light object the same key is the light's own (`SceneLightValueField`).
    case castshadow
    /// `reflected`: the object is on the planar-reflection list (default true, 0x14019086d).
    case reflected
    /// `depthtest` ("enabled" / "disabled"), authored on text objects in 3D scenes [I: it feeds
    /// the text material like an image's material pass].
    case depthtest
}

/// A model object's bindable fields (`WESceneModel.values`).
enum SceneModelValueField: String, CaseIterable {
    case skin, rootmotion
}

/// A camera layer's bindable fields (`WESceneCameraLayer.values`).
enum SceneCameraLayerValueField: String, CaseIterable {
    case fov, zoom
}

/// An animation layer's bindable fields (`WEAnimationLayer.values`).
enum SceneAnimationLayerValueField: String, CaseIterable {
    case visible, additive, blendin, blendout, rate, blend, blendtime
}

/// Value-bearing fields of a light object (`WESceneLight`), as `wallpaper64.exe` registers them
/// (0x14025da80). The raw forms are kept in `WESceneLight.values`.
enum SceneLightValueField: String, CaseIterable {
    case color, intensity, radius, exponent, innercone, outercone, controlpoint
    case castshadow, usecookie, castvolumetrics, density, volumetricsexponent
    case cascadedistance0, cascadedistance1, cascadedistance2, lightsourcesize
}

/// Fields of a particle object's `instanceoverride`. Each multiplies (or, for colours, replaces)
/// the emitter/initializer value of the particle file.
enum SceneInstanceOverrideField: String, CaseIterable {
    case alpha, brightness, color, colorn, count, lifetime, rate, size, speed
    /// Positions of the system's control points 0…7 (`ParticleControlPoint`).
    case controlpoint0, controlpoint1, controlpoint2, controlpoint3
    case controlpoint4, controlpoint5, controlpoint6, controlpoint7
    /// Orientations of the control points 0…7, radians (`wallpaper64.exe` object+0x778+0x150+12n).
    case controlpointangle0, controlpointangle1, controlpointangle2, controlpointangle3
    case controlpointangle4, controlpointangle5, controlpointangle6, controlpointangle7

    /// `controlpoint<n>` for control point `id` (0…7).
    static func controlPoint(_ id: Int) -> SceneInstanceOverrideField? {
        SceneInstanceOverrideField(rawValue: "controlpoint\(id)")
    }

    /// `controlpointangle<n>` for control point `id` (0…7).
    static func controlPointAngle(_ id: Int) -> SceneInstanceOverrideField? {
        SceneInstanceOverrideField(rawValue: "controlpointangle\(id)")
    }
}

extension SceneRawValue {
    /// The literal (authored `value`) part as WE text: `"1 0.5 0"`, `"0.5"`, `"true"`.
    /// Bindings are ignored; a missing `value` is nil.
    var literalString: String? {
        switch self {
        case .number(let n): return SceneJSON.number(n).scalarString
        case .bool(let b): return b ? "true" : "false"
        case .string(let s): return s
        case .object(let object): return object.value?.literalString
        }
    }

    /// The literal part as a number (`true` is 1). Nil when there is none or it isn't numeric.
    var literalDouble: Double? {
        switch self {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        case .object(let object): return object.value?.literalDouble
        }
    }

    /// The literal part as an int, truncated the way WE's `asInt` truncates. Nil when there is none
    /// or it isn't numeric.
    var literalInt: Int? {
        literalDouble.map { Int(SceneTimelineDocument.asInt($0)) }
    }

    /// The literal part as a flag. Numbers are true when non-zero; strings "true"/"1".
    var literalBool: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return ["true", "1"].contains(s.lowercased())
        case .object(let object): return object.value?.literalBool
        }
    }

    /// The user property this value is bound to, if any.
    var userPropertyName: String? {
        if case .object(let object) = self { return object.userName }
        return nil
    }

    /// The script this value is driven by, if any.
    var scriptSource: String? {
        if case .object(let object) = self { return object.script }
        return nil
    }
}
