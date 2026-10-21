import AppKit
import SwiftUI

/// Which settings tab shows, and the setting a search result or a link asked to see.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var tab: SettingsTab = .general {
        didSet { toolbar?.selectedItemIdentifier = tab.toolbarIdentifier }
    }
    /// A setting's anchor (`SettingsAnchor`) to scroll to and highlight briefly.
    @Published var highlight: String?
    /// Edit › Find while the settings window is in front: the search field takes the focus.
    @Published var focusesSearch = false

    /// The settings window's toolbar, kept in step with `tab`.
    weak var toolbar: NSToolbar?

    /// Shows `tab`, and the setting `anchor` on it when given.
    func show(_ tab: SettingsTab, anchor: String? = nil) {
        self.tab = tab
        highlight = anchor
        if anchor != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                if self?.highlight == anchor { self?.highlight = nil }
            }
        }
    }
}
