import OWEInspectorKit
import SwiftUI

/// A settings page's grouped form. It scrolls to the setting `SettingsNavigation.highlight`
/// names, when the page opens and when a search result picks one on it.
struct SettingsForm<Content: View>: View {
    @EnvironmentObject private var navigation: SettingsNavigation
    @ViewBuilder let content: Content

    var body: some View {
        ScrollViewReader { proxy in
            Form { content }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .onAppear { scroll(proxy, to: navigation.highlight) }
                .onChange(of: navigation.highlight) { _, anchor in scroll(proxy, to: anchor) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to anchor: String?) {
        guard let anchor else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(anchor, anchor: .top) }
        }
    }
}

extension View {
    /// Marks a settings section as `anchor` for search: it can be scrolled to and flashes when
    /// a search result opens it.
    func settingsAnchor(_ anchor: String) -> some View {
        modifier(SettingsAnchorHighlight(anchor: anchor))
    }

    /// A small dot before a setting that differs from its default.
    func changedFromDefault(_ isChanged: Bool) -> some View {
        overlay(alignment: .leading) {
            if isChanged {
                Circle()
                    .fill(.tint)
                    .frame(width: 5, height: 5)
                    .offset(x: -10)
                    .help(Text("Changed from the default"))
                    .accessibilityLabel(Text("Changed from the default"))
            }
        }
    }
}

private struct SettingsAnchorHighlight: ViewModifier {
    @EnvironmentObject private var navigation: SettingsNavigation
    @Environment(\.appAccentColor) private var accentColor
    let anchor: String

    func body(content: Content) -> some View {
        content
            .id(anchor)
            .listRowBackground(navigation.highlight == anchor
                               ? accentColor.opacity(0.18) : nil)
            .animation(.easeInOut(duration: 0.3), value: navigation.highlight)
    }
}

extension GlobalSettingsViewModel {
    /// Whether the setting at `keyPath` differs from its default, for `changedFromDefault`.
    func isChanged<Value: Equatable>(_ keyPath: KeyPath<GlobalSettings, Value>) -> Bool {
        settings[keyPath: keyPath] != GlobalSettings()[keyPath: keyPath]
    }
}
