import Foundation

extension SceneEditOverlay {
    /// Whether any layer has a puppet made or edited in the editor.
    public var hasPuppetEdits: Bool { !(puppets?.isEmpty ?? true) }

    /// The layer's puppet as the editor last left it; nil when it has none here.
    public func puppet(of objectID: Int) -> PuppetDocument? {
        puppets?[String(objectID)]
    }

    /// Sets (nil: drops) the layer's puppet.
    public mutating func setPuppet(_ document: PuppetDocument?, of objectID: Int) {
        var all = puppets ?? [:]
        all[String(objectID)] = document
        puppets = all.isEmpty ? nil : all
    }
}

extension SceneEditSession {
    /// The layer's edited puppet; nil when the editor hasn't changed one.
    public func puppet(of layerID: Int) -> PuppetDocument? {
        overlay.puppet(of: layerID)
    }

    /// Stores the layer's puppet in the overlay as one undo step (`coalescing` merges a run of
    /// edits of one control). nil drops the editor's puppet: the layer is as authored again.
    public func setPuppet(_ document: PuppetDocument?, of layerID: Int, actionName: String, coalescing: Bool = false) {
        var next = overlay
        next.setPuppet(document, of: layerID)
        commit(next, actionName: actionName, coalescingKey: coalescing ? "\(layerID):puppet:\(actionName)" : nil)
    }
}
