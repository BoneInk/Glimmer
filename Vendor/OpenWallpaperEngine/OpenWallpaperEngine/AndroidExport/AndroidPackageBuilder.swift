import Foundation

/// What goes into the `.mpkg` WE's "Export .mpkg" writes for its Android app, for each kind of
/// export, as WE 2.8.42's samples have it (`MobilePackageWriter` writes them):
///
/// - **Video:** the wallpaper's video file byte for byte, under its own name, its preview, and a
///   project.json of only `file`, `preview`, `title` and `type: "video"`.
/// - **Scene, Dynamic:** the scene itself, loose: every file of its scene.pkg (or, without one, of
///   its folder) but its sound files (WE drops the music; the sound layer keeps naming it),
///   project.json and the preview as they are, scene.json written again with
///   `general.texturereduction`, shaders made GLSL ES-safe (`MobileShaderCompatibility`) and
///   `.tex` files converted (`MobileTextureConverter`). From Scene Edit / Export's Android
///   Export mode, its layer edits and user properties are baked in (`AndroidSceneBake`).
/// - **Scene, Pre-Rendered:** `wallpaper.mp4` (`AndroidVideoRenderer`), scene.json (with
///   `texturereduction` 4, as WE's has it), project.json with `file` set to `wallpaper.mp4`
///   (its `type` stays `Scene`), and the preview.
///
/// Web and application wallpapers aren't supported on Android ("Wallpaper type not supported on
/// Android devices").
enum AndroidPackageBuilder {
    typealias Entry = MobilePackageWriter.Entry

    static let videoFileName = "wallpaper.mp4"

    enum Failure: LocalizedError {
        case unsupported
        case missingFile(String)
        case unreadable(String, Error)

        var errorDescription: String? {
            switch self {
            case .unsupported: return String(localized: "Wallpaper type not supported on Android devices")
            case .missingFile(let file): return String(localized: "Failed copying wallpaper files.") + " (\(file))"
            case .unreadable(let file, let error): return String(localized: "Failed unpacking project files.") + " (\(file): \(error.localizedDescription))"
            }
        }
    }

    enum Kind: Equatable {
        case scene, video
    }

    /// Scenes and videos export; web and application wallpapers don't.
    static func kind(of wallpaper: WEWallpaper) -> Kind? {
        switch wallpaper.project.type.lowercased() {
        case "scene": return .scene
        case "video": return wallpaper.isRemoteMedia ? nil : .video
        default: return nil
        }
    }

    // MARK: Video

    static func videoEntries(_ wallpaper: WEWallpaper) throws -> [Entry] {
        guard kind(of: wallpaper) == .video else { throw Failure.unsupported }
        let directory = wallpaper.wallpaperDirectory
        let file = wallpaper.project.file
        let video = directory.appending(path: file)
        guard FileManager.default.fileExists(atPath: video.path(percentEncoded: false)) else { throw Failure.missingFile(file) }
        var entries = [Entry(path: file, file: video)]
        var project: [String: WEJSONDocument] = ["file": .string(file), "title": .string(wallpaper.project.title), "type": .string("video")]
        if let preview = previewEntry(wallpaper) {
            entries.append(preview)
            project["preview"] = .string(preview.path)
        }
        entries.append(Entry(path: "project.json", data: WEJSONWriter.data(.object(project))))
        return entries
    }

    // MARK: Scene

    /// The Dynamic package: the scene's files, converted for `options`. Runs off the main thread.
    /// `baking`: values whose layer edits and user properties are baked into scene.json, the
    /// files they replace and project.json (`AndroidSceneBake`); nil packs them as they are.
    static func dynamicEntries(_ wallpaper: WEWallpaper, options: AndroidExportOptions, baking: [String: String]? = nil,
                               progress: ((Double) -> Void)? = nil) throws -> [Entry] {
        ThreadGuards.assertBackground("AndroidPackageBuilder.dynamicEntries")
        guard kind(of: wallpaper) == .scene else { throw Failure.unsupported }
        // WE leaves the music out of a mobile package; the sound layer still names its file.
        var files = try sceneFiles(wallpaper).filter { !isAudio($0.path) }
        if let baking { files = AndroidSceneBake.replacingFiles(files, values: baking) }
        let secondary = secondaryTextures(in: files)
        let reduction = options.effectiveTextureReduction.rawValue
        var entries: [Entry] = []
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let lowered = file.path.lowercased()
            if file.path == wallpaper.project.file {
                let data = try baking.map { try AndroidSceneBake.scene(file.data, values: $0) } ?? file.data
                entries.append(Entry(path: file.path, data: try scene(data, textureReduction: options.sceneTextureReduction)))
            } else if lowered.hasPrefix("shaders/"), lowered.hasSuffix(".frag") || lowered.hasSuffix(".vert") {
                let source = String(decoding: file.data, as: UTF8.self)
                entries.append(Entry(path: file.path, data: Data(MobileShaderCompatibility.rewrite(source).utf8)))
            } else if lowered.hasSuffix(".tex") {
                entries.append(Entry(path: file.path, data: try MobileTextureConverter.convert(
                    file.data, path: file.path, reduction: reduction, pixelArt: options.pixelArt,
                    secondary: secondary.contains(file.path))))
            } else {
                entries.append(Entry(path: file.path, data: file.data))
            }
            progress?(Double(index + 1) / Double(files.count))
        }
        let project = try baking.map { try AndroidSceneBake.project(projectData(wallpaper), values: $0) }
        return try entries + projectAndPreview(wallpaper, project: project)
    }

    /// The Pre-Rendered package around the rendered `video`: scene.json with the options'
    /// `texturereduction` (4 for WE's preset), no sound file.
    static func preRenderedEntries(_ wallpaper: WEWallpaper, video: URL,
                                   options: AndroidExportOptions = AndroidExportOptions(mode: .preRendered)) throws -> [Entry] {
        guard kind(of: wallpaper) == .scene else { throw Failure.unsupported }
        let sceneFile = wallpaper.project.file
        let scene = try scene(sceneData(wallpaper), textureReduction: options.sceneTextureReduction)
        var project = try projectDocument(wallpaper)
        project["file"] = .string(videoFileName)
        return try [Entry(path: videoFileName, file: video), Entry(path: sceneFile, data: scene)]
            + projectAndPreview(wallpaper, project: WEJSONWriter.data(project))
    }

    /// scene.json written as WE writes it, with `general.texturereduction`.
    static func scene(_ data: Data, textureReduction: Int) throws -> Data {
        var document: WEJSONDocument
        do {
            document = try WEJSONDocument(parsing: data)
        } catch {
            throw Failure.unreadable("scene.json", error)
        }
        var general = document["general"] ?? .object([:])
        general["texturereduction"] = .integer(Int64(textureReduction))
        document["general"] = general
        return WEJSONWriter.data(document)
    }

    // MARK: Files

    /// The scene file's bytes, from the scene.pkg or the folder.
    static func sceneData(_ wallpaper: WEWallpaper) throws -> Data {
        let file = wallpaper.project.file
        let directory = wallpaper.wallpaperDirectory
        let package = directory.appending(path: (file as NSString).deletingPathExtension + ".pkg")
        do {
            if FileManager.default.fileExists(atPath: package.path(percentEncoded: false)) {
                guard let data = try PKGParser(url: package).extractFile(named: file) else { throw Failure.missingFile(file) }
                return Data(data)
            }
            guard let data = try AssetPathResolver.data(file, in: directory) else { throw Failure.missingFile(file) }
            return data
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreadable(file, error)
        }
    }

    /// The scene as the renderer draws it, its saved overlay applied (`SceneDrawnSize`), which the
    /// pre-rendered crop is measured in.
    static func sceneSize(_ wallpaper: WEWallpaper) throws -> SIMD2<Double> {
        do {
            return try SceneDrawnSize.of(sceneData: sceneData(wallpaper), overlay: SceneDrawnSize.savedOverlay(of: wallpaper),
                                         readAsset: SceneImageSize.reader(for: wallpaper))
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreadable(wallpaper.project.file, error)
        }
    }

    /// The sound files a mobile package leaves out.
    static let audioExtensions: Set<String> = ["mp3", "ogg", "wav", "m4a", "flac"]

    static func isAudio(_ path: String) -> Bool {
        audioExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    struct File {
        var path: String
        var data: Data
    }

    /// The scene's own files: its scene.pkg's entries, or its folder's files (no hidden files,
    /// project.json, the preview or a package).
    static func sceneFiles(_ wallpaper: WEWallpaper) throws -> [File] {
        let directory = wallpaper.wallpaperDirectory
        let package = directory.appending(path: (wallpaper.project.file as NSString).deletingPathExtension + ".pkg")
        if FileManager.default.fileExists(atPath: package.path(percentEncoded: false)) {
            do {
                let parser = try PKGParser(url: package)
                return try parser.fileList.map { path in
                    guard let data = parser.extractFile(named: path) else { throw Failure.missingFile(path) }
                    return File(path: path, data: Data(data))
                }
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure.unreadable(package.lastPathComponent, error)
            }
        }
        let skipped: Set<String> = ["project.json", wallpaper.project.preview ?? "", package.lastPathComponent]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles]) else {
            throw Failure.missingFile(directory.lastPathComponent)
        }
        var files: [File] = []
        let base = directory.standardizedFileURL.path(percentEncoded: false)
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            var path = url.standardizedFileURL.path(percentEncoded: false)
            guard path.hasPrefix(base) else { continue }
            path = String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !skipped.contains(path) else { continue }
            do {
                files.append(File(path: path, data: try Data(contentsOf: url)))
            } catch {
                throw Failure.unreadable(path, error)
            }
        }
        return files
    }

    /// project.json (as it is, or `project`) and the preview.
    private static func projectAndPreview(_ wallpaper: WEWallpaper, project: Data?) throws -> [Entry] {
        [Entry(path: "project.json", data: try project ?? projectData(wallpaper))] + (previewEntry(wallpaper).map { [$0] } ?? [])
    }

    /// project.json's bytes.
    static func projectData(_ wallpaper: WEWallpaper) throws -> Data {
        do {
            return try WEProject.data(in: wallpaper.settingsDirectory)
        } catch {
            throw Failure.unreadable("project.json", error)
        }
    }

    private static func projectDocument(_ wallpaper: WEWallpaper) throws -> WEJSONDocument {
        let url = WEProject.url(in: wallpaper.settingsDirectory)
        do {
            return try WEJSONDocument(parsing: Data(contentsOf: url))
        } catch {
            throw Failure.unreadable("project.json", error)
        }
    }

    private static func previewEntry(_ wallpaper: WEWallpaper) -> Entry? {
        guard let preview = wallpaper.project.preview, !preview.isEmpty,
              let url = wallpaper.previewURL, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }
        return Entry(path: preview, file: url)
    }

    // MARK: Texture slots

    /// The `.tex` files the scene samples only as a second or later texture of a pass (masks,
    /// flow phases): every `textures` list in its JSON files, by slot.
    static func secondaryTextures(in files: [File]) -> Set<String> {
        var first = Set<String>(), later = Set<String>()
        func visit(_ document: WEJSONDocument) {
            switch document {
            case .object(let members):
                for (key, value) in members {
                    if key == "textures", case .array(let names) = value {
                        for (slot, name) in names.enumerated() {
                            guard let name = name.stringValue, !name.isEmpty else { continue }
                            let path = "materials/\(name).tex"
                            if slot == 0 { first.insert(path) } else { later.insert(path) }
                        }
                    } else {
                        visit(value)
                    }
                }
            case .array(let elements):
                elements.forEach(visit)
            default:
                break
            }
        }
        for file in files where file.path.lowercased().hasSuffix(".json") {
            // A JSON file that doesn't parse names no textures; the scene loader reports it.
            guard let document = try? WEJSONDocument(parsing: file.data) else { continue }
            visit(document)
        }
        return later.subtracting(first)
    }
}
