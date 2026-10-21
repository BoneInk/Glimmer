import Foundation
import OWESceneEditing

/// The size a scene wallpaper is drawn at, in scene units: WE's canvas
/// (`SceneContentLoader.sceneSize(of:)`, 0x14018b2c0) of its scene.json with the Wallpaper
/// Editor's overlay and the per-object edits applied, as the renderer loads it. What anything
/// framing the drawn scene (Scene Edit / Export, the iPhone & iPad and Android exports)
/// measures in.
enum SceneDrawnSize {
    /// `sceneData`'s drawn size with `overlay` and `edits` (stored `_owe_scene_object_…` values)
    /// applied (`ScenePreparation.resolvedScene`). `readAsset` reads the wallpaper's files, for an
    /// `auto` scene whose image has no `size` (`SceneImageSize`).
    static func of(sceneData: Data, overlay: SceneEditOverlay?, edits: [String: String] = [:],
                   readAsset: ((String) -> Data?)? = nil) throws -> SIMD2<Double> {
        let resolved = try ScenePreparation.resolvedScene(sceneData, edits: edits, overlay: overlay)
        let scene = try JSONDecoder().decode(WEScene.self, from: resolved)
        return SIMD2<Double>(SceneContentLoader.sceneSize(of: scene, imageSize: readAsset.map { read in
            { model in SceneImageSize.of(model: model, readAsset: read) }
        }))
    }

    /// The overlay the renderer applies to `wallpaper`: the one saved for its settings identity.
    static func savedOverlay(of wallpaper: WEWallpaper) -> SceneEditOverlay? {
        SceneEditOverlayFiles.overlay(for: WallpaperSettingsIdentity.resolve(directory: wallpaper.settingsDirectory))
    }
}
