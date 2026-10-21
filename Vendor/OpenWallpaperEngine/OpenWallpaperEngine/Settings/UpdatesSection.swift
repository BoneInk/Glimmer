import SwiftUI

/// Settings › Updates: Sparkle's preferences and the beta channel.
struct UpdatesSection: View {
    @ObservedObject var updater: AppUpdater
    @AppStorage(WhatsNew.hidesReleaseNotesKey, store: .app) private var hidesReleaseNotes = false

    var body: some View {
        Section {
            if updater.isEnabled {
                Toggle("Update automatically", isOn: $updater.updatesAutomatically)
                    .help("Downloads and installs updates by itself: when you quit, while you're away from your Mac, or within a day.")
                if !updater.updatesAutomatically {
                    Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                        .help("Checks GitHub for new versions on a schedule and tells you when one is ready.")
                }
                Toggle("Receive beta updates", isOn: $updater.receivesBetaUpdates)
                    .help("Also offers pre-release versions, which get new features first and may be less stable.")
                HStack {
                    if let date = updater.lastUpdateCheckDate {
                        Text("Last checked: \(date.formatted(date: .abbreviated, time: .shortened))",
                             comment: "%@ is a date and time")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never checked")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            } else {
                Text("Updates are off in this build because it has no update signing key. Builds from GitHub Releases update themselves.")
                    .foregroundStyle(.secondary)
            }
            Toggle("Don't show release notes", isOn: $hidesReleaseNotes)
                .help("Skips the release notes window after the app updates.")
        } header: {
            Label("Updates", systemImage: "arrow.down.circle")
        } footer: {
            Text("Open Wallpaper Engine checks for new versions in the update list at openwallpaperengine.app and downloads them from GitHub Releases. No personal data is sent. Automatic updates install when you quit, when you're away from your Mac, or within a day.")
        }
    }
}
