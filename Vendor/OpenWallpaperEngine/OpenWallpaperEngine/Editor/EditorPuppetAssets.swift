import AppKit
import Foundation
import OWEEditor
import OWESceneEditing

/// What the Wallpaper Editor's Puppet Warp reads of a wallpaper (`PuppetEditorAssets`): its files
/// as the scene loader finds them (the package first, then the folder) and an image layer's
/// picture, decoded by the app's own texture reader.
enum EditorPuppetAssets {
    static func make(for wallpaper: WEWallpaper) -> PuppetEditorAssets {
        let directory = wallpaper.wallpaperDirectory
        let package = OWELog.attempt(.ui, "Puppet Warp: \(directory.lastPathComponent)", { try WallpaperEditorSource.read(wallpaper) })?.package
        let read: (String) -> Data? = { path in
            let normalized = path.replacingOccurrences(of: "\\", with: "/")
            if let package, let data = package.extractFile(named: normalized) { return Data(data) }
            return OWELog.attempt(.ui, "Puppet Warp: \(normalized)") { try AssetPathResolver.data(normalized, in: directory) } ?? nil
        }
        return PuppetEditorAssets(readFile: read, image: { modelPath in image(modelPath: modelPath, read: read) })
    }

    /// The picture an image model draws: its material's first texture (`materials/<name>.tex`,
    /// or a PNG or JPEG in its place), as the scene loader looks for it.
    static func image(modelPath: String, read: (String) -> Data?) -> CGImage? {
        // Optional: a model or material that isn't JSON has no picture here (the scene's load logs it).
        guard let model = read(modelPath).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              let materialPath = model["material"] as? String,
              let material = read(materialPath).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              let passes = material["passes"] as? [[String: Any]],
              let name = (passes.first?["textures"] as? [Any])?.first as? String else { return nil }
        let folder = (materialPath as NSString).deletingLastPathComponent
        let root = folder.split(separator: "/").first.map(String.init) ?? "materials"
        var candidates = ["\(folder)/\(name).tex", "\(root)/\(name).tex", "\(name).tex"]
        candidates = candidates.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        for path in candidates {
            if let data = read(path), let image = TEXParser(data: Data(data)).extractImage(),
               let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return cgImage
            }
        }
        for path in candidates {
            for ext in ["png", "jpg", "jpeg"] {
                let file = (path as NSString).deletingPathExtension + ".\(ext)"
                if let data = read(file), let image = NSImage(data: data),
                   let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    return cgImage
                }
            }
        }
        return nil
    }
}
