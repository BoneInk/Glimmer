import AppKit
import Foundation

/// Route-owned Scene work. The preparation starts as soon as a local Scene
/// detail is opened, while the cover animation is still running.
@MainActor
protocol WorkspaceScenePreviewOwning: AnyObject {
    func cancel()
}

@MainActor
final class SceneWallpaperPreviewPreparation: WorkspaceScenePreviewOwning {
    let itemID: UUID
    let model: SceneWallpaperPreviewModel
    private var task: Task<Void, Never>?
    private var cancelled = false

    init(item: WallpaperItem, storage: AppStorage, wallpaperFPS: Int,
         screenResolution: SceneVector2?) {
        itemID = item.id
        model = SceneWallpaperPreviewModel()
        task = Task { @MainActor [weak model] in
            guard let model, !Task.isCancelled else { return }
            model.activate()
            await model.update(item: item, paused: false, storage: storage,
                               wallpaperFPS: wallpaperFPS, screenResolution: screenResolution)
        }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        task?.cancel()
        task = nil
        model.dispose()
    }

    isolated deinit {
        task?.cancel()
        model.dispose()
    }
}

/// Resolve only the display that owns the click event's window. A missing
/// event/window intentionally falls back to the existing host-mounted screen
/// discovery; never substitute an unrelated main screen.
@MainActor
enum SceneWallpaperClickContext {
    static func physicalDisplayResolution() -> SceneVector2? {
        guard let screen = NSApp.currentEvent?.window?.screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return SceneWallpaperRuntime.physicalScreenResolution(displayID: number.uint32Value)
    }
}
