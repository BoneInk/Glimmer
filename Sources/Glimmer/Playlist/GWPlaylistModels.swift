import Foundation

// F19 播放列表轮播：模型 + 纯选择算法。
//
// 播放列表只保存素材 UUID（不保存文件路径、不复制素材），
// 素材是否存在/可播放由主控通过 `isItemPlayable` 闭包注入判断，
// 因此本模块不依赖素材库类型，也不会硬编码任何真实用户库。

// MARK: - 模式

/// 轮播顺序模式。
enum GWPlaylistMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case ordered
    case shuffle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ordered: return "顺序"
        case .shuffle: return "随机"
        }
    }

    var symbolName: String {
        switch self {
        case .ordered: return "list.number"
        case .shuffle: return "shuffle"
        }
    }
}

// MARK: - 设置

/// F19 播放列表设置（独立持久化，可导出/导入）。
struct GWPlaylistSettings: Codable, Equatable, Sendable {
    /// 是否启用自动轮播。
    var isEnabled: Bool
    /// 轮播顺序。
    var mode: GWPlaylistMode
    /// 轮播间隔（秒）。
    var intervalSeconds: TimeInterval
    /// 参与轮播的素材 ID（有序；顺序模式按此顺序）。
    var itemIDs: [UUID]
    /// 当前展示的素材 ID（上次轮播结果）。
    var currentItemID: UUID?

    init(
        isEnabled: Bool = false,
        mode: GWPlaylistMode = .ordered,
        intervalSeconds: TimeInterval = 300,
        itemIDs: [UUID] = [],
        currentItemID: UUID? = nil
    ) {
        self.isEnabled = isEnabled
        self.mode = mode
        self.intervalSeconds = intervalSeconds
        self.itemIDs = itemIDs
        self.currentItemID = currentItemID
    }

    static let `default` = GWPlaylistSettings()

    static let minimumIntervalSeconds: TimeInterval = 5
    static let maximumIntervalSeconds: TimeInterval = 86_400
    /// 设置界面提供的间隔预设。
    static let intervalPresets: [TimeInterval] = [30, 60, 120, 300, 600, 900, 1800, 3600]

    /// 修正越界/重复值（导入、编辑后的防御）。
    func normalized() -> GWPlaylistSettings {
        var copy = self
        let finiteInterval = intervalSeconds.isFinite ? intervalSeconds : GWPlaylistSettings.default.intervalSeconds
        copy.intervalSeconds = min(max(finiteInterval, Self.minimumIntervalSeconds), Self.maximumIntervalSeconds)
        var seen = Set<UUID>()
        copy.itemIDs = itemIDs.filter { seen.insert($0).inserted }
        if let current = copy.currentItemID, !copy.itemIDs.contains(current) {
            copy.currentItemID = nil
        }
        return copy
    }

    /// 宽松解码：缺失字段回退默认值，便于设置导入与版本演进。
    init(from decoder: Decoder) throws {
        let defaults = GWPlaylistSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        mode = try container.decodeIfPresent(GWPlaylistMode.self, forKey: .mode) ?? defaults.mode
        intervalSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .intervalSeconds) ?? defaults.intervalSeconds
        itemIDs = try container.decodeIfPresent([UUID].self, forKey: .itemIDs) ?? defaults.itemIDs
        currentItemID = try container.decodeIfPresent(UUID.self, forKey: .currentItemID)
    }

    /// 人类可读间隔文本。
    static func formatInterval(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) 秒" }
        if total % 3600 == 0 { return "\(total / 3600) 小时" }
        if total % 60 == 0 { return "\(total / 60) 分钟" }
        return "\(total / 60) 分 \(total % 60) 秒"
    }

    /// 倒计时文本 mm:ss。
    static func formatCountdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 状态

/// 轮播运行状态（供 UI 与诊断展示）。
enum GWPlaylistStatus: Equatable, Sendable {
    /// 未启用自动轮播。
    case idle
    /// 轮播运行中。
    case rotating(currentItemID: UUID?, nextFireAt: Date?)
    /// 因播放被策略/手动暂停而挂起（计时已停止）。
    case suspended(reason: String)
    /// 已停止（无可用素材等），等待用户修复后重新开始。
    case stopped(reason: String)

    var displayText: String {
        switch self {
        case .idle:
            return "未启用自动轮播"
        case .rotating:
            return "轮播中"
        case .suspended(let reason):
            return "已挂起（\(reason)）"
        case .stopped(let reason):
            return "已停止（\(reason)）"
        }
    }

    var isRotationActive: Bool {
        if case .rotating = self { return true }
        return false
    }
}

/// 轮播触发来源（诊断/回调使用）。
enum GWPlaylistTrigger: String, Sendable {
    /// 计时器到点自动切换。
    case timer
    /// 用户点击「立即切换下一个」。
    case manual

    var displayName: String {
        switch self {
        case .timer: return "定时切换"
        case .manual: return "手动切换"
        }
    }
}

// MARK: - 纯选择算法

/// 下一项选择算法（纯函数，随机源可注入，便于行为验证）。
enum GWPlaylistSelection {
    /// 从可用候选中选出下一项。
    ///
    /// - ordered：当前项在候选中的下一项（回绕）；当前项不在候选/为 nil 时取第一项。
    /// - shuffle：随机取一项；候选多于一项时排除当前项，避免连续重复。
    /// - 候选为空返回 nil（调用方负责停止并给出原因，不允许假成功）。
    static func nextID(
        current: UUID?,
        candidates: [UUID],
        mode: GWPlaylistMode,
        randomIndex: (Range<Int>) -> Int
    ) -> UUID? {
        guard !candidates.isEmpty else { return nil }
        switch mode {
        case .ordered:
            guard let current, let index = candidates.firstIndex(of: current) else {
                return candidates.first
            }
            return candidates[(index + 1) % candidates.count]
        case .shuffle:
            if candidates.count == 1 { return candidates[0] }
            let pool = candidates.filter { $0 != current }
            let effective = pool.isEmpty ? candidates : pool
            let rawIndex = randomIndex(0..<effective.count)
            let index = min(max(rawIndex, 0), effective.count - 1)
            return effective[index]
        }
    }
}
