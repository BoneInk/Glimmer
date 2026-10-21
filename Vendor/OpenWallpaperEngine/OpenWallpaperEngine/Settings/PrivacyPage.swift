import SwiftUI

/// Settings › Privacy: what the app keeps and contacts, the Terms of Use and Privacy Policy (the
/// version shown and when it was confirmed), and where to report a security problem.
struct PrivacyPage: View {
    private let acknowledgement = LegalNotice.acknowledgement(in: .app)
    private let currentVersion = LegalNotice.currentVersion

    var body: some View {
        SettingsForm {
            Section {
                Label("Everything Open Wallpaper Engine saves stays on your Mac: your settings, library, cache and SteamCMD's login.",
                      systemImage: "internaldrive")
                Label("There are no servers, accounts, analytics or tracking.", systemImage: "hand.raised")
                Label("The app contacts Valve (Steam and SteamCMD), GitHub (app updates) and, when you install an optional plugin, its publisher. Web wallpapers and URLs you add load their own online content.",
                      systemImage: "network")
                Label("You can turn update checks off in Settings › Updates.", systemImage: "arrow.down.circle")
            } header: {
                Label("Privacy", systemImage: "hand.raised.fill")
            }
            .settingsAnchor(SettingsAnchor.privacy)

            Section {
                ForEach(LegalDocument.allCases) { document in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(document.title)
                            Spacer()
                            Button("Read") { LegalDocumentWindow.show(document) }
                            Link(destination: document.onlineURL) {
                                Image(systemName: "arrow.up.right.square")
                            }
                            .help("Open on the Website")
                        }
                        if let edition = document.edition() {
                            Text("Version \(edition.version), effective \(edition.effectiveDate)",
                                 comment: "A legal document's version and effective date, e.g. Version 1.0, effective 2026-09-28")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Text("Confirmed")
                    Spacer()
                    if let acknowledgement, acknowledgement.version == currentVersion {
                        Text(acknowledgement.date, format: .dateTime.year().month().day())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not yet")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("Terms of Use and Privacy Policy", systemImage: "doc.text")
            } footer: {
                Text("You confirmed you have read these documents in the setup assistant. If they change, the app shows them again once.")
            }
            .settingsAnchor(SettingsAnchor.legal)

            Section {
                HStack {
                    Text("Found a security problem? Please report it privately, not in a public issue.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Report a Security Issue") { AppDelegate.shared.openSecurityReport() }
                }
            } header: {
                Label("Security", systemImage: "lock.shield")
            } footer: {
                Text("Opens the Security tab of the project on GitHub.")
            }
            .settingsAnchor(SettingsAnchor.security)
        }
    }
}
