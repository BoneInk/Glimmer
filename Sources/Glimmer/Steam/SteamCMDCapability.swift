import Foundation

/// SteamCMD 运行时能力探测（F13）。
///
/// 设计原则：
/// - **不推断**下载权限：网页登录/OpenID 与 SteamCMD 下载认证完全无关。
/// - 只做真实检测：官方安装包下载 + 校验、二进制架构读取、Rosetta 可用性、真实进程探测。
/// - 不自动安装系统组件（Rosetta 需要用户自行在系统设置中安装），不触碰全局 Steam 目录。

/// 已安装 SteamCMD 二进制的架构。
enum SteamCMDBinaryArchitecture: String, Sendable, Equatable {
    case arm64
    case x86_64
    case universal
    case unknown

    var displayName: String {
        switch self {
        case .arm64: return "arm64（Apple Silicon 原生）"
        case .x86_64: return "x86_64（Intel；Apple Silicon 上需要 Rosetta）"
        case .universal: return "通用二进制（arm64 + x86_64）"
        case .unknown: return "未知架构"
        }
    }
}

/// Rosetta 2 可用性检测结果。
enum RosettaStatus: Sendable, Equatable {
    /// 当前机器不需要 Rosetta（原生 arm64 二进制或 Intel 主机）。
    case notRequired
    case available(detail: String)
    case missing(detail: String)

    var isUsable: Bool {
        switch self {
        case .notRequired, .available: return true
        case .missing: return false
        }
    }

    var displayText: String {
        switch self {
        case .notRequired: return "无需 Rosetta"
        case .available(let detail): return "Rosetta 可用（\(detail)）"
        case .missing(let detail): return "缺少 Rosetta（\(detail)）"
        }
    }
}

/// SteamCMD 运行时的整体状态。
enum SteamCMDRuntimeStatus: Sendable, Equatable {
    /// 未安装（用户可以点击下载）。
    case notInstalled
    /// 本机是 arm64 且缺少 Rosetta，官方 x86_64 二进制无法运行。
    /// `canStillDownload` 表示仍可下载安装包（安装后依然需要 Rosetta 才能运行）。
    case rosettaRequired(canStillDownload: Bool)
    /// 已安装且真实探测通过。
    case ready(version: String?)
    /// 已安装但无法执行（含真实错误输出摘要）。
    case unusable(reason: String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .notInstalled: return "未安装 SteamCMD"
        case .rosettaRequired: return "需要 Rosetta 2 才能运行官方 SteamCMD"
        case .ready(let version): return "SteamCMD 可用" + (version.map { "（\($0)）" } ?? "")
        case .unusable(let reason): return "SteamCMD 不可用：\(reason)"
        }
    }
}

/// SteamCMD 能力报告（供 UI 与 evidence 使用）。
struct SteamCMDReport: Sendable, Equatable {
    var status: SteamCMDRuntimeStatus
    var executablePath: String?
    var architecture: SteamCMDBinaryArchitecture?
    var rosetta: RosettaStatus
    var hostArchitecture: String
    var binaryExists: Bool
    /// 探测过程中真实观察到的证据（命令、输出摘要），全部脱敏。
    var evidence: [String]
    /// 官方安装包地址（HTTPS）。
    var archiveURL: URL = SteamCMDLayout.archiveURL

    var summaryText: String {
        var lines: [String] = []
        lines.append("主机架构：\(hostArchitecture)")
        lines.append("SteamCMD：\(status.displayText)")
        lines.append("Rosetta：\(rosetta.displayText)")
        if let architecture { lines.append("二进制架构：\(architecture.displayName)") }
        if let executablePath { lines.append("位置：\(SteamCMDLayout.displayPath(executablePath))") }
        return lines.joined(separator: "\n")
    }
}

/// 官方 SteamCMD 的目录布局（全部位于应用管理目录内，绝不写入全局 Steam 目录）。
struct SteamCMDLayout: Sendable {
    /// 官方 macOS 安装包（HTTPS，Steam CDN）。
    static let archiveURL = URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz")!
    static let layoutVersion = 1

    let root: URL

    init(root: URL) { self.root = root }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        self.root = base
            .appendingPathComponent(AppConstants.applicationSupportFolderName, isDirectory: true)
            .appendingPathComponent("Workshop", isDirectory: true)
            .appendingPathComponent("SteamCMD", isDirectory: true)
    }

    var executableURL: URL { root.appendingPathComponent("steamcmd", isDirectory: false) }
    var installRecordURL: URL { root.appendingPathComponent("install-record.json", isDirectory: false) }
    var downloadsURL: URL { root.appendingPathComponent("downloads", isDirectory: true) }

    /// 隔离的 HOME：SteamCMD 的账号缓存只写入这里，不读取用户真实 ~/Steam。
    var homeURL: URL { root.appendingPathComponent("home", isDirectory: true) }
    var logFileURL: URL { homeURL.appendingPathComponent("steamcmd.log", isDirectory: false) }
    var loginUsersURL: URL { homeURL.appendingPathComponent("config/loginusers.vdf", isDirectory: false) }

    /// Both official layouts remain inside the isolated HOME, never the user's Steam.
    var loginCacheDirectories: [URL] {
        [homeURL.appendingPathComponent("config", isDirectory: true),
         homeURL.appendingPathComponent("Library/Application Support/Steam/config", isDirectory: true)]
    }
    var loginCacheFiles: [URL] {
        loginCacheDirectories.flatMap { directory in
            [directory.appendingPathComponent("loginusers.vdf"), directory.appendingPathComponent("config.vdf")]
        }
    }
    func isSafeProfileLocation(_ url: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let homePath = homeURL.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return homePath.hasPrefix(rootPath + "/") && path.hasPrefix(homePath + "/")
    }

    func downloadDirectory(for itemID: WorkshopItemID) -> URL {
        downloadsURL
            .appendingPathComponent("\(WorkshopInputValidator.wallpaperEngineAppID)", isDirectory: true)
            .appendingPathComponent(itemID.value, isDirectory: true)
    }

    func manifestURL(for itemID: WorkshopItemID) -> URL {
        downloadDirectory(for: itemID).appendingPathComponent(GlimmerIdentity.downloadManifestName, isDirectory: false)
    }

    func legacyManifestURL(for itemID: WorkshopItemID) -> URL {
        downloadDirectory(for: itemID).appendingPathComponent(GlimmerIdentity.legacyDownloadManifestName, isDirectory: false)
    }

    func installRecord() -> SteamCMDInstallRecord? {
        guard let data = try? Data(contentsOf: installRecordURL) else { return nil }
        return try? JSONDecoder().decode(SteamCMDInstallRecord.self, from: data)
    }

    /// 展示用路径（用户主目录替换为 `~`，避免把完整用户名写进日志/证据）。
    static func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

/// 安装记录（记录安装时间与校验结果，便于诊断；不含任何账号信息）。
struct SteamCMDInstallRecord: Codable, Sendable, Equatable {
    var layoutVersion: Int
    var installedAt: Date
    var archiveURL: String
    var archiveByteSize: Int64
    var archiveSHA256: String
    var executableRelativePath: String
    var architecture: String
    var smokeTestPassed: Bool
    var smokeTestOutputSummary: String
}

/// 能力探测服务。
struct SteamCMDCapabilityProbe: Sendable {
    private let layout: SteamCMDLayout
    private let processRunner = WorkshopProcessRunner()

    init(layout: SteamCMDLayout = SteamCMDLayout()) {
        self.layout = layout
    }

    /// 完整探测：二进制存在性 → 架构 → Rosetta → 真实进程探测。
    func probe() async -> SteamCMDReport {
        var evidence: [String] = []
        let hostArchitecture = Self.hostArchitecture()
        evidence.append("主机架构：\(hostArchitecture)")

        let fileManager = FileManager.default
        let executable = layout.executableURL
        let exists = fileManager.isExecutableFile(atPath: executable.path)
        evidence.append("二进制存在：\(exists ? "是" : "否")（\(SteamCMDLayout.displayPath(executable.path))）")

        guard exists else {
            let rosetta = Self.detectRosetta()
            evidence.append("Rosetta 检测：\(rosetta.displayText)")
            return SteamCMDReport(
                status: .notInstalled,
                executablePath: nil,
                architecture: nil,
                rosetta: rosetta,
                hostArchitecture: hostArchitecture,
                binaryExists: false,
                evidence: evidence
            )
        }

        var architecture = Self.readArchitecture(at: executable)
        evidence.append("二进制架构：\(architecture.displayName)")

        var rosetta: RosettaStatus = architecture == .arm64 || architecture == .universal ? .notRequired : Self.detectRosetta()
        evidence.append("Rosetta 检测：\(rosetta.displayText)")

        if architecture == .x86_64 {
            if hostArchitecture == "arm64", !rosetta.isUsable {
                evidence.append("官方 SteamCMD 为 x86_64，本机为 Apple Silicon 且未检测到 Rosetta，无法执行。")
                return SteamCMDReport(
                    status: .rosettaRequired(canStillDownload: true),
                    executablePath: executable.path,
                    architecture: architecture,
                    rosetta: rosetta,
                    hostArchitecture: hostArchitecture,
                    binaryExists: true,
                    evidence: evidence
                )
            }
        }

        // 真实进程探测：只执行 +quit（不登录、不下载）。
        do {
            let smokeTest = try await runSmokeTest(executable: executable)
            // Self-update may replace the Intel bootstrap with an arm64/universal runtime.
            let updatedArchitecture = Self.readArchitecture(at: executable)
            if updatedArchitecture != architecture {
                evidence.append("更新后的二进制架构：\(updatedArchitecture.displayName)")
                architecture = updatedArchitecture
            }
            if architecture == .arm64 || architecture == .universal { rosetta = .notRequired }
            let output = smokeTest.output
            if smokeTest.updateRestarts > 0 {
                evidence.append("SteamCMD 首次更新完成后自动重启 \(smokeTest.updateRestarts) 次；随后真实退出码为 0")
            }
            let summary = SteamCMDCapabilityProbe.summarize(output)
            evidence.append("执行 `steamcmd +quit` 成功")
            evidence.append("输出摘要：\(summary.isEmpty ? "(无输出)" : summary)")
            let version = Self.extractVersionLine(from: output)
            if var existing = layout.installRecord() {
                existing.smokeTestPassed = true
                existing.smokeTestOutputSummary = summary
                if let data = try? JSONEncoder().encode(existing) {
                    try? data.write(to: layout.installRecordURL, options: .atomic)
                }
            }
            return SteamCMDReport(
                status: .ready(version: version),
                executablePath: executable.path,
                architecture: architecture,
                rosetta: rosetta,
                hostArchitecture: hostArchitecture,
                binaryExists: true,
                evidence: evidence
            )
        } catch {
            let reason = (error as? WorkshopProcessError)?.errorDescription ?? error.localizedDescription
            evidence.append("执行 `steamcmd +quit` 失败：\(WorkshopLog.sanitize(reason))")
            if var record = layout.installRecord() {
                record.smokeTestPassed = false
                record.smokeTestOutputSummary = WorkshopLog.sanitize(reason)
                if let data = try? JSONEncoder().encode(record) {
                    try? data.write(to: layout.installRecordURL, options: .atomic)
                }
            }
            return SteamCMDReport(
                status: .unusable(reason: WorkshopLog.sanitize(reason)),
                executablePath: executable.path,
                architecture: architecture,
                rosetta: rosetta,
                hostArchitecture: hostArchitecture,
                binaryExists: true,
                evidence: evidence
            )
        }
    }

    private func runSmokeTest(executable: URL) async throws -> SteamCMDBootstrap.Result {
        try await SteamCMDBootstrap.run { remainingTimeout in
            try await processRunner.run(
                executable: executable,
                arguments: ["+quit"],
                environment: WorkshopProcessRunner.steamcmdEnvironment(home: layout.homeURL),
                currentDirectory: layout.root,
                timeout: remainingTimeout,
                stdinLines: nil,
                lineHandler: nil
            )
        }
    }

    static func summarize(_ output: String) -> String {
        let lines: [String] = output
            .split(separator: "\n")
            .map { SteamHTML.collapseWhitespace(String($0)) }
            .filter { !$0.isEmpty }
        let interesting = lines.filter { line in
            let lowered = line.lowercased()
            return lowered.contains("steamcmd")
                || lowered.contains("version")
                || lowered.contains("error")
                || lowered.contains("fail")
                || lowered.contains("update")
        }
        let chosen: [String] = interesting.isEmpty ? Array(lines.suffix(3)) : Array(interesting.suffix(4))
        return WorkshopLog.sanitize(chosen.joined(separator: " | "))
    }

    static func extractVersionLine(from output: String) -> String? {
        for line in output.split(separator: "\n").reversed() {
            let trimmed = SteamHTML.collapseWhitespace(String(line))
            let lowered = trimmed.lowercased()
            // 真实 SteamCMD 的版本行形如：
            // `Steam Console Client (c) Valve Corporation - version 1234567890`
            if lowered.contains("steam console client") || (lowered.contains("steamcmd") && lowered.contains("version")) {
                return WorkshopLog.sanitize(trimmed)
            }
        }
        return nil
    }

    // MARK: - 静态检测

    static func hostArchitecture() -> String {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return "unknown" }
        let machine = withUnsafeBytes(of: &systemInfo.machine) { buffer -> String in
            let bytes = buffer.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine
    }

    static func detectRosetta() -> RosettaStatus {
        if hostArchitecture() != "arm64" {
            return .notRequired
        }
        // 唯一可信的判据：真实执行一个 x86_64 进程。
        // 注意：/Library/Apple/usr/libexec/oah 目录在未安装 Rosetta 的机器上也可能存在
        // （本机实测如此），因此绝不能仅凭目录存在就认定 Rosetta 可用。
        if canExecuteX86_64Process() {
            return .available(detail: "x86_64 进程执行成功（/usr/bin/arch -x86_64 /usr/bin/true）")
        }
        return .missing(detail: "无法执行 x86_64 进程：未安装或未启用 Rosetta 2")
    }

    /// 真实执行 `/usr/bin/arch -x86_64 /usr/bin/true`，以退出状态为准。
    private static func canExecuteX86_64Process() -> Bool {
        let executablePath = "/usr/bin/arch"
        guard FileManager.default.isExecutableFile(atPath: executablePath) else { return false }
        let arguments = [executablePath, "-x86_64", "/usr/bin/true"]
        let cArguments = arguments.map { strdup($0) } + [nil]
        defer { cArguments.forEach { free($0) } }

        // 把子进程的 stdout/stderr 丢弃，避免把系统的 "Bad CPU type" 提示打进应用日志。
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 2, "/dev/null", O_WRONLY, 0)

        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, executablePath, &fileActions, nil, cArguments, environ)
        guard spawnStatus == 0 else { return false }
        var status: Int32 = 0
        guard waitpid(pid, &status, 0) == pid else { return false }
        return status == 0
    }

    /// 读取 Mach-O 头部的 CPU 架构。
    static func readArchitecture(at url: URL) -> SteamCMDBinaryArchitecture {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count >= 8 else { return .unknown }
        let magic = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let littleEndian = magic.littleEndian

        func mapCPU(_ cpu: UInt32) -> SteamCMDBinaryArchitecture? {
            // CPU_TYPE_X86_64 = 0x01000007, CPU_TYPE_ARM64 = 0x0100000C
            switch cpu {
            case 0x01000007: return .x86_64
            case 0x0100000C: return .arm64
            default: return nil
            }
        }

        switch littleEndian {
        case 0xFEEDFACF: // MH_MAGIC_64 (little-endian thin Mach-O)
            let cpu = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian }
            return mapCPU(cpu) ?? .unknown
        // Header bytes are big-endian CAFEBABE / CAFEBABF, read above as little-endian.
        case 0xBEBAFECA, 0xBFBAFECA:
            let entrySize = littleEndian == 0xBFBAFECA ? 32 : 20
            let count = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).bigEndian }
            guard count > 0, count <= 64,
                  let entries = try? handle.read(upToCount: Int(count) * entrySize),
                  entries.count == Int(count) * entrySize else { return .unknown }
            var architectures: Set<SteamCMDBinaryArchitecture> = []
            for index in 0..<Int(count) {
                let cpu = entries.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * entrySize, as: UInt32.self).bigEndian }
                if let mapped = mapCPU(cpu) { architectures.insert(mapped) }
            }
            if architectures.contains(.arm64) && architectures.contains(.x86_64) { return .universal }
            return architectures.first ?? .unknown
        default:
            return .unknown
        }
    }
}
