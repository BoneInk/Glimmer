import Foundation

/// Arranging layers on the scene: snapping a drag, aligning to the scene, moving by a scene offset.
extension SceneEditSession {
    /// The layer's rectangle on the scene, as an axis-aligned box around its corners.
    public func bounds(of layerID: Int) -> SceneRect? {
        geometry(of: layerID).map { SceneRect(around: $0.corners) }
    }

    /// What a moved layer snaps to: the scene, and every other visible planar layer (not the ones
    /// under it, which move with it).
    public func snapTargets(excluding layerID: Int) -> [SceneRect] {
        guard let size = outline.size else { return [] }
        let moving = Set(subtree(of: layerID))
        let others = outline.layers.filter { !moving.contains($0.id) && isVisible($0.id) }.compactMap { bounds(of: $0.id) }
        return LayerSnapping.targets(scene: size, others: others)
    }

    /// The transform a body drag gives once snapped, and the guides to draw. `drag` is the gizmo's;
    /// `threshold` is in scene units.
    public func snappedMove(_ drag: LayerGizmo.Drag, layer layerID: Int, to scenePoint: SIMD2<Double>,
                            threshold: Double) -> (transform: LayerTransform, guides: [LayerSnapping.Guide]) {
        let unsnapped = drag.transform(at: scenePoint)
        guard drag.handle == .body, threshold > 0 else { return (unsnapped, []) }
        let start = SceneRect(around: drag.start.corners)
        let delta = scenePoint - drag.startPoint
        let result = LayerSnapping.snap(start, delta: delta, to: snapTargets(excluding: layerID), threshold: threshold)
        var transform = drag.start.transform
        let local = drag.start.parent.inverted?.applyVector(result.delta) ?? result.delta
        transform.origin.x += local.x
        transform.origin.y += local.y
        return (transform, result.guides)
    }

    /// Moves the layer by `delta` in scene space (its origin moves in its parent's space).
    public func move(_ layerID: Int, bySceneOffset delta: SIMD2<Double>, actionName: String, coalescing: Bool = false) {
        guard delta != .zero else { return }
        let local = parentWorld(of: layerID).inverted?.applyVector(delta) ?? delta
        var transform = self.transform(of: layerID)
        transform.origin.x += local.x
        transform.origin.y += local.y
        setTransform(transform, of: layerID, actionName: actionName, coalescing: coalescing)
    }

    /// Lines the layer's left/centre/right (0, 1, 2) and bottom/centre/top up with the scene's.
    public func alignToScene(_ layerID: Int, horizontal: Int?, vertical: Int?, actionName: String) {
        guard let size = outline.size, let rect = bounds(of: layerID) else { return }
        let delta = LayerSnapping.alignment(rect, within: SceneRect(minimum: .zero, maximum: size),
                                            horizontal: horizontal, vertical: vertical)
        move(layerID, bySceneOffset: delta, actionName: actionName)
    }
}
