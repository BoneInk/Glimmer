import simd

/// An orthographic scene's zoom: WE scales its orthographic projection about the screen's centre
/// by `general.zoom` × the camera's zoom (0x14017fd50; WE 2.8's capture, docs/models-plan.md
/// §5.19: at `zoom` 2 an 870 px image is drawn 1742 px wide about the centre). World matrices
/// don't change, only what the camera shows.
///
/// Scaling the projection's x and y about its centre is the same as drawing the scene scaled about
/// its centre through the unzoomed projection, and with z scaled too every distance scales alike,
/// so lighting is unchanged. The app draws everything in that *drawn space*: the layer path,
/// which keeps its own matrix, in the scene plane scaled (`plane`: layers, particle emitters and
/// their cursor), and the models, the lights (with their distances, `scaled(_:)`), the shadow
/// casters and the volumetrics in it (`space`), seen by the orthographic camera over a depth range
/// grown alike (`orthographicDepth`). What scripts see stays WE's world: their world matrices
/// are unzoomed, and the cursor's world position is the drawn point taken back through the zoom
/// (`worldPoint(drawn:)`), so a click lands on what is drawn under it.
///
/// A camera layer or a camera path moves an orthographic scene's view too (WE 2.8.42's capture,
/// docs/models-plan.md §5.19): WE's view becomes `lookAt(eye, centre, up)` in place of the reset
/// view (the identity), under the same projection. The drawn space takes that view first, then
/// the zoom: `space` is zoom · view. The layer path's `plane` is its xy part, which is exact for
/// what lies in the scene plane and for any view turning about z; a view tilted out of the plane
/// moves an object with a depth by its z too, which the plane leaves out [I: no capture has one].
struct SceneOrthographicZoom: Equatable {
    /// The projection's scale; 1 is none.
    let factor: Float
    /// The scene's centre, which the zoom keeps in place.
    let centre: SIMD2<Float>
    /// The camera's view: the identity (WE's reset view) unless a camera layer or path moves it.
    let view: simd_float4x4

    static let none = SceneOrthographicZoom(factor: 1, sceneSize: .zero)

    /// A zoom that isn't positive and finite is none.
    init(factor: Float, sceneSize: SIMD2<Float>, view: simd_float4x4 = matrix_identity_float4x4) {
        self.factor = factor.isFinite && factor > 0 ? factor : 1
        centre = sceneSize / 2
        self.view = view
    }

    var isNone: Bool { factor == 1 && view == matrix_identity_float4x4 }

    /// The drawn plane: the scene seen through the view, then scaled by `factor` about its centre.
    var plane: SceneAffineTransform {
        guard !isNone else { return .identity }
        let zoom = SceneAffineTransform(linear: simd_float2x2(diagonal: SIMD2(repeating: factor)),
                                        translation: centre - factor * centre)
        guard view != matrix_identity_float4x4 else { return zoom }
        let viewPlane = SceneAffineTransform(linear: simd_float2x2(SIMD2(view[0].x, view[0].y), SIMD2(view[1].x, view[1].y)),
                                             translation: SIMD2(view[3].x, view[3].y))
        return zoom * viewPlane
    }

    /// The same in 3D, z scaled too, so every distance in it grows by `factor` alike.
    var space: simd_float4x4 {
        guard !isNone else { return matrix_identity_float4x4 }
        let shift = centre - factor * centre
        let zoom = simd_float4x4(columns: (SIMD4(factor, 0, 0, 0), SIMD4(0, factor, 0, 0), SIMD4(0, 0, factor, 0),
                                           SIMD4(shift.x, shift.y, 0, 1)))
        return zoom * view
    }

    /// The world point drawn at `drawn` (a point of the drawn plane, which is the screen's scene
    /// units): what unprojecting the cursor through the zoomed camera gives, on the scene plane.
    func worldPoint(drawn: SIMD2<Float>) -> SIMD2<Float> {
        guard !isNone else { return drawn }
        guard view != matrix_identity_float4x4 else { return centre + (drawn - centre) / factor }
        return plane.inverse?.apply(drawn) ?? drawn
    }

    /// A projection with its x and y scaled by `factor` about its centre: WE's zoom itself, for
    /// the temporary perspective camera of an orthographic scene's `perspective` layers and
    /// systems, whose view a scaled scene wouldn't reproduce.
    func projection(_ projection: simd_float4x4) -> simd_float4x4 {
        guard !isNone else { return projection }
        return simd_float4x4(diagonal: SIMD4(factor, factor, 1, 1)) * projection
    }

    /// The camera's depth range in the drawn space, ±`SceneCamera.orthographicDepth` × `factor`:
    /// a world z lands at the depth it has without the zoom, so models and layers keep testing
    /// against each other as they do in WE.
    var orthographicDepth: Float { SceneCamera.orthographicDepth * factor }

    /// A light's distances in the drawn space: its radius, source size and shadow cascades.
    func scaled(_ light: SceneLight) -> SceneLight {
        guard !isNone else { return light }
        var scaled = light
        scaled.radius *= factor
        scaled.lightSourceSize *= factor
        scaled.cascadeDistances *= factor
        return scaled
    }
}
