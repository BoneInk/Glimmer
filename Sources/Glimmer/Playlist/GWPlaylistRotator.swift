import Foundation
import Observation

// F19 播放列表轮播器（无 UI 依赖；可由单元行为验证直接驱动）。
//
// 接入 API（主控后续连接 B01 播放控制器）：
// ```
// let playlist = GWPlaylistRotator()
// playlist.isItemPlayable = { id in store.items.first { $0.id == id }?.fileExists == true }
// playlist.onSelectWallpaper = { id in
//     guard let item = store.item(withID: id) else { return }
//     playback.apply(item: item, to: nil)
// }
// // 与 F09 策略联动（暂停期间停止计时）：
// policy.onPolicyChanged = { transition in
//     playlist.setTimerSuspended(!transition.effectiveIsPlaying, reason: transition.summary)
// }
// ```
// 计时只在本类内部维护：任何变更都先取消旧任务再创建新任务，杜绝重复计时。
@MainActor
@Observable
final class GWPlaylistRotator {
    /// 播放列表设置（持久化）。
    private(set) var settings: GWPlaylistSettings
    /// 运行状态（SwiftUI 直接观察）。
    private(set) var status: GWPlaylistStatus = .idle
    /// 下一次自动切换时间（运行中；UI 倒计时用）。
    private(set) var nextFireAt: Date?
    /// 最近一次配置读写错误（已脱敏，供诊断页展示）。
    private(set) var lastErrorMessage: String?

    /// 选中新素材时回调（主线程）。
    var onSelectWallpaper: ((UUID) -> Void)?
    /// 素材可用性检查。由主控注入（例如「记录存在且文件存在」）；
    /// 未注入时按「全部可用」处理，并在诊断中明确说明未接入。
    var isItemPlayable: ((UUID) -> Bool)?
    /// 随机源（默认系统随机；验证时可注入确定性实现）。
    var randomIndexProvider: ((Range<Int>) -> Int)?

    let paths: GWPersistencePaths

    private let persistenceEnabled: Bool
    private var rotationTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var suspensionReason: String?
    private var lastStopReason: String?

    private static let saveDebounce: Duration = .milliseconds(500)

    init(
        settings: GWPlaylistSettings? = nil,
        paths: GWPersistencePaths = GWPersistencePaths(),
        persistenceEnabled: Bool = true,
        randomIndexProvider: ((Range<Int>) -> Int)? = nil
    ) {
        self.paths = paths
        self.persistenceEnabled = persistenceEnabled
        self.randomIndexProvider = randomIndexProvider

        var initialSettings = settings
        var loadError: String?
        if persistenceEnabled, initialSettings == nil {
            do {
                if let document = try GWPlaylistPersistence.load(from: paths.playlistFile) {
                    initialSettings = document.settings.normalized()
                }
            } catch {
                loadError = error.localizedDescription
                GWPlaylistPersistence.quarantine(paths.playlistFile)
            }
        }
        self.settings = (initialSettings ?? .default).normalized()
        self.lastErrorMessage = loadError
        refreshStatus()
    }

    isolated deinit {
        // 释放兜底：正常情况下调用方应先调用 shutdown()。
        rotationTask?.cancel()
        saveTask?.cancel()
    }

    // MARK: - 查询

    var isRotating: Bool { rotationTask != nil }
    var isSuspended: Bool { suspensionReason != nil }
    var currentItemID: UUID? { settings.currentItemID }
    var itemCount: Int { settings.itemIDs.count }
    /// 已失效（按注入的可用性检查判断）的素材数量。
    var missingItemCount: Int { settings.itemIDs.filter { !isPlayable($0) }.count }
    /// 是否已接入素材可用性检查（未接入时轮播无法发现缺失文件）。
    var hasPlayabilityCheck: Bool { isItemPlayable != nil }
    var storageDescription: String { GWPathRedaction.short(paths.playlistFile) }

    func isPlayable(_ id: UUID) -> Bool {
        isItemPlayable?(id) ?? true
    }

    // MARK: - 启停

    /// 启动轮播。重复调用是安全的（防止重复计时任务）。
    func startRotation() {
        guard rotationTask == nil else { return }
        settings.isEnabled = true
        lastStopReason = nil
        scheduleSave()
        scheduleNextFire()
    }

    /// 停止轮播（用户关闭自动轮播）。
    func stopRotation() {
        settings.isEnabled = false
        rotationTask?.cancel()
        rotationTask = nil
        nextFireAt = nil
        lastStopReason = nil
        scheduleSave()
        refreshStatus()
    }

    /// 暂停期间停止计时（F09 联动入口）。
    ///
    /// - suspended 为 true：取消计时任务、记录原因（例如「系统睡眠」），不触发切换；
    /// - suspended 为 false：重新开始一个完整的轮播间隔（不补计暂停期间的时间）。
    func setTimerSuspended(_ suspended: Bool, reason: String?) {
        if suspended {
            suspensionReason = reason ?? suspensionReason ?? "播放已暂停"
            rotationTask?.cancel()
            rotationTask = nil
            nextFireAt = nil
            refreshStatus()
        } else {
            guard suspensionReason != nil else { return }
            suspensionReason = nil
            scheduleNextFire()
        }
    }

    /// 立即切换到下一个（用户手动操作）。即使轮播未启用也允许执行；
    /// 若轮播运行中，则同时重置倒计时。
    func advanceNow() {
        guard selectNextInternal(trigger: .manual) != nil else { return }
        if rotationTask != nil {
            scheduleNextFire()
        }
    }

    // MARK: - 列表编辑

    func addItem(_ id: UUID) {
        updateSettings { $0.itemIDs.append(id) }
    }

    func removeItem(_ id: UUID) {
        updateSettings { $0.itemIDs.removeAll { $0 == id } }
    }

    func setItems(_ ids: [UUID]) {
        updateSettings { $0.itemIDs = ids }
    }

    func moveItem(fromIndex: Int, toIndex: Int) {
        updateSettings { settings in
            guard settings.itemIDs.indices.contains(fromIndex),
                  settings.itemIDs.indices.contains(toIndex),
                  fromIndex != toIndex else { return }
            let id = settings.itemIDs.remove(at: fromIndex)
            settings.itemIDs.insert(id, at: toIndex)
        }
    }

    func clearPlaylist() {
        updateSettings { settings in
            settings.itemIDs.removeAll()
            settings.currentItemID = nil
        }
    }

    /// 修改设置；自动处理计时任务的重排与移除。
    func updateSettings(_ body: (inout GWPlaylistSettings) -> Void) {
        var updated = settings
        body(&updated)
        settings = updated.normalized()
        scheduleSave()
        if settings.isEnabled {
            scheduleNextFire()
        } else {
            rotationTask?.cancel()
            rotationTask = nil
            nextFireAt = nil
            lastStopReason = nil
            refreshStatus()
        }
    }

    /// 恢复默认设置并停止轮播。
    func resetSettings() {
        rotationTask?.cancel()
        rotationTask = nil
        settings = .default
        nextFireAt = nil
        suspensionReason = nil
        lastStopReason = nil
        scheduleSave()
        refreshStatus()
    }

    // MARK: - 持久化

    /// 立即保存（原子写入）。返回字节数；失败时记录 lastErrorMessage。
    @discardableResult
    func saveNow() -> Int? {
        guard persistenceEnabled else { return nil }
        do {
            let bytes = try GWPlaylistPersistence.save(settings, to: paths.playlistFile)
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

    /// 立即落盘（退出前调用）。
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        saveNow()
    }

    /// 退出前调用：停止计时并落盘。
    func shutdown() {
        rotationTask?.cancel()
        rotationTask = nil
        flush()
    }

    // MARK: - 诊断

    func diagnosticsLines() -> [String] {
        var lines: [String] = []
        lines.append("轮播状态: \(status.displayText)")
        lines.append("轮播模式: \(settings.mode.displayName)，间隔: \(GWPlaylistSettings.formatInterval(settings.intervalSeconds))")
        lines.append("列表条目: \(itemCount)，当前: \(currentItemID.map { String($0.uuidString.prefix(8)) } ?? "无")")
        lines.append("缺失素材: \(missingItemCount)")
        if !hasPlayabilityCheck {
            lines.append("注意: 尚未接入素材可用性检查（isItemPlayable），缺失文件不会被跳过")
        }
        if let suspensionReason { lines.append("挂起原因: \(suspensionReason)") }
        lines.append("配置文件: \(storageDescription)")
        if let lastErrorMessage { lines.append("最近错误: \(lastErrorMessage)") }
        return lines
    }

    // MARK: - 内部

    /// 选出并发布下一项。没有可用素材时停止计时并给出明确原因（绝不静默假成功）。
    @discardableResult
    private func selectNextInternal(trigger: GWPlaylistTrigger) -> UUID? {
        let normalized = settings.normalized()
        let candidates = normalized.itemIDs.filter { isPlayable($0) }
        guard !candidates.isEmpty else {
            haltForNoCandidates(normalized: normalized)
            return nil
        }
        guard let next = GWPlaylistSelection.nextID(
            current: normalized.currentItemID,
            candidates: candidates,
            mode: normalized.mode,
            randomIndex: randomIndexProvider ?? { Int.random(in: $0) }
        ) else {
            haltForNoCandidates(normalized: normalized)
            return nil
        }
        settings.currentItemID = next
        scheduleSave()
        onSelectWallpaper?(next)
        refreshStatus()
        return next
    }

    private func haltForNoCandidates(normalized: GWPlaylistSettings) {
        rotationTask?.cancel()
        rotationTask = nil
        nextFireAt = nil
        lastStopReason = normalized.itemIDs.isEmpty
            ? "播放列表为空"
            : "没有可用的素材（文件缺失或无法访问）"
        refreshStatus()
    }

    /// 取消旧计时任务并（在允许时）创建新计时任务。
    private func scheduleNextFire() {
        rotationTask?.cancel()
        rotationTask = nil
        nextFireAt = nil

        guard settings.isEnabled else {
            refreshStatus()
            return
        }
        guard suspensionReason == nil else {
            refreshStatus()
            return
        }
        let normalized = settings.normalized()
        let candidates = normalized.itemIDs.filter { isPlayable($0) }
        guard !candidates.isEmpty else {
            lastStopReason = normalized.itemIDs.isEmpty
                ? "播放列表为空"
                : "没有可用的素材（文件缺失或无法访问）"
            refreshStatus()
            return
        }

        let interval = normalized.intervalSeconds
        nextFireAt = Date().addingTimeInterval(interval)

        // 先创建任务再刷新状态：refreshStatus 依赖 rotationTask 判断「轮播中」。
        // Task 体在下一次主线程让步前不会执行，因此这里不存在重入问题。
        rotationTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                self.fireTimerTick()
                guard !Task.isCancelled else { return }
                self.nextFireAt = Date().addingTimeInterval(interval)
                self.refreshStatus()
            }
        }
        refreshStatus()
    }

    private func fireTimerTick() {
        guard settings.isEnabled, suspensionReason == nil else { return }
        selectNextInternal(trigger: .timer)
    }

    private func refreshStatus() {
        if !settings.isEnabled {
            status = .idle
        } else if let suspensionReason {
            status = .suspended(reason: suspensionReason)
        } else if rotationTask != nil {
            status = .rotating(currentItemID: settings.currentItemID, nextFireAt: nextFireAt)
        } else if let lastStopReason {
            status = .stopped(reason: lastStopReason)
        } else {
            status = .idle
        }
    }
}
