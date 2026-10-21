import AppKit
import OWEEditor
import OWESceneEditing

/// What the Wallpaper Editor's particle editor reads from the app: the wallpaper's files (its
/// package, else its folder) and WE's assets, as the scene loader finds them; the textures a
/// particle material can draw and their previews; and WE's particle systems and presets.
final class WallpaperEditorParticleAssets {
    private let directory: URL
    private let package: PKGParser?

    init(wallpaper: WEWallpaper, package: PKGParser?) {
        directory = wallpaper.wallpaperDirectory
        self.package = package
    }

    /// The file at `path`: the wallpaper's, else WE's (`materials/presets/x` also as
    /// `materials/x`, as the loader looks it up).
    func data(_ path: String) -> Data? {
        if let data = package?.extractFile(named: path) { return data }
        // A missing loose file is an ordinary miss: WE's assets are tried next.
        do {
            if let data = try AssetPathResolver.data(path, in: directory) { return data }
        } catch {
            OWELog.error(.scene, "Wallpaper Editor: \(path) of \(directory.path) can't be read: \(error)")
        }
        guard let assets = WallpaperEngineAssets.directory else { return nil }
        var candidates = [path]
        if path.hasPrefix("materials/presets/") {
            candidates.append("materials/" + String(path.dropFirst("materials/presets/".count)))
        }
        guard let url = WallpaperEngineAssets.locate(candidates, in: [assets]) else { return nil }
        do {
            return try AssetPathResolver.readRegularFile(at: url)
        } catch {
            OWELog.error(.scene, "Wallpaper Editor: WE's \(url.path) can't be read: \(error)")
            return nil
        }
    }

    /// WE's default particle systems and presets, titled in WE's own words for the user's
    /// language; empty without WE's assets.
    func catalog(labels: WallpaperEngineLabels) -> ParticleCatalog {
        guard let assets = WallpaperEngineAssets.directory else { return ParticleCatalog(items: [], hasPresets: false) }
        return ParticleCatalog.load(assetsDirectory: assets, translate: { labels.translation($0) })
    }

    /// The wallpaper's textures (`materials/**.tex`) and WE's particle sprites
    /// (`materials/particle/**.tex`), by the name a material gives them.
    func textures() -> [ParticleTextureChoice] {
        var own = Set<String>()
        let packaged = package?.fileList ?? []
        for path in packaged where path.hasPrefix("materials/") && path.hasSuffix(".tex") { own.insert(path) }
        own.formUnion(Self.texturePaths(under: directory.appending(path: "materials", directoryHint: .isDirectory),
                                        prefix: "materials/"))
        var choices = own.sorted().map { ParticleTextureChoice(name: Self.name(of: $0), frames: frames(of: $0), isShared: false) }
        if let assets = WallpaperEngineAssets.directory {
            let shared = Self.texturePaths(under: assets.appending(path: "materials/particle", directoryHint: .isDirectory),
                                           prefix: "materials/particle/")
            let names = Set(choices.map(\.name))
            choices += shared.sorted().map { ParticleTextureChoice(name: Self.name(of: $0), frames: frames(of: $0), isShared: true) }
                .filter { !names.contains($0.name) }
        }
        return choices
    }

    /// A preview of the texture a material names, read through the app's TEX reader.
    func thumbnail(_ name: String) -> NSImage? {
        guard let data = data("materials/\(name).tex") else { return nil }
        return TEXParser(data: data).extractImage()
    }

    /// Frames of the texture's sprite sheet, from its `.tex-json`; 0 for a still one or none.
    private func frames(of texturePath: String) -> Int {
        struct Metadata: Decodable {
            struct Sequence: Decodable { let frames: Int }
            let spritesheetsequences: [Sequence]?
        }
        // Optional metadata: a texture without a readable `.tex-json` is shown as a still one.
        guard let data = data(texturePath + "-json"),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else { return 0 }
        return metadata.spritesheetsequences?.first?.frames ?? 0
    }

    /// `materials/particle/halo.tex` → `particle/halo`.
    static func name(of texturePath: String) -> String {
        var name = texturePath
        if name.hasPrefix("materials/") { name.removeFirst("materials/".count) }
        if name.hasSuffix(".tex") { name.removeLast(".tex".count) }
        return name
    }

    /// The `.tex` files under `folder`, as paths beginning with `prefix`.
    static func texturePaths(under folder: URL, prefix: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var paths: [String] = []
        let base = folder.standardizedFileURL.path
        for case let url as URL in enumerator where url.pathExtension == "tex" {
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base) else { continue }
            let relative = full.dropFirst(base.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            paths.append(prefix + relative)
        }
        return paths
    }
}
