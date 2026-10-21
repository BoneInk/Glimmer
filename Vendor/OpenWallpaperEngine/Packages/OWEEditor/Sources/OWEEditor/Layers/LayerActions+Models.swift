import Foundation
import OWEModelImport
import OWESceneEditing

extension LayerActions {
    /// Add Layer › Model's choices: the wallpaper's models, the ones imported into the edits'
    /// files, then WE's.
    func modelChoices() -> [EditorModelChoice] {
        let imported = importedModels()
        let others = services.models().filter { !imported.contains($0.path) }
        return others.filter { !$0.isShared } + imported.sorted().map { EditorModelChoice(path: $0, isShared: false) }
            + others.filter(\.isShared)
    }

    /// The `.mdl` files imported in the editor (`EditorAssetStore.importedModels`).
    func importedModels() -> Set<String> { Set(services.assetStore?.importedModels() ?? []) }

    /// Imports FBX and OBJ files as WE's Add Asset › Model does (their configuration, model,
    /// materials and textures into the edits' files) and adds a model layer for each, at the
    /// drop point in a 2D scene, else where a new model goes.
    func importModels(_ urls: [URL], at point: SIMD2<Double>? = nil) {
        guard let store = services.assetStore else { return }
        for url in urls {
            do {
                let imported = try EditorModelImporter.importModel(from: url, into: store)
                addModel(EditorModelChoice(path: imported.model, isShared: false), at: point)
                if !imported.missingTextures.isEmpty {
                    let file = url.lastPathComponent
                    let names = imported.missingTextures.map { ($0.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent }
                        .joined(separator: ", ")
                    tools.problem = L("“\(file)” names textures that weren’t found beside it: \(names).")
                }
            } catch {
                tools.problem = L("“\(url.lastPathComponent)” couldn’t be added: \(error.localizedDescription)")
            }
        }
    }

    func chooseModels() { importModels(EditorFilePicker.choose(.model, multiple: true)) }
}
