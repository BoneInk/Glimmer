import Combine
import Foundation

/// The wallpaper's user properties (project.json `general.properties`) as the editor authors them:
/// add, edit, remove, reorder and rename, bind them to fields, every change one undo step of the
/// session. The edited list lives in the overlay (`SceneAuthoring.properties`); until the first
/// change it is project.json's own.
@MainActor
public final class UserPropertyAuthoring: ObservableObject {
    public let session: SceneEditSession
    /// project.json's properties as authored, in WE's order (`order`, then key).
    public let authored: [UserPropertyDraft]
    private var forward: AnyCancellable?
    /// Reads a file of the wallpaper (else WE's), for the image layers' materials a texture
    /// binding is written into (`bindTexture`); without one, bindings go into the layer's `instance`.
    let readAsset: (String) -> Data?

    public init(session: SceneEditSession, authored: [UserPropertyDraft], readAsset: @escaping (String) -> Data? = { _ in nil }) {
        self.session = session
        self.authored = authored
        self.readAsset = readAsset
        forward = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// From project.json's data; no properties when it can't be read.
    public convenience init(session: SceneEditSession, projectJSON: Data?, readAsset: @escaping (String) -> Data? = { _ in nil }) {
        self.init(session: session, authored: projectJSON.map(Self.read) ?? [], readAsset: readAsset)
    }

    /// project.json's `general.properties`, ordered as WE's sidebar orders them.
    public nonisolated static func read(projectJSON data: Data) -> [UserPropertyDraft] {
        guard let root = EditorLog.attempt("Properties: project.json", { try JSONSerialization.jsonObject(with: data) }) as? [String: Any],
              let general = root["general"] as? [String: Any],
              let entries = general["properties"] as? [String: Any] else { return [] }
        var drafts: [(order: Int, draft: UserPropertyDraft)] = []
        for (key, entry) in entries {
            guard case .object(let raw)? = SceneJSONValue(any: entry) else { continue }
            let order = raw["order"]?.doubleValue.map { Int($0) } ?? Int.max
            drafts.append((order, UserPropertyDraft(key: key, raw: raw)))
        }
        return drafts.sorted { ($0.order, $0.draft.key) < ($1.order, $1.draft.key) }.map(\.draft)
    }

    // MARK: Reading

    public var properties: [UserPropertyDraft] { session.overlay.authoring?.properties ?? authored }

    /// The properties differ from project.json's.
    public var isEdited: Bool { session.overlay.authoring?.properties != nil }

    public func property(_ key: String) -> UserPropertyDraft? {
        properties.first { $0.key == key }
    }

    public var keys: Set<String> { Set(properties.map(\.key)) }

    /// Properties a field of `kind` can be bound to: a value of the same kind, and for a flag
    /// also a combo (bound with a condition: on for one of its values).
    public func candidates(for kind: UserPropertyDraft.Kind) -> [UserPropertyDraft] {
        properties.filter { property in
            guard property.kind.hasValue else { return false }
            if property.kind == kind { return true }
            if kind == .bool { return property.kind == .combo }
            if kind == .slider { return property.kind == .bool }
            return false
        }
    }

    // MARK: Changing

    /// Adds a property of `kind` after the others; returns its key.
    @discardableResult
    public func add(_ kind: UserPropertyDraft.Kind, label: String, actionName: String) -> String {
        let key = UserPropertyDraft.key(from: label, taken: keys)
        var list = properties
        list.append(.new(kind, key: key, text: label))
        commit(list, actionName: actionName)
        return key
    }

    /// Changes one property; a run of changes to it (typing, a slider) is one undo step.
    public func update(_ key: String, actionName: String, coalescing: Bool = true,
                       _ change: (inout UserPropertyDraft) -> Void) {
        var list = properties
        guard let index = list.firstIndex(where: { $0.key == key }) else { return }
        change(&list[index])
        list[index].key = key // Renaming goes through `rename`, which re-points conditions and bindings.
        commit(list, actionName: actionName, coalescingKey: coalescing ? "property:\(key)" : nil)
    }

    /// Removes properties. Fields bound to them keep their values (WE falls back to the bound
    /// field's `value` for a property the project doesn't declare).
    public func remove(_ removed: Set<String>, actionName: String) {
        let list = properties.filter { !removed.contains($0.key) }
        guard list.count != properties.count else { return }
        commit(list, actionName: actionName)
    }

    /// Moves properties as a list's drag does (`fromOffsets` before `toOffset`).
    public func move(fromOffsets source: IndexSet, toOffset destination: Int, actionName: String) {
        var list = properties
        let moving = source.sorted().filter(list.indices.contains).map { list[$0] }
        guard !moving.isEmpty else { return }
        let before = source.filter { $0 < destination }.count
        for index in source.sorted(by: >) where list.indices.contains(index) { list.remove(at: index) }
        list.insert(contentsOf: moving, at: max(0, min(list.count, destination - before)))
        commit(list, actionName: actionName)
    }

    /// Renames a property's key and re-points what names it: the other properties' conditions,
    /// every field bound to it and every texture slot linked to it. False when `newKey` is invalid or taken.
    @discardableResult
    public func rename(_ key: String, to newKey: String, actionName: String) -> Bool {
        guard key != newKey, UserPropertyDraft.isValidKey(newKey), !keys.contains(newKey),
              let index = properties.firstIndex(where: { $0.key == key }) else { return false }
        var list = properties
        list[index].key = newKey
        for position in list.indices {
            if let condition = list[position].condition {
                list[position].condition = Self.renaming(key, to: newKey, in: condition)
            }
        }
        let bound = session.fields(boundTo: key)
        let normalized = normalizedList(list)
        session.editOverlay(actionName: actionName) { overlay in
            for (layer, path) in bound {
                let condition = session.drivers(path, of: layer).user?.condition
                session.changeDrivers(in: &overlay, path, of: layer) { edit in
                    edit.bind(SceneUserBinding(name: newKey, condition: condition))
                }
            }
            renameTextureBindings(key, to: newKey, in: &overlay)
            setProperties(normalized, in: &overlay)
        }
        return true
    }

    /// Adds a property and binds a field to it, one undo step (`Bind to User Property…` › New).
    @discardableResult
    public func addAndBind(_ kind: UserPropertyDraft.Kind, label: String, path: SceneFieldPath, of layerID: Int,
                           defaultValue: SceneJSONValue?, actionName: String) -> String {
        let key = UserPropertyDraft.key(from: label, taken: keys)
        var draft = UserPropertyDraft.new(kind, key: key, text: label)
        if let defaultValue { draft.value = defaultValue }
        if kind == .slider, let number = defaultValue?.doubleValue {
            draft.minimum = min(draft.minimum ?? 0, number)
            draft.maximum = max(draft.maximum ?? 1, number)
        }
        let list = normalizedList(properties + [draft])
        session.editOverlay(actionName: actionName) { overlay in
            session.changeDrivers(in: &overlay, path, of: layerID) { edit in
                edit.bind(SceneUserBinding(name: key))
            }
            setProperties(list, in: &overlay)
        }
        return key
    }

    /// Adds `draft` (whose key is free, `UserPropertyDraft.key(from:taken:)` with `keys`) and
    /// changes the overlay with it, one undo step (a texture variant's condition on a new property).
    public func add(_ draft: UserPropertyDraft, actionName: String, with change: (inout SceneEditOverlay) -> Void) {
        guard !keys.contains(draft.key) else { return }
        let list = normalizedList(properties + [draft])
        session.editOverlay(actionName: actionName) { overlay in
            change(&overlay)
            setProperties(list, in: &overlay)
        }
    }

    /// Back to project.json's properties (bindings stay).
    public func revertToAuthored(actionName: String) {
        commit(authored, actionName: actionName)
    }

    private func commit(_ list: [UserPropertyDraft], actionName: String, coalescingKey: String? = nil) {
        let normalized = normalizedList(list)
        session.editOverlay(actionName: actionName, coalescingKey: coalescingKey) { overlay in
            setProperties(normalized, in: &overlay)
        }
    }

    /// nil when the list is project.json's own, so an undone edit leaves nothing behind.
    private func normalizedList(_ list: [UserPropertyDraft]) -> [UserPropertyDraft]? {
        list == authored ? nil : list
    }

    private func setProperties(_ list: [UserPropertyDraft]?, in overlay: inout SceneEditOverlay) {
        var authoring = overlay.authoring ?? SceneAuthoring()
        authoring.properties = list
        overlay.authoring = authoring.isEmpty ? nil : authoring
    }

    /// `condition` with `old.value` (and a bare `old`) renamed.
    nonisolated static func renaming(_ old: String, to new: String, in condition: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: old)
        let pattern = #"(?<![A-Za-z0-9_$.])"# + escaped + #"(?![A-Za-z0-9_$])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return condition }
        // Leave string literals alone: rename only outside quotes.
        var result = ""
        var inQuote: Character?
        var segment = ""
        func flush() {
            let segmentRange = NSRange(segment.startIndex..., in: segment)
            result += regex.stringByReplacingMatches(in: segment, range: segmentRange,
                                                     withTemplate: NSRegularExpression.escapedTemplate(for: new))
            segment = ""
        }
        for character in condition {
            if let quote = inQuote {
                result.append(character)
                if character == quote { inQuote = nil }
            } else if character == "\"" || character == "'" {
                flush()
                inQuote = character
                result.append(character)
            } else {
                segment.append(character)
            }
        }
        flush()
        return result
    }
}
