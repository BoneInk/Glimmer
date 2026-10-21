import Foundation

/// What a change of user properties needs, from the binding table (`UserPropertyBindingTable`):
/// the owners whose bound values are applied in place, the objects rebuilt on their own, and a
/// whole-content rebuild or re-parse only for the app's own keys and scene-wide structural bindings.
struct SceneBindingUpdate: Equatable {
    /// A rebuild or re-parse of the whole scene: the app's own keys (`SceneChangeImpact.impact(of:)`),
    /// or a structural binding of the scene itself (`general`).
    var impact: SceneChangeImpact = .none
    /// Objects a structural binding change rebuilds, off the render thread, swapped in alone.
    var rebuild: Set<Int> = []
    /// Every owner a changed binding reads: each moves to a new binding revision, and takes its
    /// uniform and object values in place.
    var owners: Set<UserPropertyBindingOwner> = []

    init() {}

    /// The update for `keys`. A declared property no binding reads (only scripts do) needs nothing
    /// here: the renderer hands it to the scripts.
    init(keys: [String], table: UserPropertyBindingTable) {
        var properties = Set<String>()
        var synced = Set<String>()
        for key in keys {
            let own = SceneChangeImpact.impact(of: key)
            if own == .rebuildContent, !key.hasPrefix("_owe_") {
                properties.insert(key)
            } else {
                impact = max(impact, own)
                // Music sync on or off, or its amount: the kept values of the property move.
                synced.formUnion(Self.musicSyncedProperties(key))
            }
        }
        for (owner, _) in table.changes(for: synced) { owners.insert(owner) }
        for (owner, dependency) in table.changes(for: properties) {
            owners.insert(owner)
            guard dependency == .structural else { continue }
            switch owner {
            case .object(let id): rebuild.insert(id)
            case .scene: impact = max(impact, .rebuildContent)
            }
        }
    }

    /// The properties `<name>_musicSync` and `<name>_musicAmount` modulate: `<name>`, and for a
    /// component's `<name>_<i>` also the vector's name. Empty for any other key.
    static func musicSyncedProperties(_ key: String) -> Set<String> {
        for suffix in ["_musicSync", "_musicAmount"] where key.hasSuffix(suffix) {
            let base = String(key.dropLast(suffix.count))
            var names: Set<String> = [base]
            if let underscore = base.lastIndex(of: "_"), base.index(after: underscore) < base.endIndex,
               base[base.index(after: underscore)...].allSatisfy(\.isNumber) {
                names.insert(String(base[..<underscore]))
            }
            return names
        }
        return []
    }

    /// Nothing to do but hand the scripts the change.
    var isEmpty: Bool { impact == .none && rebuild.isEmpty && owners.isEmpty }
}
