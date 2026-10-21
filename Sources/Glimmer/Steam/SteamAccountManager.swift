import Foundation
import Observation

/// 安装进度回调桥：把 URLSession 后台线程的回调安全地转到主线程，避免在 Sendable 闭包中捕获 self。
private final class InstallProgressBridge: @unchecked Sendable {
    struct Update: Sendable {
        var receivedBytes: Int64
        var expectedBytes: Int64?
        var fraction: Double?
    }

    private let deliver: @Sendable (Update) -> Void

    init(deliver: @escaping @Sendable (Update) -> Void) {
        self.deliver = deliver
    }

    var handler: @Sendable (SteamCMDInstaller.DownloadProgress) -> Void {
        { [deliver] progress in
            deliver(Update(
                receivedBytes: progress.receivedBytes,
                expectedBytes: progress.expectedBytes,
                fraction: progress.fraction
            ))
        }
    }
}

/// 账号与 SteamCMD 能力管理（F13 + F14 的界面状态层）。
///
/// 状态来源全部是真实探测/真实进程结果：
/// - `report` 来自 `SteamCMDCapabilityProbe`（真实执行 `steamcmd +quit`）；
/// - 登录状态来自 SteamCMD 真实输出或原生内容会话的登录确认；
/// - 「登录缓存存在」只是本机缓存事实，不等于任何下载权限。
@MainActor
@Observable
final class SteamAccountManager {

    enum TaskState: Sendable, Equatable {
        case idle
        case installing(progress: Double?, text: String)
        case uninstalling
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .installing, .uninstalling: return true
            default: return false
            }
        }

        var displayText: String {
            switch self {
            case .idle: return ""
            case .installing(let progress, let text):
                if let progress {
                    return String(format: "正在下载 SteamCMD %.1f%% · %@", progress * 100, text)
                }
                return "正在处理 SteamCMD：\(text)"
            case .uninstalling: return "正在移除应用内的 SteamCMD"
            case .failed(let message): return "操作失败：\(message)"
            }
        }
    }

    // MARK: - 可观察状态

    private(set) var report: SteamCMDReport?
    private(set) var isProbing = false
    private(set) var taskState: TaskState = .idle
    private(set) var loginState: SteamLoginState = .idle
    /// 应用自有 profile 中是否存在 SteamCMD 会话缓存文件（事实陈述，不代表任何下载权限或已验证身份）。
    private(set) var hasCachedSession = false
    /// 缓存证据的简短描述（不含账号名）。
    private(set) var cachedSessionDetail: String?
    private(set) var lastSignedInAt: Date?
    /// 当前占用 profile 的操作名（例如「登录」「下载 3818965540」），供 UI 提示串行等待。
    private(set) var profileOperationOwner: String?
    /// 用户上一次使用的账号名（仅内存，用于登录表单预填；不落盘、不写日志）。
    var rememberedUsername: String = ""

    let loginStatus = SteamLoginStatusModel()
    let layout: SteamCMDLayout
    private let gate: SteamProfileGate

    @ObservationIgnored private var storedRosettaInstaller: RosettaInstallController?
    var rosettaInstaller: RosettaInstallController {
        if let storedRosettaInstaller { return storedRosettaInstaller }
        let controller = RosettaInstallController { [weak self] in
            guard let self else { return }
            while self.isProbing {
                try? await Task.sleep(for: .milliseconds(100))
            }
            await self.refreshCapability()
        }
        storedRosettaInstaller = controller
        return controller
    }

    @ObservationIgnored var onDownloadSessionReady: (@MainActor () -> Void)?
    private(set) var nativeContentBroker: SteamContentBroker?
    private(set) var isUsingNativeSignIn = false
    private var nativeSessionAcknowledged = false
    private var nativeShutdownRequested = false
    private var nativeAwaitingMobileApproval = false
    private var legacyStateBeforeNativeSignIn: SteamLoginState?
    private(set) var isNativeContentCleaningUp = false
    private(set) var nativeSavedSessionRetryAvailable = false
    private(set) var nativeSessionNotice: String?
    private(set) var isSavingNativeSession = false
    var canRetryRememberingNativeSession: Bool {
        isNativeContentReady && nativeSessionPersistenceEnabled && nativeContentBroker?.hasSavedSession == false
    }
    @ObservationIgnored private let sessionStore: (any SteamContentSessionStoring)?
    private var preparedForDownloads = false
    var nativeSessionPersistenceEnabled: Bool { sessionStore != nil }
    @ObservationIgnored private let nativeExecutableURL: URL
    @ObservationIgnored private let savedSessionRetryDelays: [Duration]
    @ObservationIgnored private var nativeLoginTask: Task<Void, Never>?
    @ObservationIgnored private var nativeCleanupTask: Task<Void, Never>?
    private var nativeCleanupGeneration = UUID()
    var nativeContentAvailable: Bool { FileManager.default.isExecutableFile(atPath: nativeExecutableURL.path) }
    var isNativeContentReady: Bool {
        guard nativeSessionAcknowledged, let broker = nativeContentBroker, broker.isReady,
              case .loggedIn = broker.state else { return false }
        return true
    }

    private var loginSession: SteamLoginSession?
    private var loginTask: Task<SteamLoginState, Never>?
    private var clearCacheTask: Task<Void, Never>?
    private var installProgress: Double?
    @ObservationIgnored private let capabilityOperation: @Sendable (SteamCMDLayout) async -> SteamCMDReport
    @ObservationIgnored private let makeLoginSession: @MainActor (URL, SteamCMDLayout) -> SteamLoginSession
    private var attemptedCachedRestoration = false
    private var loginGeneration = UUID()
    private var clearCacheGeneration = UUID()

    private static let sessionFileName = "account-session.json"

    init(layout: SteamCMDLayout = SteamCMDLayout(),
         capabilityOperation: @escaping @Sendable (SteamCMDLayout) async -> SteamCMDReport = { await SteamCMDCapabilityProbe(layout: $0).probe() },
         makeLoginSession: @escaping @MainActor (URL, SteamCMDLayout) -> SteamLoginSession = { SteamLoginSession(executable: $0, layout: $1) },
         nativeContentExecutableURL: URL? = nil,
         sessionStore: (any SteamContentSessionStoring)? = nil,
         savedSessionRetryDelays: [Duration] = [.seconds(2), .seconds(5)]) {
        self.layout = layout
        self.sessionStore = sessionStore
        // Bounded startup recovery only; this is not a user-facing setting.
        self.savedSessionRetryDelays = Array(savedSessionRetryDelays.prefix(2)).map {
            max(.zero, min($0, .seconds(30)))
        }
        self.gate = SteamProfileGateRegistry.gate(for: layout)
        self.capabilityOperation = capabilityOperation
        self.makeLoginSession = makeLoginSession
        self.nativeExecutableURL = nativeContentExecutableURL ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/SteamContent/GlimmerSteamContent")
        loadSessionRecord()
        refreshCachedSessionState()
    }

    // MARK: - 能力探测与安装

    var isReady: Bool { report?.status.isReady ?? false }

    var executableURL: URL { layout.executableURL }

    /// 是否存在可用于下载的账号会话缓存（账号名可从应用自有 profile 中临时读取，或用户已输入）。
    var canAttemptAuthenticatedDownload: Bool {
        if isNativeContentReady { return true }
        if !rememberedUsername.isEmpty, SteamCMDCredentialPolicy.isValidAccountName(rememberedUsername) { return true }
        return WorkshopDownloadService.cachedAccountName(layout: layout) != nil
    }

    /// 用于下载的账号名（内存中的输入优先，其次临时读取应用自有 profile；不写日志）。
    var transientAccountNameForDownload: String? {
        if SteamCMDCredentialPolicy.isValidAccountName(rememberedUsername) { return rememberedUsername }
        return WorkshopDownloadService.cachedAccountName(layout: layout)
    }

    var statusTitle: String {
        guard let report else { return "尚未检测" }
        return report.status.displayText
    }

    /// 真实探测（不修改任何系统状态；与登录/下载共享 profile 闸门）。
    func refreshCapability() async {
        guard !isProbing else { return }
        isProbing = true
        // probe 会真实执行 steamcmd +quit，因此同样要占用 profile 闸门。
        let acquired = await gate.acquire(owner: "能力检测")
        if acquired {
            let result = await capabilityOperation(layout)
            await gate.release()
            report = result
            WorkshopLog.info("SteamCMD 能力探测：\(result.status.displayText)")
        } else {
            WorkshopLog.info("能力检测已取消（未取得 profile 闸门）")
        }
        isProbing = false
        refreshCachedSessionState()
        restoreCachedSessionIfPossible()
    }

    /// 下载官方安装包并展开到应用管理目录（不安装系统组件、不触碰全局 Steam）。
    func installSteamCMD() async {
        guard !taskState.isBusy else { return }
        taskState = .installing(progress: nil, text: "正在连接官方下载源")
        installProgress = nil
        let installer = SteamCMDInstaller(layout: layout)
        let bridge = InstallProgressBridge { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.installProgress = update.fraction
                let text: String
                if let expected = update.expectedBytes {
                    let formatter = ByteCountFormatter()
                    formatter.countStyle = .file
                    text = "\(formatter.string(fromByteCount: update.receivedBytes)) / \(formatter.string(fromByteCount: expected))"
                } else {
                    text = ByteCountFormatter.string(fromByteCount: update.receivedBytes, countStyle: .file)
                }
                self.taskState = .installing(progress: update.fraction, text: text)
            }
        }
        do {
            _ = try await installer.downloadAndInstall(progress: bridge.handler)
            taskState = .installing(progress: 1, text: "正在验证可执行性")
            await refreshCapability()
            taskState = .idle
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            taskState = .failed(WorkshopLog.sanitize(message))
            WorkshopLog.notice("SteamCMD 安装失败：\(WorkshopLog.sanitize(message))")
        }
    }

    /// 移除应用管理目录内的 SteamCMD 与登录缓存（不动系统与全局 Steam）。
    func uninstallSteamCMD() async {
        guard !taskState.isBusy else { return }
        if loginSession != nil || loginTask != nil { cancelSignIn() }
        taskState = .uninstalling
        // 等其它 profile 操作（下载）结束再删除，避免删掉正在使用的文件。
        let acquired = await gate.acquire(owner: "清理")
        if acquired {
            await SteamCMDInstaller(layout: layout).uninstall()
            await gate.release()
        } else {
            taskState = .failed("已有其它 Steam 操作在进行，请稍后再清理。")
            return
        }
        taskState = .idle
        await refreshCapability()
    }

    func clearTaskError() {
        if case .failed = taskState { taskState = .idle }
    }

    // MARK: - 登录

    var isSignedIn: Bool {
        if case .loggedIn = loginState { return true }
        return false
    }

    /// 发起真实交互式登录流程；用户需要在界面上输入密码/验证码。
    func startSignIn() {
        if nativeSavedSessionRetryAvailable { retryNativeSavedSession(); return }
        if nativeContentAvailable { startNativeSignIn(); return }
        startLegacySignIn()
    }

    /// Kept in the low-frequency compatibility section when native auth is unavailable.
    func startLegacySignIn() {
        guard !isNativeContentReady, nativeCleanupTask == nil, !nativeShutdownRequested else { return }
        preparedForDownloads = true
        nativeSavedSessionRetryAvailable = false
        nativeSessionNotice = nil
        attemptedCachedRestoration = true
        let entered = rememberedUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let retryingFailure: Bool
        if case .failed = loginState { retryingFailure = true } else { retryingFailure = false }
        if entered.isEmpty, !retryingFailure, hasCachedSession,
           let cached = WorkshopDownloadService.cachedAccountName(layout: layout) {
            beginSignIn(username: cached, restoringCache: true)
        } else {
            beginSignIn(username: entered, restoringCache: false)
        }
    }

    /// Manual native authentication never reads or promotes legacy cached credentials.
    /// A helper startup ACK alone is insufficient: readiness requires loggedIn ACK.
    func startNativeSignIn() {
        guard nativeContentAvailable, !nativeShutdownRequested, !isUsingNativeSignIn, !taskState.isBusy, loginTask == nil,
              nativeLoginTask == nil, nativeCleanupTask == nil, clearCacheTask == nil,
              nativeContentBroker?.isDownloading != true, !isNativeContentReady else { return }
        attemptedCachedRestoration = true
        preparedForDownloads = true
        nativeSavedSessionRetryAvailable = false
        nativeSessionNotice = nil
        if case .loggedIn = loginState { legacyStateBeforeNativeSignIn = loginState }
        else { legacyStateBeforeNativeSignIn = nil }
        loginGeneration = UUID()
        isUsingNativeSignIn = true
        nativeSessionAcknowledged = false
        loginStatus.reset()
        loginStatus.startedAt = Date()
        let entered = rememberedUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        rememberedUsername = SteamCMDCredentialPolicy.isValidAccountName(entered) ? entered : ""
        setNativeLoginState(rememberedUsername.isEmpty ? .awaitingUsername : .awaitingPassword)
        loginStatus.append(line: nativeSessionPersistenceEnabled
            ? "连接后将把登录会话保存到 macOS 钥匙串，便于下次自动恢复；不保存密码或验证码。"
            : "此临时环境不保存登录会话；连接后可显示真实下载进度。")
    }

    private func setNativeLoginState(_ state: SteamLoginState) {
        loginState = state
        loginStatus.state = state
    }

    /// Explicitly injected stores only. Review/tests/default coordinators never
    /// touch Keychain merely because a helper or legacy cached profile exists.
    func prepareForDownloads() async {
        guard !preparedForDownloads else {
            if let task = nativeLoginTask { await task.value }
            return
        }
        preparedForDownloads = true
        guard !nativeShutdownRequested, !isUsingNativeSignIn, loginTask == nil,
              nativeLoginTask == nil, clearCacheTask == nil else { return }
        if nativeContentAvailable, sessionStore != nil {
            if let task = beginSavedNativeRestoration(allowLegacyFallback: true, automaticRetry: true) { await task.value }
        } else {
            await refreshCapability()
        }
    }

    func retryNativeSavedSession() {
        _ = beginSavedNativeRestoration(allowLegacyFallback: false)
    }

    private func beginSavedNativeRestoration(allowLegacyFallback: Bool, automaticRetry: Bool = false) -> Task<Void, Never>? {
        guard nativeContentAvailable, sessionStore != nil, !nativeShutdownRequested,
              !isUsingNativeSignIn, !taskState.isBusy, loginTask == nil, nativeLoginTask == nil,
              nativeCleanupTask == nil, clearCacheTask == nil,
              nativeContentBroker?.isDownloading != true, !isNativeContentReady else { return nil }
        let broker: SteamContentBroker
        do { broker = try makeNativeBroker() }
        catch {
            nativeSavedSessionRetryAvailable = true
            setNativeLoginState(.failed(reason: "无法准备已保存的 Steam 连接，请稍后重试。"))
            return nil
        }
        let ticket = UUID()
        loginGeneration = ticket
        isUsingNativeSignIn = true
        nativeSavedSessionRetryAvailable = false
        nativeSessionNotice = "正在恢复已保存的 Steam 登录。"
        loginStatus.reset()
        loginStatus.startedAt = Date()
        setNativeLoginState(.preparing)
        observeNativeBroker(broker, ticket: ticket)
        let task = Task { [weak self, broker] in
            do {
                let available = try await broker.loadSavedSessionAvailability()
                guard let self, !Task.isCancelled, self.loginGeneration == ticket,
                      self.nativeContentBroker === broker else { return }
                if !available {
                    self.nativeLoginTask = nil
                    self.isUsingNativeSignIn = false
                    self.nativeSessionNotice = nil
                    self.setNativeLoginState(.idle)
                    self.detachNativeContent()
                    let cleanup = self.nativeCleanupTask
                    await cleanup?.value
                    guard !Task.isCancelled, self.loginGeneration == ticket, !self.nativeShutdownRequested else { return }
                    if allowLegacyFallback { await self.refreshCapability() }
                    else { self.startNativeSignIn() }
                    return
                }
                self.attemptedCachedRestoration = true
                let retryDelays = automaticRetry ? self.savedSessionRetryDelays : []
                var retryIndex = 0
                while true {
                    do {
                        try Task.checkCancellation()
                        try await broker.restoreSavedSession()
                        break
                    } catch {
                        guard !Task.isCancelled, self.loginGeneration == ticket,
                              self.nativeContentBroker === broker, !self.nativeShutdownRequested,
                              retryIndex < retryDelays.count,
                              Self.isTransientSavedSessionFailure(error) else { throw error }
                        // auth_failed is emitted after the helper closes the old
                        // auth session. A timeout drains the owned helper first.
                        // Neither path retries credentials or fabricates readiness.
                        self.nativeSessionAcknowledged = false
                        self.nativeSessionNotice = "Steam 连接暂时中断，正在重试…"
                        self.setNativeLoginState(.preparing)
                        let delay = retryDelays[retryIndex]
                        retryIndex += 1
                        try await Task.sleep(for: delay)
                        try Task.checkCancellation()
                        guard self.loginGeneration == ticket,
                              self.nativeContentBroker === broker, !self.nativeShutdownRequested else { return }
                    }
                }
                guard !Task.isCancelled, self.loginGeneration == ticket,
                      self.nativeContentBroker === broker, broker.isReady,
                      case .loggedIn = broker.state else { return }
                self.finishNativeSignIn(broker)
            } catch {
                guard let self, self.loginGeneration == ticket, self.nativeContentBroker === broker else { return }
                self.nativeLoginTask = nil
                self.isUsingNativeSignIn = false
                self.nativeSessionAcknowledged = false
                self.attemptedCachedRestoration = true // Failed native restore must not become a legacy login.
                let failure = error as? SteamContentBrokerError
                let needsManualSignIn = failure == .savedSessionRevoked
                    || failure == .savedSessionUnavailable
                    || failure == .savedSessionAccessFailed
                self.nativeSavedSessionRetryAvailable = !needsManualSignIn
                let message: String
                if failure == .savedSessionAccessFailed {
                    message = "无法读取已保存的旧 Steam 登录；应用不会反复请求旧钥匙串访问。请重新登录，旧钥匙串项目不会被删除。"
                } else if needsManualSignIn {
                    message = "已保存的 Steam 登录已失效或不可用，请重新输入账号和密码。"
                } else { message = "暂时无法恢复 Steam 登录；已保留会话，请检查网络后重试。" }
                self.nativeSessionNotice = broker.sessionPersistenceMessage ?? message
                self.setNativeLoginState(.failed(reason: message))
                self.loginStatus.finishedAt = Date()
                self.detachNativeContent()
            }
        }
        nativeLoginTask = task
        return task
    }

    /// Retry only fixed connection failures. Revocation, Keychain denial, invalid
    /// protocol/component errors and user cancellation require their existing path.
    private static func isTransientSavedSessionFailure(_ error: Error) -> Bool {
        guard let error = error as? SteamContentBrokerError else { return false }
        switch error {
        case .timeout, .helperRejected("steam_disconnected"), .helperRejected("steam_auth_timeout"): return true
        default: return false
        }
    }

    func retrySavingNativeSession() async {
        guard canRetryRememberingNativeSession, !isSavingNativeSession,
              let broker = nativeContentBroker else { return }
        let ticket = loginGeneration
        isSavingNativeSession = true
        _ = await broker.retryPersistCurrentSession()
        guard loginGeneration == ticket, nativeContentBroker === broker else {
            isSavingNativeSession = false
            return
        }
        isSavingNativeSession = false
        nativeSessionNotice = broker.sessionPersistenceMessage
    }

    private func makeNativeBroker() throws -> SteamContentBroker {
        if let existing = nativeContentBroker { return existing }
        let workspace = layout.root.deletingLastPathComponent().appendingPathComponent("SteamContent", isDirectory: true)
        if !FileManager.default.fileExists(atPath: workspace.path) {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        let values = try workspace.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw SteamContentBrokerError.invalidWorkspace }
        let broker = try SteamContentBroker(executableURL: nativeExecutableURL,
            workspaceURL: workspace.resolvingSymlinksInPath().standardizedFileURL, sessionStore: sessionStore)
        nativeContentBroker = broker
        return broker
    }

    private func observeNativeBroker(_ broker: SteamContentBroker, ticket: UUID) {
        broker.onStateChange = { [weak self, weak broker] state in
            guard let self, let broker, self.loginGeneration == ticket,
                  self.nativeContentBroker === broker else { return }
            if case .loggedIn = state { return } // Completion owns authentication publication.
            if state == .loggingIn, self.nativeAwaitingMobileApproval {
                self.setNativeLoginState(.awaitingMobileConfirmation)
                return
            }
            if case .failed = state {
                self.nativeSessionAcknowledged = false
                self.nativeAwaitingMobileApproval = false
            }
            self.setNativeLoginState(state)
            if state == .awaitingMobileConfirmation, broker.challenge?.kind == .deviceConfirmation {
                self.nativeAwaitingMobileApproval = true
                // This selects SteamKit's phone-approval method, not approval itself.
                // Keep awaitingMobileConfirmation until the actual auth_result ACK.
                do { try broker.respondToChallenge(accepted: true) }
                catch { self.loginStatus.append(line: "手机确认方式尚未启用，请取消后重试。") }
            }
        }
    }

    private func finishNativeSignIn(_ broker: SteamContentBroker) {
        nativeLoginTask = nil
        isUsingNativeSignIn = false
        nativeSessionAcknowledged = true
        nativeSavedSessionRetryAvailable = false
        legacyStateBeforeNativeSignIn = nil
        nativeAwaitingMobileApproval = false
        setNativeLoginState(.loggedIn(userID: nil))
        loginStatus.finishedAt = Date()
        lastSignedInAt = Date()
        nativeSessionNotice = broker.sessionPersistenceMessage ?? (broker.hasSavedSession
            ? "已保存 Steam 登录，下次启动会自动恢复。" : "此连接未保存到本地。")
        loginStatus.append(line: "Steam 已连接，实时下载进度已启用。")
        onDownloadSessionReady?()
    }

    /// A download may discover that an otherwise idle helper lost its CM session.
    /// The failed download waiter is resumed only after that helper has drained and
    /// stopped. Restore exactly this saved identity through a new helper/login ACK;
    /// never use this path for user cancellation, shutdown, or ordinary CDN errors.
    func recoverNativeContentSessionAfterAuthenticationLoss(from broker: SteamContentBroker) async -> SteamContentBroker? {
        guard !Task.isCancelled, !nativeShutdownRequested, sessionStore != nil,
              nativeContentBroker === broker, broker.hasSavedSession, !broker.isDownloading,
              nativeLoginTask == nil, nativeCleanupTask == nil, clearCacheTask == nil else { return nil }
        let ticket = UUID()
        loginGeneration = ticket
        isUsingNativeSignIn = true
        nativeSessionAcknowledged = false
        nativeSavedSessionRetryAvailable = false
        nativeSessionNotice = "Steam 连接已中断，正在恢复已保存的登录。"
        loginStatus.reset(); loginStatus.startedAt = Date()
        setNativeLoginState(.preparing)
        observeNativeBroker(broker, ticket: ticket)
        do {
            try Task.checkCancellation()
            try await broker.restoreSavedSession()
            try Task.checkCancellation()
            guard loginGeneration == ticket, nativeContentBroker === broker, broker.isReady,
                  case .loggedIn = broker.state, !nativeShutdownRequested else { return nil }
            finishNativeSignIn(broker)
            return broker
        } catch {
            guard loginGeneration == ticket, nativeContentBroker === broker else { return nil }
            isUsingNativeSignIn = false
            nativeSessionAcknowledged = false
            let failure = error as? SteamContentBrokerError
            if Task.isCancelled || failure == .cancelled {
                setNativeLoginState(.cancelled)
            } else {
                let needsManualSignIn = failure == .savedSessionRevoked
                    || failure == .savedSessionUnavailable
                    || failure == .savedSessionAccessFailed
                nativeSavedSessionRetryAvailable = !needsManualSignIn
                let message = needsManualSignIn
                    ? (failure == .savedSessionAccessFailed
                        ? "无法读取已保存的旧 Steam 登录；应用不会反复请求旧钥匙串访问。请重新登录，旧钥匙串项目不会被删除。"
                        : "已保存的 Steam 登录已失效，请重新输入账号和密码。")
                    : "暂时无法恢复 Steam 登录；已保留会话，请检查网络后重试。"
                nativeSessionNotice = broker.sessionPersistenceMessage ?? message
                setNativeLoginState(.failed(reason: message))
            }
            loginStatus.finishedAt = Date()
            detachNativeContent()
            return nil
        }
    }

    private func beginNativeCredentials(password: String) {
        guard isUsingNativeSignIn, loginState == .awaitingPassword,
              nativeLoginTask == nil, !password.isEmpty,
              SteamCMDCredentialPolicy.isValidAccountName(rememberedUsername) else { return }
        let ticket = loginGeneration
        let broker: SteamContentBroker
        do { broker = try makeNativeBroker() }
        catch {
            isUsingNativeSignIn = false
            setNativeLoginState(.failed(reason: "无法准备下载连接，请检查应用管理目录权限后重试。"))
            loginStatus.finishedAt = Date()
            return
        }
        setNativeLoginState(.loggingIn)
        observeNativeBroker(broker, ticket: ticket)
        let username = rememberedUsername
        nativeLoginTask = Task { [weak self, broker] in
            do {
                try await broker.loginCredentials(username: username, password: password)
                guard let self, !Task.isCancelled, self.loginGeneration == ticket,
                      self.nativeContentBroker === broker, broker.isReady,
                      case .loggedIn = broker.state else { return }
                self.finishNativeSignIn(broker)
            } catch {
                guard let self, self.loginGeneration == ticket, self.nativeContentBroker === broker else { return }
                self.nativeLoginTask = nil
                self.isUsingNativeSignIn = false
                self.nativeSessionAcknowledged = false
                self.setNativeLoginState(.failed(reason: "Steam 连接未完成，请重试；如需验证码请检查 Steam 邮件或手机。"))
                self.loginStatus.finishedAt = Date()
                // Drop this failed session before retry. Late helper events cannot republish it.
                self.detachNativeContent()
            }
        }
    }

    /// Detaches immediately; async draining affects only this owned native helper.
    private func detachNativeContent(clearSavedSession: Bool = false) {
        nativeSessionAcknowledged = false
        nativeAwaitingMobileApproval = false
        isUsingNativeSignIn = false
        nativeLoginTask?.cancel()
        nativeLoginTask = nil
        let broker = nativeContentBroker
        guard broker != nil || (clearSavedSession && sessionStore != nil) else { return }
        broker?.onStateChange = nil
        nativeContentBroker = nil
        let store = sessionStore
        let previous = nativeCleanupTask
        let cleanupTicket = UUID()
        nativeCleanupGeneration = cleanupTicket
        isNativeContentCleaningUp = true
        nativeCleanupTask = Task { [weak self] in
            await previous?.value
            var notice: String?
            if let broker {
                if clearSavedSession { await broker.logout() }
                else { await broker.cancelAuthentication() }
                await broker.shutdown()
                if clearSavedSession { notice = broker.sessionPersistenceMessage }
            } else if clearSavedSession, let store {
                do { try await store.delete(); notice = "已清除保存的 Steam 登录。" }
                catch { notice = "未能清除保存的登录，请重试退出登录。" }
            }
            guard let self, self.nativeCleanupGeneration == cleanupTicket else { return }
            if clearSavedSession { self.nativeSessionNotice = notice }
            self.nativeCleanupTask = nil
            self.isNativeContentCleaningUp = false
        }
    }

    func shutdownNativeContent() async {
        nativeShutdownRequested = true
        loginGeneration = UUID()
        detachNativeContent()
        let cleanup = nativeCleanupTask
        await cleanup?.value
        nativeCleanupTask = nil
    }

    /// One attempt per application lifetime after a real ready capability probe.
    /// Cache existence never sets authenticated state; the existing interactive
    /// session must still receive Steam's login ACK and finish normally.
    private func restoreCachedSessionIfPossible() {
        guard !attemptedCachedRestoration, isReady, hasCachedSession,
              !taskState.isBusy, clearCacheTask == nil, loginTask == nil,
              !isUsingNativeSignIn, nativeLoginTask == nil, !isNativeContentReady,
              loginState == .idle,
              let cached = WorkshopDownloadService.cachedAccountName(layout: layout) else { return }
        attemptedCachedRestoration = true
        beginSignIn(username: cached, restoringCache: true)
    }

    private func beginSignIn(username: String, restoringCache: Bool) {
        guard !taskState.isBusy else { return }
        guard isReady else {
            loginStatus.append(line: "SteamCMD 尚未就绪，请先完成安装与能力检测。")
            return
        }
        guard loginTask == nil, nativeLoginTask == nil, !isUsingNativeSignIn else { return }
        guard clearCacheTask == nil else {
            loginStatus.append(line: "正在清理上次会话，请稍后再连接。")
            return
        }

        if !username.isEmpty, !SteamCMDCredentialPolicy.isValidAccountName(username) {
            loginStatus.reset()
            loginStatus.append(line: "账号名格式不正确：只允许字母、数字与 _ - .（3–64 位），请修正后再试。")
            return
        }

        loginStatus.reset()
        loginStatus.startedAt = Date()
        loginState = .preparing
        loginStatus.state = .preparing
        loginStatus.append(line: restoringCache
            ? "正在验证已有 SteamCMD 会话缓存；需要密码或 Steam Guard 时，请在本页继续。"
            : username.isEmpty ? "已启动 SteamCMD 控制台，等待输入账号名。" : "已启动 SteamCMD 控制台，将使用你填写的账号名（不记录、不显示）。")

        let ticket = UUID()
        loginGeneration = ticket
        let session = makeLoginSession(layout.executableURL, layout)
        loginSession = session

        // 状态回调只负责更新界面状态；最终「已登录」由 finishSignIn 在
        // 会话完成路径（优雅退出 + 缓存写入）真正结束后发布。
        session.start(configuredUsername: username.isEmpty ? nil : username) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.loginGeneration == ticket else { return }
                switch event {
                case .session(let state, _):
                    // Final success is published only by the completion path,
                    // after process finalization and profile-gate release.
                    if case .loggedIn = state { break }
                    self.loginState = state
                    self.loginStatus.state = state
                case .line(let line):
                    self.loginStatus.append(line: line)
                }
            }
        }

        loginTask = Task { [weak self, session] in
            let state = await session.waitForCompletion()
            await MainActor.run { [weak self] in
                guard let self, self.loginGeneration == ticket else { return }
                self.finishSignIn(state: state)
            }
            return state
        }
    }

    /// 提交账号名（校验后经 stdin 以 `login <account>` 发送）。
    func submitUsername(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SteamCMDCredentialPolicy.isValidAccountName(trimmed) else {
            loginStatus.append(line: "账号名格式不正确：只允许字母、数字与 _ - .（3–64 位）。")
            return
        }
        rememberedUsername = trimmed
        if isUsingNativeSignIn {
            guard loginState == .awaitingUsername else { return }
            setNativeLoginState(.awaitingPassword)
        } else { loginSession?.submitUsername(trimmed) }
    }

    /// 提交密码（仅当 SteamCMD 要求时；只经 stdin，不保存）。
    func submitPassword(_ value: String) {
        guard SteamCMDCredentialPolicy.isSafeSecretLine(value) else {
            loginStatus.append(line: "密码包含不允许的控制字符，请重新输入。")
            return
        }
        if isUsingNativeSignIn {
            beginNativeCredentials(password: value)
        } else { loginSession?.submitPassword(value) }
    }

    /// 提交 Steam Guard 验证码（只经 stdin，不保存）。
    func submitGuardCode(_ value: String) {
        guard SteamCMDCredentialPolicy.isValidGuardCode(value) else {
            loginStatus.append(line: "验证码格式不正确，请输入 4–32 位字母数字。")
            return
        }
        if isUsingNativeSignIn {
            guard loginState == .awaitingGuardCode else { return }
            do { try nativeContentBroker?.respondToChallenge(code: value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            catch { loginStatus.append(line: "验证码尚未提交，请检查后重试。") }
        } else { loginSession?.submitGuardCode(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func cancelSignIn() {
        let preservedLegacyState = isUsingNativeSignIn ? legacyStateBeforeNativeSignIn : nil
        if isUsingNativeSignIn {
            if sessionStore != nil { nativeSavedSessionRetryAvailable = true }
            nativeSessionNotice = sessionStore == nil ? "登录已取消。" : "登录已取消；不会删除已保存的会话。"
        }
        legacyStateBeforeNativeSignIn = nil
        if isUsingNativeSignIn {
            detachNativeContent()
        }
        attemptedCachedRestoration = true
        preparedForDownloads = true
        loginGeneration = UUID()
        loginSession?.cancel()
        loginSession = nil
        loginTask?.cancel()
        loginTask = nil
        loginState = preservedLegacyState ?? .cancelled
        loginStatus.state = loginState
        loginStatus.finishedAt = Date()
    }

    /// 退出登录：结束登录会话，并在**不与其它 profile 操作冲突**的前提下清除应用自有缓存。
    ///
    /// 说明（R12）：退出不会强杀正在进行的下载；若此刻有其它 Steam 操作占用 profile，
    /// 会等待其结束（最多约 5 秒）后再清除，并在界面上如实提示。
    func signOut() {
        legacyStateBeforeNativeSignIn = nil
        nativeSavedSessionRetryAvailable = false
        preparedForDownloads = true
        detachNativeContent(clearSavedSession: true)
        attemptedCachedRestoration = true
        preparedForDownloads = true
        loginGeneration = UUID()
        loginSession?.cancel()
        loginSession = nil
        loginTask?.cancel()
        loginTask = nil
        loginState = .idle
        loginStatus.state = .idle
        lastSignedInAt = nil
        // 账号名只用于本次运行的表单预填；退出后不再保留。
        rememberedUsername = ""
        saveSessionRecord()
        clearCacheTask?.cancel()
        let ticket = UUID()
        clearCacheGeneration = ticket
        clearCacheTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.clearCacheGeneration == ticket { self.clearCacheTask = nil } }
            var waited = 0
            while await self.gate.isBusy, waited < 20 {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
                waited += 1
            }
            let acquired = await self.gate.acquire(owner: "退出清理")
            guard acquired else {
                await MainActor.run {
                    self.loginStatus.append(line: "仍有其它 Steam 操作占用账户配置，未清除缓存；请等它结束后重试。")
                }
                return
            }
            self.clearLoginCache()
            await self.gate.release()
            await MainActor.run {
                self.refreshCachedSessionState()
                self.loginStatus.append(line: self.hasCachedSession ? "已结束会话，但缓存文件仍在（可稍后重试清除）。" : "已清除应用内 Steam 登录缓存。")
            }
        }
    }

    /// 标记会话失效（下载过程中 Steam 报告未登录时调用）。不做任何「假装已登录」的状态。
    func markSessionExpired(reason: String) {
        detachNativeContent()
        attemptedCachedRestoration = true
        preparedForDownloads = true
        loginGeneration = UUID()
        loginSession?.cancel()
        loginSession = nil
        loginTask?.cancel()
        loginTask = nil
        loginState = .failed(reason: reason)
        loginStatus.state = loginState
        lastSignedInAt = nil
        saveSessionRecord()
        refreshCachedSessionState()
        loginStatus.append(line: "会话已失效，请在需要时重新登录（不会自动重试登录）。")
    }

    private func finishSignIn(state: SteamLoginState) {
        loginTask = nil
        loginSession = nil
        // 以会话完成路径的结果为准（此时优雅退出/缓存写入已经结束）。
        loginState = state
        loginStatus.state = state
        loginStatus.finishedAt = Date()
        switch state {
        case .loggedIn:
            lastSignedInAt = Date()
            saveSessionRecord()
            refreshCachedSessionState()
            WorkshopLog.notice("SteamCMD 登录成功（不记录账号名）")
            onDownloadSessionReady?()
        case .failed(let reason):
            refreshCachedSessionState()
            WorkshopLog.notice("SteamCMD 登录未完成：\(WorkshopLog.sanitize(reason))")
        case .cancelled:
            refreshCachedSessionState()
        default:
            break
        }
    }

    // MARK: - 缓存与会话记录

    /// 重新评估「应用自有 profile 中的缓存证据」（事实陈述，不代表已验证身份或下载权限）。
    func refreshCachedSessionState() {
        let manager = FileManager.default
        // 只认应用管理目录内的 profile（绝不读取用户全局 Steam）。
        guard WorkshopProjectResolver.isInside(layout.homeURL, root: layout.root) else {
            hasCachedSession = false
            cachedSessionDetail = "profile 目录不在应用管理目录内，已忽略"
            return
        }
        var evidences: [String] = []
        if layout.loginCacheFiles.contains(where: { SteamCachedLoginProfile.read($0, layout: layout) != nil }) {
            evidences.append("应用内 Steam 会话缓存")
        }
        if let contents = try? manager.contentsOfDirectory(atPath: layout.homeURL.path) {
            let ssfn = contents.filter { $0.hasPrefix("ssfn") }
            if !ssfn.isEmpty { evidences.append("ssfn 凭据文件 \(ssfn.count) 个") }
        }
        hasCachedSession = !evidences.isEmpty
        cachedSessionDetail = evidences.isEmpty ? nil : evidences.joined(separator: " + ")
    }

    /// 只清除应用自有 profile 内的会话文件（带目录归属校验）。
    private func clearLoginCache() {
        let manager = FileManager.default
        // 安全护栏：只允许操作应用管理目录内的 profile。
        guard WorkshopProjectResolver.isInside(layout.homeURL, root: layout.root) else {
            WorkshopLog.notice("拒绝清除 profile：目录不在应用管理目录内")
            return
        }
        let targets = layout.loginCacheFiles
        for target in targets where layout.isSafeProfileLocation(target) && manager.fileExists(atPath: target.path) {
            try? manager.removeItem(at: target)
        }
        if let contents = try? manager.contentsOfDirectory(atPath: layout.homeURL.path) {
            for name in contents where name.hasPrefix("ssfn") {
                let target = layout.homeURL.appendingPathComponent(name)
                if layout.isSafeProfileLocation(target) { try? manager.removeItem(at: target) }
            }
        }
        refreshCachedSessionState()
    }

    /// 会话记录只保存「是否登录过 + 时间」，不保存账号名、密码或令牌。
    private struct SessionRecord: Codable {
        var schemaVersion: Int
        var lastSignedInAt: Date?
    }

    private var sessionRecordURL: URL {
        layout.homeURL.appendingPathComponent(Self.sessionFileName, isDirectory: false)
    }

    private func loadSessionRecord() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: sessionRecordURL),
              let record = try? decoder.decode(SessionRecord.self, from: data) else { return }
        lastSignedInAt = record.lastSignedInAt
    }

    private func saveSessionRecord() {
        let record = SessionRecord(schemaVersion: 1, lastSignedInAt: lastSignedInAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(at: layout.homeURL, withIntermediateDirectories: true)
        try? data.write(to: sessionRecordURL, options: .atomic)
    }
}
