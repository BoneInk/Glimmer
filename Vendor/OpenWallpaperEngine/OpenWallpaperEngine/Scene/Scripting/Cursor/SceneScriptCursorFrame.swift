import simd

/// What the renderer hands the cursor pass once per frame (docs/scenescript-plan.md §4.8, WP11):
/// where the cursor is, whether the left button is down, and the hit-testable layers as last drawn.
struct SceneScriptCursorFrame {
    /// Camera parallax as the renderer ran it this frame. Only an orthographic scene with parallax
    /// on offsets the quads (flags 0x108 at 0x140189f17), so it is nil otherwise.
    struct Parallax {
        var state: SceneCameraParallax
        /// `cameraparallaxamount`.
        var amount: Float
    }

    /// The scene point under the cursor as WE's camera sees it, the `worldPosition` of every event:
    /// scene units, y up. WE moves the camera eye for camera shake, so this is the unshaken scene
    /// point plus the shake offset. WE uses only x and y; z is reported as given.
    var cursorWorldPosition: SIMD3<Float>
    /// The left button, for clicks the wallpaper itself receives (plan §4.8).
    var leftButtonDown: Bool
    var parallax: Parallax?
    /// The ray every object is tested against; nil for an orthographic scene's, the one straight
    /// down through `cursorWorldPosition` (`SceneScriptCursorRay.orthographic`).
    var ray: SceneScriptCursorRay?
    /// A perspective scene's view direction (`g_ViewForward`), by which the pass orders the objects
    /// (WE's "3D click sorting", 0x1401865c0); nil in an orthographic scene, which keeps the draw
    /// order (scene flag 0x8, 0x140189f98).
    var viewForward: SIMD3<Float>?
    /// Every hit-testable object in draw order, bottom first. The pass walks it from the top.
    var layers: [SceneScriptCursorLayer]

    init(cursorWorldPosition: SIMD3<Float>, leftButtonDown: Bool, parallax: Parallax? = nil,
         ray: SceneScriptCursorRay? = nil, viewForward: SIMD3<Float>? = nil, layers: [SceneScriptCursorLayer]) {
        self.cursorWorldPosition = cursorWorldPosition
        self.leftButtonDown = leftButtonDown
        self.parallax = parallax
        self.ray = ray
        self.viewForward = viewForward
        self.layers = layers
    }

    /// The ray the objects are tested against.
    var cursorRay: SceneScriptCursorRay {
        ray ?? .orthographic(through: SIMD2(cursorWorldPosition.x, cursorWorldPosition.y))
    }

    /// The objects in the order the pass visits them, first visited first. An orthographic scene
    /// walks the draw order from the top. A perspective scene sorts the objects by
    /// `dot(origin, viewForward)`, descending and stable (0x14019ee60), and walks that from the end:
    /// the object whose own `origin` lies least far along the view comes first, and objects with
    /// equal keys go top first as in an orthographic scene. (WE gives fullscreen layers, flag
    /// 0x200, the key −∞, so they come first of all; fullscreen layers aren't hit tested here.)
    var visitOrder: [SceneScriptCursorLayer] {
        guard let forward = viewForward else { return layers.reversed() }
        let keyed = layers.enumerated().map { index, layer in
            (key: simd_dot(SIMD3(layer.origin, layer.originZ), forward), index: index, layer: layer)
        }
        let sorted = keyed.sorted { $0.key > $1.key || ($0.key == $1.key && $0.index < $1.index) }
        return sorted.reversed().map(\.layer)
    }

    /// How far WE's hit test moves `layer`'s quad for camera parallax (0x14018a0b3):
    /// `amount · (origin − position) · parallaxDepth` of the object itself.
    func parallaxOffset(of layer: SceneScriptCursorLayer) -> SIMD2<Float> {
        guard let parallax else { return .zero }
        return parallax.state.offset(rootOrigin: layer.origin, rootDepth: layer.parallaxDepth, amount: parallax.amount)
    }
}
