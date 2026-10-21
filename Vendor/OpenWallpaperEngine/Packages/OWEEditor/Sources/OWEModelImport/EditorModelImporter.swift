import Foundation
import OWESceneEditing

/// Imports FBX and OBJ files into the edits' files as WE's importer does (Add Asset › Model, a
/// file dropped on the canvas): reads the file, writes its configuration with WE's defaults
/// (normals and tangents on), compiles the `.mdl` and keeps the source, its materials and their
/// textures (`EditorAssetStore.storeModel`). The Model Editor compiles a stored model again with
/// an edited configuration (`recompile`).
public enum EditorModelImporter {
    /// The file types the importer offers (`ModelFileLoader.fileExtensions`).
    public static var fileExtensions: Set<String> { ModelFileLoader.fileExtensions }

    public static func importModel(from url: URL, into store: EditorAssetStore,
                                   config: ModelImportConfig = ModelImportConfig()) throws -> ImportedModel {
        let source = try ModelFileLoader.load(contentsOf: url)
        guard let bytes = try? Data(contentsOf: url) else { throw EditorAssetStore.ImportError.unreadable(url.lastPathComponent) }
        let title = url.deletingPathExtension().lastPathComponent
        let folder = EditorAssetStore.modelFolder(title: title, source: bytes)
        let output = try ModelCompiler.compile(source, config: config, folder: folder)
        return try store.storeModel(output, sourceURL: url, companions: companions(of: url), config: config.completed(with: output),
                                    folder: folder, title: title)
    }

    /// Compiles a model the store holds again with `config` (the Model Editor's edits), with the
    /// additional files it names from the model's folder; returns the new model, named by the
    /// configuration's content.
    public static func recompile(_ model: String, config: ModelImportConfig, in store: EditorAssetStore) throws -> ImportedModel {
        guard let sourceURL = store.modelSource(for: model) else { throw EditorAssetStore.ImportError.unreadable(model) }
        let source = try ModelFileLoader.load(contentsOf: sourceURL)
        let folder = (model as NSString).deletingLastPathComponent.components(separatedBy: "/").last ?? ""
        let directory = sourceURL.deletingLastPathComponent()
        let additional = try config.additionalFiles.map { try ModelFileLoader.load(contentsOf: directory.appending(path: $0)) }
        let output = try ModelCompiler.compile(source, config: config, folder: folder, additional: additional)
        // Saved as the importer saves it (`skinning`, every animation's id), so the import's own
        // configuration compiles to the import's own model.
        let saved = config.completed(with: output)
        let revision = EditorAssetStore.contentHash(try saved.jsonData(), bytes: 4)
        let title = sourceURL.deletingPathExtension().lastPathComponent
        return try store.storeModel(output, sourceURL: sourceURL, config: saved, folder: folder, title: title,
                                    revision: saved == ModelImportConfig().completed(with: output) ? nil : revision)
    }

    /// Adds an animation file to a stored model (Model Editor › Add FBX File): it is copied
    /// beside the source, and its name is added to the configuration's `additionalfiles`.
    public static func addAnimationFile(_ url: URL, to model: String, config: ModelImportConfig,
                                        in store: EditorAssetStore) throws -> ModelImportConfig {
        guard let sourceURL = store.modelSource(for: model) else { throw EditorAssetStore.ImportError.unreadable(model) }
        _ = try ModelFileLoader.load(contentsOf: url)  // it must be a model file
        guard let data = try? Data(contentsOf: url) else { throw EditorAssetStore.ImportError.unreadable(url.lastPathComponent) }
        let folder = (model as NSString).deletingLastPathComponent
        let name = ModelCompiler.fileName(url.lastPathComponent)
        if !FileManager.default.fileExists(atPath: sourceURL.deletingLastPathComponent().appending(path: name).path) {
            try store.store(data, at: "\(folder)/\(name)")
        }
        var updated = config
        if !updated.additionalFiles.contains(name) { updated.additionalFiles.append(name) }
        return updated
    }

    /// The animations, clips and bones a stored model has after compiling with `config`
    /// (without writing anything), for the Model Editor's lists.
    public static func inspect(_ model: String, config: ModelImportConfig, in store: EditorAssetStore) throws -> ModelCompiler.Output {
        guard let sourceURL = store.modelSource(for: model) else { throw EditorAssetStore.ImportError.unreadable(model) }
        let source = try ModelFileLoader.load(contentsOf: sourceURL)
        let directory = sourceURL.deletingLastPathComponent()
        // An additional file that can't be loaded is left out of the compile, after a log line.
        let additional = config.additionalFiles.compactMap { file in
            EditorLog.attempt("Model import: additional file \(file)") { try ModelFileLoader.load(contentsOf: directory.appending(path: file)) }
        }
        let folder = (model as NSString).deletingLastPathComponent.components(separatedBy: "/").last ?? ""
        return try ModelCompiler.compile(source, config: config, folder: folder, additional: additional)
    }

    /// An OBJ's `.mtl` files (its `mtllib` lines and `<name>.mtl`), which the source needs again.
    static func companions(of url: URL) -> [URL] {
        guard url.pathExtension.lowercased() == "obj" else { return [] }
        var names = ModelFileLoader.materialLibraries(objAt: url)
        names.append(url.deletingPathExtension().lastPathComponent + ".mtl")
        return Set(names).map { url.deletingLastPathComponent().appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
