import simd

/// A layer's user-bound transform and colour values, re-resolved every frame so a changed user
/// property shows immediately. Sites applied here alone need no content rebuild (`SceneLiveBindingSites`).
///
/// Each binding stores the value the layer was built with. Per frame the renderer applies the
/// change since then: origin and angles as an offset, scale/colour/alpha/brightness as a ratio.
/// That keeps parent offsets, fullscreen sizes and solid colours baked into the layer intact.
struct SceneLayerBindings {
    struct Binding {
        let source: SceneValueSource
        let built: ShaderValue
    }

    private(set) var fields: [SceneObjectValueField: Binding] = [:]

    var isEmpty: Bool { fields.isEmpty }

    /// The user properties the bindings read.
    var properties: Set<String> { Set(fields.values.compactMap(\.source.boundUserProperty)) }

    init() {}

    /// Bindings for `object`'s user-bound transform/colour fields; `context` is what the layer was built with.
    init(object: WESceneObject, builtWith context: SceneValueContext) {
        let perFrame: [SceneObjectValueField] = [.origin, .scale, .angles, .color, .alpha, .brightness]
        for field in perFrame {
            guard let source = object.values[field]?.userBindingSource else { continue }
            fields[field] = Binding(source: source, built: field.resolve(source, in: context))
        }
    }

    /// The layer's base values this frame, before scripts and animations.
    func baseValues(for layer: SceneMetalLayer, in context: SceneValueContext) -> SceneLayerBaseValues {
        baseValues(SceneLayerBaseValues(layer), in: context)
    }

    /// `base` (what the object was built with) moved by the bindings' change since the build.
    func baseValues(_ built: SceneLayerBaseValues, in context: SceneValueContext) -> SceneLayerBaseValues {
        var base = built
        for (field, binding) in fields {
            let now = field.resolve(binding.source, in: context)
            guard now != binding.built else { continue }
            switch field {
            case .origin:
                base.position += now.vec2 - binding.built.vec2
            case .angles:
                base.rotation += now.vec3.z - binding.built.vec3.z
                base.tilt += SIMD2(now.vec3.x - binding.built.vec3.x, now.vec3.y - binding.built.vec3.y)
            case .scale:
                base.scale = Self.scaled(base.scale, from: SIMD2(binding.built.vec2), to: SIMD2(now.vec2))
            case .color:
                let rgb = Self.scaled(SIMD3(base.color.x, base.color.y, base.color.z), from: binding.built.vec3, to: now.vec3)
                base.color = SIMD4(rgb.x, rgb.y, rgb.z, base.color.w)
            case .alpha:
                base.opacity = Self.scaled(SIMD2(repeating: base.opacity), from: SIMD2(repeating: binding.built.float),
                                           to: SIMD2(repeating: now.float)).x
            case .brightness:
                base.brightness = Self.scaled(SIMD2(repeating: base.brightness), from: SIMD2(repeating: binding.built.float),
                                              to: SIMD2(repeating: now.float)).x
            case .size, .pointsize:
                break
            }
        }
        return base
    }

    /// `value * now / built` per component. Where `built` is 0 there is no ratio: a value equal to
    /// it is replaced by `now`, anything else (e.g. a colour baked into a texture) is kept until
    /// the content rebuild that follows the property change.
    private static func scaled<V: SIMD>(_ value: V, from built: V, to now: V) -> V where V.Scalar == Float {
        var result = value
        for index in result.indices {
            if built[index] != 0 {
                result[index] = value[index] * now[index] / built[index]
            } else if value[index] == 0 {
                result[index] = now[index]
            }
        }
        return result
    }
}

/// A layer's transform and colour inputs for one frame.
struct SceneLayerBaseValues: Equatable {
    var position: SIMD2<Float>
    var scale: SIMD2<Float>
    var rotation: Float
    /// `angles.x` and `angles.y`.
    var tilt: SIMD2<Float>
    var opacity: Float
    var brightness: Float
    var color: SIMD4<Float>

    init(position: SIMD2<Float>, scale: SIMD2<Float>, rotation: Float, tilt: SIMD2<Float> = .zero) {
        self.position = position
        self.scale = scale
        self.rotation = rotation
        self.tilt = tilt
        opacity = 1
        brightness = 1
        color = SIMD4(repeating: 1)
    }

    init(_ layer: SceneMetalLayer) {
        position = layer.position
        scale = layer.scale
        rotation = layer.rotation
        tilt = layer.tilt
        opacity = layer.opacity
        brightness = layer.brightness
        color = layer.color
    }
}
