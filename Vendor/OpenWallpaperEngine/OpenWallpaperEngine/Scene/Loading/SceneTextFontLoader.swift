import AppKit
import CoreText

/// Finds a text object's `font` (`SceneFontResolver`: the wallpaper, WE's assets, Workshop items,
/// installed `systemfont_*` families) and registers it, so `SceneFontRegistry` and `NSFont(name:)`
/// find it under the scene's path. One per loaded wallpaper: the loader registers the fonts the
/// scene names, and the text raster the ones scripts name (`thisLayer.font`), on whichever thread
/// it runs.
final class SceneTextFontLoader: @unchecked Sendable {
    private let resolver: SceneFontResolver
    /// Guards `names`, and serialises registration so a path is resolved once.
    private let lock = NSLock()
    /// The name each path registered under, by path.
    private var names: [String: String] = [:]

    init(resolver: SceneFontResolver) {
        self.resolver = resolver
    }

    /// Fonts of the wallpaper in `package` (or its folder `directory`), else WE's assets and
    /// Workshop items.
    convenience init(package: PKGParser?, directory: URL?) {
        self.init(resolver: SceneFontResolver(
            wallpaperData: { Self.wallpaperData(named: $0, package: package, directory: directory) },
            assetDirectories: WallpaperEngineAssets.searchDirectories,
            workshop: WorkshopAssetResolver(roots: WorkshopAssetResolver.defaultRoots())))
    }

    /// The name `path` is registered under: a font file's PostScript name, a `systemfont_*`
    /// family, or `path` itself when it can't be found or read (logged; Arial draws, as in WE).
    func register(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let registered = names[path] { return registered }
        let name = resolve(path)
        names[path] = name
        return name
    }

    private func resolve(_ path: String) -> String {
        let data: Data
        switch resolver.resolve(path) {
        case .system(let family)?:
            // The per-layer font setting is seeded with the scene's name (`systemfont_*`).
            if let installed = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12) {
                SceneFontRegistry.register(postScriptName: installed.fontName, names: [path])
            }
            return family
        case .data(let bytes, _)?:
            data = bytes
        case nil:
            OWELog.error(.scene, "Font \"\(path)\" not found in the wallpaper, WE assets or workshop items; using Arial, as WE does")
            return path
        }
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
              let descriptor = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else {
            OWELog.error(.scene, "Font \"\(path)\" is not a font file; using Arial, as WE does")
            return path
        }
        // Fonts inside a PKG have no filesystem URL, so register their in-memory
        // CGFont before NSFont(name:) is used by either text rendering path.
        if let provider = CGDataProvider(data: data as CFData), let font = CGFont(provider) {
            var error: Unmanaged<CFError>?
            _ = CTFontManagerRegisterGraphicsFont(font, &error)
            let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
            SceneFontRegistry.register(font, names: [path, name, family ?? ""])
        }
        return name
    }

    /// The wallpaper's own package or folder; `SceneFontResolver` handles the other sources.
    static func wallpaperData(named path: String, package: PKGParser?, directory: URL?) -> Data? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        for key in [path, normalized, (normalized as NSString).lastPathComponent] {
            if let data = package?.extractFile(named: key) { return data }
        }
        if let entry = package?.fileList.first(where: {
            let candidate = $0.replacingOccurrences(of: "\\", with: "/")
            return candidate.caseInsensitiveCompare(normalized) == .orderedSame
                || (candidate as NSString).lastPathComponent.caseInsensitiveCompare((normalized as NSString).lastPathComponent) == .orderedSame
        }), let data = package?.extractFile(named: entry) {
            return data
        }
        guard let directory else { return nil }
        for candidate in [normalized, (normalized as NSString).lastPathComponent] {
            do {
                if let data = try AssetPathResolver.data(candidate, in: directory) { return data }
            } catch {
                OWELog.error(.scene, "Failed to read font \(candidate): \(error)")
            }
        }
        return nil
    }
}
