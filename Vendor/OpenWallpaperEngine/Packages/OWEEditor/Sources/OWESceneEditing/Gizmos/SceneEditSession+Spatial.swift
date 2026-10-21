import Foundation

/// Where an object of a 3D scene is: its parents' world matrix and its own, as WE composes them
/// (world = parentWorld · local, wallpaper64.exe 0x1401850a0), for the canvas's 3D gizmo.
public struct LayerSpatial: Hashable, Sendable {
    public var transform: LayerTransform
    /// The parents' matrices composed: the object's parent space to world space.
    public var parent: EditorMatrix4

    public init(transform: LayerTransform, parent: EditorMatrix4 = .identity) {
        self.transform = transform
        self.parent = parent
    }

    /// Object space to world space.
    public var world: EditorMatrix4 { parent * EditorMatrix4.local(transform) }

    /// The object's origin in world space, which the gizmo sits on.
    public var pivot: SIMD3<Double> { parent.applyPoint(transform.origin) }
}

extension SceneEditSession {
    /// The object's place in a 3D scene, its parents' transforms included (a bone attachment's
    /// offset isn't known to the editor, so an attached object sits on its parent's origin); nil
    /// in a 2D scene, whose layers the 2D gizmo edits, and for a sound, which has no place.
    public func spatial(of layerID: Int) -> LayerSpatial? {
        guard outline.size == nil, let layer = outline.layer(layerID), layer.kind != .sound else { return nil }
        var parent = EditorMatrix4.identity
        for ancestor in outline.ancestors(of: layerID).reversed() {
            parent = parent * EditorMatrix4.local(transform(of: ancestor.id))
        }
        return LayerSpatial(transform: transform(of: layerID), parent: parent)
    }

    /// The visible, unlocked object of a 3D scene whose origin is nearest `canvasPoint` within
    /// `radius` canvas points, as clicking the canvas picks one; the topmost on a tie.
    public func spatialLayer(at canvasPoint: SIMD2<Double>, camera: EditorSceneCamera, viewport: CanvasViewport,
                             radius: Double = Gizmo3D.pickRadius) -> Int? {
        var best: (id: Int, distance: Double)?
        for layer in outline.layers.reversed() where isVisible(layer.id) && !isLocked(layer.id) {
            guard let spatial = spatial(of: layer.id),
                  let point = camera.canvasPoint(spatial.pivot, in: viewport) else { continue }
            let delta = point - canvasPoint
            let distance = (delta * delta).sum().squareRoot()
            if distance <= radius, distance < (best?.distance ?? .infinity) { best = (layer.id, distance) }
        }
        return best?.id
    }
}
