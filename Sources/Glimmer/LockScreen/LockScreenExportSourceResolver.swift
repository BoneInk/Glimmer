import AppKit
import CoreGraphics

@MainActor
enum LockScreenExportSourceResolver {
    static func desktopConfiguration(settings: GWLockScreenExportSettings = .init(),
                                     wallpaperFPS: Int = 30, displayID: CGDirectDisplayID = CGMainDisplayID())
        -> LockScreenExportConfiguration {
        let mode = CGDisplayCopyDisplayMode(displayID)
        var width = mode?.pixelWidth, height = mode?.pixelHeight
        let bounds = CGDisplayBounds(displayID)
        if let w = width, let h = height, bounds.width != bounds.height,
           (bounds.width < bounds.height) != (w < h) { swap(&width, &height) }
        return .init(settings: settings, wallpaperWidth: width, wallpaperHeight: height,
                     wallpaperFPS: Double(wallpaperFPS))
    }

    static func renderedSource(item: WallpaperItem, configuration: LockScreenExportConfiguration)
        throws -> LockScreenExportSpecification {
        var width = item.pixelWidth, height = item.pixelHeight
        if item.isSceneWallpaper {
            #if GW_UNIVERSAL_SCENE_BACKEND
            // Reads the real loose or packaged Scene canvas, never a preview thumbnail.
            let descriptor = try SceneWallpaperProjectDescriptor(projectURL: item.fileURL)
            width = Int(descriptor.inspection.canvasSize.x.rounded(.down))
            height = Int(descriptor.inspection.canvasSize.y.rounded(.down))
            #else
            throw LockScreenExportConfigurationFailure(message: "当前构建不支持 Scene 锁屏导出。")
            #endif
        } else {
            let project = try WebWallpaperProjectDescriptor(projectURL: item.fileURL)
            let json = try JSONSerialization.jsonObject(with: WebProjectPaths.readProject(project.projectURL)) as? [String: Any]
            if let general = json?["general"] as? [String: Any],
               let canvas = general["orthogonalprojection"] as? [String: Any],
               let w = canvas["width"] as? Double, let h = canvas["height"] as? Double,
               w.isFinite, h.isFinite, (2...65_536).contains(w), (2...65_536).contains(h) {
                width = Int(w.rounded(.down)); height = Int(h.rounded(.down))
            }
        }
        // Procedural content has no encoded native FPS. Its current runtime cap
        // is the source ceiling; responsive Web content also uses the desktop viewport.
        guard let width = width ?? configuration.wallpaperWidth,
              let height = height ?? configuration.wallpaperHeight,
              let fps = configuration.wallpaperFPS else {
            throw LockScreenExportConfigurationFailure(message: "无法确定壁纸渲染尺寸或帧率，请连接显示器后重试。")
        }
        return .init(width: width, height: height, framesPerSecond: fps)
    }
}
