import SwiftUI

/// Settings › Updates: Sparkle's preferences, the beta channel and release notes.
struct UpdatesPage: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        SettingsForm {
            UpdatesSection(updater: updater)
                .settingsAnchor(SettingsAnchor.updates)
        }
    }
}
