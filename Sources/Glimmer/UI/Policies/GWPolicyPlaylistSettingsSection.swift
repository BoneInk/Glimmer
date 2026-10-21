import SwiftUI

// B03 组合组件：电源策略 + 播放列表轮播（供 F17 设置窗口整段嵌入）。
//
// 接入示例：
// ```
// let section = GWPolicyPlaylistSettingsSection(
//     policy: policyController,
//     playlist: playlistRotator,
//     titleProvider: { store.item(withID: $0)?.displayTitle },
//     availableItemsProvider: { store.items.map { ($0.id, $0.displayTitle) } }
// )
// ```
// 策略与轮播的联动（暂停时停止计时）由主控接线：
// `policy.onPolicyChanged = { playlist.setTimerSuspended(!$0.effectiveIsPlaying, reason: $0.summary) }`
struct GWPolicyPlaylistSettingsSection: View {
    let policy: GWPolicyController
    let playlist: GWPlaylistRotator
    var titleProvider: ((UUID) -> String)?
    var availableItemsProvider: (() -> [(id: UUID, title: String)])?
    var showsResetButtons: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GWPolicySettingsView(controller: policy, showsResetButton: showsResetButtons)
            GWPlaylistSettingsView(
                rotator: playlist,
                titleProvider: titleProvider,
                availableItemsProvider: availableItemsProvider,
                showsResetButton: showsResetButtons
            )
        }
    }
}
