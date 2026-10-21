import Foundation
import OWEControlProtocol
import OWESceneEditing

/// What one `scene_apply_edits` list runs on: a copy of the wallpaper's edit session, its
/// resources, and the editor's models over that session (the particle editor's, the timeline's,
/// the user-property authoring's), made when an edit first needs them.
@MainActor
final class SceneEditOperationContext {
    let session: SceneEditSession
    let resources: SceneEditResources
    let timelineIndex: TimelineSceneIndex
    private let particleSchema: () throws -> ParticleEditorSchema
    private var particleModel: ParticleEditingModel?
    private var timelineEditor: SceneTimelineEditor?
    private var propertyAuthoring: UserPropertyAuthoring?

    init(session: SceneEditSession, resources: SceneEditResources, timelineIndex: TimelineSceneIndex,
         particleSchema: @escaping () throws -> ParticleEditorSchema) {
        self.session = session
        self.resources = resources
        self.timelineIndex = timelineIndex
        self.particleSchema = particleSchema
    }

    /// The particle editor's model (`ParticleEditingModel`) over the session.
    func particles() throws -> ParticleEditingModel {
        if let particleModel { return particleModel }
        let schema: ParticleEditorSchema
        do {
            schema = try particleSchema()
        } catch {
            throw ControlError(.unavailable, "The particle editor's schema can't be read: \(error.localizedDescription)")
        }
        let model = ParticleEditingModel(session: session, schema: schema, readAsset: { [resources] in resources.readAsset($0) })
        particleModel = model
        return model
    }

    /// The timeline (`SceneTimelineEditor`) over the session.
    var timeline: SceneTimelineEditor {
        if let timelineEditor { return timelineEditor }
        let editor = SceneTimelineEditor(session: session, index: timelineIndex)
        timelineEditor = editor
        return editor
    }

    /// The wallpaper's user properties as the editor authors them.
    var properties: UserPropertyAuthoring {
        if let propertyAuthoring { return propertyAuthoring }
        let authoring = UserPropertyAuthoring(session: session, projectJSON: resources.projectJSON,
                                             readAsset: { [resources] in resources.readAsset($0) })
        propertyAuthoring = authoring
        return authoring
    }
}

/// `scene_apply_edits`' edit kinds (`docs/mcp.md`, "Scene edits"): each a call of the session
/// method the editor's control for it makes, with its parameters checked first so a client
/// learns what was wrong instead of an edit that silently does nothing.
@MainActor
enum SceneEditOperations {
    typealias Operation = @MainActor (ControlParameters, SceneEditOperationContext) throws -> JSONValue

    static var all: [String: Operation] {
        layerOperations.merging(effectOperations) { first, _ in first }
            .merging(particleOperations) { first, _ in first }
            .merging(puppetOperations) { first, _ in first }
            .merging(timelineOperations) { first, _ in first }
            .merging(authoringOperations) { first, _ in first }
    }

    static func apply(_ edit: ControlParameters, in context: SceneEditOperationContext) throws -> JSONValue {
        let name = try edit.required("op")
        guard let operation = all[name] else {
            throw ControlError(.invalidParams, "There is no edit \"\(name)\". The edits: \(all.keys.sorted().joined(separator: ", ")).")
        }
        let result = try operation(edit, context)
        guard case .object(var object) = result else { return ["op": .string(name)] }
        object["op"] = .string(name)
        return .object(object)
    }

    // MARK: Finding what an edit names

    /// The layer `key` names (its scene.json id).
    static func layer(_ edit: ControlParameters, _ context: SceneEditOperationContext, key: String = "layer") throws -> SceneLayer {
        let id = try edit.requiredInt(key)
        guard let layer = context.session.outline.layer(id) else {
            let ids = context.session.outline.layers.map { String($0.id) }.joined(separator: ", ")
            throw ControlError(.notFound, "No layer \(id). The layers' ids: \(ids). scene_get lists them.")
        }
        return layer
    }

    /// The layers `layers` names, every one of them there.
    static func layers(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> [Int] {
        let ids = try edit.ints("layers")
        guard !ids.isEmpty else { throw ControlError(.invalidParams, "layers is required: a list of layer ids.") }
        for id in ids where context.session.outline.layer(id) == nil {
            throw ControlError(.notFound, "No layer \(id). scene_get lists the layers.")
        }
        return ids
    }

    /// The layer's effect `effect` names: its key (`"0"`, `"+1"`, as scene_get lists them).
    static func effect(_ edit: ControlParameters, of layer: SceneLayer) throws -> SceneLayerEffect {
        let key = try edit.required("effect")
        guard let effect = layer.effects.first(where: { $0.key == key }) else {
            let keys = layer.effects.map { "\"\($0.key)\" (\($0.title))" }.joined(separator: ", ")
            throw ControlError(.notFound, "Layer \(layer.id) has no effect \"\(key)\". "
                               + (keys.isEmpty ? "It has none." : "Its effects: \(keys)."))
        }
        return effect
    }

    /// A field the editor may set: not one a user property sets, which `unbind_field` frees first.
    static func editableField(_ field: String, of layer: SceneLayer, _ context: SceneEditOperationContext) throws {
        if case .userProperty(let property) = context.session.binding(field, of: layer.id) {
            throw ControlError(.refused, "\(field) of layer \(layer.id) follows the user property \"\(property)\"; unbind_field it first.")
        }
    }
}
