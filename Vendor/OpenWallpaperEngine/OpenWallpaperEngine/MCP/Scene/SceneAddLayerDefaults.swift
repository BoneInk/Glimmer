import Foundation
import OWEControlProtocol
import OWESceneEditing

/// What `add_layer` sizes and places a new layer by when the request leaves it out: the scene as
/// the renderer draws it (`SceneContentLoader.sceneSize(of:)`, WE's canvas, 0x14018b2c0) and
/// an image model's own size.
enum SceneAddLayerDefaults {
    /// The edited scene's drawn size, and where a new layer goes: its centre, a 3D scene's origin
    /// (as the editor's Add menu places it, `LayerActions.sceneCentre`).
    @MainActor
    static func canvas(sceneData: Data, overlay: SceneEditOverlay) throws -> (size: SIMD2<Double>, centre: SIMD2<Double>) {
        let scene: WEScene
        do {
            guard var root = try JSONSerialization.jsonObject(with: sceneData) as? [String: Any] else {
                throw SceneEditOverlayError.notAScene
            }
            try overlay.apply(to: &root)
            scene = try JSONDecoder().decode(WEScene.self, from: JSONSerialization.data(withJSONObject: root))
        } catch {
            OWELog.error(.app, "MCP: add_layer can't read the scene's size: \(error)")
            throw ControlError(.failed, "The scene's size can't be read: \(error.localizedDescription)")
        }
        let size = SIMD2<Double>(SceneContentLoader.sceneSize(of: scene))
        return (size, scene.general.projection == .perspective ? .zero : size / 2)
    }

    /// An image model's size as the renderer gives a layer without one (`SceneImageSize`).
    static func imageSize(ofModel model: String, readAsset: (String) -> Data?) -> SIMD2<Double>? {
        SceneImageSize.of(model: model, readAsset: readAsset)
    }
}
