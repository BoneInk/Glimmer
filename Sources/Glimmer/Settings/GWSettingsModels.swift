import Foundation

// F17 外观与全局偏好：独立于素材库的版本化设置文件。
//
// 存储位置：Application Support/Glimmer/preferences.json（与应用数据目录一致）。
// 设计约束：
// - 独立 JSON、schemaVersion、原子写入、损坏文件隔离保留；
// - 宽松解码：缺失字段回退默认值，旧文件/新文件都可读（向后兼容）；
// - 不包含任何账号、令牌、Guard 或 Steam 会话字段。

/// 应用外观模式。
enum GWAppearanceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// 辅助说明（设置界面与 VoiceOver 提示）。
    var hintText: String {
        switch self {
        case .system: return "外观跟随 macOS 系统设置自动切换"
        case .light: return "始终使用浅色外观"
        case .dark: return "始终使用深色外观"
        }
    }
}

/// 全局偏好设置（独立持久化，可导出/导入）。
///
/// 说明：启动时恢复壁纸的最终行为由主程序通过外部绑定（闭包）读取/应用，
/// 这里保存的是用户的意图值，用于重启后恢复与配置迁移。
struct GWPreferencesSettings: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case appearance
        case backgroundBrightness
        case backgroundBlur
        case wallpaperFPS
        case lockScreenExport
        case restoreWallpapersOnLaunch
    }

    /// 界面外观（跟随系统/浅色/深色）。
    var appearance: GWAppearanceMode
    /// 应用内背景明暗（0 最暗，1 最亮）。
    var backgroundBrightness: Double {
        didSet {
            backgroundBrightness = Self.normalizedUnitValue(backgroundBrightness, fallback: 0.15)
        }
    }
    /// 应用内背景模糊强度（0 无模糊，1 最大模糊）。
    var backgroundBlur: Double {
        didSet {
            backgroundBlur = Self.normalizedUnitValue(backgroundBlur, fallback: 0.15)
        }
    }
    /// Scene 与 Web 壁纸的全局帧率上限；视频保持素材原始帧率。
    var wallpaperFPS: Int {
        didSet { wallpaperFPS = Self.normalizedFPS(wallpaperFPS) }
    }
    var lockScreenExport: GWLockScreenExportSettings
    /// 启动应用时恢复上次的桌面视频壁纸。
    var restoreWallpapersOnLaunch: Bool

    init(
        appearance: GWAppearanceMode = .dark,
        backgroundBrightness: Double = 0.15,
        backgroundBlur: Double = 0.15,
        wallpaperFPS: Int = 30,
        lockScreenExport: GWLockScreenExportSettings = .init(),
        restoreWallpapersOnLaunch: Bool = false
    ) {
        self.appearance = appearance
        self.backgroundBrightness = Self.normalizedUnitValue(backgroundBrightness, fallback: 0.15)
        self.backgroundBlur = Self.normalizedUnitValue(backgroundBlur, fallback: 0.15)
        self.wallpaperFPS = Self.normalizedFPS(wallpaperFPS)
        self.lockScreenExport = lockScreenExport
        self.restoreWallpapersOnLaunch = restoreWallpapersOnLaunch
    }

    static let `default` = GWPreferencesSettings()

    /// 宽松解码：缺失字段回退默认值；无法识别的枚举值回退为默认深色。
    init(from decoder: Decoder) throws {
        let defaults = GWPreferencesSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try container.decodeIfPresent(String.self, forKey: .appearance),
           let mode = GWAppearanceMode(rawValue: raw) {
            appearance = mode
        } else {
            appearance = defaults.appearance
        }
        backgroundBrightness = Self.decodeUnitValue(
            from: container,
            forKey: .backgroundBrightness,
            fallback: defaults.backgroundBrightness
        )
        backgroundBlur = Self.decodeUnitValue(
            from: container,
            forKey: .backgroundBlur,
            fallback: defaults.backgroundBlur
        )
        wallpaperFPS = Self.normalizedFPS(
            (try? container.decode(Int.self, forKey: .wallpaperFPS)) ?? defaults.wallpaperFPS
        )
        lockScreenExport = (try? container.decode(GWLockScreenExportSettings.self, forKey: .lockScreenExport))
            ?? defaults.lockScreenExport
        restoreWallpapersOnLaunch = try container.decodeIfPresent(
            Bool.self,
            forKey: .restoreWallpapersOnLaunch
        ) ?? defaults.restoreWallpapersOnLaunch
    }

    private static func decodeUnitValue(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        fallback: Double
    ) -> Double {
        guard let value = try? container.decode(Double.self, forKey: key) else {
            return fallback
        }
        return normalizedUnitValue(value, fallback: fallback)
    }

    private static func normalizedUnitValue(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, 0), 1)
    }

    private static func normalizedFPS(_ value: Int) -> Int {
        min(max(value, 1), 240)
    }
}

/// 偏好设置文档（带版本号，可隔离损坏文件）。
struct GWPreferencesDocument: GWVersionedDocument {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var updatedAt: Date
    /// 写入时的应用版本（仅诊断用，可为空）。
    var appVersion: String?
    var settings: GWPreferencesSettings

    init(settings: GWPreferencesSettings, appVersion: String? = nil, updatedAt: Date = Date()) {
        self.schemaVersion = Self.currentSchemaVersion
        self.updatedAt = updatedAt
        self.appVersion = appVersion ?? GWSettingsBuildInfo.appVersion
        self.settings = settings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
        settings = try container.decodeIfPresent(GWPreferencesSettings.self, forKey: .settings) ?? .default
    }
}

/// 应用构建信息（避免依赖其他模块的常量）。
enum GWSettingsBuildInfo {
    /// 当前应用版本（从应用包读取；CLI 环境回退为「未知版本」）。
    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "未知版本"
    }

    /// 当前运行的是否为独立应用包（.app）。
    static func isRunningFromAppBundle(_ bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        bundleURL.pathExtension.lowercased() == "app"
    }
}

/// 设置模块的存储路径（默认与应用数据目录一致）。
struct GWSettingsPaths: Sendable, Equatable {
    static let preferencesFileName = "preferences.json"

    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? GWPersistencePaths.defaultRoot
    }

    var preferencesFile: URL {
        root.appendingPathComponent(Self.preferencesFileName, isDirectory: false)
    }
}

/// 偏好设置持久化：读取失败不崩溃；损坏文件隔离保留，便于用户找回。
enum GWPreferencesPersistence {
    /// 读取偏好；文件不存在返回 nil；版本过高/损坏抛出具名错误。
    static func load(from url: URL) throws -> GWPreferencesDocument? {
        try GWJSONFileStore.load(GWPreferencesDocument.self, from: url)
    }

    /// 原子保存，返回写入字节数。
    @discardableResult
    static func save(_ settings: GWPreferencesSettings, to url: URL) throws -> Int {
        let document = GWPreferencesDocument(settings: settings)
        return try GWJSONFileStore.save(document, to: url)
    }

    /// 隔离不可解析/版本过高的配置文件（保留原文用于诊断）。
    @discardableResult
    static func quarantine(_ url: URL) -> URL? {
        GWJSONFileStore.quarantine(url)
    }
}

/// 展示格式化（设置界面与清理结果共用，不依赖 AppKit）。
enum GWSettingsFormat {
    static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "0 字节" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func fileCount(_ count: Int) -> String {
        "\(count) 个文件"
    }

    static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
