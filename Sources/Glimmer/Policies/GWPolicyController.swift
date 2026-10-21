import AppKit
import Foundation
import IOKit.ps
import Observation

// F09 电源与睡眠策略控制器（macOS 公开 API）。
//
// 观察来源：
// - NSWorkspace 通知中心：系统睡眠/唤醒、会话活跃状态、显示器睡眠/唤醒。
// - DistributedNotificationCenter：屏幕锁定/解锁（com.apple.screenIsLocked，尽力而为，
//   系统未公开文档但为业界通行做法；不可用时其他来源仍然生效）。
// - NotificationCenter：低电量模式变化（NSProcessInfoPowerStateDidChange）。
// - IOKit 电源通知源 + 周期轮询：电池供电与电量阈值（仅阈值策略开启时轮询）。
//
// 接入 API（主控后续连接 B01 播放控制器）：
// ```
// let policy = GWPolicyController(startMonitoring: true)
// policy.onPolicyChanged = { [weak playback] transition in
//     if transition.effectiveIsPlaying { playback?.resumeAll() } else { playback?.pauseAll() }
// }
// // 用户点击播放/暂停时：
// policy.userRequestedPlay() / policy.userRequestedPause()
// // 播放列表联动：
// policy.onPolicyChanged = { playlist.setTimerSuspended(!$0.effectiveIsPlaying, reason: $0.summary) }
// ```
// 手动暂停意图保存在状态机内部（userIntent），策略解除不会覆盖它。
@MainActor
@Observable
final class GWPolicyController {
    /// 策略状态机（纯值；可整体读取用于测试/诊断）。
    private(set) var core: GWPolicyCore
    /// 对外状态快照（SwiftUI 设置组件直接观察）。
    private(set) var status: GWPolicyStatusSnapshot = .initial
    /// 是否正在观察系统通知（预览/测试可保持关闭）。
    private(set) var isMonitoring = false
    /// 最近一次配置读写错误（已脱敏，供诊断页展示）。
    private(set) var lastErrorMessage: String?

    /// 有效播放状态或暂停原因变化时回调（主线程）。
    var onPolicyChanged: ((GWPolicyTransition) -> Void)?

    let paths: GWPersistencePaths

    private let persistenceEnabled: Bool
    private var workspaceNotificationCenter: NotificationCenter?
    private var distributedNotificationCenter: DistributedNotificationCenter?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []
    private var defaultCenterTokens: [NSObjectProtocol] = []
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var environmentTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var lastTransitionSummary: String?

    /// 环境轮询间隔（仅在电池阈值策略开启时运行；系统另有即时电源变化通知）。
    static let environmentPollInterval: Duration = .seconds(30)
    private static let saveDebounce: Duration = .milliseconds(400)

    init(
        settings: GWPolicySettings? = nil,
        userIntent: GWPlaybackIntent = .playing,
        paths: GWPersistencePaths = GWPersistencePaths(),
        persistenceEnabled: Bool = true,
        autoStartMonitoring: Bool = false
    ) {
        self.paths = paths
        self.persistenceEnabled = persistenceEnabled

        var initialSettings = settings
        var loadError: String?
        if persistenceEnabled, initialSettings == nil {
            do {
                if let document = try GWPolicyPersistence.load(from: paths.policyFile) {
                    initialSettings = document.settings.normalized()
                }
            } catch {
                loadError = error.localizedDescription
                GWPolicyPersistence.quarantine(paths.policyFile)
            }
        }
        self.core = GWPolicyCore(settings: initialSettings ?? .default, userIntent: userIntent)
        self.lastErrorMessage = loadError
        refreshStatus()
        if autoStartMonitoring {
            startMonitoring()
        }
    }

    // MARK: - 查询

    var settings: GWPolicySettings { core.settings }
    var userIntent: GWPlaybackIntent { core.userIntent }
    var effectiveIsPlaying: Bool { core.effectiveIsPlaying }
    var orderedActivePauseReasons: [GWPolicyPauseReason] { core.orderedActivePauseReasons }
    /// 策略层是否阻断播放（与用户意图无关）。
    var isPolicyBlockingPlayback: Bool { core.isPolicyBlockingPlayback }

    /// 逐屏集成辅助：给定该显示器保存的用户意图（B01 `DisplayPlaybackSettings.isPaused`），
    /// 返回现在是否应让它播放。用户保存的暂停意图为真时永远返回 false。
    func shouldPlayOnDisplay(userIsPaused: Bool) -> Bool {
        !userIsPaused && core.effectiveIsPlaying
    }

    /// 诊断用文件说明（已脱敏）。
    var storageDescription: String { GWPathRedaction.short(paths.policyFile) }

    // MARK: - 生命周期

    /// 开始观察系统状态。幂等：重复调用不会注册重复观察者。
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceNotificationCenter = workspaceCenter
        let workspaceMap: [(Notification.Name, GWPolicyEvent)] = [
            (NSWorkspace.willSleepNotification, .systemWillSleep),
            (NSWorkspace.didWakeNotification, .systemDidWake),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionResignedActive),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionBecameActive),
            (NSWorkspace.screensDidSleepNotification, .displaysSlept),
            (NSWorkspace.screensDidWakeNotification, .displaysWoke)
        ]
        for (name, event) in workspaceMap {
            workspaceTokens.append(observe(center: workspaceCenter, name: name) { controller in
                controller.handle(event)
            })
        }

        let distributedCenter = DistributedNotificationCenter.default()
        distributedNotificationCenter = distributedCenter
        let distributedMap: [(Notification.Name, GWPolicyEvent)] = [
            (Notification.Name("com.apple.screenIsLocked"), .screenLocked),
            (Notification.Name("com.apple.screenIsUnlocked"), .screenUnlocked)
        ]
        for (name, event) in distributedMap {
            distributedTokens.append(observe(center: distributedCenter, name: name) { controller in
                controller.handle(event)
            })
        }

        defaultCenterTokens.append(
            observe(center: NotificationCenter.default, name: .NSProcessInfoPowerStateDidChange) { controller in
                controller.handle(.lowPowerModeChanged(ProcessInfo.processInfo.isLowPowerModeEnabled))
            }
        )

        installPowerSourceListener()
        refreshEnvironmentNow()
        updateEnvironmentTask()
        refreshStatus()
    }

    /// 停止观察并释放所有观察者与计时任务。幂等。
    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false

        if let workspaceNotificationCenter {
            for token in workspaceTokens { workspaceNotificationCenter.removeObserver(token) }
        }
        workspaceTokens.removeAll()
        workspaceNotificationCenter = nil

        if let distributedNotificationCenter {
            for token in distributedTokens { distributedNotificationCenter.removeObserver(token) }
        }
        distributedTokens.removeAll()
        distributedNotificationCenter = nil

        for token in defaultCenterTokens { NotificationCenter.default.removeObserver(token) }
        defaultCenterTokens.removeAll()

        if let powerSourceRunLoopSource {
            CFRunLoopSourceInvalidate(powerSourceRunLoopSource)
            self.powerSourceRunLoopSource = nil
        }
        environmentTask?.cancel()
        environmentTask = nil
        refreshStatus()
    }

    /// 退出前调用：停止观察并立即落盘当前设置。
    func shutdown() {
        stopMonitoring()
        saveNow()
    }

    isolated deinit {
        // 释放兜底：正常情况下调用方应先调用 shutdown()/stopMonitoring()。
        if let workspaceNotificationCenter {
            for token in workspaceTokens { workspaceNotificationCenter.removeObserver(token) }
        }
        if let distributedNotificationCenter {
            for token in distributedTokens { distributedNotificationCenter.removeObserver(token) }
        }
        for token in defaultCenterTokens { NotificationCenter.default.removeObserver(token) }
        if let powerSourceRunLoopSource { CFRunLoopSourceInvalidate(powerSourceRunLoopSource) }
        environmentTask?.cancel()
        saveTask?.cancel()
    }

    // MARK: - 用户操作

    /// 用户显式请求播放（播放按钮/菜单命令）。
    func userRequestedPlay() {
        handle(.userRequestedPlay)
    }

    /// 用户显式请求暂停。该意图会被保存，唤醒/解锁不会覆盖它。
    func userRequestedPause() {
        handle(.userRequestedPause)
    }

    /// 在两种意图之间切换（菜单栏「暂停/继续」可直接调用）。
    func toggleUserIntent() {
        if core.userIntent == .playing {
            userRequestedPause()
        } else {
            userRequestedPlay()
        }
    }

    // MARK: - 设置

    /// 修改设置并立即重算有效状态（例如开启「低电量模式暂停」时可能立即暂停）。
    func updateSettings(_ body: (inout GWPolicySettings) -> Void) {
        var updated = core.settings
        body(&updated)
        handle(.policySettingsChanged(updated.normalized()))
        scheduleSave()
        updateEnvironmentTask()
    }

    /// 恢复默认策略设置。
    func resetSettings() {
        updateSettings { $0 = .default }
    }

    // MARK: - 环境读取（公开 API）

    /// 立即重新读取低电量模式与电池状态（系统唤醒、电源变化、启动时调用）。
    func refreshEnvironmentNow() {
        handle(.lowPowerModeChanged(ProcessInfo.processInfo.isLowPowerModeEnabled))
        handle(.batteryStateUpdated(GWBatterySnapshotReader.read()))
    }

    // MARK: - 事件处理

    /// 状态机入口。返回 nil 表示有效状态与暂停原因均未变化。
    @discardableResult
    func handle(_ event: GWPolicyEvent) -> GWPolicyTransition? {
        let transition = core.handle(event)
        if let transition {
            lastTransitionSummary = transition.summary
        }
        refreshStatus()
        if let transition {
            onPolicyChanged?(transition)
        }
        return transition
    }

    // MARK: - 持久化

    /// 立即保存设置（原子写入）。返回字节数；失败时记录 lastErrorMessage。
    @discardableResult
    func saveNow() -> Int? {
        guard persistenceEnabled else { return nil }
        do {
            let bytes = try GWPolicyPersistence.save(core.settings, to: paths.policyFile)
            lastErrorMessage = nil
            return bytes
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    private func scheduleSave() {
        guard persistenceEnabled else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    // MARK: - 诊断

    func diagnosticsLines() -> [String] {
        var lines: [String] = []
        lines.append("策略监控: \(isMonitoring ? "运行中" : "已停止")")
        lines.append("用户意图: \(core.userIntent.displayName)")
        lines.append("有效播放: \(core.effectiveIsPlaying ? "是" : "否")")
        lines.append("暂停原因: \(status.reasonListText)")
        lines.append("系统睡眠: \(core.isSystemAsleep ? "是" : "否")，屏幕锁定: \(core.isScreenLocked ? "是" : "否")，会话活跃: \(core.isSessionActive ? "是" : "否")")
        lines.append("低电量模式: \(core.isLowPowerMode ? "开启" : "关闭")")
        lines.append("电源: \(core.battery.displayText)")
        lines.append("配置文件: \(storageDescription)")
        if let lastErrorMessage { lines.append("最近错误: \(lastErrorMessage)") }
        if let lastTransitionSummary { lines.append("最近转换: \(lastTransitionSummary)") }
        return lines
    }

    // MARK: - 内部

    private func refreshStatus() {
        status = GWPolicyStatusSnapshot(
            userIntent: core.userIntent,
            effectiveIsPlaying: core.effectiveIsPlaying,
            activePauseReasons: core.orderedActivePauseReasons,
            isLowPowerMode: core.isLowPowerMode,
            battery: core.battery,
            isMonitoring: isMonitoring,
            isResumeSuppressed: core.isResumeSuppressed,
            lastTransitionSummary: lastTransitionSummary
        )
    }

    private func observe(
        center: NotificationCenter,
        name: Notification.Name,
        handler: @escaping @MainActor (GWPolicyController) -> Void
    ) -> NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
    }

    private func installPowerSourceListener() {
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let controller = Unmanaged<GWPolicyController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                controller.refreshEnvironmentNow()
            }
        }
        if let unmanaged = IOPSNotificationCreateRunLoopSource(callback, Unmanaged.passUnretained(self).toOpaque()) {
            let source = unmanaged.takeRetainedValue()
            // 回调在注册的运行循环（主运行循环）上执行。
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSourceRunLoopSource = source
        }
    }

    /// 仅在「电池阈值」策略开启时轮询电量；其余状态都有系统通知即时驱动。
    private func updateEnvironmentTask() {
        environmentTask?.cancel()
        environmentTask = nil
        guard isMonitoring, core.settings.needsBatteryPolling else { return }
        environmentTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.environmentPollInterval)
                guard !Task.isCancelled, let self else { return }
                self.handle(.batteryStateUpdated(GWBatterySnapshotReader.read()))
            }
        }
    }
}

/// IOKit 电源快照读取器（公开 API：pmset 之上的 IOPowerSources）。
enum GWBatterySnapshotReader {
    static func read() -> GWBatterySnapshot {
        guard let infoUnmanaged = IOPSCopyPowerSourcesInfo() else { return .unknown }
        let blob = infoUnmanaged.takeRetainedValue()
        guard let listUnmanaged = IOPSCopyPowerSourcesList(blob) else { return .unknown }
        let list = listUnmanaged.takeRetainedValue() as NSArray

        var hasBattery = false
        var isOnBattery = false
        var percentage: Int?

        for element in list {
            let source = element as CFTypeRef
            guard let descriptionUnmanaged = IOPSGetPowerSourceDescription(blob, source) else { continue }
            let description = descriptionUnmanaged.takeUnretainedValue() as NSDictionary
            guard let type = description[kIOPSTypeKey as String] as? String,
                  type == (kIOPSInternalBatteryType as String) else { continue }
            hasBattery = true
            if let state = description[kIOPSPowerSourceStateKey as String] as? String {
                isOnBattery = state == (kIOPSBatteryPowerValue as String)
            }
            let current = description[kIOPSCurrentCapacityKey as String] as? Int
            let maximum = description[kIOPSMaxCapacityKey as String] as? Int
            if let current, let maximum, maximum > 0 {
                percentage = Int((Double(current) / Double(maximum) * 100).rounded())
            }
        }

        guard hasBattery else { return .unknown }
        return GWBatterySnapshot(hasBattery: true, isOnBattery: isOnBattery, percentage: percentage)
    }
}
