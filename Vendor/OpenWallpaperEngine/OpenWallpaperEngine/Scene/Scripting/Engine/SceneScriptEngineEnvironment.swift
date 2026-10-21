import Foundation

/// What `engine` reports about the display and the scene (lib.sceneScript.d.ts `IEngine`), set by
/// the wallpaper instance that owns the runtime. Confined to the runtime's thread.
struct SceneScriptEngineEnvironment: Equatable {
    /// `engine.screenResolution`: the display the wallpaper renders on, in pixels.
    var screenResolution: SIMD2<Double>
    /// `engine.canvasSize`: the scene's own size (`general.orthogonalprojection`), in scene units.
    var canvasSize: SIMD2<Double>
    /// How the scene is placed on the display; `input.cursorWorldPosition` inverts it.
    var placement: WallpaperPlacement = .fill
    /// Display pixels per point (2 on Retina); `.center` placement shows one scene unit per point.
    var pixelsPerPoint: Double = 1
    /// An orthographic scene's zoom this frame; `input.cursorWorldPosition` unprojects through it.
    var zoom = SceneOrthographicZoom.none
    /// `engine.isScreensaver()`; `engine.isWallpaper()` is its opposite.
    var isScreensaver = false
    /// `engine.isRunningInEditor()`: true in the Wallpaper Editor's canvas (`SceneMetalRenderer.runsInEditor`),
    /// false on the displays, the screen saver and Scene Edit / Export, as WE's is false outside its editor.
    var isRunningInEditor = false

    init(screenResolution: SIMD2<Double>, canvasSize: SIMD2<Double>, placement: WallpaperPlacement = .fill,
         pixelsPerPoint: Double = 1, isScreensaver: Bool = false) {
        self.screenResolution = screenResolution
        self.canvasSize = canvasSize
        self.placement = placement
        self.pixelsPerPoint = pixelsPerPoint
        self.isScreensaver = isScreensaver
    }

    /// WE's default project size, until the owner knows better.
    static let standard = SceneScriptEngineEnvironment(screenResolution: SIMD2(1920, 1080),
                                                       canvasSize: SIMD2(1920, 1080))
}
