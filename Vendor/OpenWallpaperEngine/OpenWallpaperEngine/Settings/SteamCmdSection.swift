import SwiftUI
import AppKit

/// Settings › Assets › SteamCMD: which steamcmd the app uses, the copy it installed from Valve
/// (where, how big, Remove and Reinstall), and whether it installs one on its own.
struct SteamCmdSection: View {
    @ObservedObject var steamCmd: SteamCmdService
    @ObservedObject var installer: SteamCmdInstaller
    @AppStorage(SteamCmdInstaller.autoInstallKey, store: .app) private var installsAutomatically = true
    @AppStorage(WallpaperEngineAssetsService.autoInstallKey, store: .app) private var installsAssetsAutomatically = true
    @State private var removeError: String?

    var body: some View {
        Section {
            HStack {
                Text("Status")
                Spacer()
                if steamCmd.steamCmdPath != nil {
                    Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("Missing", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            if let path = steamCmd.steamCmdPath {
                row("Location", Text(verbatim: path).font(.caption.monospaced()))
                if usesOwnCopy, let size = installer.installedSize {
                    row("Size", Text(size.formatted(.byteCount(style: .file))))
                }
            }
            Toggle("Install SteamCMD automatically", isOn: $installsAutomatically)
                .help("Downloads SteamCMD from Valve when no copy is found. Workshop downloads and the assets install need it.")
            Toggle("Install Wallpaper Engine assets automatically after signing in", isOn: $installsAssetsAutomatically)
                .help("After you sign in to Steam, downloads the Wallpaper Engine assets if none are installed or chosen.")
            if installer.isBusy || steamCmd.steamCmdPath == nil {
                SteamCmdSetupView(installer: installer)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if usesOwnCopy {
                HStack {
                    Button("Reinstall") { installer.install() }
                        .help("Downloads SteamCMD from Valve again, replacing the app's copy.")
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([installer.executable])
                    }
                    Button("Remove", role: .destructive) { remove() }
                        .help("Moves the app's SteamCMD to the Trash. Workshop downloads won't work until SteamCMD is installed again.")
                    Spacer()
                }
            }
            if let removeError {
                Label(removeError, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
        } header: {
            Label("SteamCMD", systemImage: "terminal")
        } footer: {
            Text("Workshop downloads and the assets install use SteamCMD, Valve's command-line Steam client. When none is found, Open Wallpaper Engine downloads it from Valve. Homebrew's steamcmd works too.")
        }
        .onAppear {
            installer.refreshSize()
            installer.detectThenAutoInstall(steamCmd)
        }
    }

    private var usesOwnCopy: Bool {
        steamCmd.steamCmdPath == installer.executable.path
    }

    private func remove() {
        do {
            try installer.remove()
            removeError = nil
        } catch {
            OWELog.error(.workshop, "Can't move SteamCMD to the Trash: \(error)")
            removeError = error.localizedDescription
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: Text) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            value
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
