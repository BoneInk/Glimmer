import Foundation

/// The running scene's camera as its renderer drew the last frame (the app's
/// `SceneFrameCamera`): what the canvas needs to put a 3D scene's gizmo where its objects are.
public struct EditorSceneCamera: Hashable, Sendable {
    public var view: EditorMatrix4
    public var projection: EditorMatrix4

    public init(view: EditorMatrix4, projection: EditorMatrix4) {
        self.view = view
        self.projection = projection
    }

    public var viewProjection: EditorMatrix4 { projection * view }

    /// The world point in clip space, and whether it is in front of the camera.
    func clip(_ point: SIMD3<Double>) -> SIMD4<Double> {
        viewProjection.apply(SIMD4(point.x, point.y, point.z, 1))
    }

    /// The world point on the canvas: the render fills the viewport's scene rectangle, normalized
    /// device coordinates' y up. Nil behind the camera.
    public func canvasPoint(_ point: SIMD3<Double>, in viewport: CanvasViewport) -> SIMD2<Double>? {
        let clip = clip(point)
        guard clip.w > 1e-9 else { return nil }
        let ndc = SIMD2(clip.x / clip.w, clip.y / clip.w)
        let rect = viewport.sceneRect
        return SIMD2(rect.origin.x + (ndc.x + 1) / 2 * rect.size.x, rect.origin.y + (1 - ndc.y) / 2 * rect.size.y)
    }

    /// The world point under `canvasPoint` at the depth `point` has on screen, as dragging in the
    /// view's plane moves an object.
    public func worldPoint(at canvasPoint: SIMD2<Double>, depthOf point: SIMD3<Double>, in viewport: CanvasViewport) -> SIMD3<Double>? {
        let clip = clip(point)
        guard clip.w > 1e-9, let inverse = viewProjection.inverted else { return nil }
        let rect = viewport.sceneRect
        let ndc = SIMD2((canvasPoint.x - rect.origin.x) / max(rect.size.x, 1e-9) * 2 - 1,
                        1 - (canvasPoint.y - rect.origin.y) / max(rect.size.y, 1e-9) * 2)
        let unprojected = inverse.apply(SIMD4(ndc.x * clip.w, ndc.y * clip.w, clip.z, clip.w))
        guard abs(unprojected.w) > 1e-12 else { return nil }
        return SIMD3(unprojected.x, unprojected.y, unprojected.z) / unprojected.w
    }
}
