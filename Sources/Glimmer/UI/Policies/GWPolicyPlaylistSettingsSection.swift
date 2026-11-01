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
// AppPlaybackIntegration 在所有活动显示器都无法播放时挂起轮播计时。
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
