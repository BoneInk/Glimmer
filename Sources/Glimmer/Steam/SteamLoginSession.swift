import Foundation
import Observation

/// SteamCMD 交互式登录（F14）。
///
/// 安全设计（必须保持）：
/// - 账号名、密码与 Steam Guard 验证码**只**通过子进程 stdin 写入（`login <account>` 是
///   官方文档化的控制台命令），绝不进入 argv、环境变量、日志、磁盘或诊断输出。
/// - 登录成功后让 SteamCMD 自行 `quit` 并等待它把会话缓存写入应用私有 profile；
///   只有超过上限（`shutdownTimeout`）才强制终止，避免杀掉正在写缓存的进程。
/// - 不把网页登录/OpenID 当成下载认证：只有 SteamCMD 自身报告登录成功才标记为已登录。
/// - 会话缓存位于应用管理目录的私有 profile，可在 UI 中一键清除（只清应用自有目录）。
/// - 登录与下载等所有触碰 profile 的操作共享 `SteamProfileGate`，绝不并发访问同一 profile。
///
/// 状态机（R12 修复，顺序敏感）：
/// `preparing → (awaitingUsername / login) → awaitingPassword → awaitingGuardCode →
///  loggingIn → finalizing → loggedIn`
/// - `Logged in OK` **不是**终态，只表示 Steam 接受了本次登录（`.loginAccepted`）；
/// - `Waiting for user info...` 只有在明确以 `OK` 结尾时才算就绪，
///   无换行的片段（后面可能追加 `FAILED`）一律视为未完成；
/// - 即使已经就绪，仍继续消费输出直到进程自行退出；期间出现的任何失败行都会覆盖成功。
/// - 完成路径单飞：多个 `waitForCompletion` 等待者共享同一个结果，避免重复触发
///   优雅退出/强制终止（这会导致缓存写入被中途打断）。

/// 交互式登录会话状态。
enum SteamLoginState: Sendable, Equatable {
    case idle
    /// 已启动 SteamCMD，等待控制台就绪。
    case preparing
    /// 等待输入 Steam 账号名。
    case awaitingUsername
    /// 已提交 `login <account>`，等待输入密码。
    case awaitingPassword
    /// 等待 Steam Guard 验证码。
    case awaitingGuardCode
    /// 需要 Steam App 上的手机确认（无法用验证码完成）。
    case awaitingMobileConfirmation
    /// 已提交凭据，Steam 正在验证。
    case loggingIn
    /// 登录已被 Steam 接受，正在等待用户信息就绪并让 SteamCMD 写入缓存。
    case finalizing
    case loggedIn(userID: String?)
    case failed(reason: String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .loggedIn, .failed, .cancelled: return true
        default: return false
        }
    }

    var isActive: Bool {
        switch self {
        case .idle, .loggedIn, .failed, .cancelled: return false
        default: return true
        }
    }

    var isAwaitingInput: Bool {
        switch self {
        case .awaitingUsername, .awaitingPassword, .awaitingGuardCode: return true
        default: return false
        }
    }

    var displayText: String {
        switch self {
        case .idle: return "未开始登录"
        case .preparing: return "正在启动 SteamCMD 控制台"
        case .awaitingUsername: return "等待输入 Steam 账号名"
        case .awaitingPassword: return "等待输入密码（不会记录或显示）"
        case .awaitingGuardCode: return "等待输入 Steam Guard 验证码"
        case .awaitingMobileConfirmation: return "请在手机 Steam App 上确认本次登录"
        case .loggingIn: return "Steam 正在验证登录"
        case .finalizing: return "登录已被 Steam 接受，正在写入会话缓存"
        case .loggedIn(let userID): return "已登录" + (userID.map { "（账号 ID \($0)）" } ?? "")
        case .failed(let reason): return "等待重新登录：\(reason)"
        case .cancelled: return "登录已取消"
        }
    }
}

/// 登录状态的可观察包装（供 SwiftUI 使用）。
@MainActor
@Observable
final class SteamLoginStatusModel {
    var state: SteamLoginState = .idle
    /// 已脱敏且限长的近期状态行（最多 40 行 × 200 字符），不含密码/验证码/账号名。
    private(set) var recentLines: [String] = []
    var startedAt: Date?
    var finishedAt: Date?

    func append(line: String) {
        let sanitized = SteamLoginSession.sanitize(line, limit: 200)
        guard !sanitized.isEmpty else { return }
        recentLines.append(sanitized)
        if recentLines.count > 40 {
            recentLines.removeFirst(recentLines.count - 40)
        }
    }

    func reset() {
        recentLines = []
        startedAt = nil
        finishedAt = nil
    }
}

/// SteamCMD 交互会话中识别出的提示/事件。
enum SteamLoginPrompt: Equatable {
    case consoleReady
    case accountName
    case password(repeated: Bool)
    case guardCode
    case mobileConfirmation
    /// Steam 明确接受了登录（`Logged in OK` / `Logging in user …OK`），但还不是最终成功。
    case loginAccepted
    /// `Waiting for user info...OK`（用户信息就绪）。
    case userInfoReady
    /// `Waiting for user info...FAILED`。
    case userInfoFailed
    /// 已确认登录成功（保留给需要终态语义的调用方；当前 classify 不直接返回）。
    case loggedIn(userID: String?)
    case failed(WorkshopDownloadError)
}

/// 真实的 SteamCMD 交互式登录会话。
@MainActor
final class SteamLoginSession {
    private var session: WorkshopInteractiveSession?
    /// 启动 → 取得 profile 闸门 → 启动进程 → 消费输出（单飞）。
    private var runTask: Task<Void, Never>?
    /// 完成路径（优雅退出 + 释放闸门，单飞）；所有等待者共享同一个结果。
    private var completionTask: Task<SteamLoginState, Never>?
    private var eventHandler: (@Sendable (SteamLoginEvent) -> Void)?
    private var currentState: SteamLoginState = .idle
    private var usernameUsed: String?
    private var sawLoginAccepted = false
    private var sawUserInfoReady = false
    private var sawFailureLine = false
    /// Steam 已接受登录（`Logged in OK` 或 `Waiting for user info...OK`），进入收尾。
    private var becameAuthenticated = false
    private var terminalError: WorkshopDownloadError?
    private var acceptedAt: Date?
    private var isCancelling = false
    private var consoleReady = false
    private var loginCommandSent = false
    private var gateAcquired = false
    private var gateReleased = false
    private var assembler = SteamConsoleLineAssembler()
    private let executable: URL
    private let layout: SteamCMDLayout
    private let gate: SteamProfileGate
    private let commandTimeout: TimeInterval
    /// 登录被接受后（例如只看到 `Logged in OK`）等待 user info 或失败行的宽限期。
    private let settleGrace: TimeInterval
    /// 成功后等待 SteamCMD 自行退出（写缓存）的上限。
    private let shutdownTimeout: TimeInterval

    init(
        executable: URL,
        layout: SteamCMDLayout,
        commandTimeout: TimeInterval = 600,
        settleGrace: TimeInterval = 6,
        shutdownTimeout: TimeInterval = 20
    ) {
        self.executable = executable
        self.layout = layout
        self.gate = SteamProfileGateRegistry.gate(for: layout)
        self.commandTimeout = commandTimeout
        self.settleGrace = settleGrace
        self.shutdownTimeout = shutdownTimeout
    }

    var isActive: Bool {
        guard let session else { return false }
        return session.isRunning && !currentState.isTerminal
    }

    /// 启动交互式登录：argv 只放选项，账号/密码/验证码全部经 stdin。
    ///
    /// 命令序列（官方控制台命令）：
    /// ```
    /// login <account>            ← 经 stdin，账号名不进入 argv
    /// <password>                 ← 仅当 SteamCMD 明确要求时经 stdin 发送
    /// <steam guard code>         ← 仅当 SteamCMD 明确要求时经 stdin 发送
    /// quit                       ← 成功后由我们发送，让 SteamCMD 正常写缓存并退出
    /// ```
    func start(configuredUsername: String?, eventHandler: @escaping @Sendable (SteamLoginEvent) -> Void) {
        guard runTask == nil, completionTask == nil else { return }
        self.eventHandler = eventHandler
        transition(to: .preparing)

        let username = configuredUsername?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard username.isEmpty || SteamCMDCredentialPolicy.isValidAccountName(username) else {
            transition(to: .failed(reason: "账号名格式不正确"))
            return
        }
        usernameUsed = username.isEmpty ? nil : username

        let arguments = [
            "+@ShutdownOnFailedCommand", "1",
            "+@NoPromptForPassword", "0",
            // 不强制平台：登录/探测都不需要平台覆盖（下载时另行按 App 平台设置）。
        ]

        runTask = Task { [weak self] in
            guard let self else { return }
            // 与下载/清理共享 profile 闸门（避免并发访问同一 profile）。
            let acquired = await self.gate.acquire(owner: "登录")
            guard acquired else {
                self.markCancelled()
                return
            }
            self.gateAcquired = true
            guard !Task.isCancelled, !self.isCancelling else {
                self.markCancelled()
                await self.releaseGateIfHeld()
                return
            }
            self.begin(launchArguments: arguments, username: username)
            guard self.session != nil else { return }
            await self.consumeOutput()
        }

        // 完成路径：单飞，保证「优雅退出 → 释放闸门」只执行一次，且结果对所有等待者一致。
        completionTask = Task { [weak self] in
            guard let self else { return SteamLoginState.cancelled }
            return await self.awaitOutcome()
        }
    }

    private func begin(launchArguments: [String], username: String) {
        do {
            let session = try WorkshopInteractiveSession(
                executable: executable,
                arguments: launchArguments,
                environment: WorkshopProcessRunner.steamcmdEnvironment(home: layout.homeURL),
                currentDirectory: layout.root
            )
            self.session = session
        } catch {
            let reason = (error as? WorkshopProcessError)?.errorDescription ?? error.localizedDescription
            terminalError = .downloadFailed(detail: WorkshopLog.sanitize(reason))
            transition(to: .failed(reason: WorkshopLog.sanitize(reason)))
        }
    }

    // MARK: - 用户输入（全部经 stdin）

    /// 用户提交账号名（仅当 SteamCMD 明确要求输入账号时允许）。
    func submitUsername(_ username: String) {
        guard case .awaitingUsername = currentState, let session else { return }
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SteamCMDCredentialPolicy.isValidAccountName(trimmed) else { return }
        usernameUsed = trimmed
        sendLoginCommand(username: trimmed, session: session)
    }

    /// 用户提交密码（只写入 stdin，不记录）。
    func submitPassword(_ password: String) {
        guard case .awaitingPassword = currentState, let session else { return }
        guard SteamCMDCredentialPolicy.isSafeSecretLine(password) else { return }
        session.send(line: password)
        eventHandler?(.line("已提交密码（内容不显示）"))
        transition(to: .loggingIn)
    }

    /// 用户提交 Steam Guard 验证码（只写入 stdin，不记录）。
    func submitGuardCode(_ code: String) {
        guard case .awaitingGuardCode = currentState, let session else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SteamCMDCredentialPolicy.isValidGuardCode(trimmed) else { return }
        session.send(line: trimmed)
        eventHandler?(.line("已提交 Steam Guard 验证码（内容不显示）"))
        transition(to: .loggingIn)
    }

    /// 取消登录并终止进程。完成路径仍会收尾并释放 profile 闸门。
    func cancel() {
        guard runTask != nil || completionTask != nil else {
            transition(to: .cancelled)
            return
        }
        markCancelled()
        runTask?.cancel()
        session?.terminate()
        session = nil
        usernameUsed = nil
    }

    /// 等待登录流程结束（成功/失败/取消）。
    ///
    /// 不带 `timeout` 时返回完成路径的最终状态（成功路径包含优雅退出与缓存写入）。
    func waitForCompletion(timeout: TimeInterval? = nil) async -> SteamLoginState {
        guard let completionTask else { return currentState }
        guard let timeout else { return await completionTask.value }

        let deadline = Date().addingTimeInterval(timeout)
        while !currentState.isTerminal, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if !currentState.isTerminal, Date() >= deadline {
            terminalError = .downloadFailed(detail: "登录超时")
            transition(to: .failed(reason: "登录超时。请检查网络后重试。"))
        }
        return currentState
    }

    // MARK: - 完成路径（单飞）

    /// 等待终态或「认证被接受」，然后优雅收尾并释放闸门。
    private func awaitOutcome() async -> SteamLoginState {
        let deadline = Date().addingTimeInterval(commandTimeout)
        while !currentState.isTerminal, !becameAuthenticated {
            if Task.isCancelled {
                markCancelled()
                break
            }
            if Date() > deadline {
                terminalError = .downloadFailed(detail: "登录超时")
                transition(to: .failed(reason: "登录超时。请检查网络后重试。"))
                break
            }
            // Steam 已明确接受登录（例如只有 `Logged in OK`），宽限期内没有失败行才按成功收尾。
            if let acceptedAt, sawLoginAccepted, !sawUserInfoReady, !sawFailureLine,
               Date() >= acceptedAt.addingTimeInterval(settleGrace) {
                becameAuthenticated = true
                break
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        await settleAndRelease()
        return currentState
    }

    /// 收尾：成功时先让 SteamCMD 自行退出（写缓存），失败/取消时终止进程；最后释放闸门。
    private func settleAndRelease() async {
        if becameAuthenticated, !sawFailureLine, !isCancelling, !currentState.isTerminal {
            await finalizeAuthenticatedSession()
        } else {
            session?.terminate()
            session = nil
        }
        await releaseGateIfHeld()
    }

    /// 成功后收尾：发送 `quit`，有界等待进程自行结束（缓存落盘），随后才发布 `.loggedIn`。
    private func finalizeAuthenticatedSession() async {
        guard let session else {
            transition(to: .loggedIn(userID: nil))
            return
        }
        if session.isRunning {
            transition(to: .finalizing)
            session.send(line: "quit")
            let deadline = Date().addingTimeInterval(shutdownTimeout)
            while session.isRunning, Date() < deadline {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let forcedShutdown = session.isRunning
        session.terminate()
        self.session = nil
        guard !isCancelling, !Task.isCancelled else {
            transition(to: .cancelled)
            return
        }
        if forcedShutdown {
            transition(to: .failed(reason: "SteamCMD 未在时限内正常退出，无法确认会话缓存已保存。请重试登录。"))
            return
        }

        // 收尾期间到达的失败行优先于成功（不伪造登录成功）。
        if sawFailureLine, let terminalError {
            transition(to: .failed(reason: terminalError.errorDescription ?? "登录失败"))
            return
        }
        let cacheReady = WorkshopDownloadService.profileHasCachedSession(layout: layout)
        eventHandler?(.line(cacheReady
            ? "SteamCMD 已正常退出，会话缓存已写入应用私有 profile。"
            : "SteamCMD 已正常退出；未观察到缓存文件（下载时若要求重新登录，请再登录一次）。"))
        transition(to: .loggedIn(userID: nil))
    }

    private func releaseGateIfHeld() async {
        guard gateAcquired, !gateReleased else { return }
        gateReleased = true
        await gate.release()
    }

    // MARK: - 输出消费

    private func consumeOutput() async {
        guard let session else { return }
        for await event in session.events {
            if Task.isCancelled { break }
            handle(event: event)
        }
        handleStreamEnd()
    }

    private func handle(event: WorkshopConsoleEvent) {
        guard !isCancelling else { return }
        if let text = assembler.consume(event) {
            handle(line: text)
        }
    }

    private func handle(line: String) {
        guard !isCancelling else { return }
        // 对外只发送已脱敏文本（账号名/密码/验证码不进诊断）。
        eventHandler?(.line(SteamLoginSession.sanitize(line, limit: 200)))

        if let prompt = Self.classify(line) {
            apply(prompt)
            return
        }
        if !consoleReady, Self.isConsoleReadyLine(line) {
            consoleReady = true
            continueAfterConsoleReady()
        }
    }

    private func continueAfterConsoleReady() {
        guard !loginCommandSent else { return }
        if let usernameUsed, let session {
            sendLoginCommand(username: usernameUsed, session: session)
        } else if usernameUsed == nil {
            transition(to: .awaitingUsername)
        }
    }

    private func sendLoginCommand(username: String, session: WorkshopInteractiveSession) {
        // 官方文档化控制台命令：`login <account>`，账号名只经 stdin。
        session.send(line: "login \(username)")
        loginCommandSent = true
        eventHandler?(.line("已发送登录命令（账号名不记录、不显示）"))
        transition(to: .loggingIn)
    }

    private func handleStreamEnd() {
        // 已接受登录且没有失败行：收尾由完成路径负责（不要在这里发布成功）。
        if becameAuthenticated, !sawFailureLine, !isCancelling { return }
        guard !currentState.isTerminal else { return }
        if let terminalError {
            transition(to: .failed(reason: terminalError.errorDescription ?? "登录失败"))
            return
        }
        if isCancelling {
            transition(to: .cancelled)
            return
        }
        transition(to: .failed(reason: "SteamCMD 进程已退出，但未确认登录成功"))
    }

    private func apply(_ prompt: SteamLoginPrompt) {
        switch prompt {
        case .consoleReady:
            consoleReady = true
            continueAfterConsoleReady()
        case .accountName:
            if becameAuthenticated { return }
            if case .awaitingUsername = currentState { return }
            transition(to: .awaitingUsername)
        case .password(let repeated):
            if becameAuthenticated { return }
            if repeated, case .awaitingPassword = currentState { return }
            transition(to: .awaitingPassword)
        case .guardCode:
            if becameAuthenticated { return }
            transition(to: .awaitingGuardCode)
        case .mobileConfirmation:
            if becameAuthenticated { return }
            transition(to: .awaitingMobileConfirmation)
        case .loginAccepted:
            // 只表示「Steam 接受了本次登录」，绝不能在这里发布成功。
            sawLoginAccepted = true
            if acceptedAt == nil { acceptedAt = Date() }
            if !becameAuthenticated { transition(to: .loggingIn) }
        case .userInfoReady:
            sawLoginAccepted = true
            sawUserInfoReady = true
            if acceptedAt == nil { acceptedAt = Date() }
            becameAuthenticated = true
        case .userInfoFailed:
            sawFailureLine = true
            terminalError = .invalidCredentials(hint: "Steam 接受了凭据，但用户信息获取失败（Waiting for user info…FAILED）")
            transition(to: .failed(reason: terminalError?.errorDescription ?? "登录失败"))
        case .loggedIn:
            sawLoginAccepted = true
            sawUserInfoReady = true
            if acceptedAt == nil { acceptedAt = Date() }
            becameAuthenticated = true
        case .failed(let error):
            sawFailureLine = true
            terminalError = error
            transition(to: .failed(reason: error.errorDescription ?? "登录失败"))
        }
    }

    private func transition(to state: SteamLoginState) {
        guard state != currentState else { return }
        currentState = state
        eventHandler?(.session(state, userID: nil))
    }

    private func markCancelled() {
        isCancelling = true
        transition(to: .cancelled)
    }

    // MARK: - 输出识别（顺序敏感：先失败，后提示）

    /// 从一行 SteamCMD 输出识别提示/事件。纯函数，可从任意线程调用。
    ///
    /// 关键顺序与语义（R12）：
    /// 1. 失败优先：限流 / 密码错误 / Guard 错误 / `Waiting for user info...FAILED` /
    ///    缓存会话无效 / `Logging in user…FAILED` / 通用登录失败。
    /// 2. `Logged in OK`、`Logging in user…OK` 只算 `.loginAccepted`（不是终态）。
    /// 3. `Waiting for user info...` 只有在明确以 `OK` 结尾时才算 `.userInfoReady`；
    ///    没有结尾判定（可能后续才追加 `OK`/`FAILED`）时返回 nil。
    /// 4. 最后才是交互提示（password / Steam Guard / 手机确认 / 账号名）。
    /// Named Steam authentication results, shared with the cached-download path.
    /// Match names (including enum spelling), never arbitrary numbers in output.
    /// A terminal denial is an error; only a separate live input prompt requests a code.
    nonisolated static func authenticationDenial(_ line: String) -> WorkshopDownloadError? {
        let withoutAccount = line.replacingOccurrences(
            of: "(?i)(logging in user|logged in user|logon user|logging into)\\s+'[^']*'",
            with: "", options: .regularExpression
        )
        let name = withoutAccount.lowercased().filter { $0.isASCII && $0.isLetter }
        if name.contains("invalidpassword") {
            return .invalidCredentials(hint: "账号或密码不正确")
        }
        if name.contains("invalidloginauthcode") || name.contains("twofactorcodemismatch")
            || name.contains("twofactoractivationcodemismatch") {
            return .invalidCredentials(hint: "Steam Guard 验证码不正确")
        }
        if name.contains("expiredloginauthcode") {
            return .guardRequired(hint: "Steam Guard 验证码已过期，请使用新的验证码重新登录")
        }
        // Specific variants precede the AccountLogonDenied prefix.
        if name.contains("accountlogondeniedverifiedemailrequired") {
            return .guardRequired(hint: "Steam 要求先验证账号邮箱，请完成邮箱验证后重新登录")
        }
        if name.contains("accountlogondeniednomail") {
            return .guardRequired(hint: "Steam 二次验证未通过，且未发送验证邮件；请检查 Steam Guard 与邮箱状态后重新登录")
        }
        if name.contains("accountlogindeniedneedtwofactor") {
            return .guardRequired(hint: "Steam 要求双重验证，请通过 Steam Guard 验证后重新登录")
        }
        if name.contains("accountlogondenied") {
            return .guardRequired(hint: "Steam 拒绝了二次验证，请检查 Steam Guard 或手机确认后重新登录；这不代表密码错误")
        }
        return nil
    }

    nonisolated static func classify(_ line: String) -> SteamLoginPrompt? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        guard !lowered.isEmpty else { return nil }

        // 1) 失败优先（必须在「Steam Guard」等宽泛关键词之前判定）。
        if lowered.contains("rate limit exceeded") {
            return .failed(.invalidCredentials(hint: "Steam 登录限流（Rate Limit Exceeded），请等待一段时间后重试"))
        }
        if let denial = authenticationDenial(trimmed) {
            return .failed(denial)
        }
        if lowered.contains("invalid login auth code")
            || lowered.contains("invalid steam guard")
            || (lowered.contains("guard") && (lowered.contains("invalid") || lowered.contains("incorrect") || lowered.contains("failed") || lowered.contains("denied")))
            || (lowered.contains("two-factor") && (lowered.contains("invalid") || lowered.contains("incorrect") || lowered.contains("failed"))) {
            return .failed(.invalidCredentials(hint: "Steam Guard 验证码不正确"))
        }
        if lowered.contains("waiting for user info") && lowered.contains("failed") {
            return .userInfoFailed
        }
        if lowered.contains("failed login with cached credentials")
            || (lowered.contains("cached credentials") && lowered.contains("fail")) {
            return .failed(.sessionExpired(hint: "SteamCMD 没有可用的缓存会话，需要重新登录"))
        }
        if lowered.contains("logging in user") && lowered.contains("failed") {
            return .failed(.invalidCredentials(hint: "Steam 拒绝了本次登录（Logging in user…FAILED）"))
        }
        if lowered.contains("failed to get user's authentication")
            || lowered.contains("login failure")
            || lowered.contains("logon failure")
            || lowered.contains("access denied") {
            return .failed(.invalidCredentials(hint: "Steam 拒绝了登录请求"))
        }
        if lowered.contains("this account is protected by steam guard") && lowered.contains("email") {
            // 「邮箱验证码」提示仍然只是提示，继续等待输入。
            return .guardCode
        }

        // 2) 成功信号（`Logged in OK` 只是被接受，必须继续等 user info / 进程收尾）。
        if lowered.contains("waiting for user info") {
            return lowered.hasSuffix("ok") ? .userInfoReady : nil
        }
        if lowered.contains("logged in ok") {
            return .loginAccepted
        }
        if lowered.contains("logged in user") && lowered.hasSuffix("ok") {
            return .loginAccepted
        }
        if lowered.contains("logging in user") && lowered.hasSuffix("ok") {
            return .loginAccepted
        }

        // 3) 交互提示（提示词未换行时由空闲冲刷送达）。
        if isPasswordPrompt(lowered) {
            return .password(repeated: lowered.contains("please enter your password"))
        }
        if isGuardPrompt(lowered) {
            return .guardCode
        }
        if isMobileConfirmation(lowered) {
            return .mobileConfirmation
        }
        if isAccountPrompt(lowered) {
            return .accountName
        }
        return nil
    }

    nonisolated static func isPasswordPrompt(_ lowered: String) -> Bool {
        // 只认提示形态，避免把错误信息当提示。
        lowered.hasSuffix("password:")
            || lowered.hasSuffix("password")
            || lowered.contains("enter your password")
            || lowered.contains("please enter your password")
    }

    nonisolated static func isGuardPrompt(_ lowered: String) -> Bool {
        if lowered.contains("invalid") || lowered.contains("failed") || lowered.contains("denied") { return false }
        let markers = [
            "steam guard code",
            "two-factor code",
            "two factor code",
            "current code from your steam guard",
            "mobile authenticator",
            "authenticator code"
        ]
        guard markers.contains(where: { lowered.contains($0) }) else { return false }
        // 提示通常以冒号结尾或包含 enter/please。
        return lowered.hasSuffix(":") || lowered.hasSuffix("code") || lowered.contains("enter") || lowered.contains("please")
    }

    nonisolated static func isMobileConfirmation(_ lowered: String) -> Bool {
        if lowered.contains("invalid") || lowered.contains("failed") { return false }
        let markers = [
            "waiting for confirmation",
            "waiting for user confirmation",
            "waiting for mobile confirmation",
            "confirm the login",
            "confirm this login",
            "confirm your login",
            "approve the login",
            "confirm via the steam app",
            "open the steam mobile app",
            "steam mobile app",
            "please confirm"
        ]
        return markers.contains(where: { lowered.contains($0) })
    }

    nonisolated static func isAccountPrompt(_ lowered: String) -> Bool {
        lowered.hasSuffix("account name:")
            || lowered.contains("please enter your username")
            || lowered.contains("enter your username")
    }

    /// 控制台就绪判定（可安全发送第一条 stdin 命令）。
    nonisolated static func isConsoleReadyLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return lowered.contains("type 'quit' to exit")
            || lowered.contains("loading steam api")
            || lowered.hasPrefix("steam>")
            || lowered.contains("steam console client")
    }

    /// 输出行脱敏（不显示密码/验证码/账号名，限制长度）。纯函数，可从任意线程调用。
    nonisolated static func sanitize(_ line: String, limit: Int) -> String {
        var text = line
        if let range = text.range(of: "(?i)(password|passphrase|guard code|验证码)\\s*[:：]?\\s*\\S+", options: .regularExpression) {
            text.replaceSubrange(range, with: "<已隐藏>")
        }
        if let range = text.range(of: "(?i)username\\s+\\S+", options: .regularExpression) {
            text.replaceSubrange(range, with: "username <已隐藏>")
        }
        // 规范输出会带账号名（Logging in user 'xxx' / Logged in user 等），一律隐藏。
        if let range = text.range(of: "(?i)(logging in user|logged in user|logon user|logging into)\\s+'[^']*'", options: .regularExpression) {
            text.replaceSubrange(range, with: "已处理账号登录请求")
        }
        text = text.replacingOccurrences(of: "\u{1B}", with: "")
        text = SteamHTML.collapseWhitespace(text)
        if text.count > limit {
            text = String(text.prefix(limit)) + "…"
        }
        return text
    }
}

/// 登录事件（由会话回调给 UI/协调器）。
enum SteamLoginEvent: Sendable {
    /// 状态变化。
    case session(SteamLoginState, userID: String?)
    /// 已脱敏的原始输出行（供界面展示，限长）。
    case line(String)
}
