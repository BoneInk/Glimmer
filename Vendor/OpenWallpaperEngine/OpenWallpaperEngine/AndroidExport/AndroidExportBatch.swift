import Foundation

/// One wallpaper an Android export packages: its options (each scene can have its own mode) and,
/// for a pre-rendered scene, the user-property values it renders with. Scene Edit / Export's
/// Android Export mode also gives a pre-render its own framing, and a Dynamic scene the values to
/// bake into its files.
struct AndroidExportItem: Identifiable, Equatable {
    var wallpaper: WEWallpaper
    var options: AndroidExportOptions
    /// The values a pre-render uses (an isolated session's, or the wallpaper's own).
    var properties: [String: String] = [:]
    /// A pre-render's crop, pointer and length (the Android Export mode's); nil frames it by the
    /// options (`AndroidExportOptions.crop`), the pointer centred, WE's 30 s.
    var framing: AndroidVideoFraming?
    /// A pre-render without its own `framing` made for a screen: the video's pixels and length
    /// (the Android Export mode's "Export More with These Settings…"), the crop centred on the
    /// scene at zoom 1, the pointer centred. Nil frames it by the options.
    var screen: AndroidVideoScreen?
    /// Dynamic: values baked into the package's scene.json and project.json
    /// (`AndroidSceneBake`), the Android Export mode's layer edits and user properties; nil packs
    /// the scene as it is.
    var bakedValues: [String: String]?

    var id: String { wallpaper.identityPath }
    var kind: AndroidPackageBuilder.Kind? { AndroidPackageBuilder.kind(of: wallpaper) }
    /// A pre-render needs the GPU; everything else only reads and writes files.
    var usesGPU: Bool { kind == .scene && options.mode == .preRendered }

    /// A pre-render's framing for a scene of `sceneSize`: its own, the screen's, or the options'.
    func framing(sceneSize: SIMD2<Double>) -> AndroidVideoFraming {
        if let framing { return framing }
        if let screen {
            return AndroidVideoFraming(crop: LivePhotoCrop(sceneSize: sceneSize, outputPixels: screen.pixels), seconds: screen.seconds)
        }
        return AndroidVideoFraming(crop: options.crop(sceneSize: sceneSize))
    }

    static func == (lhs: AndroidExportItem, rhs: AndroidExportItem) -> Bool {
        lhs.id == rhs.id && lhs.options == rhs.options && lhs.properties == rhs.properties && lhs.framing == rhs.framing
            && lhs.screen == rhs.screen && lhs.bakedValues == rhs.bakedValues
    }
}

/// The video a pre-render makes for a screen, whatever the scene: its pixels and length.
struct AndroidVideoScreen: Equatable {
    var pixels: SIMD2<Int>
    var seconds = AndroidExportOptions.videoSeconds
}

/// How a pre-rendered video frames the scene: the window and its pixels, where the pointer rests
/// (`LivePhotoParallax`) and the loop's length.
struct AndroidVideoFraming: Equatable {
    var crop: LivePhotoCrop
    var pointer = LivePhotoParallax.centre
    var seconds = AndroidExportOptions.videoSeconds
}

/// What an Android export made, in the selection's order: each package with what a later step
/// (sending them over Wi-Fi) shows of it, and the wallpapers skipped or failed, with why.
struct AndroidExportBatch: Equatable {
    struct Output: Equatable {
        var wallpaperID: String
        var title: String
        /// `scene` or `video`.
        var type: String
        var mode: AndroidExportOptions.Mode?
        var url: URL
        var size: Int64
        /// The wallpaper's preview picture in the library.
        var previewURL: URL?
    }

    struct Skipped: Equatable {
        var wallpaperID: String
        var title: String
        var reason: String
    }

    var folder: URL
    var outputs: [Output] = []
    /// Not exported: their type isn't supported on Android, or a file is missing.
    var skipped: [Skipped] = []
    /// Started but failed.
    var failed: [Skipped] = []
    var wasCancelled = false

    var urls: [URL] { outputs.map(\.url) }
}

/// Which wallpapers of a selection an export takes, and why it leaves the others out.
enum AndroidExportPlan {
    /// The items to export (in the selection's order) and the wallpapers skipped.
    static func make(_ wallpapers: [WEWallpaper], options: (WEWallpaper) -> AndroidExportOptions,
                     properties: (WEWallpaper) -> [String: String] = { _ in [:] }) -> (items: [AndroidExportItem], skipped: [AndroidExportBatch.Skipped]) {
        var items: [AndroidExportItem] = []
        var skipped: [AndroidExportBatch.Skipped] = []
        var seen = Set<String>()
        for wallpaper in wallpapers where seen.insert(wallpaper.identityPath).inserted {
            if let reason = skipReason(wallpaper) {
                skipped.append(.init(wallpaperID: wallpaper.identityPath, title: wallpaper.project.displayTitle, reason: reason))
                continue
            }
            var item = AndroidExportItem(wallpaper: wallpaper, options: options(wallpaper))
            if item.usesGPU { item.properties = properties(wallpaper) }
            items.append(item)
        }
        return (items, skipped)
    }

    /// Why `wallpaper` can't be exported, as WE says it; nil when it can.
    static func skipReason(_ wallpaper: WEWallpaper) -> String? {
        guard let kind = AndroidPackageBuilder.kind(of: wallpaper) else {
            return String(localized: "Wallpaper type not supported on Android devices")
        }
        guard kind == .video else { return nil }
        let video = wallpaper.wallpaperDirectory.appending(path: wallpaper.project.file)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: video.path(percentEncoded: false))
        } catch {
            return String(localized: "Failed copying wallpaper files.")
        }
        if let size = (attributes[.size] as? NSNumber)?.uint64Value, size > MobilePackageWriter.maximumDataSize {
            return String(localized: "Wallpapers larger than 4GB can currently not be transferred to mobile devices.")
        }
        return nil
    }
}

/// The package files' names: `<title>.mpkg`, made unique within the batch and the folder
/// (`<title> 2.mpkg`, `<title> 3.mpkg`…), in the batch's order.
enum AndroidExportNaming {
    static let fileExtension = "mpkg"

    /// A file name from a title: no path separators or colons, never empty or a dot file.
    static func baseName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cleaned.isEmpty ? "Wallpaper" : String(cleaned.prefix(120))
    }

    /// The unique names for `titles`, none of them in `taken` (compared ignoring case, as APFS does).
    static func uniqueNames(_ titles: [String], taken: Set<String>) -> [String] {
        var used = Set(taken.map { $0.lowercased() })
        return titles.map { title in
            let base = baseName(title)
            var name = "\(base).\(fileExtension)"
            var number = 2
            while used.contains(name.lowercased()) {
                name = "\(base) \(number).\(fileExtension)"
                number += 1
            }
            used.insert(name.lowercased())
            return name
        }
    }

    /// The names already in `folder`.
    static func existingNames(in folder: URL) -> Set<String> {
        do {
            return Set(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)))
        } catch {
            OWELog.error(.app, "Android export: can't list \(folder.path(percentEncoded: false)): \(error)")
            return []
        }
    }
}
