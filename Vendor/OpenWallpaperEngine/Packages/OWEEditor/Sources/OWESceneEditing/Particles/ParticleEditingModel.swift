import Combine
import Foundation
import WEFormat

/// The particle editor's model over one editor session: the scene's particle systems and their
/// definitions as the editor shows them (the overlay's documents, else the wallpaper's or WE's
/// files), and every change of them, each one undo step of the session (`SceneEditSession.edit`).
///
/// A definition edit changes only the document (`SceneParticleOverlay.assets`): the running
/// wallpaper builds again only the systems that read it (`SceneEditOverlay.LiveChange`). Adding,
/// duplicating and deleting a system changes the scene's objects.
@MainActor
public final class ParticleEditingModel: ObservableObject {
    public typealias Section = ParticleEditorSchema.Section

    public let session: SceneEditSession
    public let schema: ParticleEditorSchema
    /// A file of the wallpaper, else of WE's assets, by its path (`particles/rain.json`).
    private let readAsset: (String) -> Data?
    private var authored: [String: SceneJSONValue?] = [:]
    private var sessionChanges: AnyCancellable?

    /// A control point dragged on the canvas, drawn there until the drag ends and commits it.
    public struct ControlPointPreview: Equatable, Sendable {
        public var layer: Int
        public var index: Int
        public var offset: SIMD3<Double>

        public init(layer: Int, index: Int, offset: SIMD3<Double>) {
            self.layer = layer
            self.index = index
            self.offset = offset
        }
    }

    @Published public var controlPointPreview: ControlPointPreview?
    /// The canvas shows the selected system's control points.
    @Published public var showsControlPoints = true

    public init(session: SceneEditSession, schema: ParticleEditorSchema, readAsset: @escaping (String) -> Data?) {
        self.session = session
        self.schema = schema
        self.readAsset = readAsset
        // The panel reads the session's overlay: it follows its changes, undo included.
        sessionChanges = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// A 2D (orthographic) scene, whose particle values are in pixels; WE's editor writes other
    /// defaults in a 3D one (`add_default_3d`).
    public var pixelUnits: Bool { session.outline.size != nil }

    // MARK: Reading

    /// The particle file the layer draws.
    public func particlePath(of layerID: Int) -> String? {
        session.value("particle", of: layerID)?.stringValue
    }

    /// The document at `path` as the scene now reads it: the editor's, else the wallpaper's or WE's.
    public func document(_ path: String) -> SceneJSONValue? {
        if let edited = session.overlay.particles?.assets[path] { return edited }
        return authoredDocument(path)
    }

    /// The document as the wallpaper (or WE) ships it; nil when there's none or it isn't JSON.
    public func authoredDocument(_ path: String) -> SceneJSONValue? {
        if let cached = authored[path] { return cached }
        // Optional: a file that isn't JSON is no document the editor can show (the scene's build
        // logs it when it reads it).
        let value = readAsset(path).flatMap { data in
            (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])).flatMap { SceneJSONValue(any: $0) }
        }
        authored[path] = value
        return value
    }

    public func definition(_ path: String) -> ParticleDefinition? {
        document(path).flatMap(ParticleDefinition.init(json:))
    }

    public func material(ofDefinition path: String) -> ParticleMaterial? {
        definition(path)?.materialPath.flatMap(document).flatMap(ParticleMaterial.init(json:))
    }

    /// The editor changed or wrote the document.
    public func isEdited(_ path: String) -> Bool {
        session.overlay.particles?.assets[path] != nil
    }

    /// The layer's `instanceoverride` (alpha, rate, speed, size, count, lifetime, colorn).
    public func instanceOverride(of layerID: Int) -> [String: SceneJSONValue] {
        if case .object(let values)? = session.value("instanceoverride", of: layerID) { return values }
        return [:]
    }

    // MARK: Definitions

    /// Changes the definition at `path` as one undo step. A definition changed back to what the
    /// wallpaper ships is no longer kept.
    public func editDefinition(_ path: String, actionName: String, coalescingKey: String? = nil,
                               _ change: (inout ParticleDefinition) -> Void) {
        guard var definition = definition(path) else { return }
        change(&definition)
        let json = definition.json
        let unchanged = authoredDocument(path) == json
        session.edit(actionName: actionName, coalescingKey: coalescingKey) { overlay in
            overlay.updateParticles { $0.assets[path] = unchanged ? nil : json }
        }
    }

    /// Sets a field of the system (`index` nil) or of an item of `section`.
    public func setField(_ field: ParticleEditorSchema.Field, to value: SceneJSONValue?, section: Section,
                         index: Int?, definition path: String, actionName: String, coalescing: Bool = false) {
        let key = coalescing ? "particle:\(path):\(section.rawValue):\(index ?? -1):\(field.id)" : nil
        editDefinition(path, actionName: actionName, coalescingKey: key) { definition in
            if let index {
                definition.updateItem(section, at: index) { ParticleDefinition.set(value, for: field, in: &$0) }
            } else {
                var root = definition.root
                ParticleDefinition.set(value, for: field, in: &root)
                definition = ParticleDefinition(root: root)
            }
        }
    }

    /// Adds `component` to its list with WE's add values; returns its index.
    @discardableResult
    public func addComponent(_ component: ParticleEditorSchema.Component, to path: String, actionName: String) -> Int? {
        var added: Int?
        editDefinition(path, actionName: actionName) { definition in
            added = definition.add(component, pixelUnits: pixelUnits)
        }
        return added
    }

    public func removeComponent(_ section: Section, at index: Int, from path: String, actionName: String) {
        editDefinition(path, actionName: actionName) { $0.remove(section, at: index) }
    }

    public func moveComponent(_ section: Section, from source: Int, to destination: Int, in path: String,
                              actionName: String) {
        editDefinition(path, actionName: actionName) { $0.move(section, from: source, to: destination) }
    }

    /// Adds a child system: a new definition from WE's template, and the entry naming it.
    /// Returns the child's path.
    @discardableResult
    public func addChild(to path: String, actionName: String) -> String? {
        guard var definition = definition(path), let component = schema.component(.children) else { return nil }
        let childPath = uniquePath("particles/editor/\(Self.baseName(path))_child.json")
        guard let index = definition.add(component, pixelUnits: pixelUnits) else { return nil }
        definition.updateItem(.children, at: index) { $0["name"] = .string(childPath) }
        let child = templateDefinition().json, parent = definition.json
        session.edit(actionName: actionName) { overlay in
            overlay.updateParticles { particles in
                particles.assets[childPath] = child
                particles.assets[path] = parent
            }
        }
        return childPath
    }

    /// Moves control point `index` of the definition to `offset`, adding the points before it
    /// that the definition doesn't list yet.
    public func setControlPointOffset(_ offset: SIMD3<Double>, index: Int, definition path: String, actionName: String) {
        guard index >= 0, index < ParticleDefinition.capacity(of: .controlpoint),
              let component = schema.component(.controlpoint) else { return }
        editDefinition(path, actionName: actionName) { definition in
            while definition.items(.controlpoint).count <= index {
                guard definition.add(component, pixelUnits: pixelUnits) != nil else { return }
            }
            definition.updateItem(.controlpoint, at: index) {
                $0["offset"] = SceneVector.value([offset.x, offset.y, offset.z])
            }
        }
    }

    // MARK: Material

    /// Changes the material the definition draws with. A material the editor didn't write (the
    /// wallpaper's or WE's, which other systems may share) is copied for the definition first,
    /// as WE's editor copies an asset into the project to change it.
    public func editMaterial(ofDefinition path: String, actionName: String, coalescingKey: String? = nil,
                             _ change: (inout ParticleMaterial) -> Void) {
        guard var definition = definition(path), let materialPath = definition.materialPath,
              var material = document(materialPath).flatMap(ParticleMaterial.init(json:)) else { return }
        change(&material)
        var target = materialPath
        if !isEdited(materialPath) {
            target = uniquePath("materials/editor/\(Self.baseName(path)).json")
            definition.materialPath = target
        }
        let materialJSON = material.json, definitionJSON = definition.json, forked = target != materialPath
        session.edit(actionName: actionName, coalescingKey: coalescingKey) { overlay in
            overlay.updateParticles { particles in
                particles.assets[target] = materialJSON
                if forked { particles.assets[path] = definitionJSON }
            }
        }
    }

    // MARK: Systems

    /// Adds a particle system from WE's new-system template, centred on a 2D scene; returns its
    /// layer's id, which becomes the selection.
    @discardableResult
    public func addBlankSystem(name: String, actionName: String) -> Int {
        addSystem(definition: templateDefinition(), name: name, actionName: actionName)
    }

    /// Adds a new system from one of WE's default systems (`particles/examplecursorfollow.json`),
    /// as WE's editor creates one: a copy of the file the new system draws, centred on a 2D scene.
    /// Returns its layer's id; nil when the file can't be read.
    @discardableResult
    public func addSystem(from source: String, name: String, actionName: String) -> Int? {
        guard let definition = authoredDocument(source).flatMap(ParticleDefinition.init(json:)) else { return nil }
        return addSystem(definition: definition, name: name, actionName: actionName)
    }

    private func addSystem(definition template: ParticleDefinition, name: String, actionName: String) -> Int {
        let path = uniquePath("particles/editor/particle_system.json")
        let id = session.nextObjectID
        let object = Self.object(id: id, name: name, particle: path, origin: sceneCentre)
        let definition = template.json
        session.edit(actionName: actionName) { overlay in
            overlay.updateParticles { particles in
                particles.assets[path] = definition
                particles.addedObjects.append(object)
            }
        }
        session.selection = id
        return id
    }

    /// Adds a preset's variant as WE's editor does: its files copied into the wallpaper (under a
    /// new name when the wallpaper already has the file) and its systems added, centred on a 2D
    /// scene. Returns the first new layer's id; nil when its files can't be read.
    @discardableResult
    public func addPreset(_ preset: ParticlePreset, variant: ParticlePreset.Variant, actionName: String) -> Int? {
        var documents: [String: SceneJSONValue] = [:]
        var renamed: [String: String] = [:]
        for dependency in variant.dependencies where dependency.lowercased().hasSuffix(".json") {
            let url = preset.directory.appending(path: dependency)
            // A preset may list a file it doesn't ship; a system that needs one isn't added (below).
            guard let data = try? Data(contentsOf: url),
                  let object = try? TolerantJSON.object(from: data),
                  let json = SceneJSONValue(any: object) else { continue }
            let path = uniquePath(dependency, besides: Set(documents.keys))
            renamed[dependency] = path
            documents[path] = json
        }
        let readable = variant.objects.allSatisfy { object in
            guard let particle = object["particle"]?.stringValue else { return false }
            return renamed[particle] != nil || document(particle) != nil
        }
        guard readable else { return nil }
        // The copies name each other by their new names.
        for (path, json) in documents {
            guard var definition = ParticleDefinition(json: json), json["emitter"] != nil || json["material"] != nil else { continue }
            if let material = definition.materialPath, let new = renamed[material] { definition.materialPath = new }
            for index in definition.items(.children).indices {
                definition.updateItem(.children, at: index) { item in
                    if let name = item["name"]?.stringValue, let new = renamed[name] { item["name"] = .string(new) }
                }
            }
            documents[path] = definition.json
        }
        var id = session.nextObjectID
        let first = id
        let centre = sceneCentre
        var objects: [SceneJSONValue] = []
        for authored in variant.objects {
            guard case .object(var fields) = authored, let particle = fields["particle"]?.stringValue else { continue }
            fields["id"] = .number(Double(id))
            fields["particle"] = .string(renamed[particle] ?? particle)
            let origin = SceneVector.components(fields["origin"], fallback: [0, 0, 0])
            fields["origin"] = SceneVector.value([origin[0] + centre[0], origin[1] + centre[1], origin[2] + centre[2]])
            if fields["name"] == nil { fields["name"] = .string(variant.title) }
            objects.append(.object(fields))
            id += 1
        }
        session.edit(actionName: actionName) { overlay in
            overlay.updateParticles { particles in
                particles.assets.merge(documents) { _, new in new }
                particles.addedObjects += objects
            }
        }
        session.selection = first
        return first
    }

    /// A copy of the particle layer, its edits included, drawing the same definition, as WE's
    /// Duplicate does; returns the copy's id.
    @discardableResult
    public func duplicateSystem(_ layerID: Int, name: String, actionName: String) -> Int? {
        guard let layer = session.outline.layer(layerID), layer.kind == .particle else { return nil }
        var fields = layer.fields
        for (field, value) in session.overlay.objects[String(layerID)]?.fields ?? [:] {
            fields[field] = Self.merged(fields[field], with: value)
        }
        let id = session.nextObjectID
        fields["id"] = .number(Double(id))
        fields["name"] = .string(name)
        let object = SceneJSONValue.object(fields)
        session.edit(actionName: actionName) { overlay in
            overlay.updateParticles { $0.addedObjects.append(object) }
        }
        session.selection = id
        return id
    }

    /// Deletes the particle layer: an added one is dropped, an authored one left out of the
    /// scene; its edits go with it. Undoable.
    public func deleteSystem(_ layerID: Int, actionName: String) {
        guard let layer = session.outline.layer(layerID), layer.kind == .particle else { return }
        session.edit(actionName: actionName) { overlay in
            overlay.updateParticles { particles in
                if let index = particles.addedObjects.firstIndex(where: { $0["id"]?.doubleValue == Double(layerID) }) {
                    particles.addedObjects.remove(at: index)
                } else {
                    particles.removedObjects.append(layerID)
                }
            }
            overlay.objects[String(layerID)] = nil
        }
    }

    /// Sets one value of the layer's `instanceoverride`; a value a user property sets isn't
    /// changed, an animated one gets a new starting value.
    public func setInstanceOverride(_ key: String, to value: SceneJSONValue?, of layerID: Int, actionName: String,
                                    coalescing: Bool = false) {
        var values = instanceOverride(of: layerID)
        if case .userProperty = SceneFieldBinding(values[key]) { return }
        if let value { values[key] = Self.merged(values[key], with: value) } else { values[key] = nil }
        session.setValue(values.isEmpty ? nil : .object(values), for: "instanceoverride", of: layerID,
                         actionName: actionName, coalescing: coalescing)
    }

    // MARK: Helpers

    /// WE's template for a new system: its `particles/example.json` (`example3d.json` in a 3D
    /// scene), else the same values built in.
    public func templateDefinition() -> ParticleDefinition {
        let path = pixelUnits ? "particles/example.json" : "particles/example3d.json"
        return authoredDocument(path).flatMap(ParticleDefinition.init(json:)) ?? .template
    }

    /// `desired`, else `name_2.json`, `name_3.json`… whichever neither the overlay, the wallpaper
    /// nor WE's assets have.
    public func uniquePath(_ desired: String, besides taken: Set<String> = []) -> String {
        func exists(_ path: String) -> Bool {
            taken.contains(path) || session.overlay.particles?.assets[path] != nil || readAsset(path) != nil
        }
        guard exists(desired) else { return desired }
        let base = (desired as NSString).deletingPathExtension, ext = (desired as NSString).pathExtension
        var number = 2
        while true {
            let candidate = "\(base)_\(number)" + (ext.isEmpty ? "" : ".\(ext)")
            if !exists(candidate) { return candidate }
            number += 1
        }
    }

    /// The file's name without folder or extension (`rain` for `particles/presets/rain.json`).
    static func baseName(_ path: String) -> String {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return name.isEmpty ? "particle" : name
    }

    /// The middle of a 2D scene; the origin of a 3D one.
    private var sceneCentre: [Double] {
        guard let size = session.outline.size else { return [0, 0, 0] }
        return [(size.x / 2).rounded(), (size.y / 2).rounded(), 0]
    }

    static func object(id: Int, name: String, particle: String, origin: [Double]) -> SceneJSONValue {
        .object([
            "id": .number(Double(id)), "name": .string(name), "particle": .string(particle),
            "origin": SceneVector.value(origin), "scale": .string("1 1 1"), "angles": .string("0 0 0"),
            "visible": .bool(true),
        ])
    }

    /// An edit of a field a script, animation or user property drives sets its starting value
    /// (as the overlay applies field edits).
    static func merged(_ existing: SceneJSONValue?, with value: SceneJSONValue) -> SceneJSONValue {
        guard case .object(var fields)? = existing,
              fields["script"] != nil || fields["animation"] != nil || fields["value"] != nil || fields["user"] != nil else {
            return value
        }
        fields["value"] = value
        return .object(fields)
    }
}
