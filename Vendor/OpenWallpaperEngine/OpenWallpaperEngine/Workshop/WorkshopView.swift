import OWEInspectorKit
import SwiftUI

struct WorkshopView: SubviewOfContentView {
    var viewModel: ContentViewModel

    init(contentViewModel viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            // The browser ends its toolbar with the window's items; setup and login have only those.
            if !viewModel.steamCmd.isInstalled {
                SteamCmdNotInstalledView(steamCmd: viewModel.steamCmd)
                    .toolbar { WindowActionsToolbar(viewModel: viewModel) }
            } else if !viewModel.steamCmd.isLoggedIn {
                SteamLoginView(steamCmd: viewModel.steamCmd)
                    .toolbar { WindowActionsToolbar(viewModel: viewModel) }
            } else {
                WorkshopBrowserView(
                    viewModel: viewModel.workshopVM,
                    contentViewModel: viewModel
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - steamcmd Not Installed

private struct SteamCmdNotInstalledView: View {
    @ObservedObject var steamCmd: SteamCmdService
    @ObservedObject private var installer = AppDelegate.shared.steamCmdInstaller
    @State private var isCopied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: installer.isBusy ? "arrow.down.circle" : "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)

                Text(installer.isBusy ? "Setting Up SteamCMD" : "steamcmd Not Found")
                    .font(.title2)
                    .bold()

                Text("Steam Workshop downloads use SteamCMD, Valve's command-line Steam client. Open Wallpaper Engine can download it from Valve for you.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)

                SteamCmdSetupView(installer: installer)

                if !installer.isBusy {
                    alternatives
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .onAppear { installer.detectThenAutoInstall(steamCmd) }
    }

    @ViewBuilder
    private var alternatives: some View {
        Divider().frame(width: 200)

        Text("Or install it with Homebrew:")
            .font(.callout)
            .foregroundStyle(.secondary)

        HStack {
            Text(verbatim: "brew install steamcmd")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassBackground(in: RoundedRectangle(cornerRadius: 8)) { snippet in
                    snippet
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew install steamcmd", forType: .string)
                isCopied = true
            } label: {
                Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .glassButtonStyle()
            .help(isCopied ? "Copied" : "Copy the command")
            // Back to "Copy" after a moment; cancelled with the view.
            .task(id: isCopied) {
                guard isCopied else { return }
                do {
                    try await Task.sleep(for: .seconds(2))
                    isCopied = false
                } catch {}
            }
        }

        Text("Or locate an existing steamcmd binary:")
            .font(.callout)
            .foregroundStyle(.secondary)

        Button("Browse…") {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.message = String(localized: "Select the steamcmd executable", comment: "Open panel message; steamcmd is a program name")
            if panel.runModal() == .OK, let url = panel.url {
                steamCmd.setCustomPath(url.path)
            }
        }
        .glassButtonStyle()

        if let error = steamCmd.pathError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }

        Button("Re-detect") {
            steamCmd.detectSteamCmd()
        }
        .buttonStyle(.link)
        .font(.caption)
    }
}

// MARK: - Steam Login

private struct SteamLoginView: View {
    @ObservedObject var steamCmd: SteamCmdService

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)

                Text("Steam Login")
                    .font(.title2)
                    .bold()

                SteamLoginForm(steamCmd: steamCmd)

                // API Key section
                VStack(spacing: 6) {
                    Divider().padding(.vertical, 8)
                    Text("You'll also need a Steam Web API key to browse the Workshop.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SteamWebAPIKeyView()
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }
}
