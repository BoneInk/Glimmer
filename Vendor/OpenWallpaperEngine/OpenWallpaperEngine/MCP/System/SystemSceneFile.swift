import Foundation
import OWEControlProtocol

/// A scene wallpaper's scene.json as authored, read the way Scene Edit / Export reads it (from
/// the wallpaper's package when it has one, else its folder), for its layers.
enum SystemSceneFile {
    /// The authored scene; a `ControlError` saying why when it can't be read.
    static func scene(of wallpaper: WEWallpaper) throws -> WEScene {
        let file = wallpaper.project.file
        let directory = wallpaper.wallpaperDirectory
        let packageURL = directory.appending(path: (file as NSString).deletingPathExtension + ".pkg")
        do {
            var data: Data?
            if FileManager.default.fileExists(atPath: packageURL.path(percentEncoded: false)) {
                data = try PKGParser(url: packageURL).extractFile(named: file)
            }
            guard let data = try data ?? AssetPathResolver.data(file, in: directory) else {
                throw ControlError(.failed, "\"\(wallpaper.project.title)\" has no \(file) to read.")
            }
            return try JSONDecoder().decode(WEScene.self, from: data)
        } catch let error as ControlError {
            throw error
        } catch {
            OWELog.error(.app, "MCP: \(wallpaper.project.title)'s \(file) can't be read: \(error)")
            throw ControlError(.failed, "\"\(wallpaper.project.title)\"'s \(file) can't be read: \(error.localizedDescription)")
        }
    }

    /// The scene's layers, in scene.json's order.
    static func layers(of scene: WEScene) -> [SystemSceneLayer] {
        scene.objects.enumerated().map { index, object in
            SystemSceneLayer(id: object.id ?? index, name: object.name ?? "Layer \(index + 1)", kind: kind(of: object),
                             authoredVisible: object.visible ?? true)
        }
    }

    private static func kind(of object: WESceneObject) -> String {
        if object.particle != nil { return "particle" }
        if object.image != nil { return "image" }
        if object.textValue != nil { return "text" }
        if object.sound != nil { return "sound" }
        if object.light != nil { return "light" }
        if object.model != nil { return "model" }
        return "other"
    }
}
