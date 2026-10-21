import MetalKit
import SwiftUI

/// An isolated session's private instance (`IsolatedSceneEditSession`), drawn in a view of the
/// scene's aspect: its own registry and key, the isolated store's values, silent (a preview
/// screen, `SceneWallpaperInstance.isPreviewOnly`) and taking no loading snapshots, so nothing of
/// it reaches the desktop.
struct IsolatedSceneView: NSViewRepresentable {
    let session: IsolatedSceneEditSession
    /// How the private instance draws (`SceneWallpaperInstance.Presentation`); nil draws it as
    /// the user's displays do.
    var presentation: SceneWallpaperInstance.Presentation?
    /// Each content the private instance loads (`SceneWallpaperInstance.onContent`).
    var onContent: ((SceneMetalContent) -> Void)?
    static let screenID = SceneWallpaperInstance.previewScreenIDs.first!

    func makeCoordinator() -> SceneWallpaperPresenter { SceneWallpaperPresenter() }

    func makeNSView(context: Context) -> MTKView {
        let view = SceneRenderLoop.makeView()
        let environment = SceneWallpaperEnvironment(wallpapers: AppDelegate.shared.wallpaperViewModel,
                                                    settings: AppDelegate.shared.globalSettingsViewModel,
                                                    scriptServices: AppDelegate.shared.sceneScriptServices,
                                                    loadingSnapshots: nil)
        let key = session.instanceKey
        let wallpaper = session.wallpaper
        let presentation = presentation
        let onContent = onContent
        let lease = SceneWallpaperPresenter.Lease(session.instances, key: key) {
            let instance = SceneWallpaperInstance(wallpaper: wallpaper, environment: environment, screenID: Self.screenID,
                                                  properties: key.properties, followsLiveResize: true)
            instance.presentation = presentation
            instance.onContent = onContent
            return instance
        }
        context.coordinator.show(lease, in: view, screenID: Self.screenID)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        guard let instance = context.coordinator.instance else { return }
        // A moved pointer (the export's Parallax Position) applies with the update.
        instance.presentation = presentation
        instance.onContent = onContent
        instance.update()
    }

    static func dismantleNSView(_ view: MTKView, coordinator: SceneWallpaperPresenter) {
        coordinator.stop()
    }
}
