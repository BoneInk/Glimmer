import Foundation
import Darwin
import Observation

/// 认证后的创意工坊下载队列（F15）。
///
/// 设计要点：
/// - 所有 SteamCMD 操作**串行**执行（登录、下载共用一条队列），避免账号会话冲突。
/// - 视频必须真实可播放；Web 必须通过完整本地项目校验；写入清单后才算完成，
///   才标记为完成；任何一步失败都给出可操作原因。
/// - 下载、校验都支持取消与重试；取消不会删除已下载的部分文件。
/// - 不使用 shell 拼接：所有命令以参数数组方式启动 SteamCMD。

/// 队列条目的状态。
enum WorkshopDownloadState: Sendable, Equatable {
    case queued
    case downloading(fraction: Double?, text: String)
    case pausing
    case paused
    case validating(String)
    case completed
    case failed(message: String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }

    var isSuccess: Bool { self == .completed }
    var isActiveWork: Bool {
        switch self { case .queued, .downloading, .pausing, .validating: true; default: false }
    }

    var displayText: String {
        switch self {
        case .queued: return "排队中"
        case .pausing: return "正在暂停"
        case .paused: return "已暂停"
        case .downloading(let fraction, let text):
            if let fraction {
                return String(format: "下载中 %.1f%% · %@", fraction * 100, text)
            }
            return "下载中 · \(text)"
        case .validating(let text): return "校验中 · \(text)"
        case .completed: return "完成"
        case .failed(let message): return "失败：\(message)"
        case .cancelled: return "已取消"
        }
    }
}

/// 一个待下载/已下载条目。
struct WorkshopDownloadItem: Identifiable, Hashable, Sendable {
    var id: String { publishedFileID }
    var publishedFileID: String
    var title: String
    var kind: WorkshopItemKind
    var declaredTags: [String]
    var previewImageURLString: String?
    var fileSizeBytes: Int64?
    var state: WorkshopDownloadState = .queued
    var attempts: Int = 0
    var queuedAt: Date = Date()
    var completedAt: Date?
    /// 下载并校验通过后的结果（包含真实视频 URL）。
    var project: WorkshopVideoProject?
    var resolvedProject: WorkshopResolvedProject?
    var validatedProject: WorkshopResolvedProject? { resolvedProject ?? project.map(WorkshopResolvedProject.video) }
    /// 下载目录（管理目录内）。
    var downloadDirectoryPath: String?
    var progressText: String = ""
    var progressFraction: Double?

    static func == (lhs: WorkshopDownloadItem, rhs: WorkshopDownloadItem) -> Bool {
        lhs.publishedFileID == rhs.publishedFileID && lhs.state == rhs.state && lhs.attempts == rhs.attempts
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(publishedFileID)
    }

    var previewImageURL: URL? {
        previewImageURLString.flatMap { URL(string: $0) }
    }

    var fileSizeText: String? {
        guard let fileSizeBytes, fileSizeBytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    /// 对外回调载荷。
    var metadata: WorkshopMetadata? {
        guard let project = validatedProject else { return nil }
        return WorkshopMetadata(
            publishedFileID: publishedFileID,
            title: project.projectTitle ?? title,
            projectType: project.projectType,
            descriptionExcerpt: nil,
            previewImageURLString: previewImageURLString,
            authorSteamID: nil,
            fileSizeBytes: fileSizeBytes,
            timeCreated: nil,
            declaredTags: declaredTags,
            projectDirectoryPath: project.projectRoot.path,
            videoRelativePath: project.videoProject?.videoRelativePath,
            videoByteSize: project.videoProject?.videoByteSize,
            projectJSONRelativePath: project.projectJSONPath,
            entryRelativePath: project.entryRelativePath,
            projectByteSize: project.totalByteSize,
            projectFingerprint: project.contentFingerprint
        )
    }
}

/// 下载清单（完成校验后写入下载目录，用于检测外部修改）。
struct WorkshopDownloadManifest: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var appID: Int
    var publishedFileID: String
    var title: String
    var projectType: String
    var projectJSONRelativePath: String
    var videoRelativePath: String?
    var videoByteSize: Int64?
    var videoSHA256: String?
    var validatedAt: Date
    var declaredTags: [String]
    var appVersion: String
    var entryRelativePath: String? = nil
    var projectByteSize: Int64? = nil
    var projectFingerprint: String? = nil
    var resourceCount: Int? = nil
    var downloadBackend: String? = nil
    var previewImageURLString: String? = nil
    var fileSizeBytes: Int64? = nil
    var downloadCompletedAt: Date? = nil
}

/// 下载队列进度模型（主线程可观察）。
@MainActor
@Observable
final class WorkshopDownloadProgressModel {
    var items: [WorkshopDownloadItem] = []
    var activeItemID: String?
    var lastError: String?
    /// 已脱敏的 SteamCMD 状态行（最近 12 条）。
    private(set) var recentStatusLines: [String] = []

    func appendStatus(_ line: String) {
        let sanitized = SteamLoginSession.sanitize(line, limit: 160)
        guard !sanitized.isEmpty else { return }
        recentStatusLines.append(sanitized)
        if recentStatusLines.count > 12 {
            recentStatusLines.removeFirst(recentStatusLines.count - 12)
        }
    }

    var activeItem: WorkshopDownloadItem? {
        guard let activeItemID else { return nil }
        return items.first { $0.publishedFileID == activeItemID }
    }

    var pendingCount: Int { items.filter { !$0.state.isTerminal }.count }
}

/// SteamCMD 平台覆盖（`+@sSteamCmdForcePlatformType`）。
///
/// 依据（实测 https://store.steampowered.com/api/appdetails?appids=431960）：
/// Wallpaper Engine 仅声明 Windows（platforms: {windows:true, mac:false, linux:false}），
/// 因此下载其工坊内容必须使用 `windows`，而不是旧实现的 `macos` 强制覆盖。
enum SteamCMDPlatformOverride: String, Sendable, CaseIterable {
    case windows
    case linux
    case macos

    /// Wallpaper Engine 工坊内容使用的平台。
    static let wallpaperEngine: SteamCMDPlatformOverride = .windows
}

/// 账号名/凭据的输入校验（防止把控制字符注入 SteamCMD 的控制台命令流）。
enum SteamCMDCredentialPolicy {
    /// Steam 账号名：3–64 位，只允许字母、数字与 `_ - .`。
    static func isValidAccountName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, (3...64).contains(trimmed.count) else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-.")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// 密码：只禁止换行/控制字符（其余字符一律允许，且绝不落盘）。
    static func isSafeSecretLine(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 256 else { return false }
        return value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }

    /// Steam Guard 验证码：字母数字（含 base32/邮件码），长度 4–32。
    static func isValidGuardCode(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...32).contains(trimmed.count) else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }
    }
}

/// 下载服务（actor：串行执行 SteamCMD 下载）。
actor WorkshopDownloadService {
    /// 输出解析任务与主循环共享的运行时状态（由 LockedBox 保护）。
    ///
    /// 说明（R12 + 编译修复）：这些字段原先用可变局部变量在 `Task` 闭包与 actor 方法体
    /// 之间共享，Swift 6 region isolation 会在真实可执行编译时报错（-typecheck 不报）。
    /// 统一放进 Sendable 的锁保护盒子可消除该问题，并让读写语义更明确。
    struct DownloadProgressState: Sendable {
        // 进度
        var metrics = WorkshopDownloadMetrics()
        var isSteamValidating = false
        var sawSuccessLine = false
        var failureMessages: [String] = []
        // 认证状态机
        var sentLogin = false
        var sentDownload = false
        var downloadFinished = false
        var authFailure: WorkshopDownloadError?
        /// 登录已被接受（例如 `Logging in user …OK`）后的兜底发送时刻。
        var provisionalAuthDeadline: Date?
    }

    private let layout: SteamCMDLayout
    private let gate: SteamProfileGate
    private let executable: URL

    init(layout: SteamCMDLayout, executable: URL) {
        self.layout = layout
        self.executable = executable
        self.gate = SteamProfileGateRegistry.gate(for: layout)
    }

    /// 从应用自有 profile 中**临时**读取缓存会话的账号名（用于 `login <account>`）。
    ///
    /// - 只读取应用管理目录内的 profile（不触碰用户全局 Steam）。
    /// - 返回值只用于构造一次 stdin 命令，不写入任何日志/诊断/持久化状态。
    static func cachedAccountName(layout: SteamCMDLayout) -> String? {
        SteamCachedLoginProfile.accountName(layout: layout)
    }

    /// 下载单个条目；进度通过 `progress` 回调（主线程模型）。
    ///
    /// 认证语义（R12 修复）：
    /// - **不使用 anonymous 登录**：Wallpaper Engine 的工坊内容需要拥有该 App 的账号，
    ///   匿名会话无法通过所有权校验。
    /// - 复用当前账号在应用私有 profile 中的 SteamCMD 会话：控制台命令 `login <account>`
    ///   经 **stdin** 发送（账号名不进入 argv），`+@NoPromptForPassword 1` 保证会话失效时
    ///   直接报错而不是挂起等输入（我们绝不保存密码，无法、也不会代替用户输入密码）。
    /// - 平台覆盖使用 `windows`：Wallpaper Engine 在 Steam 上仅声明 Windows
    ///   （实测 https://store.steampowered.com/api/appdetails?appids=431960 →
    ///   platforms: {windows:true, mac:false, linux:false}），旧实现强制 macos 是错的。
    /// - 整个操作（登录 + 下载）与其它 profile 操作共享 `SteamProfileGate`，串行执行。
    ///
    /// - Throws: `WorkshopDownloadError`（可操作错误，含 `.notSignedIn` / `.sessionExpired`）。
    func download(
        item: WorkshopDownloadItem,
        username: String?,
        progress: @escaping @Sendable (WorkshopDownloadState) -> Void,
        logLine: @escaping @Sendable (String) -> Void
    ) async throws -> WorkshopResolvedProject {
        guard item.kind.isSupportedWallpaper || item.kind == .unknown else {
            throw WorkshopDownloadError.validationFailed(reason: item.kind.unsupportedReason ?? "不支持此壁纸类型")
        }
        try prepareDirectories()

        let account = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? Self.cachedAccountName(layout: layout)
        let hasAccount = !(account ?? "").isEmpty
        if let account, hasAccount, !SteamCMDCredentialPolicy.isValidAccountName(account) {
            throw WorkshopDownloadError.invalidCredentials(hint: "账号名格式不正确，请重新登录")
        }
        guard hasAccount || Self.profileHasCachedSession(layout: layout) else {
            throw WorkshopDownloadError.notSignedIn
        }

        progress(.downloading(fraction: nil, text: "正在排队（Steam 操作串行执行）"))
        let acquired = await gate.acquire(owner: "下载 \(item.publishedFileID)")
        guard acquired else { throw WorkshopDownloadError.cancelled }
        // 闸门释放必须确定发生（成功与失败路径都覆盖），否则串行语义会退化。
        do {
            let project = try await runAuthenticatedDownload(
                item: item,
                account: account,
                hasAccount: hasAccount,
                progress: progress,
                logLine: logLine
            )
            await gate.release()
            return project
        } catch {
            await gate.release()
            throw error
        }
    }

    /// 在持有 profile 闸门的前提下执行一次认证下载。
    private func runAuthenticatedDownload(
        item: WorkshopDownloadItem,
        account: String?,
        hasAccount: Bool,
        progress: @escaping @Sendable (WorkshopDownloadState) -> Void,
        logLine: @escaping @Sendable (String) -> Void
    ) async throws -> WorkshopResolvedProject {
        progress(.downloading(fraction: nil, text: "正在启动 SteamCMD（使用你的账号会话）"))
        let itemDirectory = layout.downloadDirectory(for: WorkshopItemID(item.publishedFileID) ?? WorkshopItemID("1")!)

        // argv 只包含选项与安装目录（无账号、无密码）；登录命令经 stdin 发送，
        // 且 `+force_install_dir` 在登录命令之前已经生效。
        let arguments = [
            "+@ShutdownOnFailedCommand", "1",
            "+@NoPromptForPassword", "1",
            "+@sSteamCmdForcePlatformType", SteamCMDPlatformOverride.windows.rawValue,
            "+force_install_dir", itemDirectory.path
        ]

        let session: WorkshopInteractiveSession
        do {
            session = try WorkshopInteractiveSession(
                executable: executable,
                arguments: arguments,
                environment: WorkshopProcessRunner.steamcmdEnvironment(home: layout.homeURL),
                currentDirectory: layout.root
            )
        } catch let error as WorkshopProcessError {
            throw WorkshopDownloadError.downloadFailed(detail: error.errorDescription ?? "无法启动 SteamCMD")
        } catch {
            throw WorkshopDownloadError.downloadFailed(detail: error.localizedDescription)
        }

        let state = LockedBox(DownloadProgressState())
        let appID = WorkshopInputValidator.wallpaperEngineAppID
        let itemID = item.publishedFileID

        let consumer = Task { [weak session] in
            guard let session else { return }
            var assembler = SteamConsoleLineAssembler()
            for await event in session.events {
                // R12：把「无换行片段」与后续文本拼成逻辑行后再判定，
                // 避免把 `Waiting for user info...` 当成就绪或漏掉稍后的 FAILED。
                guard let line = assembler.consume(event) else { continue }

                switch Self.parseProgress(line) {
                case .progress(let fraction, _):
                    let snapshot = state.with { runtime -> (Double?, String)? in
                        guard runtime.sentDownload, !runtime.downloadFinished,
                              Self.lineMatchesDownload(line, appID: String(appID), itemID: itemID) else { return nil }
                        runtime.isSteamValidating = false
                        let now = ProcessInfo.processInfo.systemUptime
                        runtime.metrics.consume(fraction: fraction, bytes: Self.extractByteCount(from: line), now: now)
                        return runtime.metrics.presentation(now: now, force: true)
                    }
                    if let snapshot { progress(.downloading(fraction: snapshot.0, text: snapshot.1)) }
                case .validating:
                    let accepted = state.with { runtime in
                        guard runtime.sentDownload, !runtime.downloadFinished,
                              Self.lineMatchesDownload(line, appID: String(appID), itemID: itemID) else { return false }
                        runtime.isSteamValidating = true
                        return true
                    }
                    if accepted { progress(.validating("SteamCMD 正在校验已有下载内容")) }
                case .success:
                    state.with {
                        guard $0.sentDownload, Self.lineMatchesDownload(line, appID: String(appID), itemID: itemID) else { return }
                        $0.sawSuccessLine = true
                        $0.downloadFinished = true
                    }
                case .failure(let message):
                    state.with { $0.failureMessages.append(message) }
                case .notice:
                    break
                }

                // 认证状态机：只根据 SteamCMD 的真实输出推进。
                state.with { runtime in
                    if !runtime.sentLogin, Self.consoleIsReady(line) {
                        runtime.sentLogin = true
                        if hasAccount, let account {
                            session.send(line: "login \(account)")
                            logLine("已发送登录命令（账号名不记录、不显示）")
                        } else {
                            // 有缓存会话但没有账号名：请用户重新登录以提供账号名。
                            runtime.authFailure = .notSignedIn
                            session.send(line: "quit")
                        }
                    }
                    guard runtime.sentLogin, runtime.authFailure == nil, !runtime.downloadFinished else { return }
                    guard let signal = Self.authSignal(line) else { return }
                    switch signal {
                    case .ready:
                        guard !runtime.sentDownload else { return }
                        runtime.sentDownload = true
                        runtime.metrics.start(now: ProcessInfo.processInfo.systemUptime)
                        session.send(line: "workshop_download_item \(appID) \(itemID)")
                        logLine("已发送下载命令（作品 ID \(itemID)）")
                    case .provisional:
                        if !runtime.sentDownload, runtime.provisionalAuthDeadline == nil {
                            runtime.provisionalAuthDeadline = Date().addingTimeInterval(2.5)
                        }
                    case .interactivePrompt:
                        // 需要我们无法提供的密码/验证码 → 会话已失效，明确报错而不是挂起。
                        runtime.authFailure = .sessionExpired(hint: "SteamCMD 要求重新输入密码或验证码；应用不会代替你输入")
                        session.send(line: "quit")
                    case .failed(let error):
                        runtime.authFailure = error
                        session.send(line: "quit")
                    }
                }

                if !line.isEmpty {
                    logLine(SteamLoginSession.sanitize(line, limit: 200))
                }
            }
        }

        // 总体超时（下载大文件可能较久）。
        let deadline = Date().addingTimeInterval(3_600)
        while true {
            let snapshot = state.with { ($0.downloadFinished, $0.authFailure, $0.sentDownload, $0.provisionalAuthDeadline) }
            if snapshot.0 || snapshot.1 != nil || !session.isRunning { break }
            if Task.isCancelled {
                session.send(line: "quit")
                session.terminate()
                consumer.cancel()
                throw WorkshopDownloadError.cancelled
            }
            if Date() > deadline {
                session.terminate()
                consumer.cancel()
                throw WorkshopDownloadError.downloadFailed(detail: "下载超过时限，已终止 SteamCMD。可在队列中重试（已下载的部分会保留）。")
            }
            // 登录已被接受但迟迟没有 user info/失败行：宽限后开始下载（后续失败仍会被识别）。
            if !snapshot.2, snapshot.1 == nil, let provisional = snapshot.3, Date() >= provisional {
                state.with {
                    $0.sentDownload = true
                    $0.metrics.start(now: ProcessInfo.processInfo.systemUptime)
                }
                session.send(line: "workshop_download_item \(appID) \(itemID)")
                logLine("已发送下载命令（作品 ID \(itemID)）")
            }
            if let measured = state.with({ runtime -> (Double?, String)? in
                guard !runtime.isSteamValidating else { return nil }
                return runtime.metrics.presentation(now: ProcessInfo.processInfo.systemUptime)
            }) {
                progress(.downloading(fraction: measured.0, text: measured.1))
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // 优雅退出（让 SteamCMD 正常收尾），随后结束会话。
        if session.isRunning {
            session.send(line: "quit")
            let quitDeadline = Date().addingTimeInterval(20)
            while session.isRunning, Date() < quitDeadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        session.terminate()
        consumer.cancel()

        if let authFailure = state.with({ $0.authFailure }) { throw authFailure }

        let collected = state.with { $0 }
        if !collected.sawSuccessLine {
            if let classified = Self.classifyFailure(failureMessages: collected.failureMessages, outputTail: "") {
                throw classified
            }
            throw WorkshopDownloadError.downloadFailed(
                detail: collected.failureMessages.first ?? "SteamCMD 结束但没有确认下载成功"
            )
        }

        progress(.validating("正在定位下载内容"))
        let contentDirectory = try locateDownloadedContent(itemID: item.publishedFileID, preferred: itemDirectory)
        logLine("下载内容位于管理目录内，开始校验 project.json")

        progress(.validating("正在校验 project.json 与本地壁纸资源"))
        let project = try await WorkshopProjectResolver.resolve(
            workshopID: item.publishedFileID,
            directory: contentDirectory,
            declaredTags: item.declaredTags
        )
        switch project {
        case .video(let video): logLine("视频校验通过：\(video.videoRelativePath)（\(video.probe.resolutionText)，\(video.probe.durationText)）")
        case .web(let web): logLine("Web 本地资源校验通过：\(web.resourceCount) 个文件；远程资源仍受运行时策略限制")
        case .scene(let scene): logLine("二维 Scene 项目校验通过：\(scene.resourceCount) 个文件；受限内联脚本将在运行时验证")
        }

        progress(.validating("正在写入清单"))
        try writeManifest(project: project, item: item, directory: contentDirectory)
        return project
    }

    /// profile 内是否存在 SteamCMD 会话缓存（仅作为「可能已登录」的证据，不等于下载权限）。
    static func profileHasCachedSession(layout: SteamCMDLayout) -> Bool {
        let manager = FileManager.default
        if manager.fileExists(atPath: layout.loginUsersURL.path) { return true }
        guard let contents = try? manager.contentsOfDirectory(atPath: layout.homeURL.path) else { return false }
        return contents.contains { $0.hasPrefix("ssfn") }
    }

    /// 控制台就绪（可以发送第一条 stdin 命令）。
    static func consoleIsReady(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return lowered.contains("type 'quit' to exit")
            || lowered.contains("loading steam api")
            || lowered.contains("steam console client")
            || lowered.hasPrefix("steam>")
    }

    /// 认证失败识别（顺序：先失败）。用于识别登录会话分类器未覆盖的下载侧原始文案。
    static func classifyAuthFailure(_ line: String) -> WorkshopDownloadError? {
        let lowered = line.lowercased()
        if lowered.contains("rate limit exceeded") {
            return .invalidCredentials(hint: "Steam 登录限流，请等待后重试")
        }
        if let denial = SteamLoginSession.authenticationDenial(line) {
            return denial
        }
        if lowered.contains("invalid login auth code") || lowered.contains("invalid steam guard")
            || (lowered.contains("guard") && (lowered.contains("invalid") || lowered.contains("incorrect"))) {
            return .invalidCredentials(hint: "Steam Guard 验证码不正确")
        }
        if lowered.contains("waiting for user info") && lowered.contains("failed") {
            return .invalidCredentials(hint: "用户信息获取失败（Waiting for user info…FAILED）")
        }
        if lowered.contains("failed login with cached credentials")
            || (lowered.contains("cached credentials") && lowered.contains("fail")) {
            return .sessionExpired(hint: "SteamCMD 没有可用的缓存会话，需要重新登录")
        }
        if lowered.contains("logging in user") && lowered.contains("failed") {
            return .sessionExpired(hint: "Steam 拒绝了缓存会话登录")
        }
        if lowered.contains("failed to get user's authentication")
            || lowered.contains("login failure")
            || lowered.contains("logon failure") {
            return .sessionExpired(hint: "SteamCMD 无法使用缓存会话登录")
        }
        if lowered.contains("not logged on") || lowered.contains("not logged in") {
            return .sessionExpired(hint: "SteamCMD 报告当前未登录")
        }
        return nil
    }

    /// 认证就绪（可以发送下载命令）。
    ///
    /// R12：`Waiting for user info...` 必须明确以 `OK` 结尾才算就绪；
    /// `Logged in OK` 是强就绪信号（下载路径收到它即可开始下载，失败仍会在后续输出中暴露）。
    static func isAuthReady(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.contains("logged in ok") { return true }
        if lowered.contains("waiting for user info") && !lowered.contains("failed") && lowered.hasSuffix("ok") { return true }
        if lowered.contains("logged in user") && lowered.hasSuffix("ok") { return true }
        return false
    }

    /// SteamCMD 要求我们无法提供的输入（密码/验证码/手机确认）→ 会话失效。
    static func isAuthPrompt(_ line: String) -> Bool {
        guard let prompt = SteamLoginSession.classify(line) else {
            let lowered = line.lowercased()
            if lowered.contains("password") && (lowered.hasSuffix(":") || lowered.contains("enter your password")) { return true }
            if lowered.contains("steam guard") && lowered.hasSuffix(":") { return true }
            return false
        }
        switch prompt {
        case .accountName, .password, .guardCode, .mobileConfirmation: return true
        default: return false
        }
    }

    /// 下载路径需要的认证信号（由登录会话的分类器推导，避免两套正则漂移）。
    enum AuthSignal: Equatable {
        /// 可以发送下载命令。
        case ready
        /// 登录被 Steam 接受，但还没有 user info 就绪（例如只看到 `Logging in user …OK`）。
        case provisional
        /// 需要交互式凭据（密码 / Steam Guard / 手机确认）→ 下载路径无法满足。
        case interactivePrompt
        case failed(WorkshopDownloadError)
    }

    static func authSignal(_ line: String) -> AuthSignal? {
        // 1) 失败优先（含登录分类器未覆盖的下载侧文案，例如缓存会话无效）。
        if let failure = classifyAuthFailure(line) { return .failed(failure) }
        // 2) 强就绪信号。
        if isAuthReady(line) { return .ready }
        // 3) 其余交给登录分类器。
        guard let prompt = SteamLoginSession.classify(line) else { return nil }
        switch prompt {
        case .consoleReady:
            return nil
        case .loginAccepted:
            return .provisional
        case .userInfoReady, .loggedIn:
            return .ready
        case .userInfoFailed:
            return .failed(.invalidCredentials(hint: "用户信息获取失败（Waiting for user info…FAILED）"))
        case .accountName, .password, .guardCode, .mobileConfirmation:
            return .interactivePrompt
        case .failed(let error):
            return .failed(error)
        }
    }

    /// Fresh structural/video validation is required; a saved marker alone never
    /// promotes missing, changed-to-unsupported, or unsafe content to completed.
    func verifyExisting(item: WorkshopDownloadItem) async -> WorkshopDownloadItem? {
        guard let id = WorkshopItemID(item.publishedFileID) else { return nil }
        let directory = layout.downloadDirectory(for: id)
        guard FileManager.default.fileExists(atPath: directory.path),
              WorkshopProjectResolver.isInside(directory, root: layout.root),
              (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        let originalManifest = readManifest(directory: directory, itemID: id.value)
        do {
            let project = try await WorkshopProjectResolver.resolve(
                workshopID: item.publishedFileID,
                directory: directory,
                declaredTags: item.declaredTags
            )
            try Task.checkCancellation()
            // Persisted annotations supply display metadata only, never paths,
            // kinds, sizes/fingerprints used to validate compatibility or content.
            let retained = originalManifest.flatMap { $0.projectType == project.projectType ? $0 : nil }
            var updated = item
            if let title = project.projectTitle { updated.title = title }
            else if item.title.isEmpty || item.title == "工坊作品 \(id.value)", let title = Self.displayTitle(retained?.title) { updated.title = title }
            if updated.declaredTags.isEmpty { updated.declaredTags = Self.displayTags(retained?.declaredTags ?? []) }
            if Self.displayPreview(updated.previewImageURLString) == nil { updated.previewImageURLString = Self.displayPreview(retained?.previewImageURLString) }
            if updated.fileSizeBytes == nil { updated.fileSizeBytes = Self.displaySize(retained?.fileSizeBytes) }
            let completedAt = retained?.downloadCompletedAt ?? retained?.validatedAt ?? Date()
            try writeManifest(project: project, item: updated, directory: directory,
                              downloadBackend: Self.displayBackend(retained?.downloadBackend), downloadCompletedAt: completedAt)
            updated.resolvedProject = project
            updated.project = project.videoProject
            updated.kind = project.kind
            updated.downloadDirectoryPath = directory.path
            updated.state = .completed
            updated.completedAt = completedAt
            return updated
        } catch {
            WorkshopLog.info("已有下载校验未通过：\(PathRedaction.short(directory))")
            return nil
        }
    }

    /// 删除管理目录内的下载内容（GUI 明确操作时调用）。
    func removeDownloadedItem(_ publishedFileID: String) {
        guard let id = WorkshopItemID(publishedFileID) else { return }
        try? FileManager.default.removeItem(at: layout.downloadDirectory(for: id))
    }

    func downloadDirectoryPath(for publishedFileID: String) -> String? {
        guard let id = WorkshopItemID(publishedFileID) else { return nil }
        return layout.downloadDirectory(for: id).path
    }

    // MARK: - 输出解析

    enum DownloadLineStatus: Equatable {
        case progress(fraction: Double?, text: String?)
        case validating
        case success
        case failure(String)
        case notice
    }

    static func parseProgress(_ line: String) -> DownloadLineStatus {
        let line = cleanProgressLine(line)
        let lowered = line.lowercased()

        if lowered.contains("error!") || lowered.contains("failed to install") || lowered.contains("doesn't have a subscription") || lowered.contains("access denied") {
            return .failure(SteamLoginSession.sanitize(line, limit: 200))
        }
        if lowered.contains("success. downloaded item") || lowered.contains("downloaded, validating") {
            return .success
        }
        if lowercasedContains(lowered, any: ["steam guard", "logged in", "login", "rate limit"]) {
            return .notice
        }
        if lowered.contains("validating") { return .validating }
        // 进度行形如：`Update state (0x61) downloading, progress: 12.34 (273066778 / 2212264969)`
        if lowered.contains("downloading") || lowered.contains("progress:") {
            let fraction = extractFraction(from: line)
            let bytesText = extractBytesText(from: line)
            return .progress(fraction: fraction, text: bytesText)
        }
        if lowered.contains("update state") || lowered.contains("installing") || lowered.contains("validating") {
            return .progress(fraction: nil, text: nil)
        }
        return .notice
    }

    private static func lowercasedContains(_ lowered: String, any needles: [String]) -> Bool {
        needles.contains { lowered.contains($0) }
    }

    /// ANSI display controls carry no progress meaning. CR is a console overwrite.
    static func cleanProgressLine(_ line: String) -> String {
        let latest = line.split(separator: "\r", omittingEmptySubsequences: true).last.map(String.init) ?? line
        return latest.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    /// Identifier-bearing reports must belong to this command. Unlabelled stdout
    /// is accepted only after sending our serialized workshop command (caller guard).
    static func lineMatchesDownload(_ line: String, appID: String, itemID: String) -> Bool {
        let line = cleanProgressLine(line)
        for (pattern, expected) in [
            (#"\bApp\s*ID\s*[:=]?\s*([0-9]+)\b"#, appID),
            (#"\b(?:publishedfileid|item\s*id|item)\s*[:=]?\s*([0-9]+)\b"#, itemID)
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
            for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let range = Range(match.range(at: 1), in: line), String(line[range]) == expected else { return false }
            }
        }
        return true
    }

    static func extractFraction(from line: String) -> Double? {
        let line = cleanProgressLine(line).lowercased()
        if let range = line.range(of: "progress:\\s*([0-9]+\\.?[0-9]*)", options: .regularExpression) {
            let token = String(line[range]).replacingOccurrences(of: "progress:", with: "").trimmingCharacters(in: .whitespaces)
            if let percent = Double(token), percent.isFinite, (0...100).contains(percent) { return percent / 100 }
        }
        return extractByteCount(from: line)?.fraction
    }

    static func extractByteCount(from line: String) -> WorkshopDownloadByteCount? {
        let line = cleanProgressLine(line)
        guard let range = line.range(of: "\\(([0-9]+)\\s*/\\s*([0-9]+)\\)", options: .regularExpression) else { return nil }
        let numbers = String(line[range]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            .split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard numbers.count == 2, let done = Int64(numbers[0]), let total = Int64(numbers[1]) else { return nil }
        return WorkshopDownloadByteCount(received: done, total: total)
    }

    static func extractBytesText(from line: String) -> String? { extractByteCount(from: line)?.text }

    static func classifyFailure(failureMessages: [String], outputTail: String) -> WorkshopDownloadError? {
        let haystack = (failureMessages + [outputTail]).joined(separator: " ").lowercased()
        if haystack.contains("subscription") || haystack.contains("access denied") || haystack.contains("no license") {
            return .ownershipMissing
        }
        if haystack.contains("invalid platform") || haystack.contains("platform not supported") {
            return .platformUnsupported(detail: "SteamCMD 报告该内容与所选平台不兼容（Wallpaper Engine 工坊内容为 Windows 平台）")
        }
        if haystack.contains("not logged on") || haystack.contains("not logged in")
            || haystack.contains("cached credentials")
            || haystack.contains("login failure") || haystack.contains("logon failure")
            || haystack.contains("session") {
            return .sessionExpired(hint: "SteamCMD 报告会话无效")
        }
        if haystack.contains("rate limit exceeded") {
            return .invalidCredentials(hint: "Steam 登录限流，请等待后重试")
        }
        if haystack.contains("invalid password") {
            return .invalidCredentials(hint: "账号或密码不正确")
        }
        if haystack.contains("steam guard") || haystack.contains("two-factor") {
            return .guardRequired(hint: "需要 Steam Guard 验证")
        }
        if haystack.contains("failure!") && haystack.contains("workshop_download_item") {
            return .itemUnavailable
        }
        if haystack.contains("failed to install") || haystack.contains("error!") {
            let snippet = failureMessages.first ?? outputTail
            return .downloadFailed(detail: snippet.isEmpty ? "SteamCMD 报告下载失败" : snippet)
        }
        return nil
    }

    // MARK: - 目录与清单

    private func prepareDirectories() throws {
        let manager = FileManager.default
        do {
            for directory in [layout.root, layout.homeURL, layout.downloadsURL] {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        } catch {
            throw WorkshopDownloadError.storageUnavailable(error.localizedDescription)
        }
    }

    /// 找到真实的内容目录：优先 SteamCMD 的 app 目录，其次回退到 `force_install_dir` 目标。
    private func locateDownloadedContent(itemID: String, preferred: URL) throws -> URL {
        let manager = FileManager.default
        let steamContent = layout.homeURL
            .appendingPathComponent("Steam", isDirectory: true)
            .appendingPathComponent("steamapps", isDirectory: true)
            .appendingPathComponent("workshop", isDirectory: true)
            .appendingPathComponent("content", isDirectory: true)
            .appendingPathComponent(String(WorkshopInputValidator.wallpaperEngineAppID), isDirectory: true)
            .appendingPathComponent(itemID, isDirectory: true)

        for candidate in [steamContent, preferred] {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            // 确认目录确实位于管理根目录内（防御性检查）
            guard WorkshopProjectResolver.isInside(candidate.standardizedFileURL, root: layout.root.standardizedFileURL) else {
                throw WorkshopDownloadError.validationFailed(reason: "下载内容位置越出了应用管理目录，已拒绝处理")
            }
            if !WorkshopProjectResolver.findProjectJSONFiles(in: candidate, manager: manager).isEmpty {
                return candidate
            }
        }
        // 退化：优先目录存在但没有 project.json
        if manager.fileExists(atPath: steamContent.path) { return steamContent }
        if manager.fileExists(atPath: preferred.path) { return preferred }
        throw WorkshopDownloadError.validationFailed(
            reason: "SteamCMD 完成后没有在管理目录中找到内容（可能该作品不属于此账号，或 Steam 下载失败）"
        )
    }

    private func writeManifest(project: WorkshopResolvedProject, item: WorkshopDownloadItem, directory: URL,
                               downloadBackend: String? = "steamcmd", downloadCompletedAt: Date? = nil) throws {
        try Task.checkCancellation()
        guard let id = WorkshopItemID(item.publishedFileID) else {
            throw WorkshopDownloadError.validationFailed(reason: "作品 ID 不合法")
        }
        let digest = try project.videoProject.map { try SteamCMDInstaller.sha256(of: $0.videoURL) }
        let manifest = WorkshopDownloadManifest(
            schemaVersion: 2,
            appID: WorkshopInputValidator.wallpaperEngineAppID,
            publishedFileID: item.publishedFileID,
            title: project.projectTitle ?? item.title,
            projectType: project.projectType,
            projectJSONRelativePath: project.projectJSONPath,
            videoRelativePath: project.videoProject?.videoRelativePath,
            videoByteSize: project.videoProject?.videoByteSize,
            videoSHA256: digest,
            validatedAt: Date(),
            declaredTags: item.declaredTags,
            appVersion: AppConstants.version,
            entryRelativePath: project.entryRelativePath,
            projectByteSize: project.totalByteSize,
            projectFingerprint: project.contentFingerprint,
            resourceCount: project.resourceCount,
            downloadBackend: Self.displayBackend(downloadBackend),
            previewImageURLString: Self.displayPreview(item.previewImageURLString),
            fileSizeBytes: Self.displaySize(item.fileSizeBytes),
            downloadCompletedAt: downloadCompletedAt ?? Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try Task.checkCancellation()
        try data.write(to: directory.appendingPathComponent(GlimmerIdentity.downloadManifestName, isDirectory: false), options: .atomic)
        _ = id
    }

    private static func displayTitle(_ title: String?) -> String? {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 4096, !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return title
    }
    private static func displayTags(_ tags: [String]) -> [String] {
        Array(tags.prefix(128)).filter { !$0.isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
    }
    private static func displayPreview(_ raw: String?) -> String? {
        guard let raw, raw.utf8.count <= 8192, let url = URL(string: raw), url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false, url.user == nil, url.password == nil,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return raw
    }
    private static func displayBackend(_ backend: String?) -> String? {
        ["steamkit2", "steamcmd"].contains(backend ?? "") ? backend : nil
    }
    private static func displaySize(_ size: Int64?) -> Int64? {
        guard let size, size >= 0 else { return nil }; return size
    }
    private func readManifest(directory: URL, itemID: String) -> WorkshopDownloadManifest? {
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard folder >= 0 else { return nil }; defer { close(folder) }
        for name in GlimmerIdentity.downloadManifestNames {
            if let manifest = readManifest(named: name, folder: folder, itemID: itemID) {
                return manifest
            }
        }
        return nil
    }
    private func readManifest(named name: String, folder: Int32, itemID: String) -> WorkshopDownloadManifest? {
        let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_size > 0, info.st_size <= 262_144 else { return nil }
        var bytes = Data(count: Int(info.st_size))
        var count = 0
        let complete = bytes.withUnsafeMutableBytes { buffer -> Bool in
            while count < buffer.count {
                let n = Darwin.read(fd, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }; count += n
            }
            return true
        }
        var after = stat()
        guard complete, fstat(fd, &after) == 0, after.st_dev == info.st_dev, after.st_ino == info.st_ino,
              after.st_size == info.st_size, after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(WorkshopDownloadManifest.self, from: bytes),
              (1...2).contains(manifest.schemaVersion), manifest.appID == WorkshopInputValidator.wallpaperEngineAppID,
              manifest.publishedFileID == itemID else { return nil }
        return manifest
    }
}
