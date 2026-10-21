import Foundation
import OWEModelImport
import OWESceneEditing

/// The Model Editor's state for one imported model (WE's Configure Model,
/// docs/model-import.md): its configuration as edited, what compiling it gives (animations,
/// clips, bones, materials), and the materials as edited. OK compiles the model again and points
/// every layer drawing it at the new `.mdl`, one undo step.
@MainActor
final class ModelEditorModel: ObservableObject {
    let store: EditorAssetStore
    let readFile: (String) -> Data?
    private(set) var model: String

    @Published var config: ModelImportConfig
    @Published private(set) var output: ModelCompiler.Output?
    @Published var problem: String?
    /// Materials changed in the Materials tab, by source material name.
    @Published var materials: [String: MaterialPassDocument] = [:]
    private let savedConfig: ModelImportConfig

    init(model: String, store: EditorAssetStore, readFile: @escaping (String) -> Data?) {
        self.model = model
        self.store = store
        self.readFile = readFile
        let config = store.modelConfig(for: model) ?? ModelImportConfig()
        self.config = config
        savedConfig = config
        refresh()
    }

    var hasChanges: Bool { config != savedConfig || !materials.isEmpty }

    /// Compiles with the configuration as edited, for the lists (nothing is written).
    func refresh() {
        do {
            output = try EditorModelImporter.inspect(model, config: config, in: store)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: Lists

    var animations: [ModelCompiler.AnimationInfo] { output?.animations.filter { !$0.isClip } ?? [] }
    var clips: [ModelCompiler.AnimationInfo] { output?.animations.filter(\.isClip) ?? [] }
    var bones: [String] { output?.bones ?? [] }
    /// Bones alphabetically, as WE's dropdowns list them.
    var sortedBones: [String] { bones.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }
    var materialNames: [String] { output?.meshMaterials ?? [] }

    func animation(_ id: UInt64) -> ModelCompiler.AnimationInfo? { output?.animations.first { $0.id == id } }

    // MARK: Clips

    /// Add Clip: a clip of the whole animation as WE's makes one (capture 546): named
    /// "<animation> (Clip 0)", counting the animation's clips from 0, Match loop on and root
    /// motion's x, z and yaw flags set.
    @discardableResult
    func addClip(from animation: UInt64) -> UInt64 {
        let id = config.nextID(after: output?.animations.count ?? 0)
        let source = self.animation(animation)
        let number = config.clips.filter { $0.animation == animation }.count
        config.clips.append(ModelImportConfig.Clip(id: id, name: "\(source?.name ?? "") (\(ML("Clip \(number)")))", animation: animation,
                                                   start: 0, end: source?.frames ?? 1,
                                                   motionFlags: ModelImportConfig.Clip.defaultMotionFlags))
        refresh()
        return id
    }

    func removeClip(_ id: UInt64) {
        config.clips.removeAll { $0.id == id }
        config.events.removeAll { $0.animation == id }
        refresh()
    }

    func updateClip(_ id: UInt64, _ change: (inout ModelImportConfig.Clip) -> Void) {
        guard let index = config.clips.firstIndex(where: { $0.id == id }) else { return }
        change(&config.clips[index])
        refresh()
    }

    // MARK: Events

    @discardableResult
    func addEvent(to animation: UInt64) -> UInt64 {
        let id = config.nextID(after: output?.animations.count ?? 0)
        let number = config.events.filter { $0.animation == animation }.count + 1
        config.events.append(ModelImportConfig.Event(id: id, name: ML("Event \(number)"), frame: 0, animation: animation))
        refresh()
        return id
    }

    func removeEvent(_ id: UInt64) {
        config.events.removeAll { $0.id == id }
        refresh()
    }

    func updateEvent(_ id: UInt64, _ change: (inout ModelImportConfig.Event) -> Void) {
        guard let index = config.events.firstIndex(where: { $0.id == id }) else { return }
        change(&config.events[index])
        refresh()
    }

    // MARK: Attachments

    @discardableResult
    func addAttachment() -> UInt64 {
        let id = config.nextID(after: output?.animations.count ?? 0)
        config.attachments.append(ModelImportConfig.Attachment(id: id, name: ML("Attachment \(config.attachments.count + 1)"),
                                                               bone: sortedBones.first ?? ""))
        refresh()
        return id
    }

    func removeAttachment(_ id: UInt64) {
        config.attachments.removeAll { $0.id == id }
        refresh()
    }

    func updateAttachment(_ id: UInt64, _ change: (inout ModelImportConfig.Attachment) -> Void) {
        guard let index = config.attachments.firstIndex(where: { $0.id == id }) else { return }
        change(&config.attachments[index])
        refresh()
    }

    // MARK: Animation files

    /// Add FBX File: another file's animations for the same skeleton.
    func addAnimationFile(_ url: URL) {
        do {
            config = try EditorModelImporter.addAnimationFile(url, to: model, config: config, in: store)
            refresh()
        } catch {
            problem = error.localizedDescription
        }
    }

    func removeAnimationFile(_ name: String) {
        config.additionalFiles.removeAll { $0 == name }
        refresh()
    }

    // MARK: Materials

    func materialPath(_ name: String) -> String { EditorAssetStore.materialPath(name, model: model, config: config) }

    /// The material as edited, else as its file has it.
    func material(_ name: String) -> MaterialPassDocument {
        if let edited = materials[name] { return edited }
        let path = materialPath(name)
        let data = store.url(for: path).flatMap { url in EditorLog.attempt("Model Editor: \(path)") { try Data(contentsOf: url) } } ?? readFile(path)
        return data.flatMap(MaterialPassDocument.init(json:))
            ?? MaterialPassDocument(root: ModelCompiler.materialJSON(texture: nil))
    }

    func updateMaterial(_ name: String, _ change: (inout MaterialPassDocument) -> Void) {
        var document = material(name)
        change(&document)
        materials[name] = document
    }

    func importTexture(_ url: URL, material: String, slot: Int) {
        do {
            let texture = try store.importModelTexture(from: url, material: material, slot: slot, model: model)
            updateMaterial(material) { $0.setTexture(slot, texture) }
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: Saving

    /// OK: the edited materials kept, the model compiled with the configuration, and every
    /// layer drawing the old model pointed at the new one. Returns the new model's path.
    @discardableResult
    func apply(to session: SceneEditSession) -> String? {
        do {
            for (name, document) in materials {
                config.materials[name] = try store.storeModelMaterial(document, material: name, model: model)
            }
            materials = [:]
            let compiled = try EditorModelImporter.recompile(model, config: config, in: store)
            session.replaceModel(model, with: compiled.model, actionName: ML("Configure Model"))
            model = compiled.model
            return compiled.model
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }
}
