import AppKit
import SwiftUI

/// Steam 账号连接与 legacy-only 环境的按需依赖准备界面。
///
/// 交互原则：
/// - 通过系统官方安装窗口引导 Rosetta，由用户确认许可与授权；不触碰全局 Steam；
/// - 密码与 Steam Guard 验证码只用 SecureField 收集，提交后立即清空状态；
/// - 原生内容通道可用时不展示兼容组件；legacy-only 且缺依赖时才就地准备。
struct WorkshopAccountView: View {
    @Bindable var coordinator: WorkshopCoordinator
    let style: GlassStyle

    @GlassState private var username: String = ""
    @GlassState private var password: String = ""
    @GlassState private var guardCode: String = ""

    private var account: SteamAccountManager { coordinator.account }
    private var hasActiveDownload: Bool { coordinator.downloadProgress.activeItem != nil }
    private var canConnect: Bool { (account.nativeContentAvailable || account.isReady) && !hasActiveDownload && !account.isNativeContentCleaningUp }
    private var needsLegacyDependency: Bool { !account.nativeContentAvailable && !account.isReady }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                loginSection
            }
            .padding(16)
            .frame(maxWidth: 520, alignment: .leading)
        }
        .onAppear {
            username = account.rememberedUsername
            Task { await account.prepareForDownloads() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await account.rosettaInstaller.recheck() }
        }
        .onChange(of: account.loginState) { _, newValue in
            // 提交后立即从内存清除敏感输入。
            if case .loggingIn = newValue {
                password = ""
                guardCode = ""
            }
            if case .loggedIn = newValue {
                password = ""
                guardCode = ""
            }
            if newValue == .cancelled || newValue == .idle {
                password = ""; guardCode = ""
            }
            if case .failed = newValue { password = ""; guardCode = "" }
        }
        .onDisappear { password = ""; guardCode = "" }
    }

    // MARK: - Legacy-only 依赖准备

    private var legacyDependencyPreparation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("准备登录组件", systemImage: "shippingbox")
                .font(.callout.weight(.semibold))

            if account.isProbing {
                Label("正在检查登录环境…", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let report = account.report, case .rosettaRequired = report.status {
                rosettaGuide
            } else {
                if !account.taskState.displayText.isEmpty {
                    HStack(spacing: 8) {
                        if account.taskState.isBusy { ProgressView().controlSize(.small) }
                        Text(account.taskState.displayText)
                            .font(.caption)
                            .foregroundStyle(account.taskState.isBusy ? Color.secondary : Color.orange)
                    }
                }

                Button(account.taskState.isBusy ? "正在准备…" : "准备并继续") {
                    Task { await account.installSteamCMD() }
                }
                .buttonStyle(.glassProminent)
                .disabled(account.taskState.isBusy || account.rosettaInstaller.state.isBusy || hasActiveDownload || account.loginState.isActive)
            }
        }
        .padding(12)
        .background(style.panelBackground(cornerRadius: 14))
    }

    private var rosettaGuide: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("此 Mac 需要先安装 Rosetta 2。系统确认完成后会自动继续。")
                .font(.caption)
            switch account.rosettaInstaller.state {
            case .waiting, .checkingSteamCMD:
                HStack {
                    ProgressView().controlSize(.small)
                    Text(account.rosettaInstaller.state == .waiting ? "正在等待 Rosetta 安装…" : "Rosetta 已就绪，正在验证登录组件…")
                        .font(.caption)
                    Button("取消") { account.rosettaInstaller.cancel() }
                        .buttonStyle(.glass)
                }
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.orange)
                rosettaInstallButton("重试")
            case .cancelled:
                rosettaInstallButton("安装 Rosetta 2")
            case .ready:
                Label("Rosetta 2 已就绪，正在继续准备。", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .idle:
                rosettaInstallButton("安装 Rosetta 2")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }

    private func rosettaInstallButton(_ title: String) -> some View {
        Button(title) { account.rosettaInstaller.start() }
            .buttonStyle(.glassProminent)
            .disabled(account.taskState.isBusy || account.isProbing)
    }

    // MARK: - 登录

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Steam 账号", systemImage: "person.badge.key")
                    .font(.headline)
                Spacer()
                statusPill
            }

            if needsLegacyDependency {
                legacyDependencyPreparation
            } else {
                loginForm
            }
            if account.canRetryRememberingNativeSession {
                Text("登录状态未保存").foregroundStyle(.orange)
                Button(account.isSavingNativeSession ? "正在保存…" : "重试") {
                    Task { await account.retrySavingNativeSession() }
                }
                .buttonStyle(.glass).disabled(account.isSavingNativeSession)
            }
            if account.isNativeContentCleaningUp {
                Label("正在结束上次连接，请稍候。", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if account.isSignedIn {
                Button("退出账号") { account.signOut() }
                    .buttonStyle(.glass)
                    .disabled(hasActiveDownload || account.isNativeContentCleaningUp)
                    .accessibilityIdentifier("steam-sign-out")
                    .help(hasActiveDownload
                          ? "请先暂停当前下载"
                          : "退出并清除本应用保存的 Steam 登录；不影响系统 Steam 客户端")
            }
        }
    }

    private var statusPill: some View {
        WorkshopConnectionBadge(account: account)
    }

    @ViewBuilder
    private var loginForm: some View {
        switch account.loginState {
        case .awaitingUsername:
            HStack {
                TextField("Steam 账号名", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .accessibilityLabel("Steam 账号名")
                    .accessibilityIdentifier("steam-account-username")
                Button("继续") { account.submitUsername(username) }
                    .buttonStyle(.glassProminent)
                    .disabled(!SteamCMDCredentialPolicy.isValidAccountName(username.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        case .awaitingPassword:
            HStack {
                SecureField("Steam 密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .accessibilityLabel("Steam 密码")
                    .accessibilityIdentifier("steam-account-password")
                Button("继续") { let secret = password; password = ""; account.submitPassword(secret) }
                    .buttonStyle(.glassProminent)
                    .disabled(password.isEmpty)
            }
        case .awaitingGuardCode:
            HStack {
                TextField("Steam Guard 验证码", text: $guardCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .accessibilityLabel("Steam Guard 验证码")
                    .accessibilityIdentifier("steam-account-guard-code")
                Button("继续") { let code = guardCode; guardCode = ""; account.submitGuardCode(code) }
                    .buttonStyle(.glassProminent)
                    .disabled(!SteamCMDCredentialPolicy.isValidGuardCode(guardCode))
            }
        case .awaitingMobileConfirmation:
            Label("请在手机 Steam App 的「确认」页面批准本次登录，然后等待连接完成。", systemImage: "iphone.gen3")
                .font(.callout)
                .foregroundStyle(.orange)
        default:
            EmptyView()
        }

        HStack {
            if !account.loginState.isTerminal || account.loginState == .cancelled {
                if account.loginState.isTerminal || account.loginState == .idle {
                    Button("连接 Steam") {
                        account.startSignIn()
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!canConnect || account.taskState.isBusy)
                } else {
                    Button("取消") { account.cancelSignIn() }
                        .buttonStyle(.glass)
                }
            } else if case .failed = account.loginState {
                Button(account.nativeSavedSessionRetryAvailable ? "重试" : "重新登录") { account.startSignIn() }
                    .buttonStyle(.glassProminent)
                    .disabled(!canConnect)
                if account.nativeSavedSessionRetryAvailable {
                    Button("使用其他账号") { account.startNativeSignIn() }
                        .buttonStyle(.glass).disabled(!canConnect)
                }
            }
            if case .loggedIn = account.loginState {
                if account.nativeContentAvailable && !account.isNativeContentReady {
                    Button("重试") { account.startNativeSignIn() }
                        .buttonStyle(.glassProminent)
                        .disabled(hasActiveDownload || account.taskState.isBusy || account.isNativeContentCleaningUp)
                        .accessibilityIdentifier("steam-enable-live-progress")
                }
            }
        }

        if case .failed(let reason) = account.loginState {
            Text(WorkshopDisplayMessage.redacted(reason))
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }

    private var loginStateColor: Color {
        if case .failed = account.loginState { return .red }
        if account.loginState.isTerminal && account.isSignedIn { return .green }
        return .secondary
    }
}
