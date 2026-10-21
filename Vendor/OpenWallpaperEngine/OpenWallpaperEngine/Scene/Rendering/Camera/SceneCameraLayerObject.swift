/// A camera layer as the content was built (docs/models-plan.md §2.3): its fields and its path
/// file. The camera (M2) picks the active one each frame.
struct SceneCameraLayerObject: Equatable {
    var id: String
    var name: String
    var order: Int
    var authored: WESceneCameraLayer
    /// Its `path` file; nil without one, or when it can't be read (logged).
    var pathFile: WECameraLayerPathFile?
}
