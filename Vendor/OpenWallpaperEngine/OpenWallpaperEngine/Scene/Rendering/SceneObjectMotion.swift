import simd

/// Where an object's own transform comes from each frame: its authored (or user-bound) origin,
/// scale and `angles.z`, what its timelines set (`SceneObjectAnimation`), and what scripts wrote
/// into the object table. Drawn layers carry one, and so does every other object (groups, particle
/// systems), so children follow their live parents whatever the parent is.
struct SceneObjectMotion {
    let name: String
    let origin: SIMD2<Float>
    let scale: SIMD2<Float>
    /// `angles.z`, in radians.
    let angle: Float
    /// `angles.x` and `angles.y`, in radians.
    let tilt: SIMD2<Float>
    /// User-bound origin, scale and angles, re-resolved per frame.
    var bindings = SceneLayerBindings()

    init(layer: SceneMetalLayer) {
        name = layer.name
        origin = layer.position
        scale = layer.scale
        angle = layer.rotation
        tilt = layer.tilt
        bindings = layer.bindings
    }

    init(object: WESceneObject, bindings: SceneLayerBindings) {
        let local = SceneLocalTransform(object: object)
        name = object.name ?? ""
        origin = local.origin
        scale = local.scale
        angle = local.angle
        tilt = local.tilt
        self.bindings = bindings
    }

    /// The values animations start from this frame.
    func base(in context: SceneValueContext) -> SceneLayerBaseValues {
        let built = SceneLayerBaseValues(position: origin, scale: scale, rotation: angle, tilt: tilt)
        return bindings.isEmpty ? built : bindings.baseValues(built, in: context)
    }

    /// The object's own origin, scale and angles this frame: what scripts wrote (`script`),
    /// then its timelines (`animation`), then authored or user-bound. Scripts win over a timeline:
    /// WE runs the timeline first and applies the script's return after it (plan §1.9 P2).
    /// Without `scriptValues`: the object as the renderer alone would place it, which is what
    /// scripts read for fields they don't own.
    func local(animation: SceneObjectAnimation? = nil, script: SceneScriptObjectState? = nil,
               scriptValues: Bool = true) -> SceneLocalTransform {
        let base = base(in: LiveSceneValueContext())
        let owned = scriptValues ? script : nil
        let position = owned?.vector3(.origin).map(Self.xy) ?? animation?.origin.map(Self.xy) ?? base.position
        let scale = owned?.vector3(.scale).map(Self.xy) ?? animation?.scale.map(Self.xy) ?? base.scale
        let angles = owned?.vector3(.angles) ?? animation?.angles
        return SceneLocalTransform(origin: position, scale: scale, angle: angles?.z ?? base.rotation,
                                   tilt: angles.map { SIMD2($0.x, $0.y) } ?? base.tilt)
    }

    /// The object's own 3D transform this frame, for the 3D hierarchy (`SceneTransformHierarchy3D`):
    /// the same precedence as `local` (scripts, then timelines, then authored moved by user
    /// bindings), with every component. `authored` is the object's node in the 3D hierarchy: it
    /// carries `origin.z`, `scale.z` and WE's own defaults, which the 2D values this motion was
    /// built with (`origin`, `scale`, `angle`, `tilt`) may not (a fullscreen layer's placement),
    /// so only the user bindings' change since the
    /// build is applied to it. A script or timeline writes all three components of a field.
    func local3D(authored: SceneLocalTransform3D, animation: SceneObjectAnimation? = nil,
                 script: SceneScriptObjectState? = nil, scriptValues: Bool = true) -> SceneLocalTransform3D {
        let owned = scriptValues ? script : nil
        let base = bindings.isEmpty ? authored : Self.bound(authored, by: bindings, in: LiveSceneValueContext())
        return SceneLocalTransform3D(origin: owned?.vector3(.origin) ?? animation?.origin ?? base.origin,
                                     scale: owned?.vector3(.scale) ?? animation?.scale ?? base.scale,
                                     angles: owned?.vector3(.angles) ?? animation?.angles ?? base.angles)
    }

    /// `value` moved by the user bindings' change since the build, as `SceneLayerBindings` moves
    /// the 2D values: origin and angles by the difference, scale by the ratio.
    static func bound(_ value: SceneLocalTransform3D, by bindings: SceneLayerBindings,
                      in context: SceneValueContext) -> SceneLocalTransform3D {
        var result = value
        for field in [SceneObjectValueField.origin, .angles, .scale] {
            guard let binding = bindings.fields[field] else { continue }
            let now = field.resolve(binding.source, in: context).vec3
            let built = binding.built.vec3
            guard now != built else { continue }
            switch field {
            case .origin: result.origin += now - built
            case .angles: result.angles += now - built
            default:
                for index in 0..<3 {
                    if built[index] != 0 {
                        result.scale[index] *= now[index] / built[index]
                    } else if result.scale[index] == 0 {
                        result.scale[index] = now[index]
                    }
                }
            }
        }
        return result
    }

    private static func xy(_ value: SIMD3<Float>) -> SIMD2<Float> { SIMD2(value.x, value.y) }
}
