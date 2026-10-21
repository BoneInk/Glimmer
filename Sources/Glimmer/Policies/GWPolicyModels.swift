import Foundation

// F09 电源与睡眠策略：纯数据模型 + 可独立验证的状态机。
//
// 核心不变量：用户的播放意图与「策略导致的临时暂停」严格分离。
// 策略事件只会改变临时状态与暂停原因集合；唤醒/解锁等策略解除只会
// 在用户意图仍为 .playing 且未被显式禁用自动恢复时恢复播放。

// MARK: - 用户播放意图

/// 用户的播放意图。只由用户的显式操作（播放/暂停按钮、菜单命令）改变。
enum GWPlaybackIntent: String, Codable, Sendable, CaseIterable, Identifiable {
    case playing
    case paused

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .playing: return "希望播放"
        case .paused: return "手动暂停"
        }
    }

    var symbolName: String {
        switch self {
        case .playing: return "play.circle.fill"
        case .paused: return "pause.circle.fill"
        }
    }
}

// MARK: - 策略暂停原因

/// 策略导致的临时暂停原因。任一原因处于激活状态时，播放被临时挂起。
enum GWPolicyPauseReason: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    /// 系统睡眠（NSWorkspace willSleep）。
    case systemSleep
    /// 屏幕锁定（DistributedNotificationCenter com.apple.screenIsLocked，尽力而为）。
    case screenLocked
    /// 用户会话不活跃（快速用户切换，NSWorkspace sessionDidResignActive）。
    case sessionInactive
    /// 显示器睡眠（NSWorkspace screensDidSleep）。
    case displaySleep
    /// 系统低电量模式（ProcessInfo.isLowPowerModeEnabled）。
    case lowPowerMode
    /// 电池供电且电量低于用户阈值（IOKit 电源快照）。
    case batteryThreshold

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemSleep: return "系统睡眠"
        case .screenLocked: return "屏幕锁定"
        case .sessionInactive: return "会话不活跃"
        case .displaySleep: return "显示器睡眠"
        case .lowPowerMode: return "低电量模式"
        case .batteryThreshold: return "电池电量不足"
        }
    }

    var symbolName: String {
        switch self {
        case .systemSleep: return "moon.zzz.fill"
        case .screenLocked: return "lock.fill"
        case .sessionInactive: return "person.crop.circle.badge.questionmark"
        case .displaySleep: return "display"
        case .lowPowerMode: return "battery.25"
        case .batteryThreshold: return "battery.0"
        }
    }

    /// 稳定的展示顺序（状态文本与 UI 使用）。
    static let displayOrder: [GWPolicyPauseReason] = [
        .systemSleep, .screenLocked, .sessionInactive, .displaySleep, .lowPowerMode, .batteryThreshold
    ]
}

// MARK: - 设置

/// F09 电源与睡眠策略设置（独立持久化，可导出/导入）。
struct GWPolicySettings: Codable, Equatable, Sendable {
    /// 系统睡眠时暂停，唤醒后按用户意图恢复。
    var pauseOnSystemSleep: Bool
    /// 屏幕锁定时暂停，解锁后按用户意图恢复。
    var pauseOnScreenLock: Bool
    /// 快速用户切换离开本会话时暂停。
    var pauseOnSessionInactive: Bool
    /// 显示器进入睡眠时暂停。
    var pauseOnDisplaySleep: Bool
    /// 低电量模式开启时暂停。
    var pauseOnLowPowerMode: Bool
    /// 电池供电且低于阈值时暂停。
    var pauseOnBatteryBelowThreshold: Bool
    /// 电量阈值（百分比）。
    var batteryThresholdPercentage: Int
    /// 策略解除后是否自动恢复。即使开启，也不会覆盖「用户手动暂停」。
    var resumeWhenPolicyLifts: Bool

    init(
        pauseOnSystemSleep: Bool = true,
        pauseOnScreenLock: Bool = true,
        pauseOnSessionInactive: Bool = true,
        pauseOnDisplaySleep: Bool = true,
        pauseOnLowPowerMode: Bool = true,
        pauseOnBatteryBelowThreshold: Bool = false,
        batteryThresholdPercentage: Int = 20,
        resumeWhenPolicyLifts: Bool = true
    ) {
        self.pauseOnSystemSleep = pauseOnSystemSleep
        self.pauseOnScreenLock = pauseOnScreenLock
        self.pauseOnSessionInactive = pauseOnSessionInactive
        self.pauseOnDisplaySleep = pauseOnDisplaySleep
        self.pauseOnLowPowerMode = pauseOnLowPowerMode
        self.pauseOnBatteryBelowThreshold = pauseOnBatteryBelowThreshold
        self.batteryThresholdPercentage = batteryThresholdPercentage
        self.resumeWhenPolicyLifts = resumeWhenPolicyLifts
    }

    static let `default` = GWPolicySettings()

    static let batteryThresholdRange: ClosedRange<Int> = 5...50

    /// 是否需要周期性读取电池状态（阈值策略需要；低电量模式有系统通知，无需轮询）。
    var needsBatteryPolling: Bool { pauseOnBatteryBelowThreshold }

    /// 越界值修正（导入/编辑后的防御）。
    func normalized() -> GWPolicySettings {
        var copy = self
        copy.batteryThresholdPercentage = min(
            max(copy.batteryThresholdPercentage, Self.batteryThresholdRange.lowerBound),
            Self.batteryThresholdRange.upperBound
        )
        return copy
    }

    /// 宽松解码：缺失字段回退默认值，便于设置导入与版本演进。
    init(from decoder: Decoder) throws {
        let defaults = GWPolicySettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pauseOnSystemSleep = try container.decodeIfPresent(Bool.self, forKey: .pauseOnSystemSleep) ?? defaults.pauseOnSystemSleep
        pauseOnScreenLock = try container.decodeIfPresent(Bool.self, forKey: .pauseOnScreenLock) ?? defaults.pauseOnScreenLock
        pauseOnSessionInactive = try container.decodeIfPresent(Bool.self, forKey: .pauseOnSessionInactive) ?? defaults.pauseOnSessionInactive
        pauseOnDisplaySleep = try container.decodeIfPresent(Bool.self, forKey: .pauseOnDisplaySleep) ?? defaults.pauseOnDisplaySleep
        pauseOnLowPowerMode = try container.decodeIfPresent(Bool.self, forKey: .pauseOnLowPowerMode) ?? defaults.pauseOnLowPowerMode
        pauseOnBatteryBelowThreshold = try container.decodeIfPresent(Bool.self, forKey: .pauseOnBatteryBelowThreshold) ?? defaults.pauseOnBatteryBelowThreshold
        batteryThresholdPercentage = try container.decodeIfPresent(Int.self, forKey: .batteryThresholdPercentage) ?? defaults.batteryThresholdPercentage
        resumeWhenPolicyLifts = try container.decodeIfPresent(Bool.self, forKey: .resumeWhenPolicyLifts) ?? defaults.resumeWhenPolicyLifts
    }
}

// MARK: - 电源/电池快照

/// IOKit 电源快照（只读，不含任何用户身份信息）。
struct GWBatterySnapshot: Equatable, Sendable {
    /// 是否存在内置电池（台式机为 false）。
    var hasBattery: Bool
    /// 当前是否由电池供电。
    var isOnBattery: Bool
    /// 电量百分比（0...100），无法读取时为 nil。
    var percentage: Int?

    static let unknown = GWBatterySnapshot(hasBattery: false, isOnBattery: false, percentage: nil)

    var displayText: String {
        guard hasBattery else { return "未检测到电池（或无法读取电源信息）" }
        let percentText = percentage.map { "\($0)%" } ?? "电量未知"
        return isOnBattery ? "电池供电 · \(percentText)" : "已接通电源 · \(percentText)"
    }
}

// MARK: - 事件与转换

/// 策略状态机事件。控制器把真实系统通知/环境读取映射为这些事件；
/// 单元验证可通过同一入口注入事件，保证行为一致。
enum GWPolicyEvent: Equatable, Sendable {
    case userRequestedPlay
    case userRequestedPause
    case systemWillSleep
    case systemDidWake
    case screenLocked
    case screenUnlocked
    case sessionResignedActive
    case sessionBecameActive
    case displaysSlept
    case displaysWoke
    case lowPowerModeChanged(Bool)
    case batteryStateUpdated(GWBatterySnapshot)
    case policySettingsChanged(GWPolicySettings)

    var displayText: String {
        switch self {
        case .userRequestedPlay: return "用户请求播放"
        case .userRequestedPause: return "用户请求暂停"
        case .systemWillSleep: return "系统即将睡眠"
        case .systemDidWake: return "系统已唤醒"
        case .screenLocked: return "屏幕已锁定"
        case .screenUnlocked: return "屏幕已解锁"
        case .sessionResignedActive: return "用户会话已离开"
        case .sessionBecameActive: return "用户会话已恢复"
        case .displaysSlept: return "显示器已休眠"
        case .displaysWoke: return "显示器已唤醒"
        case .lowPowerModeChanged(let enabled): return enabled ? "低电量模式已开启" : "低电量模式已关闭"
        case .batteryStateUpdated: return "电源状态已刷新"
        case .policySettingsChanged: return "电源策略设置已更新"
        }
    }
}

/// 一次有效状态变化（播放有效状态或暂停原因集合发生变化时产生）。
struct GWPolicyTransition: Equatable, Sendable {
    var trigger: GWPolicyEvent
    /// 中文摘要，可直接展示或记录到诊断。
    var summary: String
    var effectiveWasPlaying: Bool
    var effectiveIsPlaying: Bool
    /// 变化发生后的暂停原因（稳定顺序）。
    var activePauseReasons: [GWPolicyPauseReason]
    var userIntent: GWPlaybackIntent
    var isResumeSuppressed: Bool
}

// MARK: - 状态机

/// F09 策略状态机（纯值类型，无系统依赖，可脱离硬件验证）。
struct GWPolicyCore: Equatable, Sendable {
    private(set) var settings: GWPolicySettings
    /// 用户播放意图。只会被用户的显式请求改变。
    private(set) var userIntent: GWPlaybackIntent

    private(set) var isSystemAsleep = false
    private(set) var isScreenLocked = false
    private(set) var isSessionActive = true
    private(set) var areDisplaysAsleep = false
    private(set) var isLowPowerMode = false
    private(set) var battery: GWBatterySnapshot = .unknown
    /// 「策略解除后不自动恢复」的一次性抑制标记：唤醒时按设置置位，用户显式播放后清除。
    private(set) var isResumeSuppressed = false

    init(settings: GWPolicySettings = .default, userIntent: GWPlaybackIntent = .playing) {
        self.settings = settings.normalized()
        self.userIntent = userIntent
    }

    /// 当前生效（阻断播放）的暂停原因集合。
    var activePauseReasons: Set<GWPolicyPauseReason> {
        var reasons: Set<GWPolicyPauseReason> = []
        if settings.pauseOnSystemSleep && isSystemAsleep { reasons.insert(.systemSleep) }
        if settings.pauseOnScreenLock && isScreenLocked { reasons.insert(.screenLocked) }
        if settings.pauseOnSessionInactive && !isSessionActive { reasons.insert(.sessionInactive) }
        if settings.pauseOnDisplaySleep && areDisplaysAsleep { reasons.insert(.displaySleep) }
        if settings.pauseOnLowPowerMode && isLowPowerMode { reasons.insert(.lowPowerMode) }
        if settings.pauseOnBatteryBelowThreshold,
           battery.isOnBattery,
           let percentage = battery.percentage,
           percentage <= settings.batteryThresholdPercentage {
            reasons.insert(.batteryThreshold)
        }
        return reasons
    }

    /// 稳定顺序的暂停原因（UI/诊断展示）。
    var orderedActivePauseReasons: [GWPolicyPauseReason] {
        let active = activePauseReasons
        return GWPolicyPauseReason.displayOrder.filter { active.contains($0) }
    }

    /// 当前是否应该播放：用户意图为播放、没有任何策略暂停原因、且未被抑制。
    ///
    /// 策略解除（唤醒/解锁/接上电源）只会移除原因；`userIntent` 不会被改写，
    /// 因此手动暂停绝不会被策略恢复动作覆盖。
    var effectiveIsPlaying: Bool {
        userIntent == .playing && activePauseReasons.isEmpty && !isResumeSuppressed
    }

    /// 策略层当前是否阻断播放（与用户意图无关；包含「等待手动恢复」抑制状态）。
    ///
    /// 主控逐屏集成用法：策略解除后对每台显示器判断
    /// `!core.isPolicyBlockingPlayback && !displaySettings.isPaused` 才恢复播放。
    var isPolicyBlockingPlayback: Bool {
        !activePauseReasons.isEmpty || isResumeSuppressed
    }

    /// 处理一个事件；返回 nil 表示有效状态与原因集合都没有变化。
    @discardableResult
    mutating func handle(_ event: GWPolicyEvent) -> GWPolicyTransition? {
        let beforePlaying = effectiveIsPlaying
        let beforeReasons = activePauseReasons

        switch event {
        case .userRequestedPlay:
            userIntent = .playing
            isResumeSuppressed = false
        case .userRequestedPause:
            userIntent = .paused
        case .systemWillSleep:
            isSystemAsleep = true
        case .systemDidWake:
            // 唤醒同时兜底清除显示器睡眠（screensDidWake 可能被合并/丢失）。
            isSystemAsleep = false
            areDisplaysAsleep = false
            if !settings.resumeWhenPolicyLifts {
                isResumeSuppressed = true
            }
        case .screenLocked:
            isScreenLocked = true
        case .screenUnlocked:
            isScreenLocked = false
        case .sessionResignedActive:
            isSessionActive = false
        case .sessionBecameActive:
            isSessionActive = true
        case .displaysSlept:
            areDisplaysAsleep = true
        case .displaysWoke:
            areDisplaysAsleep = false
        case .lowPowerModeChanged(let enabled):
            isLowPowerMode = enabled
        case .batteryStateUpdated(let snapshot):
            battery = snapshot
        case .policySettingsChanged(let newSettings):
            settings = newSettings.normalized()
        }

        let afterPlaying = effectiveIsPlaying
        let afterReasons = activePauseReasons
        guard beforePlaying != afterPlaying || beforeReasons != afterReasons else { return nil }

        return GWPolicyTransition(
            trigger: event,
            summary: Self.makeSummary(
                event: event,
                beforePlaying: beforePlaying,
                afterPlaying: afterPlaying,
                beforeReasons: beforeReasons,
                afterReasons: afterReasons,
                userIntent: userIntent,
                isResumeSuppressed: isResumeSuppressed
            ),
            effectiveWasPlaying: beforePlaying,
            effectiveIsPlaying: afterPlaying,
            activePauseReasons: GWPolicyPauseReason.displayOrder.filter { afterReasons.contains($0) },
            userIntent: userIntent,
            isResumeSuppressed: isResumeSuppressed
        )
    }

    private static func makeSummary(
        event: GWPolicyEvent,
        beforePlaying: Bool,
        afterPlaying: Bool,
        beforeReasons: Set<GWPolicyPauseReason>,
        afterReasons: Set<GWPolicyPauseReason>,
        userIntent: GWPlaybackIntent,
        isResumeSuppressed: Bool
    ) -> String {
        let reasonText = GWPolicyPauseReason.displayOrder
            .filter { afterReasons.contains($0) }
            .map(\.displayName)
            .joined(separator: "、")

        if afterPlaying != beforePlaying {
            if afterPlaying {
                switch event {
                case .userRequestedPlay:
                    return "用户请求播放，已恢复。"
                default:
                    return "\(event.displayText)，按用户播放意图恢复播放。"
                }
            }
            switch event {
            case .userRequestedPause:
                return "用户手动暂停；策略恢复动作不会覆盖这一意图。"
            default:
                return "\(event.displayText)，临时暂停（原因：\(reasonText.isEmpty ? "策略" : reasonText)）。"
            }
        }

        // 有效状态未变，但暂停原因集合发生变化。
        if !afterPlaying {
            if userIntent == .paused {
                return "\(event.displayText)；用户此前已手动暂停，保持暂停。"
            }
            if isResumeSuppressed {
                return "\(event.displayText)；已按设置等待手动恢复。"
            }
            return "\(event.displayText)，保持暂停（原因：\(reasonText.isEmpty ? "策略" : reasonText)）。"
        }
        return "\(event.displayText)，恢复条件已满足，继续播放。"
    }
}

// MARK: - 状态快照（供 SwiftUI 设置组件展示）

/// 策略控制器对外暴露的不可变状态快照。
struct GWPolicyStatusSnapshot: Equatable, Sendable {
    var userIntent: GWPlaybackIntent
    var effectiveIsPlaying: Bool
    var activePauseReasons: [GWPolicyPauseReason]
    var isLowPowerMode: Bool
    var battery: GWBatterySnapshot
    var isMonitoring: Bool
    var isResumeSuppressed: Bool
    var lastTransitionSummary: String?

    static let initial = GWPolicyStatusSnapshot(
        userIntent: .playing,
        effectiveIsPlaying: true,
        activePauseReasons: [],
        isLowPowerMode: false,
        battery: .unknown,
        isMonitoring: false,
        isResumeSuppressed: false,
        lastTransitionSummary: nil
    )

    /// 一句话状态（设置页与诊断共用）。
    var headlineText: String {
        if effectiveIsPlaying { return "播放中" }
        if userIntent == .paused { return "已暂停（用户手动暂停）" }
        if !activePauseReasons.isEmpty {
            return "已临时暂停（\(activePauseReasons.map(\.displayName).joined(separator: "、"))）"
        }
        if isResumeSuppressed { return "已暂停（等待手动恢复）" }
        return "已暂停"
    }

    var reasonListText: String {
        activePauseReasons.isEmpty ? "无" : activePauseReasons.map(\.displayName).joined(separator: "、")
    }
}
