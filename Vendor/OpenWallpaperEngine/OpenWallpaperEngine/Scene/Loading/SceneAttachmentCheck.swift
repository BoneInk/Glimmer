import Foundation

/// Logs, once per content, every object whose `attachment` its parent can't resolve
/// (docs/models-plan.md §2.6, §5.15): the parent has no rig (a model's or a puppet's `.mdl`
/// attachment points, `MDAT`), or none of that exact name. Such an object hangs from its parent as
/// if it named none (`SceneAttachmentProviding` answers nil), which is what the renderer does; this
/// only says so, once, instead of silently.
enum SceneAttachmentCheck {
    /// `objects` are the scene's; `models` the built model objects (with their plans) and
    /// `layers` the built layers (a puppet's plan carries its rig's attachments), by object id.
    static func logUnresolved(in objects: [WESceneObject], models: [SceneModelObject], layers: [SceneMetalLayer],
                              wallpaperName: String) {
        var points: [String: [MDLAttachment]] = [:]
        for model in models { if let plan = model.plan { points[model.id] = plan.attachments } }
        for layer in layers { if let puppet = layer.puppet { points[layer.id] = puppet.attachments } }
        for (index, object) in objects.enumerated() {
            guard let name = object.attachment ?? object.model?.attachment, !name.isEmpty else { continue }
            let id = object.id.map(String.init) ?? String(index)
            guard let parent = object.parent.map(String.init) else {
                OWELog.error(.scene, "\(wallpaperName): object \(id) \(object.name ?? "") names attachment \"\(name)\" "
                             + "but has no parent; it isn't attached")
                continue
            }
            guard let attachments = points[parent] else {
                OWELog.error(.scene, "\(wallpaperName): object \(id) \(object.name ?? "") names attachment \"\(name)\" "
                             + "of object \(parent), which has no rig that draws; it hangs from its parent")
                continue
            }
            if !attachments.contains(where: { $0.name == name }) {
                OWELog.error(.scene, "\(wallpaperName): object \(id) \(object.name ?? "") names attachment \"\(name)\", "
                             + "which object \(parent)'s rig doesn't have (\(attachments.map(\.name))); it hangs from its parent")
            }
        }
    }
}
