import AppKit
import OWEEditor
import OWESceneEditing
import WEFormat

/// What the Wallpaper Editor reads of the wallpaper and of Wallpaper Engine's assets
/// (editor-plan notes, phases 2–3): the effects it can add, what each effect lets it change
/// (from the effect's shaders, as Scene Edit / Export reads them), the wallpaper's files, its
/// textures as pictures, its fonts and its user properties.
@MainActor
final class EditorWallpaperResources {
    let wallpaper: WEWallpaper
    let assets: EditorAssetStore
    private let labels: WallpaperEngineLabels
    let package: PKGParser?
    private var schemas: [String: EffectSchema?] = [:]
    private var textures: [String: CGImage?] = [:]
    private var catalog: [EffectCatalogEntry]?
    /// Read once: the wallpaper's files, WE's and the wallpaper's fonts, and its properties don't
    /// change while it is edited.
    private var ownAssets: [EditorAsset]?
    private var ownPaths: [String]?
    private var shippedFonts: [EditorFont]?
    private var propertyChoices: [EditorUserPropertyChoice]?
    /// The draft's own files (the effects made in the editor, `SceneEditOverlay.effectFiles`),
    /// which the loader reads before any other.
    var draftFiles: () -> [String: String] = { [:] }

    init(wallpaper: WEWallpaper, package: PKGParser?, assets: EditorAssetStore,
         labels: WallpaperEngineLabels = WallpaperEngineLabels.load()) {
        self.wallpaper = wallpaper
        self.package = package
        self.assets = assets
        self.labels = labels
    }

    /// A file as the scene loader finds it: the draft's files, the wallpaper's package, its
    /// folder, the editor's files, then WE's assets.
    func data(_ path: String) -> Data? {
        if let text = draftFiles()[path] { return Data(text.utf8) }
        if let data = package?.extractFile(named: path) { return data }
        // A source without the file is the next one's turn; one that has it but can't read it logs.
        if let data = OWELog.attempt(.ui, "Wallpaper Editor: \(path)", { try AssetPathResolver.data(path, in: wallpaper.wallpaperDirectory) }) ?? nil {
            return data
        }
        if let url = assets.url(for: path),
           let data = OWELog.attempt(.ui, "Wallpaper Editor: added asset \(path)", { try Data(contentsOf: url) }) { return data }
        guard let candidate = WallpaperEngineAssets.locate([path], in: WallpaperEngineAssets.searchDirectories) else { return nil }
        return OWELog.attempt(.ui, "Wallpaper Editor: Wallpaper Engine asset \(path)") { try AssetPathResolver.readRegularFile(at: candidate) }
    }

    // MARK: Effects

    /// WE's built-in effects (`effects/*/effect.json` in its assets) and the Workshop effects the
    /// wallpaper's layers use.
    func effectCatalog(outline: SceneOutline) -> [EffectCatalogEntry] {
        // Read again until WE's assets are installed: the browser offers to install them.
        if catalog?.isEmpty ?? true {
            catalog = Self.builtInEffects(labels: labels, read: { self.data($0) })
        }
        let builtIn = Set((catalog ?? []).map(\.folderName))
        let own = ownEffects()
        let workshop = EffectCatalog.workshopEffects(in: outline, builtIn: builtIn,
                                                     excluded: Set(own.map { $0.file.lowercased() })).compactMap { file in
            Self.entry(file, data: data(file), labels: labels, preview: nil, isWorkshop: true).map { entry in
                var entry = entry
                entry.wallpaperDirectory = wallpaper.wallpaperDirectory.path(percentEncoded: false)
                return entry
            }
        }
        return own + (catalog ?? []) + workshop
    }

    /// WE's "My Effects": the effects made in the editor (the draft's) and the wallpaper's own
    /// `effects/<name>/effect.json` that it marks `editable`, which the shader editor edits.
    private func ownEffects() -> [EffectCatalogEntry] {
        let drafted = Set(CustomEffect.effectFiles(in: Array(draftFiles().keys)))
        let shipped = CustomEffect.effectFiles(in: wallpaperFilePaths())
        return Array(drafted.union(shipped)).sorted().compactMap { file in
            guard let data = data(file),
                  let json = try? TolerantJSON.object(from: data) as? [String: Any] else { return nil }
            let madeHere = drafted.contains(file) && !shipped.contains(file)
            guard madeHere || json["editable"] as? Bool == true else { return nil }
            guard var entry = Self.entry(file, data: data, labels: labels, preview: nil, isWorkshop: false) else { return nil }
            entry.group = CustomEffect.group
            entry.groupTitle = CustomEffect.group
            entry.isEditable = true
            entry.isMadeHere = madeHere
            entry.wallpaperDirectory = wallpaper.wallpaperDirectory.path(percentEncoded: false)
            return entry
        }
    }

    /// WE's built-in effects (`effects/*/effect.json` in its assets), titled with `labels`; `read`
    /// reads an effect's file (the wallpaper's own copy first, in an editor window). The browser's
    /// entries, and the background pre-warm's (`EditorPreviewPrewarm`).
    nonisolated static func builtInEffects(labels: WallpaperEngineLabels, read: (String) -> Data?) -> [EffectCatalogEntry] {
        var entries: [EffectCatalogEntry] = []
        for directory in WallpaperEngineAssets.searchDirectories {
            for file in EffectCatalog.builtInEffectFiles(in: directory) {
                let folder = directory.appending(path: (file as NSString).deletingLastPathComponent, directoryHint: .isDirectory)
                guard !entries.contains(where: { $0.file == file }),
                      let entry = entry(file, data: read(file), labels: labels, preview: preview(in: folder), isWorkshop: false)
                else { continue }
                entries.append(entry)
            }
        }
        return entries
    }

    nonisolated private static func entry(_ file: String, data: Data?, labels: WallpaperEngineLabels, preview: URL?,
                                          isWorkshop: Bool) -> EffectCatalogEntry? {
        // Optional: an effect file that can't be read or decoded isn't offered.
        guard let data, let document = try? decodeTolerant(EffectDocument.self, from: data) else { return nil }
        let folder = ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let title = document.name.flatMap(labels.translation) ?? document.name.map(SceneEffectParameters.title)
            ?? folder.replacingOccurrences(of: "_", with: " ").capitalized
        return EffectCatalogEntry(file: file, title: title, summary: document.description.flatMap(labels.translation) ?? "",
                                  group: document.group ?? "", groupTitle: document.group ?? "", preview: preview,
                                  isWorkshop: isWorkshop, passCount: max(document.passes.count, 1))
    }

    /// Copies a built-in effect's dependencies (`effect.json`'s `dependencies`: its materials,
    /// shaders and textures) from WE's assets into the project files the editor keeps, where the
    /// wallpaper doesn't have them: WE reads an effect's files at the project root, then the assets
    /// root, never inside `assets/effects/<name>/` (`SceneEffectPlanBuilder.readWallpaperFile`), so
    /// its editor copies them into a project an effect is added to. A Workshop effect the wallpaper
    /// ships needs nothing.
    func prepareEffect(_ entry: EffectCatalogEntry) throws {
        guard !entry.isWorkshop, let data = data(entry.file),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let folder = (entry.file as NSString).deletingLastPathComponent
        for dependency in json["dependencies"] as? [String] ?? [] {
            let ownCopy = (try? AssetPathResolver.data(dependency, in: wallpaper.wallpaperDirectory)) ?? nil
            guard package?.extractFile(named: dependency) == nil, ownCopy == nil,
                  let source = WallpaperEngineAssets.locate(["\(folder)/\(dependency)"], in: WallpaperEngineAssets.searchDirectories)
            else { continue }
            try assets.store(try AssetPathResolver.readRegularFile(at: source), at: dependency)
        }
    }

    /// An effect's picture, where its folder has one.
    nonisolated private static func preview(in folder: URL) -> URL? {
        for name in ["preview/preview.gif", "preview/preview.jpg", "preview/preview.png", "preview.gif", "preview.jpg", "preview.png"] {
            let url = folder.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// The effect's constants, combos and texture slots, from its shaders (as Scene Edit / Export
    /// reads them: `SceneEffectParameters`), titled with WE's labels.
    func effectSchema(_ file: String) -> EffectSchema? {
        // An effect the editor's files hold changes as its shaders are edited: keyed by them too.
        let folder = (file as NSString).deletingLastPathComponent + "/"
        let ownFiles = draftFiles().filter { $0.key.hasPrefix(folder) }.sorted { $0.key < $1.key }
        let cacheKey = ownFiles.isEmpty ? file : file + "\u{0}" + ownFiles.map { "\($0.key)\u{0}\($0.value)" }.joined(separator: "\u{0}")
        if let cached = schemas[cacheKey] { return cached }
        let read: (String) -> Data? = { [weak self] path in self?.data(path) }
        guard let effectData = read(file), let document = try? decodeTolerant(EffectDocument.self, from: effectData) else {
            schemas[cacheKey] = .some(nil)
            return nil
        }
        let parameters = SceneEffectParameters.parameters(for: file, readFile: read).map { parameter in
            EffectSchema.Parameter(key: parameter.materialKey, title: labels.translation(parameter.label) ?? parameter.title,
                                   defaultValue: parameter.defaultValue, minimum: parameter.minimum, maximum: parameter.maximum,
                                   isInteger: parameter.isInteger, isColor: parameter.isColor, isLinked: parameter.isLinked,
                                   isPosition: parameter.isPosition, isDirection: parameter.isDirection,
                                   showsDegrees: parameter.showsDegrees)
        }
        let combos = SceneEffectParameters.combos(for: file, readFile: read).filter(\.isEditable).map { combo in
            EffectSchema.Combo(name: combo.combo, title: labels.translation(combo.label) ?? SceneEffectParameters.title(combo.label),
                               defaultValue: combo.defaultValue,
                               options: combo.options.map { option in
                                   EffectSchema.Combo.Option(title: labels.translation(option.label) ?? option.english
                                                                ?? SceneEffectParameters.title(option.label),
                                                             value: option.value,
                                                             group: option.group.map { labels.translation($0) ?? SceneBlendModeOptions.groupTitle($0) })
                               },
                               requirements: combo.requirements)
        }
        let schema = EffectSchema(parameters: parameters, combos: combos,
                                  textures: textureSlots(file, document: document, read: read),
                                  passCount: max(document.passes.count, 1), gizmos: gizmos(file, data: effectData))
        schemas[cacheKey] = schema
        return schema
    }

    /// `effect.json`'s `gizmos`, which the canvas draws; none when they can't be read (logged).
    private func gizmos(_ file: String, data: Data) -> [EffectGizmo] {
        do {
            return try EffectGizmo.gizmos(effectJSON: data)
        } catch {
            OWELog.error(.ui, "Wallpaper Editor: \(file)'s gizmos couldn't be read: \(error.localizedDescription)")
            return []
        }
    }

    /// The samplers WE's editor shows, of every pass that draws a material: those not hidden, past
    /// the layer's own image (`g_Texture0`) and not fed by the pass's `bind` (render targets).
    /// Each keeps its pass, so a multi-pass effect's mask (Blur's, in its fourth pass) is set where
    /// WE's scenes name it.
    private func textureSlots(_ file: String, document: EffectDocument, read: @escaping (String) -> Data?) -> [EffectSchema.TextureSlot] {
        let directory = (file as NSString).deletingLastPathComponent
        let scoped: (String) -> Data? = { path in ["\(directory)/\(path)", path].lazy.compactMap(read).first }
        let loader = ShaderSourceLoader(readFile: scoped)
        var slots: [EffectSchema.TextureSlot] = []
        for (pass, effectPass) in document.passes.enumerated() {
            guard let materialPath = effectPass.material, let materialData = scoped(materialPath),
                  let material = try? decodeTolerant(MaterialDocument.self, from: materialData),
                  let shader = material.passes.first?.shader else { continue }
            let bound = Set(effectPass.bind.map(\.index))
            let materialName = ((materialPath as NSString).lastPathComponent as NSString).deletingPathExtension
            for stage in ShaderStage.allCases {
                guard let source = try? loader.load(shader, stage: stage) else { continue }
                for sampler in source.samplers {
                    guard let slot = sampler.textureSlot, slot > 0, !bound.contains(slot), sampler.annotation["hidden"] as? Bool != true,
                          !slots.contains(where: { $0.pass == pass && $0.slot == slot }) else { continue }
                    let label = sampler.annotation["label"] as? String ?? sampler.name
                    let mode = (sampler.annotation["mode"] as? String)?.lowercased()
                    let isMask = mode?.contains("mask") == true || label.lowercased().contains("mask")
                    let paintDefault = (sampler.annotation["paintdefaultcolor"] as? String)
                        .map { $0.split(separator: " ").compactMap { Double($0) } }
                    slots.append(EffectSchema.TextureSlot(slot: slot, title: labels.translation(label) ?? SceneEffectParameters.title(label),
                                                          defaultTexture: sampler.defaultTexture, isMask: isMask,
                                                          combo: sampler.combo, paintDefault: paintDefault, mode: mode,
                                                          pass: pass, materialName: materialName))
                }
            }
        }
        return slots.sorted { ($0.pass, $0.slot) < ($1.pass, $1.slot) }
    }

    // MARK: Files

    /// The wallpaper's own textures, models, sounds and fonts.
    func wallpaperAssets() -> [EditorAsset] {
        if let ownAssets { return ownAssets }
        let assets = readWallpaperAssets()
        ownAssets = assets
        return assets
    }

    /// Every file of the wallpaper (its package's and its folder's), by path. Read once.
    private func wallpaperFilePaths() -> [String] {
        if let ownPaths { return ownPaths }
        var paths: [String] = package?.fileList ?? []
        let root = wallpaper.wallpaperDirectory.standardizedFileURL.path
        if let enumerator = FileManager.default.enumerator(at: wallpaper.wallpaperDirectory, includingPropertiesForKeys: [.isRegularFileKey],
                                                           options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                paths.append(String(url.standardizedFileURL.path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            }
        }
        ownPaths = paths
        return paths
    }

    private func readWallpaperAssets() -> [EditorAsset] {
        let paths = wallpaperFilePaths()
        var seen = Set<String>()
        return paths.compactMap { path in
            guard seen.insert(path.lowercased()).inserted else { return nil }
            let kind = EditorAsset.kind(of: path)
            return kind == .other ? nil : EditorAsset(path: path, kind: kind)
        }
    }

    /// A texture (`foo`, `masks/…`, `editor/…`) as a picture: its `.tex`, else a PNG or JPEG where
    /// the `.tex` would be. Kept once read.
    func texture(_ name: String) -> CGImage? {
        if let cached = textures[name] { return cached }
        var image: CGImage?
        for candidate in ["materials/\(name).tex", "materials/\(name).png", "materials/\(name).jpg", "\(name).tex"] {
            guard let data = data(candidate) else { continue }
            let picture = candidate.hasSuffix(".tex") ? TEXParser(data: data).extractImage() : NSImage(data: data)
            if let picture, let cg = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                image = cg
                break
            }
        }
        textures[name] = image
        return image
    }

    /// WE's system fonts, WE's own font files, the wallpaper's and the imported ones.
    func fonts() -> [EditorFont] {
        var fonts = shippedFonts ?? readShippedFonts()
        shippedFonts = fonts
        for file in assets.assets().map(\.path) where EditorAsset.kind(of: file) == .font && !fonts.contains(where: { $0.value == file }) {
            fonts.append(EditorFont(value: file, title: ((file as NSString).lastPathComponent as NSString).deletingPathExtension))
        }
        return fonts
    }

    private func readShippedFonts() -> [EditorFont] {
        var fonts = SceneFontResolver.weSystemFonts.keys.sorted().map { name in
            EditorFont(value: SceneFontResolver.systemFontPrefix + name, title: SceneFontResolver.weSystemFonts[name]?.family ?? name)
        }
        var files: [String] = []
        for directory in WallpaperEngineAssets.searchDirectories {
            let folder = directory.appending(path: "fonts", directoryHint: .isDirectory)
            for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where EditorAssetStore.fontTypes.contains(url.pathExtension.lowercased()) {
                files.append("fonts/\(url.lastPathComponent)")
            }
        }
        files += wallpaperAssets().filter { $0.kind == .font }.map(\.path)
        for file in files where !fonts.contains(where: { $0.value == file }) {
            fonts.append(EditorFont(value: file, title: ((file as NSString).lastPathComponent as NSString).deletingPathExtension))
        }
        return fonts
    }

    /// The wallpaper's user properties a value can follow (not its text rows and groups).
    func userPropertyChoices() -> [EditorUserPropertyChoice] {
        if let propertyChoices { return propertyChoices }
        let choices = readUserPropertyChoices()
        propertyChoices = choices
        return choices
    }

    private func readUserPropertyChoices() -> [EditorUserPropertyChoice] {
        guard let root = OWELog.attempt(.ui, "Wallpaper Editor: project.json", { try WEProject.json(in: wallpaper.wallpaperDirectory) }) ?? nil else { return [] }
        let labels = self.labels.addingAuthorTranslations(projectJSON: root)
        return UserPropertyDefinition.all(projectJSON: root)
            .filter { !["text", "group"].contains($0.type) }
            .sorted { ($0.order ?? .max, $0.key) < ($1.order ?? .max, $1.key) }
            .map { definition in
                let title = Self.plain(labels.translation(definition.text) ?? definition.text)
                return EditorUserPropertyChoice(key: definition.key, title: title.isEmpty ? definition.key : title,
                                                type: definition.type)
            }
    }

    /// Text without HTML tags (WE allows them in property labels).
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
