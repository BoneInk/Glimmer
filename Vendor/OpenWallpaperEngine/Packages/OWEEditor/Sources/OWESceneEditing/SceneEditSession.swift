import Combine
import Foundation

/// One editor window's edit model: the scene as authored, the overlay of edits over it, the
/// selection, and undo. Every edit goes through `commit`, which registers its undo (a snapshot of
/// the overlay before it) and hands the new overlay to `onChange`, which saves it and has the
/// running wallpaper apply it.
@MainActor
public final class SceneEditSession: ObservableObject {
    /// The scene as the wallpaper ships it.
    public let authored: SceneOutline
    /// The scene as edited: layers added, deleted, reordered and regrouped, effects added and
    /// reordered, names changed, the particle editor's systems added and deleted
    /// (`SceneParticleOverlay`). What the layer list, the canvas and the inspector show.
    @Published public private(set) var outline: SceneOutline
    /// The scene with the structural edits only: what a layer's values are compared against (an
    /// added layer's own values are its authored ones).
    public private(set) var baseOutline: SceneOutline
    /// The scene's layers as authored (`authored`).
    public var authoredOutline: SceneOutline { authored }
    public let undoManager: UndoManager
    @Published public private(set) var overlay: SceneEditOverlay
    /// The layer the inspector shows: the one clicked last, one of `selectedLayers`.
    @Published public var selection: Int? {
        didSet { if selection != oldValue { keepSelectedLayers() } }
    }
    /// Every selected layer (Shift- or ⌘-click, a marquee, the list's multiple selection), with
    /// `selection` among them; setting `selection` alone selects that layer only.
    @Published public var selectedLayers: Set<Int> = []
    /// A drag of several layers: each one's transform as dragged, drawn like `dragPreview` until
    /// the drag ends and commits them as one undo step (`endGroupDrag`).
    @Published public var groupDragPreview: [Int: LayerTransform] = [:] {
        didSet { if !groupDragPreview.isEmpty { onLivePreview?(previewOverlay) } }
    }
    /// A gizmo drag in progress: the layer's transform as dragged, drawn on the canvas (and, through
    /// `onLivePreview`, by the running wallpaper) until the drag ends and commits it.
    @Published public var dragPreview: (layer: Int, transform: LayerTransform)? {
        didSet { if dragPreview != nil { onLivePreview?(previewOverlay) } }
    }
    /// The text layer being edited on the canvas.
    @Published public var editingText: Int?
    /// Saves and applies the overlay after every change, undo and redo included.
    public var onChange: ((SceneEditOverlay) -> Void)?
    /// The overlay with a drag in progress, for the running wallpaper to draw live; not saved.
    public var onLivePreview: ((SceneEditOverlay) -> Void)?
    /// The timeline's say over animated fields: what they show at the playhead, and the keyframe
    /// an edit of one sets there (`SceneTimelineEditor`). Nil leaves every field static.
    public weak var animatedFields: SceneAnimatedFields?

    /// Edits of one control within this long of each other are one undo step (a slider drag, typing).
    public var coalescingInterval: TimeInterval = 1
    private var lastCoalescing: (key: String, date: Date)?
    private var undoObservers: [AnyCancellable] = []

    /// `undoManager`: a new one when nil.
    public init(outline: SceneOutline, overlay: SceneEditOverlay = SceneEditOverlay(),
                undoManager: UndoManager? = nil) {
        authored = outline
        self.overlay = overlay
        self.outline = outline
        baseOutline = outline
        let undoManager = undoManager ?? UndoManager()
        self.undoManager = undoManager
        refreshOutlines()
        // Undo, redo and steps others register (the user properties) change what Undo and Redo
        // offer, with or without an overlay change.
        let center = NotificationCenter.default
        undoObservers = [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
                         .NSUndoManagerDidRedoChange].map { name in
            center.publisher(for: name, object: undoManager)
                .sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }

    /// The overlay with the drag in progress applied.
    public var previewOverlay: SceneEditOverlay {
        var previews = groupDragPreview
        if let preview = dragPreview { previews[preview.layer] = preview.transform }
        guard !previews.isEmpty else { return overlay }
        var next = overlay
        for (layer, transform) in previews {
            let current = storedTransform(of: layer)
            func set(_ field: String, _ vector: SIMD3<Double>, _ was: SIMD3<Double>) {
                guard vector != was, isEditable(field, of: layer) else { return }
                next.setField(field, to: SceneVector.value([vector.x, vector.y, vector.z]), of: layer)
            }
            set("origin", transform.origin, current.origin)
            set("scale", transform.scale, current.scale)
            set("angles", transform.angles, current.angles)
        }
        return next
    }

    /// The scene applied with `overlay` (every edit) and with its structure only, read again
    /// when the structure, a name or a parent changed. Without the scene's data (an outline made
    /// from a decoded root) the authored outline stands.
    private func refreshOutlines(from previous: SceneEditOverlay? = nil) {
        if let previous, previous.outlineSignature == overlay.outlineSignature { return }
        guard let data = authored.sceneData else {
            outline = authored.applying(overlay.particles)
            baseOutline = outline
            if let selection, outline.layer(selection) == nil { self.selection = nil }
            pruneSelectedLayers()
            return
        }
        do {
            outline = try Self.outline(of: data, with: overlay)
            baseOutline = try Self.outline(of: data, with: overlay.structureOnly)
        } catch {
            outline = authored
            baseOutline = authored
        }
        if let selection, outline.layer(selection) == nil { self.selection = nil }
        pruneSelectedLayers()
        if let editing = editingText, outline.layer(editing) == nil { editingText = nil }
    }

    /// What `baseOutline` is for a session over `sceneData` with `overlay`: the scene with the
    /// structural edits only. A wallpaper running in another process than the editor's measures
    /// the editor's overlay against it (`SceneEditLiveValues`).
    public static func baseOutline(sceneData: Data, overlay: SceneEditOverlay) throws -> SceneOutline {
        try outline(of: sceneData, with: overlay.structureOnly)
    }

    static func outline(of data: Data, with overlay: SceneEditOverlay) throws -> SceneOutline {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SceneEditOverlayError.notAScene
        }
        try overlay.apply(to: &root, markingEffectKeys: true)
        return try SceneOutline(root: root)
    }

    public var canUndo: Bool { undoManager.canUndo }
    public var canRedo: Bool { undoManager.canRedo }

    public func undo() {
        guard undoManager.canUndo else { return }
        undoManager.undo()
    }

    public func redo() {
        guard undoManager.canRedo else { return }
        undoManager.redo()
    }

    // MARK: Reading

    /// The field as the scene now has it: the edit, else the authored value (a driven field's
    /// starting value).
    public func value(_ field: String, of layerID: Int) -> SceneJSONValue? {
        if let animated = animatedFields?.value(field, of: layerID) { return animated }
        return staticValue(field, of: layerID)
    }

    /// The field's value without its timeline: the edit, else the authored (starting) value.
    public func staticValue(_ field: String, of layerID: Int) -> SceneJSONValue? {
        overlay.field(field, of: layerID) ?? SceneFieldBinding.literal(of: baseOutline.layer(layerID)?.fields[field])
    }

    /// How the authored field gets its value; a field bound to a user property isn't edited here.
    public func binding(_ field: String, of layerID: Int) -> SceneFieldBinding {
        SceneFieldBinding(drivenField(SceneFieldPath(components: [field]), of: layerID))
    }

    public func isEditable(_ field: String, of layerID: Int) -> Bool {
        if case .userProperty = binding(field, of: layerID) { return false }
        return true
    }

    public func number(_ field: String, of layerID: Int, default fallback: Double) -> Double {
        value(field, of: layerID)?.doubleValue ?? fallback
    }

    public func vector(_ field: String, of layerID: Int, default fallback: [Double]) -> [Double] {
        SceneVector.components(value(field, of: layerID), fallback: fallback)
    }

    public func transform(of layerID: Int) -> LayerTransform {
        if let preview = dragPreview, preview.layer == layerID { return preview.transform }
        if let preview = groupDragPreview[layerID] { return preview }
        return storedTransform(of: layerID)
    }

    /// The transform as the overlay has it, without a drag in progress.
    func storedTransform(of layerID: Int) -> LayerTransform {
        let origin = vector("origin", of: layerID, default: [0, 0, 0])
        let scale = vector("scale", of: layerID, default: [1, 1, 1])
        let angles = vector("angles", of: layerID, default: [0, 0, 0])
        return LayerTransform(origin: SIMD3(origin[0], origin[1], origin[2]),
                              scale: SIMD3(scale[0], scale[1], scale[2]),
                              angles: SIMD3(angles[0], angles[1], angles[2]))
    }

    public func isVisible(_ layerID: Int) -> Bool {
        value("visible", of: layerID)?.boolValue ?? true
    }

    /// The user property that sets the layer's `visible`, if one does.
    public func visibilityProperty(of layerID: Int) -> String? {
        if case .userProperty(let name) = binding("visible", of: layerID) { return name }
        return nil
    }

    /// Hidden by hand over the user property that sets its `visible` (`setVisible`): hidden
    /// whatever the property says.
    public func isHiddenOverProperty(_ layerID: Int) -> Bool {
        visibilityProperty(of: layerID) != nil && overlay.field("visible", of: layerID)?.boolValue == false
    }

    /// A parent (or its parent…) is hidden: WE draws an object only while it and every parent are
    /// visible (wallpaper64.exe 0x140185010), so hiding a group hides what's in it, and each layer
    /// keeps its own switch for when the group shows again.
    public func isHiddenByParent(_ layerID: Int) -> Bool {
        outline.ancestors(of: layerID).contains { !isVisible($0.id) }
    }

    public func isLocked(_ layerID: Int) -> Bool { overlay.isLocked(layerID) }

    public func isEdited(_ layerID: Int) -> Bool { overlay.hasEdits(layerID) }

    public func isEffectVisible(_ effect: SceneLayerEffect, of layerID: Int) -> Bool {
        overlay.effectEdit(effect.key, of: layerID)?.visible
            ?? SceneFieldBinding.literal(of: baseEffect(effect.key, of: layerID)?.visible ?? effect.visible)?.boolValue ?? true
    }

    /// The effect as the structure-only scene has it: its authored values (an added effect's own).
    public func baseEffect(_ key: String, of layerID: Int) -> SceneLayerEffect? {
        baseOutline.layer(layerID)?.effects.first { $0.key == key }
    }

    /// The planar layer's rectangle on the scene, its parents' transforms included; nil for a
    /// layer the canvas can't show a rectangle for (3D, sound, particles) or a 3D scene.
    public func geometry(of layerID: Int) -> LayerGeometry? {
        guard outline.size != nil, let layer = outline.layer(layerID), layer.isPlanar else { return nil }
        var parent = SceneTransform2D.identity
        for ancestor in outline.ancestors(of: layerID).reversed() {
            parent = parent.concatenating(transform(of: ancestor.id).local)
        }
        let size = layerSize(layer)
        let alignment = value("alignment", of: layerID)?.stringValue
        return LayerGeometry(transform: transform(of: layerID), parent: parent, size: size,
                             anchorOffset: LayerGeometry.anchorOffset(alignment: alignment, size: size))
    }

    /// An image's `size`; a text layer's, else an estimate from its point size and text (the
    /// renderer lays text out; the canvas only needs something to grab).
    func layerSize(_ layer: SceneLayer) -> SIMD2<Double> {
        let size = SceneVector.components(value("size", of: layer.id))
        if size.count >= 2, size[0] > 0, size[1] > 0 { return SIMD2(size[0], size[1]) }
        guard layer.kind == .text else { return SIMD2(100, 100) }
        let points = value("pointsize", of: layer.id)?.doubleValue ?? 32
        let text = textContent(of: layer.id) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let longest = lines.map(\.count).max() ?? 0
        var width = max(Double(longest) * points * 0.6, points * 2)
        if let maxWidth = value("maxwidth", of: layer.id)?.doubleValue, maxWidth > 0,
           value("limitwidth", of: layer.id)?.boolValue == true {
            width = min(width, maxWidth)
        }
        return SIMD2(width, Double(max(lines.count, 1)) * points * 1.4)
    }

    /// The topmost visible, unlocked planar layer at `scenePoint`, as clicking the canvas picks.
    public func layer(at scenePoint: SIMD2<Double>) -> Int? {
        for layer in outline.layers.reversed() where isVisible(layer.id) && !isLocked(layer.id) {
            if let geometry = geometry(of: layer.id), geometry.contains(scenePoint) { return layer.id }
        }
        return nil
    }

    // MARK: Editing

    /// Sets the field; a value equal to the authored one drops the edit. `coalescing` merges
    /// a run of edits of one control into one undo step.
    public func setValue(_ value: SceneJSONValue?, for field: String, of layerID: Int,
                         actionName: String, coalescing: Bool = false) {
        guard isEditable(field, of: layerID) else { return }
        var next = overlay
        if let value, let keyed = animatedFields?.overlay(setting: value, for: field, of: layerID, in: next) {
            next = keyed
        } else {
            next.setField(field, to: normalized(value, field: field, of: layerID), of: layerID)
        }
        commit(next, actionName: actionName, coalescingKey: coalescing ? "\(layerID):\(field)" : nil)
    }

    /// Sets the changed transform fields at once: one undo step for a gizmo drag.
    public func setTransform(_ transform: LayerTransform, of layerID: Int, actionName: String,
                             coalescing: Bool = false) {
        let current = self.transform(of: layerID)
        var next = overlay
        func set(_ field: String, _ vector: SIMD3<Double>, _ was: SIMD3<Double>) {
            guard vector != was, isEditable(field, of: layerID) else { return }
            let value = SceneVector.value([vector.x, vector.y, vector.z])
            if let keyed = animatedFields?.overlay(setting: value, for: field, of: layerID, in: next) {
                next = keyed
                return
            }
            next.setField(field, to: normalized(value, field: field, of: layerID), of: layerID)
        }
        set("origin", transform.origin, current.origin)
        set("scale", transform.scale, current.scale)
        set("angles", transform.angles, current.angles)
        commit(next, actionName: actionName, coalescingKey: coalescing ? "\(layerID):transform" : nil)
    }

    /// Commits the gizmo drag shown in `dragPreview`.
    public func endDrag(actionName: String) {
        guard let preview = dragPreview else { return }
        dragPreview = nil
        // The preview is what `transform(of:)` read; compare against the stored values.
        setTransform(preview.transform, of: preview.layer, actionName: actionName)
    }

    /// Shows or hides the layer. A layer a user property shows is hidden by an override the scene
    /// applies as a plain `false` (`SceneEditOverlay.apply`), whatever the property says; showing
    /// it drops the override, and the property sets it again. The authored binding stays.
    public func setVisible(_ visible: Bool, _ layerID: Int, actionName: String) {
        guard visibilityProperty(of: layerID) != nil else {
            setValue(.bool(visible), for: "visible", of: layerID, actionName: actionName)
            return
        }
        var next = overlay
        next.setField("visible", to: visible ? nil : .bool(false), of: layerID)
        commit(next, actionName: actionName, coalescingKey: nil)
    }

    public func setLocked(_ locked: Bool, _ layerID: Int, actionName: String) {
        var next = overlay
        next.setLocked(locked, layerID)
        commit(next, actionName: actionName, coalescingKey: nil)
    }

    public func setEffectVisible(_ visible: Bool, effect: SceneLayerEffect, of layerID: Int, actionName: String) {
        let base = baseEffect(effect.key, of: layerID)?.visible ?? effect.visible
        guard !isUserBound(base) else { return }
        let authored = SceneFieldBinding.literal(of: base)?.boolValue ?? true
        var next = overlay
        next.updateEffect(key: effect.key, of: layerID) { $0.visible = visible == authored ? nil : visible }
        commit(next, actionName: actionName, coalescingKey: nil)
    }

    private func isUserBound(_ value: SceneJSONValue?) -> Bool {
        if case .userProperty = SceneFieldBinding(value) { return true }
        return false
    }

    /// A change of the overlay made by the editor's authoring (scripts, bindings, user
    /// properties): one undo step like every edit here.
    public func editOverlay(actionName: String, coalescingKey: String? = nil, _ change: (inout SceneEditOverlay) -> Void) {
        var next = overlay
        change(&next)
        commit(next, actionName: actionName, coalescingKey: coalescingKey)
    }

    /// File › Revert to Saved: back to `saved`, the overlay as last saved (an empty one drops every
    /// edit), locks included, so nothing is left unsaved. Undoable.
    public func revert(to saved: SceneEditOverlay, actionName: String) {
        commit(saved, actionName: actionName, coalescingKey: nil)
    }

    /// nil when `value` is what the scene authored, so the layer no longer counts as edited.
    private func normalized(_ value: SceneJSONValue?, field: String, of layerID: Int) -> SceneJSONValue? {
        guard let value else { return nil }
        let authoredField = baseOutline.layer(layerID)?.fields[field]
        // Taking a layer out of its group (null) where the scene has it at the top level is no edit.
        if value == .null { return authoredField == nil ? nil : value }
        let authored = SceneFieldBinding.literal(of: authoredField) ?? Self.defaults[field]
        return Self.same(value, authored) ? nil : value
    }

    /// WE's value of a field an object doesn't have.
    static let defaults: [String: SceneJSONValue] = [
        "visible": .bool(true), "alpha": .number(1), "colorBlendMode": .number(0),
        "origin": .string("0 0 0"), "scale": .string("1 1 1"), "angles": .string("0 0 0"), "color": .string("1 1 1"),
        // The inspector's other fields, as the player reads an object without them (`WESceneObject`,
        // `WESceneSound`; WE's objects are solid).
        "brightness": .number(1), "perspective": .bool(false), "solid": .bool(true), "disablepropagation": .bool(false),
        "copybackground": .bool(true), "clampuvs": .bool(false), "alignment": .string("center"), "parallaxDepth": .string("1 1"),
        "playbackmode": .string("loop"), "volume": .number(1), "mintime": .number(1), "maxtime": .number(5),
        "startsilent": .bool(false), "muteineditor": .bool(false), "spatialization": .bool(false),
        "mindistance": .number(1), "attenuation": .number(1),
    ]

    /// Equal, or the same numbers written differently (`"1 1 1"` and `"1.00000 1.00000 1.00000"`).
    static func same(_ lhs: SceneJSONValue?, _ rhs: SceneJSONValue?) -> Bool {
        guard let lhs, let rhs else { return false }
        if lhs == rhs { return true }
        if case .bool = lhs { return lhs.boolValue == rhs.boolValue && rhs.boolValue != nil }
        let left = SceneVector.components(lhs), right = SceneVector.components(rhs)
        guard !left.isEmpty, left.count == right.count else { return false }
        return zip(left, right).allSatisfy { abs($0 - $1) <= 1e-6 * max(1, abs($0)) }
    }

    /// Any change of the overlay as one undo step (the timeline, the particle editor's documents
    /// and systems); `coalescingKey` merges a run of changes of one control.
    public func edit(actionName: String, coalescingKey: String? = nil, _ change: (inout SceneEditOverlay) -> Void) {
        var next = overlay
        change(&next)
        commit(next, actionName: actionName, coalescingKey: coalescingKey)
    }


    // MARK: Undo

    /// Every edit ends here: one undo step (or part of the running one), saved and applied.
    func commit(_ next: SceneEditOverlay, actionName: String, coalescingKey: String?) {
        guard next != overlay else { return }
        let now = Date()
        let continues = coalescingKey.map { key in
            lastCoalescing.map { $0.key == key && now.timeIntervalSince($0.date) < coalescingInterval } ?? false
        } ?? false
        if !continues { registerUndo(restoring: overlay, actionName: actionName) }
        lastCoalescing = coalescingKey.map { ($0, now) }
        let previous = overlay
        let hadDepthParallax = hasDepthParallax
        overlay = next
        refreshOutlines(from: previous)
        // Scene settings follow from the layers (depth parallax needs camera parallax); they
        // leave the outline as it is.
        overlay = settlingDepthParallaxCamera(next, hadDepthParallax: hadDepthParallax)
        onChange?(overlay)
    }

    private func registerUndo(restoring snapshot: SceneEditOverlay, actionName: String) {
        let grouped = !undoManager.isUndoing && !undoManager.isRedoing
        if grouped { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.restore(snapshot, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        if grouped { undoManager.endUndoGrouping() }
    }

    /// Undo or redo: back to `snapshot`, registering the way back.
    private func restore(_ snapshot: SceneEditOverlay, actionName: String) {
        registerUndo(restoring: overlay, actionName: actionName)
        lastCoalescing = nil
        dragPreview = nil
        groupDragPreview = [:]
        let previous = overlay
        overlay = snapshot
        refreshOutlines(from: previous)
        onChange?(snapshot)
    }
}

/// What the timeline tells the session about animated fields (`SceneEditSession.animatedFields`).
@MainActor
public protocol SceneAnimatedFields: AnyObject {
    /// The field's value at the playhead; nil when no timeline shows it.
    func value(_ field: String, of layerID: Int) -> SceneJSONValue?
    /// `overlay` with the field's keyframes at the playhead set to `value`; nil when no timeline
    /// takes the edit (it then changes the static value).
    func overlay(setting value: SceneJSONValue, for field: String, of layerID: Int,
                 in overlay: SceneEditOverlay) -> SceneEditOverlay?
}
