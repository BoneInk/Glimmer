import Foundation

// F20 本地诊断：脱敏快照 + 中文报告。
//
// 安全边界：
// - 只读取应用自身管理的文件与公开进程信息，绝不读取 SteamCMD 原始输出或登录缓存；
// - 不包含账号名、密码、令牌、Guard 信息；
// - 用户主目录在展示与导出前替换为 `~`，其他用户目录（/Users/...、/Volumes/...）一并隐藏；
// - 主控注入的扩展条目在进入快照前会再经过一次脱敏（防御深浅两层）。

/// 诊断条目的严重级别。
enum GWDiagnosticSeverity: String, Sendable, CaseIterable, Identifiable {
    case ok
    case info
    case warning
    case error

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ok: return "正常"
        case .info: return "提示"
        case .warning: return "注意"
        case .error: return "需要处理"
        }
    }

    var symbolName: String {
        switch self {
        case .ok: return "checkmark.circle"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    /// 排序权重（越严重越靠前）。
    var sortWeight: Int {
        switch self {
        case .error: return 0
        case .warning: return 1
        case .info: return 2
        case .ok: return 3
        }
    }
}

/// 诊断分类（权限/网络/解码/Steam 工具等，帮助用户理解问题来源）。
enum GWDiagnosticCategory: String, Sendable, CaseIterable, Identifiable {
    case storage
    case permission
    case network
    case codec
    case steamHelper
    case playback
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .storage: return "存储"
        case .permission: return "权限"
        case .network: return "网络"
        case .codec: return "视频解码"
        case .steamHelper: return "Steam 工具"
        case .playback: return "播放"
        case .other: return "其他"
        }
    }

    var symbolName: String {
        switch self {
        case .storage: return "internaldrive"
        case .permission: return "lock.shield"
        case .network: return "wifi"
        case .codec: return "film"
        case .steamHelper: return "shippingbox"
        case .playback: return "play.rectangle"
        case .other: return "questionmark.circle"
        }
    }
}

/// 一条诊断结果。
struct GWDiagnosticItem: Identifiable, Sendable, Equatable {
    var id: String
    var category: GWDiagnosticCategory
    var severity: GWDiagnosticSeverity
    var title: String
    var detail: String?
    var suggestion: String?

    init(
        id: String,
        category: GWDiagnosticCategory,
        severity: GWDiagnosticSeverity,
        title: String,
        detail: String? = nil,
        suggestion: String? = nil
    ) {
        self.id = id
        self.category = category
        self.severity = severity
        self.title = title
        self.detail = detail
        self.suggestion = suggestion
    }
}

/// 环境事实（键值对，已脱敏）。
struct GWDiagnosticsFact: Sendable, Equatable, Identifiable {
    var label: String
    var value: String
    var id: String { label }
}

/// 诊断快照。
struct GWDiagnosticsSnapshot: Sendable, Equatable {
    var generatedAt: Date
    var facts: [GWDiagnosticsFact]
    var items: [GWDiagnosticItem]
    var recentIssues: [String]
    var privacyNote: String

    static let defaultPrivacyNote = "报告已脱敏：不包含账号名、密码、令牌、Guard 信息或用户主目录绝对路径；只包含本机公开状态与应用自身的计数。"
}

/// 采集输入（全部为已知安全或经过脱敏的数据）。
struct GWDiagnosticsInputs: Sendable {
    var storageRoot: URL
    var preferencesFile: URL
    var inventory: GWStorageInventory?
    var extras: [GWDiagnosticItem]
    var recentIssues: [String]
}

/// 诊断采集器（纯逻辑，可独立验证）。
struct GWDiagnosticsCollector: Sendable {
    static func collect(inputs: GWDiagnosticsInputs) -> GWDiagnosticsSnapshot {
        let manager = FileManager.default
        var items: [GWDiagnosticItem] = []

        // 1. 应用数据目录可写性
        if manager.fileExists(atPath: inputs.storageRoot.path) {
            if manager.isWritableFile(atPath: inputs.storageRoot.path) {
                items.append(GWDiagnosticItem(
                    id: "storage.root",
                    category: .storage,
                    severity: .ok,
                    title: "应用数据目录可写",
                    detail: "素材库与设置可以保存。"
                ))
            } else {
                items.append(GWDiagnosticItem(
                    id: "storage.root",
                    category: .permission,
                    severity: .error,
                    title: "应用数据目录不可写",
                    detail: "无法保存素材库、设置或缓存。",
                    suggestion: "检查「系统设置 → 隐私与安全性 → 文件与文件夹」中的访问权限，以及磁盘剩余空间后重试。"
                ))
            }
        } else {
            items.append(GWDiagnosticItem(
                id: "storage.root",
                category: .storage,
                severity: .info,
                title: "应用数据目录尚未创建",
                detail: "导入素材或应用壁纸后会自动创建。"
            ))
        }

        // 2. 偏好文件可解析
        do {
            if let document = try GWPreferencesPersistence.load(from: inputs.preferencesFile) {
                items.append(GWDiagnosticItem(
                    id: "settings.preferences",
                    category: .storage,
                    severity: .ok,
                    title: "偏好设置有效",
                    detail: "外观：\(document.settings.appearance.displayName)。"
                ))
            } else {
                items.append(GWDiagnosticItem(
                    id: "settings.preferences",
                    category: .storage,
                    severity: .info,
                    title: "偏好设置使用默认值",
                    detail: "尚未保存过自定义偏好。"
                ))
            }
        } catch {
            items.append(GWDiagnosticItem(
                id: "settings.preferences",
                category: .storage,
                severity: .warning,
                title: "偏好设置无法读取",
                detail: "已回退默认值：\(error.localizedDescription)",
                suggestion: "可在设置中使用「恢复默认设置」重建偏好文件。"
            ))
        }

        // 3. 磁盘空间
        if let values = try? inputs.storageRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            let lowSpace = capacity < 1_073_741_824
            items.append(GWDiagnosticItem(
                id: "storage.capacity",
                category: .storage,
                severity: lowSpace ? .warning : .ok,
                title: "可用磁盘空间",
                detail: GWSettingsFormat.bytes(capacity),
                suggestion: lowSpace ? "可用空间不足 1 GB，导入或下载大体积视频可能失败。" : nil
            ))
        }

        // 4. 环境事实（主目录路径脱敏）
        var facts: [GWDiagnosticsFact] = [
            GWDiagnosticsFact(label: "应用", value: "Glimmer \(GWSettingsBuildInfo.appVersion)"),
            GWDiagnosticsFact(label: "系统", value: ProcessInfo.processInfo.operatingSystemVersionString),
            GWDiagnosticsFact(label: "架构", value: architectureName),
            GWDiagnosticsFact(label: "数据目录", value: GWDiagnosticsRedactor.redact(inputs.storageRoot.path))
        ]
        if let inventory = inputs.inventory {
            facts.append(GWDiagnosticsFact(
                label: "可清理缓存合计",
                value: "\(GWSettingsFormat.fileCount(inventory.totalCleanableCount))，共 \(GWSettingsFormat.bytes(inventory.totalCleanableBytes))"
            ))
            for category in inventory.categories {
                facts.append(GWDiagnosticsFact(
                    label: category.category.displayName,
                    value: category.isAvailable
                        ? "\(GWSettingsFormat.fileCount(category.fileCount))，共 \(category.sizeText)"
                        : "目录尚未创建"
                ))
            }
        } else {
            facts.append(GWDiagnosticsFact(label: "可清理缓存合计", value: "尚未统计（打开存储清理会自动统计）"))
        }

        // 5. 主控注入的检查项（再脱敏一次，防御性）
        for item in inputs.extras {
            items.append(sanitize(item))
        }

        // 6. 最近问题（脱敏、去重、限长）
        var seenIssues = Set<String>()
        let issues = inputs.recentIssues
            .map { GWDiagnosticsRedactor.redact($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seenIssues.insert($0).inserted }
            .map { String($0.prefix(300)) }
            .prefix(12)

        return GWDiagnosticsSnapshot(
            generatedAt: Date(),
            facts: facts,
            items: items.sorted { lhs, rhs in
                if lhs.severity.sortWeight != rhs.severity.sortWeight {
                    return lhs.severity.sortWeight < rhs.severity.sortWeight
                }
                return lhs.title < rhs.title
            },
            recentIssues: Array(issues),
            privacyNote: GWDiagnosticsSnapshot.defaultPrivacyNote
        )
    }

    private static var architectureName: String {
        #if arch(arm64)
        return "Apple Silicon（arm64）"
        #elseif arch(x86_64)
        return "Intel（x86_64）"
        #else
        return "未知"
        #endif
    }

    private static func sanitize(_ item: GWDiagnosticItem) -> GWDiagnosticItem {
        GWDiagnosticItem(
            id: item.id,
            category: item.category,
            severity: item.severity,
            title: GWDiagnosticsRedactor.redact(item.title),
            detail: item.detail.map(GWDiagnosticsRedactor.redact),
            suggestion: item.suggestion.map(GWDiagnosticsRedactor.redact)
        )
    }
}

/// 脱敏器：导出与展示前的最后一道防线。
enum GWDiagnosticsRedactor {
    static func redact(_ text: String) -> String {
        var result = text
        let home = NSHomeDirectory()
        if !home.isEmpty, home != "/" {
            result = result.replacingOccurrences(of: home, with: "~")
        }
        result = replace(pattern: "/Users/[^/\\s]+", in: result, with: "~")
        result = replace(pattern: "/Volumes/[^/\\s]+", in: result, with: "/Volumes/…")
        result = replace(
            pattern: "(?i)(password|passwd|steam\\s?guard|guard\\s?code|token|api[ _-]?key|secret)\\s*[:=]\\s*\\S+",
            in: result,
            with: "$1：<已隐藏>"
        )
        result = replace(pattern: "\\b\\d{17,20}\\b", in: result, with: "<已隐藏>")
        result = replace(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", in: result, with: "<已隐藏>")
        return result
    }

    private static func replace(pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

/// 诊断报告文本（用于复制到剪贴板与导出文件）。
enum GWDiagnosticsReport {
    static func makeText(_ snapshot: GWDiagnosticsSnapshot) -> String {
        var lines: [String] = []
        lines.append("Glimmer · 诊断报告")
        lines.append("生成时间：\(GWSettingsFormat.dateTime(snapshot.generatedAt))")
        lines.append("")
        lines.append("【环境】")
        for fact in snapshot.facts {
            lines.append("\(fact.label)：\(fact.value)")
        }
        lines.append("")
        lines.append("【检查结果】")
        for item in snapshot.items {
            lines.append("[\(item.severity.displayName)] [\(item.category.displayName)] \(item.title)")
            if let detail = item.detail, !detail.isEmpty {
                lines.append("    \(detail)")
            }
            if let suggestion = item.suggestion, !suggestion.isEmpty {
                lines.append("    建议：\(suggestion)")
            }
        }
        if !snapshot.recentIssues.isEmpty {
            lines.append("")
            lines.append("【最近记录】")
            for issue in snapshot.recentIssues {
                lines.append("- \(issue)")
            }
        }
        lines.append("")
        lines.append(snapshot.privacyNote)
        return lines.joined(separator: "\n")
    }
}
