import AppKit
import Foundation

/// 策略（F09）↔ 桌面播放（F05/F07）↔ 播放列表（F19）联结层。
///
/// 设计要点（integration-contract）：
/// - 策略只负责「挂起/恢复真实会话」，绝不改写每台显示器保存的 `isPaused`（唯一的手动意图来源）；
/// - 用户手动操作（应用/播放/暂停/移除）会同步一次全局策略意图，由保存的设置推导，
///   不根据 `player.rate` 推断——策略挂起时 rate 恒为 0，推断会得到相反结论；
/// - 策略回调路径不写素材库、不触发用户命令回调，因此不存在策略意图与逐屏意图的反馈循环；
/// - 策略挂起/恢复时同步播放列表计时器的挂起状态（F19 要求：暂停期间停止计时）。
@MainActor
final class AppPlaybackIntegration {
    private let store: VideoLibraryStore
    private let playback: DesktopPlaybackController
    private let policy: GWPolicyController
    private let playlist: GWPlaylistRotator
    private var isActive = false

    init(
        store: VideoLibraryStore,
        playback: DesktopPlaybackController,
        policy: GWPolicyController,
        playlist: GWPlaylistRotator
    ) {
        self.store = store
        self.playback = playback
        self.policy = policy
        self.playlist = playlist
    }

    /// 接线：策略转换 → 会话与轮播；用户播放命令 → 策略意图同步。
    func activate() {
        guard !isActive else { return }
        isActive = true

        policy.onPolicyChanged = { [weak self] transition in
            self?.handlePolicyTransition(transition)
        }
        playback.onUserPlaybackCommand = { [weak self] in
            self?.syncPolicyIntentFromSavedSettings()
        }
        playlist.isItemPlayable = { [weak self] id in
            guard let self else { return false }
            return self.store.item(withID: id)?.fileExists == true
        }
        playlist.onSelectWallpaper = { [weak self] id in
            self?.applyRotationSelection(id)
        }

        applyCurrentPolicyState()
    }

    /// 策略转换：暂停/恢复真实会话；轮播计时随有效播放状态挂起/恢复。
    func handlePolicyTransition(_ transition: GWPolicyTransition) {
        playlist.setTimerSuspended(!transition.effectiveIsPlaying, reason: transition.summary)
        applyCurrentPolicyState()
    }

    /// 把当前策略状态应用到所有真实会话（不写用户设置）。
    func applyCurrentPolicyState() {
        let blocked = policy.isPolicyBlockingPlayback
        playback.applyPolicyState(isBlocked: blocked) { [store, policy] displayID in
            policy.shouldPlayOnDisplay(userIsPaused: store.settings(for: displayID).isPaused)
        }
    }

    /// 用户手动播放/暂停/应用后的策略意图同步。
    ///
    /// 全局意图由「保存的每屏意图」聚合而来：只要有一台显示器希望播放，全局意图即播放；
    /// 全部暂停（或没有桌面会话）时为暂停。策略解除后按每屏意图逐屏恢复。
    func syncPolicyIntentFromSavedSettings() {
        let displayIDs = Set(playback.sessions.keys).union(playback.suspendedAssignments.keys)
        let anyWantsPlay = displayIDs.contains { !store.settings(for: $0).isPaused }
        if anyWantsPlay {
            policy.userRequestedPlay()
        } else {
            policy.userRequestedPause()
        }
    }

    /// 轮播选中新素材：应用到全部显示器（每屏的暂停意图由会话设置自然保留）。
    private func applyRotationSelection(_ id: UUID) {
        guard let item = store.item(withID: id), item.fileExists else {
            NSLog("[Glimmer] 轮播选中的素材不可用：%@", id.uuidString)
            return
        }
        if let error = playback.apply(item: item, to: nil) {
            NSLog("[Glimmer] 轮播应用失败：%@", error)
        }
    }
}
