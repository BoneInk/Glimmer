import SwiftUI
import AppKit

/// "Log in with SteamCMD in Terminal": the command to run, then "I've Signed In", which reuses the
/// login SteamCMD saved.
struct SteamTerminalLoginView: View {
    @ObservedObject var steamCmd: SteamCmdService
    @Binding var account: String
    @State private var isCopied = false
    @State private var openError: String?

    private var command: String {
        SteamCmdTerminalLogin.command(steamCmdPath: steamCmd.steamCmdPath ?? "steamcmd",
                                      account: account.isEmpty ? "ACCOUNT" : account)
    }

    var body: some View {
        VStack(spacing: 10) {
            Text("Run this in Terminal. SteamCMD asks for your password and Steam Guard code there.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("Steam Username", text: $account)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)

            HStack {
                Text(verbatim: command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    isCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isCopied = false }
                } label: {
                    Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .glassButtonStyle()
                .help(isCopied ? "Copied" : "Copy the command")
            }
            .frame(maxWidth: 440)

            HStack(spacing: 12) {
                Button("Open in Terminal") { openInTerminal() }
                    .glassButtonStyle()
                    .disabled(account.isEmpty)
                Button("I've Signed In") {
                    steamCmd.loginWithCachedSession(
                        username: account,
                        failureMessage: String(localized: "SteamCMD has no saved login for this account. Finish signing in in Terminal, then try again.",
                                               comment: "Error after the user says they logged in to SteamCMD in Terminal"))
                }
                .glassButtonStyle(.prominent)
                .disabled(account.isEmpty || steamCmd.isLoggingIn)
            }

            Link("About SteamCMD", destination: SteamCmdTerminalLogin.documentationURL)
                .font(.caption)

            if let openError {
                Text(openError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func openInTerminal() {
        do {
            let file = try SteamCmdTerminalLogin.writeCommandFile(command)
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            openError = nil
        } catch {
            OWELog.error(.workshop, "Can't open the SteamCMD login in Terminal: \(error)")
            openError = error.localizedDescription
        }
    }
}
