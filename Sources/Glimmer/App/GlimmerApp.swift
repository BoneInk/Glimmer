import SwiftUI

/// SwiftUI 应用定义。真正的生命周期控制在 `AppDelegate`（菜单栏型应用）。
struct GlimmerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 管理窗口由 AppDelegate 手动创建（需要在关闭后继续运行并与菜单栏联动）。
        Settings {
            SettingsSceneRoot(delegate: appDelegate)
        }
    }
}

/// 「设置」场景内容：与主管理窗口使用完全相同的设置界面与同一批控制器。
struct SettingsSceneRoot: View {
    let delegate: AppDelegate

    var body: some View {
        if delegate.isReady,
           let store = delegate.store,
           let playback = delegate.playback,
           let workshop = delegate.workshop,
           let policy = delegate.policy,
           let playlist = delegate.playlist,
           let settings = delegate.settings,
           let cleanup = delegate.cleanup,
           let loginItem = delegate.loginItem {
            SettingsPane(
                store: store,
                playback: playback,
                workshop: workshop,
                policy: policy,
                playlist: playlist,
                settings: settings,
                cleanup: cleanup,
                loginItem: loginItem,
                onOpenPlaylist: { delegate.showPlaylistWindow() }
            )
            .environment(\.lockScreenActions, delegate.lockScreenActions)
        } else {
            ProgressView("正在准备设置…")
                .frame(width: 420, height: 300)
        }
    }
}
