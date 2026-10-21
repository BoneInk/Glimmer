/// The user-binding sites of a scene object the renderer applies from the binding itself, without
/// rebuilding the object: `UserPropertyBindingClassifier` classes them `uniform` or `object`.
///
/// - Transform (`origin`, `scale`, `angles`): every object carries a `SceneObjectMotion` or a
///   layer's `SceneLayerBindings`, and children follow their live parents, in 2D and 3D. Lights
///   are left out: their out-of-plane depth (`SceneLightDepth`) is captured at build time.
/// - Colour (`color`, `alpha`, `brightness`) of image layers, applied per binding revision
///   (`SceneLayerBindings.baseValues`), and of text layers: rasterised white and coloured when
///   drawn, or rasterised again in their fill, from the same bindings.
/// - Visibility (`visible` of an object and of its effects): hidden objects and effects are built
///   too, and the renderer takes the user's visibility again on each change (`SceneUserVisibility`).
/// - Effect constants (an effect pass's `constantshadervalues`): a user-bound constant is a dynamic
///   source (`ShaderConstantResolver.ResolvedConstants`).
/// - A particle system's `instanceoverride` but `count`: bound fields resolve in the frame inputs
///   (`ParticleFrameInputs`); the particle budget is estimated from `count` at build.
///
/// Anything else (sizes, combos, materials, `general`) is captured when the object is built, and a
/// change rebuilds it (`SceneObjectReplacement`).
enum SceneLiveBindingSites {
    static let transformFields = Set([SceneObjectValueField.origin, .scale, .angles].map(\.rawValue))
    static let colourFields = Set([SceneObjectValueField.color, .alpha, .brightness].map(\.rawValue))

    /// Whether field `key` of the scene object `object` is applied without a rebuild.
    static func isLive(_ key: String, of object: [String: SceneJSON]) -> Bool {
        if transformFields.contains(key) { return object["light"] == nil }
        if key == "visible" { return true }
        guard colourFields.contains(key) else { return false }
        if object["text"] != nil { return true }
        guard case .string(let image)? = object["image"] else { return false }
        return !image.isEmpty
    }

    /// Whether field `key` of a particle object's `instanceoverride` is applied without a rebuild.
    static func isLiveInstanceOverride(_ key: String) -> Bool {
        key != SceneInstanceOverrideField.count.rawValue
    }
}
