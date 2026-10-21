import OWESceneEditing
import simd

/// The Wallpaper Editor's live values as the renderer applies them each frame
/// (`SceneEditLiveValues`): a layer's own transform moved by the change since the build (origin
/// and angles by the difference, scale by the ratio, as user bindings move them,
/// `SceneLayerBindings`), its opacity and colour by the ratio, and an effect's visibility and
/// constants over the built ones, under any script's (which still win, as over an edit).
struct SceneEditorLive {
    struct Layer {
        var originDelta = SIMD2<Float>.zero
        var scaleFrom = SIMD2<Float>(1, 1)
        var scaleTo = SIMD2<Float>(1, 1)
        var angleDelta: Float = 0
        var tiltDelta = SIMD2<Float>.zero
        var alpha: (from: Float, to: Float)?
        var color: (from: SIMD3<Float>, to: SIMD3<Float>)?
    }

    private(set) var layers: [String: Layer] = [:]
    /// By layer id, then effect index: whether it shows, and constants written over the built ones.
    private(set) var effectVisibility: [String: [Int: Bool]] = [:]
    private(set) var effectWrites: [String: [Int: [SceneScriptConstantWrite]]] = [:]
    /// Bumped on every change, so effect chains keyed on their script revision run again.
    private(set) var revision = 0

    var isEmpty: Bool { layers.isEmpty && effectVisibility.isEmpty && effectWrites.isEmpty }

    init() {}

    init(_ values: SceneEditLiveValues, revision: Int) {
        self.revision = revision
        for (id, change) in values.layers {
            var layer = Layer()
            if let origin = change.origin {
                layer.originDelta = SIMD2(Float(origin.now.x - origin.built.x), Float(origin.now.y - origin.built.y))
            }
            if let scale = change.scale {
                layer.scaleFrom = SIMD2(Float(scale.built.x), Float(scale.built.y))
                layer.scaleTo = SIMD2(Float(scale.now.x), Float(scale.now.y))
            }
            if let angles = change.angles {
                layer.angleDelta = Float(angles.now.z - angles.built.z)
                layer.tiltDelta = SIMD2(Float(angles.now.x - angles.built.x), Float(angles.now.y - angles.built.y))
            }
            if let alpha = change.alpha { layer.alpha = (Float(alpha.built), Float(alpha.now)) }
            if let color = change.color {
                layer.color = (SIMD3(Float(color.built.x), Float(color.built.y), Float(color.built.z)),
                               SIMD3(Float(color.now.x), Float(color.now.y), Float(color.now.z)))
            }
            layers[String(id)] = layer
        }
        for (id, effects) in values.effects {
            for (index, effect) in effects {
                if let visible = effect.visible { effectVisibility[String(id), default: [:]][index] = visible }
                let writes = effect.constants.sorted { $0.key < $1.key }.map { key, value in
                    SceneScriptConstantWrite(material: nil, name: key, value: value.map(Float.init))
                }
                if !writes.isEmpty { effectWrites[String(id), default: [:]][index] = writes }
            }
        }
    }

    // MARK: Applying

    /// The layer's own transform this frame, moved by the editor.
    func local(_ local: SceneLocalTransform, id: String) -> SceneLocalTransform {
        guard let layer = layers[id] else { return local }
        var result = local
        result.origin += layer.originDelta
        result.scale = Self.scaled(result.scale, from: layer.scaleFrom, to: layer.scaleTo)
        result.angle += layer.angleDelta
        result.tilt += layer.tiltDelta
        return result
    }

    /// The layer's opacity and colour this frame, moved by the editor.
    func base(_ base: SceneLayerBaseValues, id: String) -> SceneLayerBaseValues {
        guard let layer = layers[id], layer.alpha != nil || layer.color != nil else { return base }
        var result = base
        if let alpha = layer.alpha {
            result.opacity = Self.scaled(SIMD2(repeating: base.opacity), from: SIMD2(repeating: alpha.from),
                                         to: SIMD2(repeating: alpha.to)).x
        }
        if let color = layer.color {
            let rgb = Self.scaled(SIMD3(base.color.x, base.color.y, base.color.z), from: color.from, to: color.to)
            result.color = SIMD4(rgb.x, rgb.y, rgb.z, base.color.w)
        }
        return result
    }

    /// The effect chain's hidden effects and constant writes with the editor's under the scripts'.
    func effects(_ plans: [SceneEffectPlan], of id: String,
                 scripted: (hidden: Set<Int>, writes: [Int: [SceneScriptConstantWrite]], revision: Int))
        -> (hidden: Set<Int>, writes: [Int: [SceneScriptConstantWrite]], revision: Int) {
        let visibility = effectVisibility[id], writes = effectWrites[id]
        guard visibility != nil || writes != nil else { return scripted }
        var hidden = scripted.hidden
        if let visibility {
            for (position, plan) in plans.enumerated() {
                guard let visible = visibility[plan.effectIndex] else { continue }
                if visible { hidden.remove(position) } else { hidden.insert(position) }
            }
        }
        var combined = scripted.writes
        for (index, editor) in writes ?? [:] {
            // The scripts' writes come after, so theirs win.
            combined[index] = editor + (scripted.writes[index] ?? [])
        }
        return (hidden, combined, scripted.revision &+ revision &* 7919)
    }

    /// `value * now / built` per component; where `built` is 0, `now` replaces a 0.
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
