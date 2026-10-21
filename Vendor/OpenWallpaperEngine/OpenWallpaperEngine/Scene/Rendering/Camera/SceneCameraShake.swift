import Foundation
import simd

/// Wallpaper Engine's camera shake (`general.camerashake*`): `wallpaper64.exe` 0x140199580,
/// called from the scene update while the shake is on. It moves the camera's eye and centre by
/// the same vector, so the whole scene moves the other way.
///
/// With `t = speed² · g_Time`:
/// 1. `v = (cos t, sin(1.333 · t), sin t)`. An orthographic scene zeroes z.
/// 2. With `r = roughness³` above 0.001 and not 1, `v = v / |v| · |v|^r`.
/// 3. `v` is scaled by `amplitude · 0.1`, and in an orthographic scene also by
///    `0.1 · projection height`.
enum SceneCameraShake {
    /// How far the camera moves this frame, in scene units. `orthographicHeight` is nil for a
    /// perspective scene.
    static func cameraOffset(time: Float, speed: Float, amplitude: Float, roughness: Float,
                             orthographicHeight: Float?) -> SIMD3<Float> {
        let t = speed * speed * time
        var v = SIMD3<Float>(cos(t), sin(t * 1.333), sin(t))
        var scale = amplitude * 0.1
        if let orthographicHeight {
            v.z = 0
            scale *= orthographicHeight * 0.1
        }
        let exponent = pow(roughness, 3)
        let length = simd_length(v)
        // WE divides by the length unguarded; a zero vector (a single instant) stays zero here.
        if exponent > 0.001, exponent != 1, length > 0 {
            v = v / length * pow(length, exponent)
        }
        return v * scale
    }
}
