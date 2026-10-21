import AppKit

/// Finder's click selection in a grid, shared by the Installed, Workshop and Discover tabs: a
/// click picks one item, ⌘- or ⌃-click adds or removes one, and ⇧-click selects the run from the
/// anchor (the last item clicked) to the clicked one, in the order the grid shows them.
enum ClickSelection {
    enum Kind: Equatable {
        /// A plain click: the tab decides what it picks.
        case replace
        /// ⌘- or ⌃-click.
        case toggle
        /// ⇧-click.
        case extend
    }

    /// What a click with `modifiers` held does; ⌘ or ⌃ win over ⇧, as in Finder.
    static func kind(of modifiers: NSEvent.ModifierFlags) -> Kind {
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) || modifiers.contains(.control) { return .toggle }
        return modifiers.contains(.shift) ? .extend : .replace
    }

    /// The kind of the click being handled, from the keys held now.
    static var current: Kind { kind(of: NSEvent.modifierFlags) }

    /// Applies a ⌘-click or ⇧-click on `id` to `selected`, moving `anchor`, and returns true; a
    /// plain click returns false and changes nothing. ⇧-click with no anchor in `order` (none
    /// yet, or one in another list) adds `id` alone and makes it the anchor.
    @discardableResult
    static func apply<ID: Hashable>(_ kind: Kind, on id: ID, in order: [ID],
                                    selected: inout Set<ID>, anchor: inout ID?) -> Bool {
        switch kind {
        case .replace:
            return false
        case .toggle:
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            anchor = id
        case .extend:
            if let anchorID = anchor,
               let start = order.firstIndex(of: anchorID), let end = order.firstIndex(of: id) {
                // The anchor stays, so the next ⇧-click redraws the run from it.
                selected = Set(order[min(start, end)...max(start, end)])
            } else {
                selected.insert(id)
                anchor = id
            }
        }
        return true
    }
}
