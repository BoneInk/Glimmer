import Foundation

/// `general.orthogonalprojection` read the way `wallpaper64.exe` reads it (scene load 0x1401874ec…
/// 0x1401875fb; docs/models-plan.md §2.1). A scene is **perspective by default**: the scene
/// constructor leaves the ortho flag clear (0x140186d1f), and only an object value can set it.
enum WESceneProjection: Equatable {
    /// Missing, `null`, any value that isn't an object, an object without a true `auto` or two
    /// numeric sizes, or a size with a zero side.
    case perspective
    /// `{"width": w, "height": h}` with both sides non-zero: the scene's size in scene units.
    case orthographic(width: Int, height: Int)
    /// `{"auto": true}`: orthographic, sized from the first image object, which WE centres
    /// (0x14018b2c0). `auto` is looked at before the sizes.
    case orthographicAuto

    /// WE's reading of the value: `auto` must be a JSON bool, the sizes JSON numbers (truncated
    /// to ints, WE's `asInt`). Nil (the key is missing) is a perspective scene.
    init(json: SceneJSON?) {
        guard case .object(let object)? = json else {
            self = .perspective
            return
        }
        if case .bool(true)? = object["auto"] {
            self = .orthographicAuto
            return
        }
        guard case .number(let width)? = object["width"], case .number(let height)? = object["height"] else {
            self = .perspective
            return
        }
        let w = SceneTimelineDocument.asInt(width), h = SceneTimelineDocument.asInt(height)
        self = w != 0 && h != 0 ? .orthographic(width: Int(w), height: Int(h)) : .perspective
    }

    var isPerspective: Bool { self == .perspective }
}
