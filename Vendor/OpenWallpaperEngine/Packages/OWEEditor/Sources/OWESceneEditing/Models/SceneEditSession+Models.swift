import Foundation

extension SceneEditSession {
    /// The layers drawing `model` (their `model` field as the scene now has it).
    public func layers(drawing model: String) -> [Int] {
        outline.layers.filter { value("model", of: $0.id)?.stringValue == model }.map(\.id)
    }

    /// Points every layer drawing `old` at `new` (the Model Editor's recompiled model), one undo
    /// step; a layer bound to a user property is left alone.
    public func replaceModel(_ old: String, with new: String, actionName: String) {
        let ids = layers(drawing: old).filter { isEditable("model", of: $0) }
        guard !ids.isEmpty, old != new else { return }
        edit(actionName: actionName) { overlay in
            for id in ids {
                let authored = SceneFieldBinding.literal(of: baseOutline.layer(id)?.fields["model"])
                overlay.setField("model", to: authored == .string(new) ? nil : .string(new), of: id)
            }
        }
    }
}
