import OWESceneEditing
import simd

extension EditorSceneCamera {
    /// The renderer's camera of a frame, for the Wallpaper Editor's 3D gizmo.
    init(_ camera: SceneFrameCamera) {
        self.init(view: EditorMatrix4(camera.view), projection: EditorMatrix4(camera.projection))
    }
}

extension EditorMatrix4 {
    /// A `simd_float4x4`'s columns, in the same column-major order.
    init(_ matrix: simd_float4x4) {
        func column(_ vector: SIMD4<Float>) -> SIMD4<Double> {
            SIMD4(Double(vector.x), Double(vector.y), Double(vector.z), Double(vector.w))
        }
        self.init(columns: (column(matrix.columns.0), column(matrix.columns.1), column(matrix.columns.2), column(matrix.columns.3)))
    }
}
