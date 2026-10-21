import Foundation

/// WE's depth parallax effect (`effects/depthparallax`) bound to a generated depth map, as both
/// editors add it: on the layer itself (an image, solid, composition, fullscreen or text layer),
/// or, for what has no rectangle of its own (a particle system, the whole scene), on a fullscreen
/// layer WE's editor would add above it (`models/util/fullscreenlayer.json`, the scene drawn so
/// far as its image).
///
/// From WE's shaders (`depthparallax.frag`/`.vert`):
/// - `g_Texture1` is the depth map (`"mode":"depth"`, `"format":"r8"`, default `util/black`),
///   read through its red channel in the layer's own UV space;
/// - `scale` (`g_Scale`, "Depth", vec2, linked, 0.01…2, default 1 1) is how far the image
///   shifts, `sens` (`g_Sensitivity`, "Perspective", −5…5, default 1), `center` (`g_Center`,
///   0…1, default 0.3) and the `QUALITY` combo (0 basic, 1 occlusion performance (default),
///   2 occlusion quality);
/// - the pointer comes in through `g_ParallaxPosition`, so it follows the cursor (and the
///   camera's parallax) as WE's does;
/// - occlusion steps a ray down from depth 1 and stops where the map rises above it: **1 (white)
///   is near**, 0 (black) is far. Depth Anything gives relative inverse depth (larger nearer),
///   which normalised to 0…1 is already this convention.
///
/// The depth maps are PNGs the editor keeps with its files (`materials/depth/editor_<name>.png`,
/// texture `depth/editor_<name>`), so the overlay is the one source of truth for both editors and
/// Save as New Wallpaper writes a normal WE effect and its texture.
public enum SceneDepthParallax {
    public static let effectFile = "effects/depthparallax/effect.json"
    public static let folderName = "depthparallax"
    /// The depth map's sampler (`g_Texture1`).
    public static let depthSlot = 1
    /// Generated depth maps live under `materials/depth/`.
    public static let textureFolder = "depth"
    public static let qualityCombo = "QUALITY"
    /// WE's default: occlusion, performance.
    public static let defaultQuality = 1
    /// `g_Scale`: the strength. WE's default is 1 1.
    public static let strengthKey = "scale"
    public static let defaultStrength = 1.0
    public static let strengthRange = 0.01...2.0
    /// `g_Sensitivity` and `g_Center` at WE's defaults.
    public static let perspectiveKey = "sens"
    public static let defaultPerspective = 1.0
    public static let centerKey = "center"
    public static let defaultCenter = 0.3

    /// `general.cameraparallax`: WE updates `g_ParallaxPosition` only while it is on, so the
    /// effect follows the pointer only then (`SceneCameraParallax`).
    public static let cameraParallaxSetting = "cameraparallax"
    /// `general.cameraparallaxamount`: how far the layers themselves move. Turning parallax on for
    /// the effect alone sets it to 0, so the scene's layers stay where they were.
    public static let cameraParallaxAmountSetting = "cameraparallaxamount"

    /// A texture path the generator wrote (`depth/…`).
    public static func isGeneratedDepthMap(_ texture: String?) -> Bool {
        guard let texture else { return false }
        return texture.hasPrefix(textureFolder + "/")
    }

    public static func strengthValue(_ strength: Double) -> SceneJSONValue {
        SceneVector.value([strength, strength])
    }

    /// The effect's scene.json object as WE's editor writes one: its first pass with the quality,
    /// WE's default values and the depth map in slot 1.
    public static func effectObject(texture: String, strength: Double) -> SceneJSONValue {
        .object([
            "file": .string(effectFile),
            "name": .string(""),
            "visible": .bool(true),
            "passes": .array([.object([
                "combos": .object([qualityCombo: .number(Double(defaultQuality))]),
                "constantshadervalues": .object([
                    strengthKey: strengthValue(strength),
                    perspectiveKey: .number(defaultPerspective),
                    centerKey: .number(defaultCenter),
                ]),
                "textures": .array([.null, .string(texture)]),
            ])]),
        ])
    }

    /// How a layer takes depth parallax.
    public enum Placement: Equatable, Sendable {
        /// The effect goes on the layer itself.
        case onLayer
        /// A fullscreen layer with the effect goes directly above it (a particle system).
        case layerAbove
    }

    /// Nil for a layer that can't take it (sound, light, 3D model, group).
    public static func placement(for layer: SceneLayer) -> Placement? {
        switch layer.kind {
        case .image, .text: return .onLayer
        case .particle: return .layerAbove
        case .sound, .light, .model, .group, .other: return nil
        }
    }
}

// MARK: - Editing

extension SceneEditSession {
    /// The layer's depth parallax effect bound to a generated depth map (the last one).
    public func depthParallaxEffect(of layerID: Int) -> SceneLayerEffect? {
        outline.layer(layerID)?.effects.last { effect in
            effect.folderName == SceneDepthParallax.folderName
                && SceneDepthParallax.isGeneratedDepthMap(effectTexture(SceneDepthParallax.depthSlot, effect: effect.key, of: layerID))
        }
    }

    /// Some layer has depth parallax bound to a generated depth map.
    public var hasDepthParallax: Bool {
        outline.layers.contains { depthParallaxEffect(of: $0.id) != nil }
    }

    /// `next` (the overlay `outline` now shows) with the camera parallax the effect needs: on a
    /// scene authored with parallax off, the first depth parallax turns it on at amount 0 (only
    /// `g_ParallaxPosition` moves; the scene's own influence and delay stay), and removing the
    /// last one drops those edits again. A scene authored with parallax on is left as it is, and
    /// so is a change that neither adds the first depth parallax nor removes the last
    /// (`hadDepthParallax`: the overlay before it had one), so the Scene Options' camera
    /// parallax stays as the user set it.
    func settlingDepthParallaxCamera(_ next: SceneEditOverlay, hadDepthParallax: Bool) -> SceneEditOverlay {
        let authoredSetting = SceneFieldBinding.literal(of: authored.general[SceneDepthParallax.cameraParallaxSetting])
        guard authoredSetting?.boolValue != true, hasDepthParallax != hadDepthParallax else { return next }
        var settled = next
        if hasDepthParallax {
            settled.setGeneralSetting(SceneDepthParallax.cameraParallaxSetting, to: .bool(true))
            settled.setGeneralSetting(SceneDepthParallax.cameraParallaxAmountSetting, to: .number(0))
        } else if settled.generalSetting(SceneDepthParallax.cameraParallaxSetting) == .bool(true) {
            settled.setGeneralSetting(SceneDepthParallax.cameraParallaxSetting, to: nil)
            settled.setGeneralSetting(SceneDepthParallax.cameraParallaxAmountSetting, to: nil)
        }
        return settled
    }

    /// The depth map the layer's effect is bound to.
    public func depthParallaxTexture(of layerID: Int) -> String? {
        guard let effect = depthParallaxEffect(of: layerID) else { return nil }
        return effectTexture(SceneDepthParallax.depthSlot, effect: effect.key, of: layerID)
    }

    /// The effect's strength (`scale`'s first component).
    public func depthParallaxStrength(of layerID: Int) -> Double? {
        guard let effect = depthParallaxEffect(of: layerID) else { return nil }
        return effectConstantComponents(SceneDepthParallax.strengthKey, effect: effect.key, of: layerID,
                                        default: [SceneDepthParallax.defaultStrength]).first
    }

    /// The fullscreen depth parallax layer for `target`: the one directly above the layer, or for
    /// nil (the whole scene) the topmost one.
    public func depthParallaxLayer(above target: Int?) -> Int? {
        let layers = outline.layers
        func isDepthLayer(_ layer: SceneLayer) -> Bool {
            layer.fillsScene && depthParallaxEffect(of: layer.id) != nil
        }
        guard let target else { return layers.last(where: isDepthLayer)?.id }
        guard let index = layers.firstIndex(where: { $0.id == target }) else { return nil }
        let after = subtree(of: target).compactMap { id in layers.firstIndex { $0.id == id } }.max() ?? index
        let next = after + 1
        guard layers.indices.contains(next), isDepthLayer(layers[next]) else { return nil }
        return layers[next].id
    }

    /// Adds the effect on top of the layer's effects, bound to `texture`, or binds the layer's
    /// existing one to it: one undo step. Returns the effect's key.
    @discardableResult
    public func applyDepthParallax(texture: String, strength: Double, to layerID: Int, actionName: String) -> String? {
        guard let layer = outline.layer(layerID) else { return nil }
        if let existing = depthParallaxEffect(of: layerID) {
            var next = overlay
            rebind(existing.key, of: layerID, texture: texture, strength: strength, in: &next)
            commit(next, actionName: actionName, coalescingKey: nil)
            return existing.key
        }
        let keys = layer.effects.map(\.key)
        let used = (overlay.objects[String(layerID)]?.addedEffects ?? [:]).keys.compactMap { Int($0.dropFirst()) }
            + keys.filter { $0.hasPrefix("+") }.compactMap { Int($0.dropFirst()) }
        let key = "+\((used.max() ?? 0) + 1)"
        var next = overlay
        next.update(layerID) { edit in
            var added = edit.addedEffects ?? [:]
            added[key] = SceneDepthParallax.effectObject(texture: texture, strength: strength)
            edit.addedEffects = added
            if edit.effectOrder != nil { edit.effectOrder = keys + [key] }
        }
        commit(next, actionName: actionName, coalescingKey: nil)
        return key
    }

    /// Binds the layer's depth parallax effect to another depth map (a new generation).
    public func setDepthParallaxTexture(_ texture: String, of layerID: Int, actionName: String) {
        guard let effect = depthParallaxEffect(of: layerID) else { return }
        var next = overlay
        rebind(effect.key, of: layerID, texture: texture, strength: nil, in: &next)
        commit(next, actionName: actionName, coalescingKey: nil)
    }

    /// Sets the strength (both components of `scale`, as WE's linked control does).
    public func setDepthParallaxStrength(_ strength: Double, of layerID: Int, actionName: String, coalescing: Bool = true) {
        guard let effect = depthParallaxEffect(of: layerID) else { return }
        setEffectConstant(SceneDepthParallax.strengthKey, to: SceneDepthParallax.strengthValue(strength), effect: effect.key,
                          of: layerID, defaultValue: SceneDepthParallax.strengthValue(SceneDepthParallax.defaultStrength),
                          actionName: actionName, coalescing: coalescing)
    }

    /// Removes the layer's depth parallax effect.
    public func removeDepthParallax(of layerID: Int, actionName: String) {
        guard let effect = depthParallaxEffect(of: layerID) else { return }
        removeEffect(effect.key, of: layerID, actionName: actionName)
    }

    /// Adds a fullscreen layer carrying the effect: directly above `target` (and the layers under
    /// it), or on top of the scene for nil. Returns its id; the selection stays.
    @discardableResult
    public func addDepthParallaxLayer(texture: String, strength: Double, above target: Int?, name: String,
                                      actionName: String) -> Int {
        let id = nextObjectID
        var object = SceneLayerFactory.fullscreen(name: name)
        object["effects"] = .array([SceneDepthParallax.effectObject(texture: texture, strength: strength)])
        var next = overlay
        next.addObject(.object(object), id: id)
        if let target, outline.layer(target) != nil {
            var order = outline.layers.map(\.id)
            let after = subtree(of: target).compactMap { order.firstIndex(of: $0) }.max() ?? (order.count - 1)
            order.insert(id, at: min(after + 1, order.count))
            next.order = order
        } else if let order = next.order {
            next.order = order + [id]
        }
        normalizeOrder(&next)
        commit(next, actionName: actionName, coalescingKey: nil)
        return id
    }

    /// Changes the effect's depth map (and strength) in `next`: an added layer's or effect's own
    /// object is written again; an authored effect gets a texture edit.
    private func rebind(_ effectKey: String, of layerID: Int, texture: String, strength: Double?, in next: inout SceneEditOverlay) {
        if let index = next.added?.firstIndex(where: { $0.id == layerID }),
           case .object(var object) = next.added![index].object,
           case .array(var effects)? = object["effects"],
           let position = Int(effectKey), effects.indices.contains(position) {
            let current = strength ?? depthParallaxStrength(of: layerID) ?? SceneDepthParallax.defaultStrength
            effects[position] = SceneDepthParallax.effectObject(texture: texture, strength: current)
            object["effects"] = .array(effects)
            next.added![index].object = .object(object)
            next.update(layerID) { $0.effects[effectKey] = nil }
            return
        }
        if effectKey.hasPrefix("+"), next.objects[String(layerID)]?.addedEffects?[effectKey] != nil {
            let current = strength ?? depthParallaxStrength(of: layerID) ?? SceneDepthParallax.defaultStrength
            next.update(layerID) { edit in
                edit.addedEffects?[effectKey] = SceneDepthParallax.effectObject(texture: texture, strength: current)
                edit.effects[effectKey] = nil
            }
            return
        }
        next.updateEffect(key: effectKey, of: layerID) { edit in
            var textures = edit.textures ?? [:]
            textures[String(SceneDepthParallax.depthSlot)] = .string(texture)
            edit.textures = textures
            if let strength {
                edit.constants[SceneDepthParallax.strengthKey] = SceneDepthParallax.strengthValue(strength)
            }
        }
    }
}
