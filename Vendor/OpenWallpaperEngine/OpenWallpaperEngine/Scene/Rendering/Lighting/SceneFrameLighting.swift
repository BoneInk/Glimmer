import simd

/// A light object as the content was built: its scene object's id (the light's transform, parent
/// and visibility are the object's), its fields as authored (for values that change live) and
/// resolved against the user properties.
struct SceneLightObject {
    var id: String
    var authored: WESceneLight
    var light: SceneLight
    /// The parts of the light's own transform that the 2D hierarchy doesn't carry: `origin.z`,
    /// `angles.x` and `angles.y` (radians) and `scale.z`, as authored.
    var depth = SceneLightDepth()
    /// A timeline drives one of its light fields (`intensity`, `radius`, …): the frame reads them
    /// (`live(script:animation:timeline:)`).
    var hasTimelines = false
}

/// A light object's placement in one frame (`SceneFrameLighting.objects`).
struct SceneFrameLightObject: Equatable {
    var id: String
    /// Its world matrix, as the packer reads it (`SceneFrameLighting.world`).
    var world: simd_float4x4
    /// It and every ancestor are shown.
    var visible: Bool
    /// Its fields this frame (`SceneLightObject.live`); nil leaves the content's.
    var light: SceneLight?
}

/// A light's own out-of-plane transform (`SceneLightObject.depth`).
struct SceneLightDepth: Equatable {
    var originZ: Float = 0
    var anglesXY: SIMD2<Float> = .zero
    var scaleZ: Float = 1

    init(originZ: Float = 0, anglesXY: SIMD2<Float> = .zero, scaleZ: Float = 1) {
        self.originZ = originZ
        self.anglesXY = anglesXY
        self.scaleZ = scaleZ
    }

    init(object: WESceneObject) {
        let origin = object.origin?.parseVector3()
        let angles = object.angles?.parseVector3()
        let scale = object.scale?.parseVector3()
        self.init(originZ: Float(origin?.2 ?? 0), anglesXY: SIMD2(Float(angles?.0 ?? 0), Float(angles?.1 ?? 0)),
                  scaleZ: Float(scale?.2 ?? 1))
    }
}

/// The scene's lighting as the content was built: `general`'s colours and budget, and every light
/// object in scene order (docs/lighting-plan.md §1).
struct SceneLightingContent {
    var settings = SceneLightingSettings()
    var lights: [SceneLightObject] = []
    /// Each `usecookie` light's cookie texture, by light object id (`SceneLightCookie.load`).
    var cookies: [String: SceneLightCookie] = [:]
}

/// What the renderer hands the lighting each frame, after scripts and timelines ran.
struct SceneFrameLightingInput {
    /// An object's own transform this frame (scripts and timelines included); nil for an id the
    /// scene doesn't have.
    var local: (String) -> SceneLocalTransform?
    /// The world transform of an object's parent chain this frame; identity for a root object.
    var parentWorld: (String) -> SceneAffineTransform
    /// Whether an object and all its ancestors are shown this frame (scripts included).
    var isVisible: (String) -> Bool
    /// A perspective scene's world matrix of an object this frame (M3's 3D hierarchy with live
    /// values: parents' depth and tilt included, which the 2D chain drops); nil in an orthographic
    /// scene, whose lights take `parentWorld` and their own depth (`world(parent:local:depth:)`).
    var world3D: ((String) -> simd_float4x4)? = nil
    /// A `general` colour scripts set this frame (`thisScene.ambientcolor`, `skylightcolor`); nil
    /// when no script owns it.
    var sceneColor: (SceneScriptSceneField) -> SIMD3<Float>?
    /// A light's fields and out-of-plane transform this frame (`SceneLightObject.live`); the
    /// content's when nil.
    var live: ((SceneLightObject) -> SceneLightObject)?
    /// The user's shadows setting isn't "disabled" (WE's ctx+0x1ac).
    var shadows = true
    /// The shadow maps' inputs (`SceneLightPacker.ShadowContext`): the shadows setting's level
    /// (0 makes no map), the scene's projection and the atlas's size so far.
    var shadowQuality = 0
    /// "Cheaper shadows" (`SceneShadowAtlas.mapSize`).
    var reducedShadowMaps = false
    var orthographic = true
    var shadowAtlasExtent = SIMD2<Int>.zero
    /// The camera shake this frame, in scene units. WE moves the camera's eye and centre by it
    /// (0x140199580) while every world matrix stays; the renderer instead moves every object by
    /// its negative, so the lights move with them and stay where the layers they light are.
    /// Camera parallax isn't here: WE translates only the draws' model matrices by it
    /// (0x14018b062…0x14018b14e), not the world matrices the packer reads (0x1401850a0), nor the
    /// camera the volumetrics draw with (ctx+0x930), so a lit layer slides under its lights.
    var cameraShake = SIMD2<Float>.zero
    var eyePosition: SIMD3<Float>
    var viewForward: SIMD3<Float>
    /// An orthographic scene's zoom (`SceneOrthographicZoom`): the layers are drawn in the scene
    /// scaled by it about its centre, so the lights are placed in that space too and their
    /// distances (radius, source size, cascades) grow with it, which leaves every light-to-surface
    /// relation as a camera zoom leaves it. 1 elsewhere.
    var zoom = SceneOrthographicZoom.none
}

/// One frame's lighting: the values behind `g_LightAmbientColor`, `g_LightSkylightColor`, the
/// `LightingV1` arrays (`g_LPoint_*`, `g_LSpot_*`, `g_LTube_*`, `g_LDirectional_*`,
/// `g_LFeature_*`) and the legacy `g_Lights*` (docs/lighting-plan.md §2.2). The renderer builds it
/// once per frame (`frame(_:input:)`) and carries it on `BuiltinFrameContext.lighting`, where
/// `BuiltinUniforms` reads it.
struct SceneFrameLighting: Equatable {
    var ambient = SceneGeneralDefaults.ambientColor
    var skylight = SceneGeneralDefaults.skylightColor
    /// Packed uniform values by uniform name, flattened per element (`SceneLightPacker`).
    var arrays: [String: [Float]] = [:]
    /// Every light object this frame, in scene order, whatever the budget: the volumetrics
    /// (`SceneVolumetrics`) draw each one's volume from it.
    var objects: [SceneFrameLightObject] = []
    /// This frame's shadow maps (docs/models-plan.md §2.10), which `SceneShadowPass` draws.
    var shadows = SceneShadowFrame()
    /// The scene's fog, behind `g_FogDistance*` and `g_FogHeight*` (`SceneFogSettings`).
    var fog = SceneFogSettings()
    /// `_alias_lightCookie` this frame (`SceneLightCookie`); nil when no cookie spot is packed.
    var cookie: SceneLightCookie?

    static func frame(_ content: SceneLightingContent, input: SceneFrameLightingInput) -> SceneFrameLighting {
        var lighting = SceneFrameLighting(ambient: input.sceneColor(.ambientcolor) ?? content.settings.ambient,
                                          skylight: input.sceneColor(.skylightcolor) ?? content.settings.skylight)
        lighting.fog = content.settings.fog
        guard !content.lights.isEmpty else { return lighting }
        var objects: [SceneFrameLightObject] = []
        let lights = content.lights.compactMap { built -> SceneLightPacker.Light? in
            guard let local = input.local(built.id) else { return nil }
            let object = input.live?(built) ?? built
            var world = input.world3D?(object.id) ?? world(parent: input.parentWorld(object.id), local: local, depth: object.depth)
            world.columns.3 -= SIMD4(lowHalf: input.cameraShake, highHalf: .zero)
            // In the zoom's drawn space, as everything they light is drawn.
            let light = SceneLightPacker.Light(
                light: input.zoom.scaled(object.light), world: input.zoom.space * world,
                localOrigin: SIMD3(local.origin, object.depth.originZ),
                visible: input.isVisible(object.id), id: object.id)
            objects.append(SceneFrameLightObject(id: object.id, world: light.world, visible: light.visible,
                                                 light: light.light))
            return light
        }
        lighting.objects = objects
        lighting.arrays = SceneLightPacker.legacy(lights)
        if let config = content.settings.lightConfig {
            let budget = input.shadows ? config : config.withShadowsDisabled
            let context = SceneLightPacker.ShadowContext(
                quality: input.shadows ? input.shadowQuality : 0, reduced: input.reducedShadowMaps, eye: input.eyePosition, forward: input.viewForward,
                orthographic: input.orthographic, atlasExtent: input.shadowAtlasExtent)
            let packed = SceneLightPacker.lightingV1(lights, budget: budget, shadows: input.shadows,
                                                     viewForward: input.viewForward, shadowContext: context)
            lighting.arrays.merge(packed.arrays) { _, new in new }
            lighting.shadows = packed.shadows
            lighting.cookie = SceneLightPacker.cookieLight(lights, budget: budget, viewForward: input.viewForward)
                .flatMap { content.cookies[$0] }
        }
        return lighting
    }

    /// A light's world matrix: its parents' transform, then its own `origin`, `angles` and
    /// `scale` (the object's matrix at 0x1401850a0).
    ///
    /// WE builds the rotation as `Rz(z)·Ry(y)·Rx(x)` (0x1401dd630; its row-major rows are this
    /// matrix's columns). `Rz` is the 2D hierarchy's own rotation (`SceneAffineTransform`), which
    /// turns +X toward +Y as WE's does, so a light turns with the layers it lights; x and y tilt it
    /// out of the plane. The parents are the 2D hierarchy's, which carries no depth or tilt.
    static func world(parent: SceneAffineTransform, local: SceneLocalTransform, depth: SceneLightDepth) -> simd_float4x4 {
        let parentMatrix = embed(parent)
        let turn = SceneAffineTransform(SceneLocalTransform(origin: .zero, scale: SIMD2(repeating: 1), angle: local.angle))
        let rotation = embed(turn) * rotationY(depth.anglesXY.y) * rotationX(depth.anglesXY.x)
        let scale = simd_float4x4(diagonal: SIMD4(local.scale.x, local.scale.y, depth.scaleZ, 1))
        var own = rotation * scale
        own.columns.3 = SIMD4(SIMD3(local.origin, depth.originZ), 1)
        return parentMatrix * own
    }

    private static func embed(_ transform: SceneAffineTransform) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(lowHalf: transform.linear.columns.0, highHalf: .zero),
                                SIMD4(lowHalf: transform.linear.columns.1, highHalf: .zero),
                                SIMD4(0, 0, 1, 0), SIMD4(lowHalf: transform.translation, highHalf: SIMD2(0, 1))))
    }

    private static func rotationX(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)))
    }

    private static func rotationY(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(columns: (SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1)))
    }

    /// Every uniform the frame lighting provides, with its floats per element.
    static let uniformComponents: [String: Int] = SceneLightPacker.lightingV1Components
        .merging(SceneLightPacker.legacyComponents) { a, _ in a }

    /// The scene-wide colours and every light array: they change from frame to frame.
    static let uniformNames = Set(uniformComponents.keys).union(["g_LightAmbientColor", "g_LightSkylightColor"])
}
