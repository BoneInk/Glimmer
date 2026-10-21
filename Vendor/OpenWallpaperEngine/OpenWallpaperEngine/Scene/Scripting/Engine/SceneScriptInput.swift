import Foundation
import simd

/// The cursor as scripts see it through `input` (lib.sceneScript.d.ts `IInput`). The owner sets the
/// screen position and the left button for clicks the wallpaper itself receives (plan §4.8); the
/// scene-space position is derived here from the environment's placement. Confined to the
/// runtime's thread.
struct SceneScriptInput: Equatable {
    /// `input.cursorScreenPosition`: pixels from the top-left of the wallpaper's screen area.
    var cursorScreenPosition: SIMD2<Double>
    /// `input.cursorLeftDown`.
    var cursorLeftDown: Bool
    /// How far camera shake moved the camera, in scene units: WE shakes the eye, so the scene point
    /// under the cursor moves with it (the cursor pass sees the same point).
    var shakeOffset: SIMD2<Double>

    init(cursorScreenPosition: SIMD2<Double> = .zero, cursorLeftDown: Bool = false, shakeOffset: SIMD2<Double> = .zero) {
        self.cursorScreenPosition = cursorScreenPosition
        self.cursorLeftDown = cursorLeftDown
        self.shakeOffset = shakeOffset
    }

    /// `input.cursorWorldPosition` x and y: the scene point under the cursor, in scene units with
    /// y up from the scene's bottom-left, the space `origin` uses, plus the camera shake offset.
    /// The inverse of the composite's placement, so off the drawn scene (letterbox bars, cropped
    /// edges) it lies outside the canvas. An orthographic scene's zoom is taken back out
    /// (`SceneOrthographicZoom.worldPoint`), as unprojecting through WE's zoomed camera does.
    /// WE supports only x and y ("Only x and y are supported right now"); z is 0.
    func cursorWorldPosition(in environment: SceneScriptEngineEnvironment) -> SIMD2<Double> {
        let screen = environment.screenResolution
        guard screen.x > 0, screen.y > 0 else { return .zero }
        // Screen pixels are y-down from the top; the composite's drawable space is y-up.
        let drawablePoint = SIMD2<Float>(Float(cursorScreenPosition.x), Float(screen.y - cursorScreenPosition.y))
        let scene = ScenePlacementScale.scenePoint(drawablePoint: drawablePoint, placement: environment.placement,
                                                   sceneSize: SIMD2<Float>(environment.canvasSize),
                                                   drawableSize: SIMD2<Float>(screen),
                                                   pixelsPerPoint: Float(environment.pixelsPerPoint))
        return SIMD2<Double>(environment.zoom.worldPoint(drawn: scene)) + shakeOffset
    }
}
