import SwiftUI

// MARK: - 6. Done

/// What was set up, a way back to any skipped step, and shortcuts into the app.
struct OnboardingDoneStep: View {
    @ObservedObject var flow: OnboardingFlow
    @ObservedObject var steamCmd: SteamCmdService
    @ObservedObject var assets: WallpaperEngineAssetsService
    @ObservedObject var imports: OnboardingImports
    let language: GSLocalization
    let onShortcut: (OnboardingShortcut?) -> Void

    var body: some View {
        VStack(spacing: 18) {
            OnboardingHeading(systemImage: "checkmark.seal.fill",
                              title: "You're All Set",
                              subtitle: "You can run this setup again from Settings › General")
            OnboardingCard {
                row(.welcome, title: "Language", systemImage: "globe") {
                    if let endonym = language.endonym {
                        Text(verbatim: endonym)
                    } else {
                        Text("Follow System")
                    }
                }
                Divider()
                row(.steam, title: OnboardingView.title(of: .steam), systemImage: "person.badge.key") {
                    if steamCmd.isLoggedIn {
                        Text("Logged in as \(steamCmd.steamUsername)", comment: "%@ is a Steam account name")
                    } else if steamCmd.steamCmdPath != nil {
                        Text("SteamCMD is ready; not logged in")
                    } else {
                        Text("Not set up")
                    }
                }
                Divider()
                row(.assets, title: OnboardingView.title(of: .assets), systemImage: "shippingbox") {
                    if assets.isBusy {
                        Text("Installing…")
                    } else if assets.status.resolution != nil {
                        Text("Ready")
                    } else {
                        Text("Missing: scenes won't render until you install them")
                    }
                }
                Divider()
                row(.wallpapers, title: OnboardingView.title(of: .wallpapers), systemImage: "photo.stack") {
                    if imports.queuedDownloads == 0 && imports.copiedFromSteamLibrary == 0 {
                        Text("Nothing imported yet")
                    } else {
                        Text("Downloads queued: \(imports.queuedDownloads). Copied from Steam: \(imports.copiedFromSteamLibrary).",
                             comment: "Setup summary; each %lld is a number of wallpapers")
                    }
                }
            }
            HStack(spacing: 12) {
                Button {
                    onShortcut(.installed)
                } label: {
                    Label("Installed", systemImage: "square.grid.2x2")
                }
                Button {
                    onShortcut(.workshop)
                } label: {
                    Label("Workshop", systemImage: "square.and.arrow.down")
                }
                Button {
                    onShortcut(.displaySettings)
                } label: {
                    Label("Display Settings", systemImage: "display.2")
                }
            }
            .glassButtonStyle()
        }
    }

    private func row<Status: View>(_ step: OnboardingStep, title: LocalizedStringKey, systemImage: String,
                                   @ViewBuilder status: () -> Status) -> some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
            }
            .frame(width: 150, alignment: .leading)
            status()
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if flow.skipped.contains(step) {
                Text("Skipped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Set Up") { flow.go(to: step) }
                .buttonStyle(.link)
        }
    }
}
