import Foundation

/// The editor's authoring of a wallpaper, kept in its overlay (`SceneEditOverlay.authoring`) like
/// every other edit: scripts attached to fields and user-property bindings (applied to scene.json
/// wherever the wallpaper loads), and the user properties themselves (written into project.json
/// when the wallpaper is saved as a local wallpaper).
public struct SceneAuthoring: Codable, Hashable, Sendable {
    /// Field driver edits by object key (the overlay's: its id, else its index) and field path.
    public var drivers: [String: [String: SceneFieldDriverEdit]]
    /// project.json's `general.properties` as edited, in order; nil leaves them as authored.
    public var properties: [UserPropertyDraft]?

    public init(drivers: [String: [String: SceneFieldDriverEdit]] = [:], properties: [UserPropertyDraft]? = nil) {
        self.drivers = drivers
        self.properties = properties
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        drivers = try container.decodeIfPresent([String: [String: SceneFieldDriverEdit]].self, forKey: .drivers) ?? [:]
        properties = try container.decodeIfPresent([UserPropertyDraft].self, forKey: .properties)
    }

    public var isEmpty: Bool {
        properties == nil && drivers.values.allSatisfy { $0.values.allSatisfy(\.isEmpty) }
    }

    /// Whether anything changes scene.json (the properties change project.json only).
    public var changesScene: Bool {
        drivers.values.contains { $0.values.contains { !$0.isEmpty } }
    }

    // MARK: Drivers

    public func driverEdit(_ path: SceneFieldPath, of objectID: Int) -> SceneFieldDriverEdit? {
        drivers[String(objectID)]?[path.description]
    }

    /// Sets the field's driver edit; an empty one drops it.
    public mutating func setDriverEdit(_ edit: SceneFieldDriverEdit?, _ path: SceneFieldPath, of objectID: Int) {
        let key = String(objectID)
        var fields = drivers[key] ?? [:]
        fields[path.description] = edit?.isEmpty == false ? edit : nil
        drivers[key] = fields.isEmpty ? nil : fields
    }

    /// Applies the driver edits to a decoded scene.json, before the overlay's value edits. An
    /// object or effect the scene no longer has is skipped.
    public func applyDrivers(to root: inout [String: Any]) {
        guard changesScene, var objects = root["objects"] as? [[String: Any]] else { return }
        for index in objects.indices {
            let objectID = SceneObjects.objectID(objects[index], index: index)
            guard let fields = drivers[String(objectID)] else { continue }
            for (pathText, edit) in fields.sorted(by: { $0.key < $1.key }) where !edit.isEmpty {
                let path = SceneFieldPath(pathText)
                if let effect = path.effectIndex {
                    guard let effects = objects[index]["effects"] as? [Any], effects.indices.contains(effect) else { continue }
                }
                let authored = path.value(in: objects[index]).flatMap { SceneJSONValue(any: $0) }
                path.set(edit.applied(to: authored)?.any, in: &objects[index])
            }
        }
        root["objects"] = objects
    }

    // MARK: Properties

    /// Writes the edited properties into a decoded project.json (`general.properties`); keeps it
    /// as it was when they weren't edited. WE numbers them as its editor's property list does
    /// (`editorUserProperties` sets `index` to each one's place, scheme colour left out, and the
    /// editor writes `order` 100 + `index`; WE 2.8.0.42, capture 541): the scheme colour keeps
    /// `order` 0 and no `index`.
    public func applyProperties(to project: inout [String: Any]) {
        guard let properties else { return }
        var general = project["general"] as? [String: Any] ?? [:]
        var entries: [String: Any] = [:]
        var index = 0
        for property in properties {
            var entry: [String: SceneJSONValue]
            if property.key == "schemecolor" {
                entry = property.json(order: 0)
                entry["index"] = nil
            } else {
                entry = property.json(order: 100 + index)
                entry["index"] = .number(Double(index))
                index += 1
            }
            entries[property.key] = SceneJSONValue.object(entry).any
        }
        general["properties"] = entries
        project["general"] = general
    }

    /// project.json with the edited properties; `data` itself when they weren't edited.
    public func appliedProject(to data: Data) throws -> Data {
        guard properties != nil else { return data }
        guard var project = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SceneEditOverlayError.notAScene
        }
        applyProperties(to: &project)
        return try JSONSerialization.data(withJSONObject: project, options: [.prettyPrinted, .sortedKeys])
    }
}
