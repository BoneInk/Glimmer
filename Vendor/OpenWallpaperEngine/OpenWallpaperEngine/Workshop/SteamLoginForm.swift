import SwiftUI

/// The SteamCMD login: account, password and Steam Guard code, the privacy notes, and the option
/// to log in with SteamCMD in Terminal. Used by the Workshop tab and the setup assistant.
struct SteamLoginForm: View {
    @ObservedObject var steamCmd: SteamCmdService
    @State private var username = ""
    @State private var password = ""
    @State private var guardCode = ""
    @State private var showGuardCode = false
    @State private var showsTerminalLogin = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Log in with your Steam account to browse and download wallpapers.\nYou must own Wallpaper Engine on Steam.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)

            fields

            Text("Your password and Steam Guard code go straight to SteamCMD, Valve's official tool. Open Wallpaper Engine never stores, logs or sends them anywhere. It remembers only your account name, to reuse SteamCMD's saved login.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Text("Everything Open Wallpaper Engine saves stays on your Mac: your settings, library, cache and SteamCMD's login. Open Wallpaper Engine has no server and collects no data or analytics. It only contacts Valve: Steam when you use the Workshop or install assets, and Valve's server to download SteamCMD. Web wallpapers may load their own online content.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            DisclosureGroup("Prefer to sign in yourself? Log in with SteamCMD in Terminal", isExpanded: $showsTerminalLogin) {
                SteamTerminalLoginView(steamCmd: steamCmd, account: $username)
                    .padding(.top, 8)
            }
            .font(.callout)
            .frame(maxWidth: 460)
        }
    }

    private var fields: some View {
        VStack(spacing: 10) {
            TextField("Steam Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)

            if showGuardCode {
                TextField("Steam Guard Code", text: $guardCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }

            if let error = steamCmd.loginError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)

                if error == SteamCmdService.guardCodeRequiredError && !showGuardCode {
                    Button("Enter Steam Guard Code") {
                        showGuardCode = true
                    }
                    .buttonStyle(.link)
                }
            }

            HStack(spacing: 12) {
                Button("Log In") {
                    steamCmd.login(
                        username: username,
                        password: password,
                        guardCode: showGuardCode ? guardCode : nil
                    )
                }
                .glassButtonStyle(.prominent)
                .disabled(username.isEmpty || password.isEmpty || steamCmd.isLoggingIn)

                if !username.isEmpty {
                    Button("Use Cached Session") {
                        steamCmd.loginWithCachedSession(username: username)
                    }
                    .glassButtonStyle()
                    .disabled(steamCmd.isLoggingIn)
                }
            }

            if steamCmd.isLoggingIn {
                ProgressView()
                    .controlSize(.small)
                Text("Authenticating with Steam...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
