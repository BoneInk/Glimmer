import AppKit
import OWEEditor
import OWESceneEditing

/// The Depth Map Generation plugin as both editors use it: one generator per process
/// (`generator`, the app's or the Wallpaper Editor process's own), which reads the installed model from the shared Application Support
/// folder (`DepthMapPluginLayout`), so the Wallpaper Editor finds it from its own process too;
/// and the services a depth map section needs for one wallpaper.
@MainActor
enum DepthMapPlugin {
    enum Failure: LocalizedError {
        case effectUnavailable

        var errorDescription: String? {
            String(localized: "Wallpaper Engine’s Depth Parallax effect isn’t available. Set up Wallpaper Engine’s assets in Settings › Assets.",
                   table: "DepthMaps", comment: "Depth map: WE's depthparallax effect files are missing")
        }
    }

    /// This process's one generator, made on first use: Scene Edit / Export's in the app, the
    /// editor windows' in the Wallpaper Editor's process. Its model is loaded only while it
    /// generates, and released when idle (`DepthMapGenerator.idleGrace`) in each process.
    static let generator = makeGenerator()

    /// A generator reading the installed model from this process's support folder. The model
    /// loads only while it generates.
    static func makeGenerator(root: URL = DepthMapPluginInstaller.defaultRoot, cache: URL = DepthMapPlugin.cacheDirectory) -> DepthMapGenerator {
        DepthMapGenerator(locateModel: { DepthMapPluginLayout.activeModel(in: root) },
                          cache: DepthMapCache(directory: cache),
                          log: { message in OWELog.info(.app, message) })
    }

    /// `<Caches>[/Open Wallpaper Engine (isolated <tag>)]/Open Wallpaper Engine/DepthMaps`.
    nonisolated static var cacheDirectory: URL {
        AppStorageLocation.current.cachesDirectory.appending(path: "Open Wallpaper Engine/DepthMaps", directoryHint: .isDirectory)
    }

    /// The effect WE's editor adds, as the catalog lists it.
    static let effectEntry = EffectCatalogEntry(file: SceneDepthParallax.effectFile, title: "Depth Parallax", group: "interactive")

    /// The section's services for `wallpaper`, reading its files through `resources`.
    /// `openPlugins`: shows Settings › Plugins › Depth Map Generation (the app's, from either process).
    static func services(for wallpaper: WEWallpaper, resources: EditorWallpaperResources,
                         generator: DepthMapGenerator? = nil,
                         openPlugins: @escaping @MainActor () -> Void) -> DepthMapEditorServices {
        DepthMapEditorServices(
            generator: generator ?? DepthMapPlugin.generator,
            assetStore: resources.assets,
            source: { request in try await DepthMapPlugin.source(for: request, wallpaper: wallpaper, resources: resources) },
            prepareEffect: {
                guard WallpaperEngineAssets.locate([SceneDepthParallax.effectFile], in: WallpaperEngineAssets.searchDirectories) != nil
                else { throw Failure.effectUnavailable }
                try resources.prepareEffect(DepthMapPlugin.effectEntry)
            },
            texture: { resources.texture($0) },
            openPlugins: openPlugins,
            effectSchema: { resources.effectSchema($0) },
            prepareBuiltInEffect: { try resources.prepareEffect($0) },
            encodeMask: { TEXWriter.effectMask($0, width: $1, height: $2) })
    }

    /// A still image layer's own texture as it is; anything else drawn (`DepthMapSceneCapture`).
    static func source(for request: DepthMapSourceRequest, wallpaper: WEWallpaper,
                       resources: EditorWallpaperResources) async throws -> DepthMapSource {
        if let model = request.pictureModel, let name = textureName(ofModel: model, resources: resources),
           case let (path, data)? = ["materials/\(name).tex", "materials/\(name).png", "materials/\(name).jpg", "\(name).tex"]
               .lazy.compactMap({ path in resources.data(path).map { (path, $0) } }).first {
            // Decoded off the main thread; an animated texture (frames, a sprite sheet) is drawn instead.
            let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard path.hasSuffix(".tex") else {
                    return NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                }
                let parser = TEXParser(data: data)
                if (parser.extractAnimatedImages()?.frames.count ?? 0) > 1 { return nil }
                return parser.extractImage()?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }.value
            if let image {
                return DepthMapSource(image: image, isOneFrame: false)
            }
        }
        let image = try await DepthMapSceneCapture.render(wallpaper, request: request)
        return DepthMapSource(image: image, isOneFrame: true)
    }

    /// The texture an image layer's model draws: its material's first pass's first texture.
    static func textureName(ofModel model: String, resources: EditorWallpaperResources) -> String? {
        // Optional: a model or material that isn't JSON names no texture (the scene's load logs it).
        guard let modelData = resources.data(model),
              let modelJSON = try? JSONSerialization.jsonObject(with: modelData) as? [String: Any],
              let material = modelJSON["material"] as? String,
              let materialData = resources.data(material),
              let materialJSON = try? JSONSerialization.jsonObject(with: materialData) as? [String: Any],
              let passes = materialJSON["passes"] as? [[String: Any]],
              let textures = passes.first?["textures"] as? [Any],
              let name = textures.first as? String, !name.isEmpty else { return nil }
        return name
    }
}
