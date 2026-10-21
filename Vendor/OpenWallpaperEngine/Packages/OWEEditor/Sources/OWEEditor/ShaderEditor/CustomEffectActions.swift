import Foundation
import OWESceneEditing
import WEFormat

/// Add Effect's New, Duplicate and Delete (WE's `ui_editor_effect_list_modal_create_*`, shown in
/// WE once Asset Creation is on): an effect made from WE's blank effect or copied from the chosen
/// one, kept in the edits, then added to the layer as WE's dialog does with the new item.
@MainActor
struct CustomEffectActions {
    let session: SceneEditSession
    /// A file as the scene loader finds it (the edits', the wallpaper's, then WE's assets).
    let read: (String) -> Data?

    /// Makes the effect named `name`, a copy of `source` (WE's blank effect for New), keeps its
    /// files in the edits and returns its catalog entry.
    func create(named name: String, from source: EffectCatalogEntry?) throws -> EffectCatalogEntry {
        let effect = try CustomEffect.make(named: name, from: source?.file ?? CustomEffect.templateFile, read: read)
        let actionName = source == nil ? L("Create New Effect") : L("Duplicate Effect")
        session.createCustomEffect(effect, actionName: actionName)
        return Self.entry(effect)
    }

    func delete(_ entry: EffectCatalogEntry) {
        session.deleteCustomEffect(entry.file, actionName: L("Delete Effect"))
    }

    /// The catalog entry of an effect made here.
    static func entry(_ effect: CustomEffect) -> EffectCatalogEntry {
        let passes = effect.files[effect.file].flatMap { text in
            (try? TolerantJSON.object(from: Data(text.utf8)) as? [String: Any])?["passes"] as? [Any]
        }?.count ?? 1
        var entry = EffectCatalogEntry(file: effect.file, title: effect.name, group: CustomEffect.group,
                                       groupTitle: CustomEffect.group, passCount: max(passes, 1))
        entry.isEditable = true
        entry.isMadeHere = true
        return entry
    }

    /// Whether `name` gives a folder name no effect of `entries` (WE's, the wallpaper's, the
    /// edits') has: WE asks for "a unique name".
    static func isAvailable(_ name: String, among entries: [EffectCatalogEntry]) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let id = CustomEffect.identifier(for: trimmed)
        return !entries.contains { $0.folderName == id }
    }
}
