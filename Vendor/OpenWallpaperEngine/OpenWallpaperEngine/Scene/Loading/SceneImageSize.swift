import Foundation

/// The size an image layer gets when its scene object has no `size`: its model's `width` and
/// `height`, else its material's first texture's image size (a sprite sheet's frame), as the
/// renderer sizes it. WE's GIF template (`assets/scenes/gifs/gifscene.json`) writes no `size`, so
/// an `{"auto": true}` scene takes this size (`SceneContentLoader.sceneSize(of:imageSize:)`).
enum SceneImageSize {
    /// nil when neither the model nor its texture can be read.
    static func of(model: String, readAsset: (String) -> Data?) -> SIMD2<Double>? {
        guard let modelData = readAsset(model) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(WEModel.self, from: modelData)
            if let declared = decoded.declaredSize { return SIMD2<Double>(declared) }
            guard let materialPath = decoded.material, let materialData = readAsset(materialPath) else { return nil }
            let material = try JSONDecoder().decode(WEMaterial.self, from: materialData)
            guard let texture = material.passes?.first?.textures?.first ?? nil,
                  let data = readAsset("materials/\(texture).tex"), let header = TEXFileHeader(data),
                  header.imageWidth > 0, header.imageHeight > 0 else { return nil }
            return SIMD2(Double(header.imageWidth), Double(header.imageHeight))
        } catch {
            OWELog.debug(.scene, "No size for \(model): \(error)")
            return nil
        }
    }

    /// A reader of `wallpaper`'s files for sizing: its scene package, else its folder.
    static func reader(for wallpaper: WEWallpaper) -> (String) -> Data? {
        let directory = wallpaper.wallpaperDirectory
        let packageURL = directory.appending(path: (wallpaper.project.file as NSString).deletingPathExtension + ".pkg")
        let package = try? PKGParser(url: packageURL) // Optional: most wallpapers have no package.
        return { path in
            if let data = package?.extractFile(named: path) { return Data(data) }
            // A missing file is nil (it sizes nothing); one that is there but can't be read logs.
            return OWELog.attempt(.scene, "Sizing \(path)") { try AssetPathResolver.data(path, in: directory) } ?? nil
        }
    }
}
