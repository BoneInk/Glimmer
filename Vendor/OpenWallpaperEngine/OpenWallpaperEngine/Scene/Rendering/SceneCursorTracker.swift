import simd

/// WE keeps the pointer where it left a display rather than recentring it, and reports no
/// button pressed while it is elsewhere; a jump to the centre would kick pointer-driven effects.
struct SceneCursorTracker {
    private(set) var lastPosition: SIMD2<Float>?

    /// `live` is nil while the cursor is on another display.
    mutating func update(_ live: SIMD2<Float>?, sceneSize: SIMD2<Float>) -> (position: SIMD2<Float>, onDisplay: Bool) {
        if let live {
            lastPosition = live
            return (live, true)
        }
        return (lastPosition ?? sceneSize / 2, false)
    }
}
