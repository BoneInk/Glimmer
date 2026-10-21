import Foundation

// F17 配置导出/导入：带格式标识与版本号的信封（envelope）。
//
// 设计约束：
// - 只包含偏好、播放、电源策略、播放列表四类设置字段；
//   不包含素材库内容、媒体文件、文件路径、Steam 账号、登录缓存、令牌、密码或 Guard 信息。
// - 导出内容由本文件的类型定义决定，因此天然不含凭据字段。
// - 导入两步走：`validateImport` 完整校验（零副作用）→ `commitImport`（唯一应用入口）。
//   任何未通过完整校验的数据都不会进入提交回调。
// - 校验拒绝：空文件、超大文件、非 JSON、非本应用格式、版本过高、缺少任何分节、
//   字段类型错误、数值越界（音量/倍速/间隔）、显示器或列表条目数量越界、疑似凭据字段。

// MARK: - 播放设置快照

/// 画面适配方式（导出/导入用的稳定枚举，与主程序类型解耦）。
enum GWPlaybackGravity: String, Codable, Sendable, CaseIterable, Identifiable {
    case fit
    case fill

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fit: return "适应屏幕"
        case .fill: return "填满屏幕"
        }
    }
}

/// 播放设置快照：显示器 ID → 播放参数。只含数值与枚举，不含素材文件与路径。
struct GWPlaybackConfiguration: Codable, Equatable, Sendable {
    static let maximumDisplayCount = 64

    struct DisplaySettings: Codable, Equatable, Sendable {
        var isPaused: Bool
        var isMuted: Bool
        var volume: Double
        var rate: Double
        var gravity: GWPlaybackGravity

        static let `default` = DisplaySettings(
            isPaused: false,
            isMuted: true,
            volume: 1.0,
            rate: 1.0,
            gravity: .fill
        )

        init(isPaused: Bool, isMuted: Bool, volume: Double, rate: Double, gravity: GWPlaybackGravity) {
            self.isPaused = isPaused
            self.isMuted = isMuted
            self.volume = volume
            self.rate = rate
            self.gravity = gravity
        }

        init(from decoder: Decoder) throws {
            let defaults = DisplaySettings.default
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? defaults.isPaused
            isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? defaults.isMuted
            volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? defaults.volume
            rate = try container.decodeIfPresent(Double.self, forKey: .rate) ?? defaults.rate
            gravity = try container.decodeIfPresent(GWPlaybackGravity.self, forKey: .gravity) ?? defaults.gravity
            guard volume.isFinite, rate.isFinite else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: container.codingPath,
                    debugDescription: "音量或倍速不是有效数值"
                ))
            }
        }

        /// 越界值修正（导入后的防御：音量 0–1，倍速 0.25–4）。
        func normalized() -> DisplaySettings {
            var copy = self
            copy.volume = min(max(volume, 0), 1)
            copy.rate = min(max(rate, 0.25), 4)
            return copy
        }
    }

    var displays: [String: DisplaySettings]

    init(displays: [String: DisplaySettings] = [:]) {
        self.displays = displays
    }

    static let empty = GWPlaybackConfiguration()

    var displayCount: Int { displays.count }

    func normalized() -> GWPlaybackConfiguration {
        var copy = self
        copy.displays = displays.mapValues { $0.normalized() }
        return copy
    }
}

// MARK: - 导出/导入信封

/// 配置信封：导出文件的最外层结构。
struct GWConfigurationEnvelope: Codable, Sendable {
    static let formatIdentifier = GlimmerIdentity.configurationFormat
    static let currentFormatVersion = 1

    var format: String
    var formatVersion: Int
    /// 导出时间（元数据，可缺失；旧文件/手写文件不强制）。
    var exportedAt: Date?
    var appVersion: String?
    var preferences: GWPreferencesSettings?
    var playback: GWPlaybackConfiguration?
    var policy: GWPolicySettings?
    var playlist: GWPlaylistSettings?

    init(
        format: String = GWConfigurationEnvelope.formatIdentifier,
        formatVersion: Int = GWConfigurationEnvelope.currentFormatVersion,
        exportedAt: Date? = Date(),
        appVersion: String? = nil,
        preferences: GWPreferencesSettings? = nil,
        playback: GWPlaybackConfiguration? = nil,
        policy: GWPolicySettings? = nil,
        playlist: GWPlaylistSettings? = nil
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion ?? GWSettingsBuildInfo.appVersion
        self.preferences = preferences
        self.playback = playback
        self.policy = policy
        self.playlist = playlist
    }
}

/// 通过完整校验、可以安全提交的配置。
///
/// 只能由 `GWConfigurationTransfer.validateImport` 生成；`commitImport` 只接受该类型，
/// 从而保证「先完整校验、后提交」的顺序。
struct GWValidatedConfiguration: Sendable {
    var preferences: GWPreferencesSettings?
    var playback: GWPlaybackConfiguration?
    var policy: GWPolicySettings?
    var playlist: GWPlaylistSettings?
    var sourceFormatVersion: Int
    var exportedAt: Date?

    /// 已被校验的分节名称（用于导入确认界面）。
    var sectionNames: [String] {
        var names: [String] = []
        if preferences != nil { names.append("外观与启动偏好") }
        if let playback {
            names.append("播放设置（\(playback.displayCount) 台显示器）")
        }
        if policy != nil { names.append("电源与睡眠策略") }
        if let playlist {
            names.append("播放列表轮播（\(playlist.itemIDs.count) 个素材）")
        }
        return names
    }
}

/// 配置导入/导出的具名错误（中文说明，可直接展示）。
enum GWConfigurationError: LocalizedError, Equatable {
    case emptyFile
    case oversized(bytes: Int, limit: Int)
    case notJSON
    case missingFormat
    case unrecognizedFormat(String)
    case unsupportedFormatVersion(found: Int, supported: Int)
    case noSections
    case credentialContent(keys: [String])
    case invalidSection(section: String, detail: String)
    case writeFailed(detail: String)

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "所选文件是空的，不包含可导入的配置。"
        case .oversized(let bytes, let limit):
            return "所选文件过大（\(GWSettingsFormat.bytes(Int64(bytes)))），超出配置文件上限 \(GWSettingsFormat.bytes(Int64(limit)))。请确认选择的是Glimmer导出的配置文件。"
        case .notJSON:
            return "所选文件不是有效的 JSON，无法解析。"
        case .missingFormat:
            return "所选文件缺少格式标识，不是Glimmer导出的配置文件。"
        case .unrecognizedFormat(let format):
            return "所选文件的格式标识「\(format)」不是Glimmer配置，已拒绝导入。"
        case .unsupportedFormatVersion(let found, let supported):
            return "配置文件版本 \(found) 高于当前应用支持的版本 \(supported)，请升级应用后再导入。"
        case .noSections:
            return "配置文件不包含任何可导入的设置（外观、播放、电源策略或播放列表）。"
        case .credentialContent(let keys):
            return "配置文件疑似包含账号或凭据字段（\(keys.joined(separator: "、"))），出于安全原因已拒绝导入。"
        case .invalidSection(let section, let detail):
            return "配置「\(section)」无效：\(detail)"
        case .writeFailed(let detail):
            return "写入配置失败：\(detail)"
        }
    }
}

// MARK: - 校验与读写

/// 配置导出/导入的纯逻辑（无 UI 依赖，便于行为验证）。
enum GWConfigurationTransfer {
    /// 导入文件大小上限（1 MiB）：配置文件只含设置，正常的导出远小于此。
    static let maximumImportBytes = 1_048_576
    /// 播放列表条目上限。
    static let maximumPlaylistItems = 10_000
    /// 显示器 ID 长度上限。
    static let maximumDisplayIDLength = 128

    /// 疑似凭据字段（按字段名分词匹配；只用于拒绝导入，不读取字段值）。
    private static let forbiddenKeyTokens: Set<String> = [
        "password", "passwd", "credential", "credentials",
        "token", "tokens", "secret", "secrets",
        "guard", "guardcode", "steamguard",
        "logincache", "loginusers", "auth", "apikey",
        "session", "sessions"
    ]

    // MARK: 导出

    /// 编码信封（人类可读、稳定排序）。
    static func encodeExport(_ envelope: GWConfigurationEnvelope) throws -> Data {
        do {
            return try GWJSONFileStore.makeEncoder().encode(envelope)
        } catch {
            throw GWConfigurationError.writeFailed(detail: error.localizedDescription)
        }
    }

    /// 原子写入导出文件（自动创建上级目录），返回字节数。
    @discardableResult
    static func writeExport(_ envelope: GWConfigurationEnvelope, to url: URL) throws -> Int {
        let data = try encodeExport(envelope)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
        } catch {
            throw GWConfigurationError.writeFailed(detail: error.localizedDescription)
        }
        return data.count
    }

    // MARK: 导入

    /// 从磁盘读取并完整校验配置（零副作用）。
    static func validateImport(contentsOf url: URL) throws -> GWValidatedConfiguration {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize, size > maximumImportBytes {
            throw GWConfigurationError.oversized(bytes: size, limit: maximumImportBytes)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw GWConfigurationError.invalidSection(section: "文件", detail: "无法读取：\(error.localizedDescription)")
        }
        return try validateImport(data: data)
    }

    /// 完整校验导入数据（零副作用；全部通过才返回可提交的配置）。
    static func validateImport(data: Data) throws -> GWValidatedConfiguration {
        guard !data.isEmpty else { throw GWConfigurationError.emptyFile }
        guard data.count <= maximumImportBytes else {
            throw GWConfigurationError.oversized(bytes: data.count, limit: maximumImportBytes)
        }

        // 第一层：原始 JSON 结构与文件头（在类型化解码前给出更清晰的中文错误）。
        let rootObject: Any
        do {
            rootObject = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw GWConfigurationError.notJSON
        }
        guard let root = rootObject as? [String: Any] else {
            throw GWConfigurationError.notJSON
        }
        guard let format = root["format"] as? String else {
            throw GWConfigurationError.missingFormat
        }
        guard GlimmerIdentity.acceptedConfigurationFormats.contains(format) else {
            throw GWConfigurationError.unrecognizedFormat(format)
        }
        guard let formatVersion = root["formatVersion"] as? Int else {
            throw GWConfigurationError.invalidSection(section: "文件头", detail: "缺少格式版本号 formatVersion")
        }
        guard formatVersion >= 1, formatVersion <= GWConfigurationEnvelope.currentFormatVersion else {
            throw GWConfigurationError.unsupportedFormatVersion(
                found: formatVersion,
                supported: GWConfigurationEnvelope.currentFormatVersion
            )
        }

        // 第二层：疑似凭据字段扫描（只读取字段名）。
        let suspiciousKeys = credentialKeys(in: rootObject, depth: 0)
        guard suspiciousKeys.isEmpty else {
            throw GWConfigurationError.credentialContent(keys: Array(Set(suspiciousKeys)).sorted())
        }

        // 第三层：类型化解码（缺字段用默认值，类型错误/未知枚举值报错）。
        let envelope: GWConfigurationEnvelope
        do {
            envelope = try GWJSONFileStore.makeDecoder().decode(GWConfigurationEnvelope.self, from: data)
        } catch let decodingError as DecodingError {
            throw describeDecodingError(decodingError)
        } catch {
            throw GWConfigurationError.invalidSection(section: "配置", detail: "无法解析：\(error.localizedDescription)")
        }

        // 第四层：分节内容与数量校验。
        guard envelope.preferences != nil
            || envelope.playback != nil
            || envelope.policy != nil
            || envelope.playlist != nil else {
            throw GWConfigurationError.noSections
        }

        var playback = envelope.playback
        if var value = playback {
            guard value.displayCount <= GWPlaybackConfiguration.maximumDisplayCount else {
                throw GWConfigurationError.invalidSection(
                    section: "播放设置",
                    detail: "显示器数量 \(value.displayCount) 超出上限 \(GWPlaybackConfiguration.maximumDisplayCount)"
                )
            }
            if let badKey = value.displays.keys.first(where: {
                $0.isEmpty || $0.count > maximumDisplayIDLength
            }) {
                throw GWConfigurationError.invalidSection(
                    section: "播放设置",
                    detail: "显示器标识无效（\(badKey.isEmpty ? "空标识" : "过长")）"
                )
            }
            value = value.normalized()
            playback = value
        }

        var playlist = envelope.playlist
        if var value = playlist {
            guard value.itemIDs.count <= maximumPlaylistItems else {
                throw GWConfigurationError.invalidSection(
                    section: "播放列表",
                    detail: "素材数量 \(value.itemIDs.count) 超出上限 \(maximumPlaylistItems)"
                )
            }
            value = value.normalized()
            playlist = value
        }

        let policy = envelope.policy?.normalized()

        return GWValidatedConfiguration(
            preferences: envelope.preferences,
            playback: playback,
            policy: policy,
            playlist: playlist,
            sourceFormatVersion: formatVersion,
            exportedAt: envelope.exportedAt
        )
    }

    // MARK: 校验辅助

    /// 递归扫描字段名（最多三层），返回疑似凭据的字段名列表（不读取值的任何内容）。
    private static func credentialKeys(in object: Any, depth: Int) -> [String] {
        guard depth <= 3, let dictionary = object as? [String: Any] else { return [] }
        var found: [String] = []
        for (key, value) in dictionary {
            if isForbiddenKey(key) {
                found.append(key)
            }
            if let nested = value as? [String: Any] {
                found.append(contentsOf: credentialKeys(in: nested, depth: depth + 1))
            } else if let array = value as? [Any] {
                for element in array {
                    found.append(contentsOf: credentialKeys(in: element, depth: depth + 1))
                }
            }
        }
        return found
    }

    private static func isForbiddenKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        let tokens = normalized
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        if tokens.contains(where: { forbiddenKeyTokens.contains($0) }) { return true }
        let compact = tokens.joined()
        return compact.contains("steamguard")
            || compact.contains("logincache")
            || compact.contains("loginusers")
    }

    /// 把 DecodingError 映射为中文分节错误。
    private static func describeDecodingError(_ error: DecodingError) -> GWConfigurationError {
        switch error {
        case .keyNotFound(let key, let context):
            return .invalidSection(
                section: sectionName(for: context.codingPath + [key]),
                detail: "缺少字段「\(fieldPathText(context.codingPath + [key]))」"
            )
        case .typeMismatch(_, let context):
            return .invalidSection(
                section: sectionName(for: context.codingPath),
                detail: "字段「\(fieldPathText(context.codingPath))」类型不正确"
            )
        case .valueNotFound(_, let context):
            return .invalidSection(
                section: sectionName(for: context.codingPath),
                detail: "字段「\(fieldPathText(context.codingPath))」缺少有效值"
            )
        case .dataCorrupted(let context):
            let detail = context.codingPath.isEmpty
                ? "数据无法解析"
                : "字段「\(fieldPathText(context.codingPath))」无效：\(context.debugDescription)"
            return .invalidSection(section: sectionName(for: context.codingPath), detail: detail)
        @unknown default:
            return .invalidSection(section: "配置", detail: "无法解析：\(error)")
        }
    }

    private static func sectionName(for codingPath: [CodingKey]) -> String {
        guard let first = codingPath.first?.stringValue else { return "文件头" }
        switch first {
        case "preferences": return "外观与启动偏好"
        case "playback": return "播放设置"
        case "policy": return "电源与睡眠策略"
        case "playlist": return "播放列表"
        default: return "文件头"
        }
    }

    private static func fieldPathText(_ codingPath: [CodingKey]) -> String {
        codingPath.map(\.stringValue).joined(separator: ".")
    }
}
