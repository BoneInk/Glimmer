/// A model object as the content was built (docs/models-plan.md §2.6): its authored fields, and
/// once `SceneModelBuilder` has run, its parsed `.mdl` with each mesh's material for its `skin`
/// (`plan`).
struct SceneModelObject: Equatable {
    /// The scene object's id (the key of `SceneMetalContent.transforms` and `visibility`).
    var id: String
    var name: String
    /// Its index in scene.json.
    var order: Int
    var authored: WESceneModel
    /// The object's `animationlayers`.
    var animationLayers: [WEAnimationLayer] = []
    /// `sortorder`, `castshadow` (true for models unless authored), `reflected`, `depthtest`.
    var renderValues: [SceneObjectRenderField: SceneRawValue] = [:]
    /// The object's `perspective` (flag 0x80): in an orthographic scene it draws through a
    /// perspective layer's temporary camera (0x140222770 → 0x1401e5b60).
    var perspective = false
    /// What draws it; nil when its `.mdl` couldn't be loaded or none of its meshes can draw
    /// (logged by the builder), and before the builder has run.
    var plan: SceneModelPlan?

    static func == (lhs: SceneModelObject, rhs: SceneModelObject) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.order == rhs.order && lhs.authored == rhs.authored
            && lhs.animationLayers == rhs.animationLayers && lhs.renderValues == rhs.renderValues
            && lhs.perspective == rhs.perspective && lhs.plan === rhs.plan
    }
}
