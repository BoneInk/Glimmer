//
//  SceneWallpaperView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/13.
//

import SwiftUI
import MetalKit

/// A scene (or Metal video) wallpaper on one display: a presenter of the wallpaper's shared
/// instance (`SceneWallpaperInstance`), which every display showing the same wallpaper with the
/// same properties holds. A display switched to another wallpaper, or to other properties, gets a
/// new view (`WallpaperView` keys it by the instance key), and with it that instance.
struct SceneWallpaperView: NSViewRepresentable {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    let screenId: String

    func makeCoordinator() -> SceneWallpaperPresenter { SceneWallpaperPresenter() }

    func makeNSView(context: Context) -> MTKView {
        let view = SceneRenderLoop.makeView()
        let wallpaper = wallpaperViewModel.wallpaper(for: screenId)
        let environment = Self.environment(of: wallpaperViewModel)
        let screenId = screenId
        let key = wallpaperViewModel.instanceKey(for: screenId)
        // Desktop windows have fixed sizes; the previews' windows (Workshop, Wallpaper Editor) resize.
        let resizes = !wallpaperViewModel.persistsWallpapers
        let lease = SceneWallpaperPresenter.Lease(wallpaperViewModel.sceneInstances, key: key) {
            SceneWallpaperInstance(wallpaper: wallpaper, environment: environment, screenID: screenId,
                                   properties: key.properties, followsLiveResize: resizes)
        }
        context.coordinator.show(lease, in: view, screenID: screenId)
        return view
    }

    /// What the model's scenes run with. The editor's process brings its own host; anywhere else the
    /// scene runs with the app's. A host's canvas isn't a display, so it takes no loading snapshots
    /// (whose saving updates the lock-screen picture, the app's).
    static func environment(of wallpaperViewModel: WallpaperViewModel) -> SceneWallpaperEnvironment {
        if let host = wallpaperViewModel.sceneHost {
            return SceneWallpaperEnvironment(wallpapers: wallpaperViewModel, settings: host.settings,
                                             scriptServices: host.scriptServices, loadingSnapshots: nil)
        }
        return SceneWallpaperEnvironment(wallpapers: wallpaperViewModel,
                                         settings: AppDelegate.shared.globalSettingsViewModel,
                                         scriptServices: AppDelegate.shared.sceneScriptServices,
                                         loadingSnapshots: wallpaperViewModel.loadingSnapshots)
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.instance?.update()
    }

    static func dismantleNSView(_ view: MTKView, coordinator: SceneWallpaperPresenter) {
        coordinator.stop()
    }
}
