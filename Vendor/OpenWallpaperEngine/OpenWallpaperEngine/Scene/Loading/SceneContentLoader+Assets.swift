//
//  SceneContentLoader+Assets.swift
//  Open Wallpaper Engine
//
//  The wallpaper's files: JSON, textures and shared assets.
//

import SwiftUI
import CoreText
import CryptoKit
import OWESceneEditing

extension SceneContentLoader {
    /// `colour`: the texture is a layer's or particle's own image, which "Optimise textures" may
    /// load as a prepared BC7 texture (`TexturePreparation`). Every other texture (masks, flow and
    /// normal maps, anything a material reads as data) loads as stored.
    func loadMetalTexture(named name: String, materialDir: String, wallpaperDir: URL,
                                  colour: Bool = false) -> SceneMetalTextureSource? {
        OWEPhaseTiming.measure(.texture) {
            loadMetalTextureUntimed(named: name, materialDir: materialDir, wallpaperDir: wallpaperDir, colour: colour)
        }
    }

    private func loadMetalTextureUntimed(named name: String, materialDir: String, wallpaperDir: URL,
                                         colour: Bool) -> SceneMetalTextureSource? {
        // WE's texture reduction loads a smaller mipmap (`TextureReduction`), cached apart.
        let reduction = renderSettings.textureReduction
        let optimise = colour && renderSettings.optimiseTextures && TexturePreparation.deviceSupportsBC7
        let cacheKey = "\(materialDir)|\(name)" + (reduction > 1 ? "|reduced\(reduction)" : "") + (optimise ? "|bc7" : "")
        if let cached = cachedTexture(cacheKey) { return cached }
        OWEFrameMetrics.countTextureDecode()
        let signpost = OWESignpost.begin(OWESignpost.scene, "decodeTexture")
        defer { signpost.end() }

        if name.hasPrefix("_rt") || name.hasPrefix("rt/") {
            return cacheTexture(.image(transparentPlaceholderImage), for: cacheKey)
        }

        for path in Self.texturePaths(named: name, materialDir: materialDir) {
            let data = assetData(named: path, wallpaperDir: wallpaperDir)
            guard let data else { continue }
            let parser = TEXParser(data: data)
            if let animation = parser.extractAnimatedImages(reduction: reduction) {
                return cacheTexture(.animated(animation), for: cacheKey)
            }
            if let texture = parser.extractCompressedTexture(reduction: reduction) {
                return cacheTexture(.dxt(texture), for: cacheKey)
            }
            // A video texture plays (`IVideoTexture`); its poster frame stays the fallback.
            if let video = parser.extractVideoData(), let device = MTLCreateSystemDefaultDevice(),
               let stream = VideoTextureStream.embedded(mp4: video, device: device) {
                embeddedVideoLock.withLock {
                    embeddedVideoStreams.add(stream)
                    stream.setHostRate(embeddedVideoRate)
                }
                return cacheTexture(.video(stream), for: cacheKey)
            }
            // A padded raw image keeps its allocation (`TEXRawImageRep.makeAllocationTexture`); a
            // prepared texture holds only the image.
            let prepares = optimise && !parser.isPaddedRawImage()
            let mipmaps = prepares ? parser.firstImageMipmapCount() ?? 1 : 1
            let level = TextureReduction.loadedMipmap(reduction: reduction, mipmapCount: mipmaps)
            let preparedKey = prepares ? TexturePreparation.key(texData: data, level: level) : nil
            if let preparedKey, let prepared = TexturePreparation.cachedTexture(key: preparedKey) {
                cacheLeases.hold(TexturePreparation.url(key: preparedKey), scope: wallpaperDir)
                return cacheTexture(.dxt(prepared), for: cacheKey)
            }
            if let image = parser.extractImage(reduction: reduction) {
                if let preparedKey { TexturePreparation.schedule(image, key: preparedKey, mipmaps: mipmaps - level) }
                return cacheTexture(.image(image), for: cacheKey)
            }
        }
        guard let image = loadTexture(named: name, materialDir: materialDir, wallpaperDir: wallpaperDir) else { return nil }
        return cacheTexture(.image(image), for: cacheKey)
    }

    /// Where a material's texture `name` may be, in the order they are tried.
    private static func texturePaths(named name: String, materialDir: String) -> [String] {
        let materialDirPath = (materialDir as NSString).deletingLastPathComponent
        let root = materialDirPath.split(separator: "/").first.map(String.init) ?? "materials"
        return Array(Set(["\(materialDirPath)/\(name).tex", "\(root)/\(name).tex",
                          "materials/\(name).tex", "\(name).tex"]))
    }

    /// How much smaller than its header's image texture `name` loaded under WE's texture reduction:
    /// 2 when it skipped the first of several mipmaps, else 1. A layer sized by its image keeps the
    /// header's size, as WE's texture keeps it (`TextureReduction`).
    func textureReductionApplied(named name: String, materialDir: String, wallpaperDir: URL) -> Float {
        let reduction = renderSettings.textureReduction
        guard reduction > 1 else { return 1 }
        for path in Self.texturePaths(named: name, materialDir: materialDir) {
            guard let data = assetData(named: path, wallpaperDir: wallpaperDir) else { continue }
            let mipmaps = TEXParser(data: data).firstImageMipmapCount() ?? 1
            return Float(1 << TextureReduction.loadedMipmap(reduction: reduction, mipmapCount: mipmaps))
        }
        return 1
    }

    // MARK: - Asset Loading

    func loadJSON<T: Decodable>(path: String, wallpaperDir: URL) -> T? {
        guard let original = assetData(named: path, wallpaperDir: wallpaperDir) else { return nil }
        let storageKey = settingsIdentity(for: wallpaperDir).key(.userProperties, scope: propertyScope)
        let overrideKey = sceneAssetOverrideKey(path: path)
        let data: Data
        if let values = UserDefaults.app.dictionary(forKey: storageKey) as? [String: String],
           let override = values[overrideKey], let overrideData = override.data(using: .utf8) {
            data = bindingTable.resolvedData(overrideData, path: path, properties: userProperty)
        } else {
            data = original
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            OWELog.debug(.scene, "\(path) isn't a \(T.self): \(error)")
            return nil
        }
    }

    /// The file at `path` as the build reads it: a JSON document with its user bindings resolved
    /// and recorded (`bindingTable`), any other file as it is.
    func assetData(named path: String, wallpaperDir: URL) -> Data? {
        rawAssetData(named: path, wallpaperDir: wallpaperDir).map {
            bindingTable.resolvedData($0, path: path, properties: userProperty)
        }
    }

    func rawAssetData(named path: String, wallpaperDir: URL) -> Data? {
        if let edited = editorAssetsLock.withLock({ editorAssets[path] }) { return edited }
        if let cached = assetDataCache[path] { return cached }
        // WE's fixed copy of a broken Workshop shader replaces the one the wallpaper ships.
        if let fixed = shaderCompat?.replacement(forShaderPath: path, projectId: loadedProjectId) {
            Self.log("Using WE's compatibility copy of \(path)")
            assetDataCache[path] = fixed
            return fixed
        }
        let data = wallpaperData(named: path, wallpaperDir: wallpaperDir) ?? sharedAssetData(named: path)
        if let data { assetDataCache[path] = data }
        return data
    }

    /// A file of the wallpaper itself: its package, its folder, or a Workshop item it references.
    func wallpaperData(named path: String, wallpaperDir: URL) -> Data? {
        if let data = pkgParser?.extractFile(named: path) { return data }
        // A missing loose file is an ordinary miss: the next source is tried.
        do {
            if let data = try AssetPathResolver.data(path, in: wallpaperDir) { return data }
        } catch {
            OWELog.error(.scene, "Failed to read \(path) in \(wallpaperDir.path): \(error)")
        }
        // Files the Wallpaper Editor imported for the wallpaper (`EditorAssetStore`).
        if !SceneBackendRuntimeContext.isActive, let data = SceneEditOverlayFiles.assetData(path, for: settingsIdentity(for: wallpaperDir)) { return data }
        return workshopAssets.data(for: path)
    }

    /// The project's Workshop id: `workshopid` in project.json, else a numeric folder name
    /// (Steam names downloaded items by id). Nil for a local project.
    static func workshopId(of wallpaper: WEWallpaper) -> String? {
        if let id = wallpaper.project.workshopid?.rawValue, !id.isEmpty, id.allSatisfy(\.isNumber) { return id }
        let folder = wallpaper.wallpaperDirectory.lastPathComponent
        return !folder.isEmpty && folder.allSatisfy({ $0.isASCII && $0.isNumber }) ? folder : nil
    }

    /// Where WE's assets may keep the file a scene names `path`: the path itself, a `.tex` for a
    /// texture named without one, and under `materials/` (a preset's `materials/presets/…` without it).
    static func sharedAssetPaths(for path: String) -> [String] {
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var relativePaths = [normalizedPath]
        if URL(fileURLWithPath: normalizedPath).pathExtension.isEmpty {
            relativePaths.append("\(normalizedPath).tex")
        }
        if normalizedPath.hasPrefix("materials/presets/") {
            relativePaths.append("materials/\(normalizedPath.dropFirst("materials/presets/".count))")
        } else if !normalizedPath.hasPrefix("materials/") {
            relativePaths.append("materials/\(normalizedPath)")
        }
        return relativePaths
    }

    /// Whether WE's assets have the vertex stage of `shader` (`generic4`, `shadowcaster`, …): one of
    /// WE's own shaders, as opposed to a wallpaper's (`ModelMaterialPlan.customShader`).
    static func isBuiltinShader(_ shader: String) -> Bool {
        let file = shader.hasSuffix(".vert") ? shader : "\(shader).vert"
        return WallpaperEngineAssets.locate(["shaders/\(file)", file], in: WallpaperEngineAssets.searchDirectories) != nil
    }

    private func sharedAssetData(named path: String) -> Data? {
        let assetsDirectories = WallpaperEngineAssets.searchDirectories
        guard !assetsDirectories.isEmpty else {
            Self.logDetail("Shared asset lookup skipped: no Wallpaper Engine assets available")
            return nil
        }
        guard let candidate = WallpaperEngineAssets.locate(Self.sharedAssetPaths(for: path), in: assetsDirectories)
        else { return nil }
        do {
            let data = try AssetPathResolver.readRegularFile(at: candidate)
            Self.logDetail("Using shared asset '\(candidate.path)'")
            return data
        } catch {
            OWELog.error(.scene, "Could not read shared asset \(candidate.path): \(error)")
            return nil
        }
    }

    private func loadTexture(named name: String, materialDir: String, wallpaperDir: URL) -> NSImage? {
        // Build candidate .tex paths: relative to material dir, then relative to materials/ root
        let materialDirPath = (materialDir as NSString).deletingLastPathComponent
        var texPaths = [String]()
        if !materialDirPath.isEmpty {
            texPaths.append("\(materialDirPath)/\(name).tex")
        }
        // Also try materials/{name}.tex for textures with embedded paths (e.g. "workshop/xxx/foo")
        let materialsRoot = materialDirPath.split(separator: "/").first.map(String.init) ?? "materials"
        let rootPath = "\(materialsRoot)/\(name).tex"
        if !texPaths.contains(rootPath) {
            texPaths.append(rootPath)
        }
        texPaths.append("\(name).tex")

        for texPath in texPaths {
            // Try .tex from PKG
            if let texData = assetData(named: texPath, wallpaperDir: wallpaperDir) {
                Self.logDetail("  TEX from PKG '\(texPath)' size=\(texData.count)")
                // A slice is copied so the parser's indices start at 0; whole data is used as is.
                let texParser = TEXParser(data: texData.startIndex == 0 ? texData : Data(texData))
                if let image = texParser.extractImage() {
                    return image
                }
                Self.log("  TEXParser.extractImage() returned nil for '\(texPath)'")
            }
        }

        // Try common image formats directly, where the .tex was looked for (WE ships some effect
        // textures as a PNG with a .tex-json, e.g. `materials/effects/refractnormal.png`).
        for ext in ["png", "jpg", "jpeg", "gif"] {
            for texPath in texPaths {
                let imgPath = (texPath as NSString).deletingPathExtension + ".\(ext)"
                if let imgData = assetData(named: imgPath, wallpaperDir: wallpaperDir), let image = NSImage(data: imgData) {
                    return image
                }
            }
        }

        Self.log("  No texture found for '\(name)'")
        return nil
    }
}
