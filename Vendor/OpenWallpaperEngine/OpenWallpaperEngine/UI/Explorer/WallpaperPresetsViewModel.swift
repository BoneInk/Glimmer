import AppKit
import Foundation

/// "Your Presets" for the wallpaper the Details panel shows, over the property stores it edits
/// (`WallpaperViewModel.editedPropertyScopes`).
@MainActor
final class WallpaperPresetsViewModel: ObservableObject {
    @Published private(set) var presets: [WallpaperPreset] = []
    /// The last failure, shown in an alert until dismissed.
    @Published var errorMessage: String?

    private let targets: WallpaperPropertyTargets
    private let store: WallpaperPresetStore
    private let title: String

    init(wallpaper: WEWallpaper, scopes: [WallpaperPropertyScope]) {
        targets = WallpaperPropertyTargets(wallpaper: wallpaper, scopes: scopes)
        store = WallpaperPresetStore(identity: targets.identity)
        title = wallpaper.project.displayTitle
        reload()
    }

    func reload() {
        perform("load the presets") { presets = try store.presets() }
    }

    /// Saves the shown display's properties, with its Scene Edit / Export edits, as `name`.
    func saveCurrent(named name: String) {
        perform("save preset \(name)") {
            try store.save(name: name, values: currentValues)
            presets = try store.presets()
        }
    }

    /// Replaces the edited stores' properties with the preset's and applies them to the running
    /// wallpapers. False when the preset is gone.
    @discardableResult
    func apply(_ preset: WallpaperPreset) -> Bool {
        var applied = false
        perform("apply preset \(preset.name)") {
            guard let current = try store.presets().first(where: { $0.id == preset.id }) else {
                throw WallpaperPresetError.notFound
            }
            targets.apply(preset: current.values, keeping: userShortcutKeys)
            applied = true
            OWELog.info(.library, "Applied preset \(current.name) to \(title)")
        }
        return applied
    }

    func rename(_ preset: WallpaperPreset, to name: String) {
        perform("rename preset \(preset.name)") {
            try store.rename(preset.id, to: name)
            presets = try store.presets()
        }
    }

    func delete(_ preset: WallpaperPreset) {
        perform("delete preset \(preset.name)") {
            try store.delete(preset.id)
            presets = try store.presets()
        }
    }

    func suggestedFileName(for preset: WallpaperPreset) -> String {
        WallpaperPresetTransfer(wallpaper: targets.identity.rawValue, preset: preset).suggestedFileName
    }

    func export(_ preset: WallpaperPreset, to url: URL) {
        perform("export preset \(preset.name) to \(url.path)") {
            try store.exportData(preset.id).write(to: url, options: .atomic)
        }
    }

    /// Imports an exported preset, or a Share JSON file from Wallpaper Engine (named after the file).
    func importFile(at url: URL) {
        perform("import a preset from \(url.path)") {
            let data = try Data(contentsOf: url)
            do {
                try store.importData(data)
            } catch WallpaperPresetError.notAPresetFile {
                try addShareJSON(String(decoding: data, as: UTF8.self), name: url.deletingPathExtension().lastPathComponent)
            }
            presets = try store.presets()
        }
    }

    /// The shown display's properties as they are: the saved values over the project's defaults,
    /// so a wallpaper never edited still saves (and shares) every property, as WE's Save does.
    /// User shortcuts stay out: WE leaves them out of presets, as they belong to this Mac.
    private var currentValues: [String: String] {
        definitions.filter { $0.value.type != SceneScriptUserProperties.Property.userShortcutType }.mapValues(\.defaultValue)
            .merging(targets.storedValues.filter { !userShortcutKeys.contains($0.key) }) { _, stored in stored }
    }

    /// The wallpaper's `usershortcut` properties, which presets neither save nor change.
    private var userShortcutKeys: Set<String> {
        Set(definitions.values.filter { $0.type == SceneScriptUserProperties.Property.userShortcutType }.map(\.key))
    }

    // MARK: Wallpaper Engine's Share JSON

    /// The wallpaper's property definitions, which give Share JSON its value types.
    private lazy var definitions = WallpaperEngineShareJSON.definitions(in: targets.directory)

    /// `preset` in Wallpaper Engine's Share JSON format (its properties, key → value).
    func shareJSON(_ preset: WallpaperPreset) -> Data? {
        var data: Data?
        perform("encode preset \(preset.name) for sharing") {
            data = try WallpaperEngineShareJSON.encode(preset.values, definitions: definitions)
        }
        return data
    }

    /// A Share JSON file of `preset` in a temporary folder, for the share sheet.
    func shareJSONFile(_ preset: WallpaperPreset) -> URL? {
        guard let data = shareJSON(preset) else { return nil }
        var url: URL?
        perform("write preset \(preset.name) for sharing") {
            let folder = FileManager.default.temporaryDirectory.appending(path: "owe-share-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: suggestedFileName(for: preset))
            try data.write(to: file, options: .atomic)
            url = file
        }
        return url
    }

    /// Puts `preset`'s Share JSON on the clipboard, as text Wallpaper Engine's Share JSON takes.
    func copyJSON(_ preset: WallpaperPreset) {
        guard let data = shareJSON(preset) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
    }

    /// Adds the Share JSON on the clipboard (plain or as Wallpaper Engine's Copy leaves it) as a preset.
    func pasteJSON() {
        perform("paste a preset") {
            guard let text = NSPasteboard.general.string(forType: .string) else { throw WallpaperPresetError.notAPresetFile }
            try addShareJSON(text, name: String(localized: "Pasted Preset", comment: "Name of a wallpaper preset made from pasted Share JSON"))
            presets = try store.presets()
        }
    }

    private func addShareJSON(_ text: String, name: String) throws {
        let values = WallpaperEngineShareJSON.values(from: try WallpaperEngineShareJSON.decode(text), definitions: definitions)
        guard !values.isEmpty else { throw WallpaperPresetError.noMatchingProperties }
        try store.add(name: name, values: values)
    }

    // MARK: All wallpapers

    /// Applies `preset`'s values to the installed wallpapers with matching properties; nil on failure.
    func applyToAll(_ preset: WallpaperPreset, mode: WallpaperPresetBulkApply.Mode) -> WallpaperPresetBulkApply.Result? {
        var result: WallpaperPresetBulkApply.Result?
        perform("apply preset \(preset.name) to all wallpapers") {
            guard let current = try store.presets().first(where: { $0.id == preset.id }) else {
                throw WallpaperPresetError.notFound
            }
            let bulk = WallpaperPresetBulkApply(values: current.values, sourceDefinitions: definitions, sourceIdentity: targets.identity)
            let installed = InstalledLibrary.wallpapers(in: FileManager.default.wallpapersDirectory, hiding: [])
            let applied = bulk.apply(to: installed, mode: mode)
            OWELog.info(.library, "Applied preset \(current.name) of \(title) to \(applied.applied) wallpapers (\(applied.keptCustomized) customized kept, \(applied.withoutMatch) without matching properties)")
            result = applied
        }
        return result
    }

    /// Imports the presets and saved values of a Wallpaper Engine config.json; nil on failure.
    func importWallpaperEngineConfig(at url: URL) -> WallpaperEngineConfigImport.Summary? {
        var summary: WallpaperEngineConfigImport.Summary?
        perform("import the config.json at \(url.path)") {
            let entries = try WallpaperEngineConfigImport.entries(in: Data(contentsOf: url))
            let installed = InstalledLibrary.wallpapers(in: FileManager.default.wallpapersDirectory, hiding: [])
            let imported = try WallpaperEngineConfigImport.importEntries(
                entries, installed: installed,
                savedValuesName: String(localized: "Wallpaper Engine Settings",
                                        comment: "Name of a preset made from the property values saved in Wallpaper Engine's config.json"))
            OWELog.info(.library, "Imported \(imported.presets) presets for \(imported.wallpapers) wallpapers from Wallpaper Engine's config.json; \(imported.notInstalled) not installed")
            summary = imported
            presets = try store.presets()
        }
        return summary
    }

    private func perform(_ action: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            OWELog.error(.library, "Could not \(action) for \(title): \(error)")
            errorMessage = error.localizedDescription
        }
    }
}
