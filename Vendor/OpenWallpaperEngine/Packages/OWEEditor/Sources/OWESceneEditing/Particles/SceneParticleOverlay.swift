import Foundation

/// The particle editor's part of the overlay (`SceneEditOverlay.particles`): the particle systems
/// it added to the scene or deleted from it, and the JSON documents it wrote (particle definitions
/// and their materials), all kept beside the wallpaper like every other edit. The scene loader
/// applies the objects with the rest of the overlay and reads the documents in place of the
/// wallpaper's (and WE's) files; Save as New Wallpaper writes them into the copy.
public struct SceneParticleOverlay: Codable, Hashable, Sendable {
    /// JSON documents by their path in the wallpaper (`particles/rain.json`,
    /// `materials/presets/rain.json`): definitions edited or added and the materials they use.
    public var assets: [String: SceneJSONValue] = [:]
    /// Scene objects the editor added (particle systems, each with its own `id`), drawn after the
    /// scene's own in this order.
    public var addedObjects: [SceneJSONValue] = []
    /// The scene's objects the editor deleted, by id (index without one), sorted.
    public var removedObjects: [Int] = []

    public init(assets: [String: SceneJSONValue] = [:], addedObjects: [SceneJSONValue] = [],
                removedObjects: [Int] = []) {
        self.assets = assets
        self.addedObjects = addedObjects
        self.removedObjects = removedObjects
    }

    public var isEmpty: Bool { assets.isEmpty && addedObjects.isEmpty && removedObjects.isEmpty }

    /// Changes the scene's objects, not only documents it reads.
    public var changesObjects: Bool { !addedObjects.isEmpty || !removedObjects.isEmpty }

    /// The added objects as `JSONSerialization` holds them.
    var addedObjectDictionaries: [[String: Any]] {
        addedObjects.compactMap { $0.any as? [String: Any] }
    }

    /// Leaves out the deleted objects. Run after the field edits, which name an object without an
    /// id by its index in the authored list.
    func removeDeleted(from objects: inout [[String: Any]]) {
        guard !removedObjects.isEmpty else { return }
        let removed = Set(removedObjects)
        objects = objects.enumerated().filter { index, object in
            !removed.contains(SceneObjects.objectID(object, index: index))
        }.map(\.element)
    }

    /// The documents as files, as the editor writes WE's JSON (`ParticleDefinition.encode`).
    public func assetFiles() throws -> [String: Data] {
        var files: [String: Data] = [:]
        for (path, document) in assets { files[path] = try ParticleDefinition.encode(document) }
        return files
    }

    /// The documents as the scene loader reads files, as compact JSON.
    public func assetData() -> [String: Data] {
        var files: [String: Data] = [:]
        for (path, document) in assets {
            // Values read from JSON always write back as JSON.
            if let data = try? JSONSerialization.data(withJSONObject: document.any, options: [.fragmentsAllowed]) {
                files[path] = data
            }
        }
        return files
    }
}

extension SceneEditOverlay {
    /// What saving the overlay changed for the wallpaper that runs it.
    public enum LiveChange: Equatable, Sendable {
        /// The scene itself: it is read again.
        case scene
        /// Only documents the particle systems read (definitions, materials): only the systems
        /// that read them are built again; the rest of the scene keeps running.
        case particleAssets(Set<String>)
    }

    /// How the overlay differs from `previous` for a running wallpaper.
    public func liveChange(from previous: SceneEditOverlay) -> LiveChange {
        var withoutAssets = self, previousWithoutAssets = previous
        withoutAssets.setParticleAssets([:])
        previousWithoutAssets.setParticleAssets([:])
        guard withoutAssets == previousWithoutAssets else { return .scene }
        let now = particles?.assets ?? [:], before = previous.particles?.assets ?? [:]
        let paths = Set(now.keys).union(before.keys).filter { now[$0] != before[$0] }
        return .particleAssets(paths)
    }

    /// The particle overlay, nil when it holds nothing (an overlay without particle edits is
    /// written, and digested, as it was before the particle editor).
    mutating func setParticleAssets(_ assets: [String: SceneJSONValue]) {
        var particles = self.particles ?? SceneParticleOverlay()
        particles.assets = assets
        self.particles = particles.isEmpty ? nil : particles
    }

    /// Changes the particle overlay; an empty one is dropped.
    public mutating func updateParticles(_ change: (inout SceneParticleOverlay) -> Void) {
        var particles = self.particles ?? SceneParticleOverlay()
        change(&particles)
        particles.removedObjects = Array(Set(particles.removedObjects)).sorted()
        self.particles = particles.isEmpty ? nil : particles
    }
}

extension SceneOutline {
    /// The outline with the particle editor's objects: the deleted ones left out, the added ones
    /// after the scene's own.
    public func applying(_ particles: SceneParticleOverlay?) -> SceneOutline {
        guard let particles, particles.changesObjects else { return self }
        let removed = Set(particles.removedObjects)
        var layers = self.layers.filter { !removed.contains($0.id) }
        let added = EditorLog.attempt("Particle editor: added objects", {
            try SceneOutline(root: ["objects": particles.addedObjectDictionaries])
        })?.layers ?? []
        let base = self.layers.count
        for (offset, layer) in added.enumerated() where !removed.contains(layer.id) {
            layers.append(SceneLayer(id: layer.id, index: base + offset, name: layer.name, kind: layer.kind,
                                     parentID: layer.parentID, fields: layer.fields, effects: layer.effects))
        }
        return SceneOutline(layers: layers, size: size, general: general)
    }

    /// An id no layer of the scene has, authored, added or deleted.
    public func nextObjectID(besides particles: SceneParticleOverlay?) -> Int {
        var ids = Set(layers.map(\.id))
        ids.formUnion(particles?.removedObjects ?? [])
        for object in particles?.addedObjects ?? [] {
            if let id = object["id"]?.doubleValue { ids.insert(Int(id)) }
        }
        return (ids.max() ?? -1) + 1
    }
}
