import Foundation

/// Selecting several layers: Shift- or ⌘-click adds or removes one, a marquee selects those it
/// touches, a click on layers stacked under the pointer can pick the next one down, and the
/// layer actions (move, nudge, delete, duplicate, copy and paste transforms) take them all.
extension SceneEditSession {
    /// The selected layers in the scene's order (drawn first first).
    public var selectedIDs: [Int] {
        let selected = selectedLayers.isEmpty ? Set(selection.map { [$0] } ?? []) : selectedLayers
        return outline.layers.map(\.id).filter(selected.contains)
    }

    public func isSelected(_ layerID: Int) -> Bool { selectedLayers.contains(layerID) || selection == layerID }

    /// Selects `layerID` alone, or adds it to (or, already there, takes it from) the selection
    /// when `extending` (Shift or ⌘). Nil without `extending` clears it.
    public func select(_ layerID: Int?, extending: Bool = false) {
        guard extending, let layerID else {
            selection = layerID
            selectedLayers = layerID.map { [$0] } ?? []
            return
        }
        var layers = selectedLayers
        if layers.isEmpty, let selection { layers.insert(selection) }
        // `selection` first: setting it alone selects only it, then the whole set.
        if layers.contains(layerID) {
            layers.remove(layerID)
            if selection == layerID { selection = outline.layers.map(\.id).last(where: layers.contains) }
        } else {
            layers.insert(layerID)
            selection = layerID
        }
        selectedLayers = layers
    }

    /// Selects exactly `layerIDs` (a marquee, the list); the inspector keeps the layer it shows
    /// when it is among them, else shows the topmost.
    public func select(_ layerIDs: Set<Int>, primary: Int? = nil) {
        let valid = layerIDs.filter { outline.layer($0) != nil }
        if let primary, valid.contains(primary) {
            selection = primary
        } else if let current = selection, valid.contains(current) {
            // The inspector keeps its layer.
        } else {
            selection = outline.layers.map(\.id).last(where: valid.contains)
        }
        selectedLayers = valid
    }

    /// `selection` changed alone: the selection is that layer only (none for nil).
    func keepSelectedLayers() {
        let only: Set<Int> = selection.map { [$0] } ?? []
        if selectedLayers != only { selectedLayers = only }
    }

    /// Drops layers that are gone from the selection.
    func pruneSelectedLayers() {
        let kept = selectedLayers.filter { outline.layer($0) != nil }
        if kept != selectedLayers { selectedLayers = kept }
    }

    // MARK: Picking

    /// Every visible, unlocked planar layer under `scenePoint`, topmost first: the stack a click
    /// at one place goes down through (Option-click picks the one under the selection).
    public func layers(at scenePoint: SIMD2<Double>) -> [Int] {
        outline.layers.reversed().compactMap { layer in
            guard isVisible(layer.id), !isLocked(layer.id), let geometry = geometry(of: layer.id),
                  geometry.contains(scenePoint) else { return nil }
            return layer.id
        }
    }

    /// The layer under `scenePoint` below `current` in the stack there, wrapping to the top: what
    /// clicking again through the selection picks. The topmost when `current` isn't there.
    public func layer(at scenePoint: SIMD2<Double>, below current: Int?) -> Int? {
        let stack = layers(at: scenePoint)
        guard let current, let index = stack.firstIndex(of: current) else { return stack.first }
        return stack[(index + 1) % stack.count]
    }

    /// The visible, unlocked planar layers whose rectangle meets `rect` (scene space), as a
    /// marquee selects them; group members as themselves.
    public func layers(in rect: SceneRect) -> [Int] {
        outline.layers.compactMap { layer in
            guard isVisible(layer.id), !isLocked(layer.id), let bounds = bounds(of: layer.id),
                  bounds.minimum.x <= rect.maximum.x, bounds.maximum.x >= rect.minimum.x,
                  bounds.minimum.y <= rect.maximum.y, bounds.maximum.y >= rect.minimum.y else { return nil }
            return layer.id
        }
    }

    /// The selection without the layers a selected group already carries (moving a group moves
    /// what's in it).
    public var selectedRoots: [Int] {
        let selected = Set(selectedIDs)
        return selectedIDs.filter { id in !outline.ancestors(of: id).contains { selected.contains($0.id) } }
    }

    // MARK: Editing several

    /// Sets several layers' transforms as one undo step (a drag of several, a nudge, Paste
    /// Transforms); `coalescing` merges a run of them (arrow keys) into one.
    public func setTransforms(_ transforms: [Int: LayerTransform], actionName: String, coalescing: Bool = false) {
        var next = overlay
        for (layerID, transform) in transforms.sorted(by: { $0.key < $1.key }) {
            let current = self.transform(of: layerID)
            func set(_ field: String, _ vector: SIMD3<Double>, _ was: SIMD3<Double>) {
                guard vector != was, isEditable(field, of: layerID) else { return }
                let value = SceneVector.value([vector.x, vector.y, vector.z])
                if let keyed = animatedFields?.overlay(setting: value, for: field, of: layerID, in: next) {
                    next = keyed
                    return
                }
                let authoredField = baseOutline.layer(layerID)?.fields[field]
                let authored = SceneFieldBinding.literal(of: authoredField) ?? Self.defaults[field]
                next.setField(field, to: Self.same(value, authored) ? nil : value, of: layerID)
            }
            set("origin", transform.origin, current.origin)
            set("scale", transform.scale, current.scale)
            set("angles", transform.angles, current.angles)
        }
        let key = transforms.keys.sorted().map(String.init).joined(separator: ",")
        commit(next, actionName: actionName, coalescingKey: coalescing ? "\(key):transforms" : nil)
    }

    /// Commits the drag of several layers shown in `groupDragPreview`.
    public func endGroupDrag(actionName: String) {
        let previews = groupDragPreview
        guard !previews.isEmpty else { return }
        groupDragPreview = [:]
        setTransforms(previews, actionName: actionName)
    }

    /// Each layer moved by `delta` in scene space, in its own parent's space.
    public func transforms(moving layerIDs: [Int], bySceneOffset delta: SIMD2<Double>,
                           from start: [Int: LayerTransform]? = nil) -> [Int: LayerTransform] {
        var result: [Int: LayerTransform] = [:]
        for layerID in layerIDs {
            var transform = start?[layerID] ?? self.transform(of: layerID)
            let local = parentWorld(of: layerID).inverted?.applyVector(delta) ?? delta
            transform.origin.x += local.x
            transform.origin.y += local.y
            result[layerID] = transform
        }
        return result
    }
}
