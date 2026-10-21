import SwiftUI

struct LockScreenExportSettingsSection: View {
    let coordinator: GWSettingsCoordinator

    var body: some View {
        GWSettingsCard(title: "锁屏导出", systemImage: "lock.rectangle") {
            Picker("Scene / Web 播放方式", selection: Binding(
                get: { coordinator.preferences.lockScreenExport.projectPlayback },
                set: { value in coordinator.updatePreferences { $0.lockScreenExport.projectPlayback = value } }
            )) {
                ForEach(GWLockScreenProjectPlayback.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("lock-screen-project-playback")
            GWSettingsFootnote(text: "实时渲染保留时间、日期和脚本更新；锁屏可见时播放，休眠时暂停。录制视频更省资源，时间等内容保留录制时的画面。")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("允许锁屏网页访问 HTTPS 网络", isOn: Binding(
                get: { coordinator.preferences.lockScreenExport.allowWebHTTPS },
                set: { value in coordinator.updatePreferences { $0.lockScreenExport.allowWebHTTPS = value } }
            ))
            .disabled(coordinator.preferences.lockScreenExport.projectPlayback != .live)
            .accessibilityIdentifier("lock-screen-web-network")
            GWSettingsFootnote(text: "联网后，网页可请求天气等数据及远程资源；服务地址、城市与密钥由壁纸本身的作者设置决定。")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("同步壁纸设置", isOn: Binding(
                get: { coordinator.preferences.lockScreenExport.syncWallpaperSettings },
                set: { value in coordinator.updatePreferences { $0.lockScreenExport.syncWallpaperSettings = value } }
            ))
            .accessibilityIdentifier("lock-screen-export-sync")
            GWSettingsFootnote(text: "准备锁屏时跟随壁纸所在显示器的渲染尺寸与帧率；同时适用于实时渲染和视频导出。未应用到桌面的壁纸使用主显示器。")
                .fixedSize(horizontal: false, vertical: true)
            Picker("导出分辨率", selection: Binding(
                get: { coordinator.preferences.lockScreenExport.resolution },
                set: { value in coordinator.updatePreferences { $0.lockScreenExport.resolution = value } }
            )) {
                ForEach(GWLockScreenExportResolution.allCases) { resolution in
                    Text(resolution.title).tag(resolution)
                }
            }
            .accessibilityIdentifier("lock-screen-export-resolution")
            .disabled(coordinator.preferences.lockScreenExport.syncWallpaperSettings)
            Picker("导出帧率", selection: Binding(
                get: { coordinator.preferences.lockScreenExport.framesPerSecond },
                set: { value in coordinator.updatePreferences { $0.lockScreenExport.framesPerSecond = value } }
            )) {
                Text("原始帧率").tag(0)
                ForEach(lockScreenFrameRateChoices, id: \.self) { fps in Text("\(fps) FPS").tag(fps) }
            }
            .accessibilityIdentifier("lock-screen-export-fps")
            .disabled(coordinator.preferences.lockScreenExport.syncWallpaperSettings)
            GWSettingsFootnote(text: "保持画面比例，最高不超过素材原始分辨率与帧率。Web / Scene 无固定原始帧率时，以当前壁纸帧率上限为准；Web 无声明尺寸时使用显示器渲染尺寸。修改设置或作者属性后，需重新设为锁屏；重新导出会覆盖旧视频，导出失败时保留旧文件。")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lockScreenFrameRateChoices: [Int] {
        let current = coordinator.preferences.lockScreenExport.framesPerSecond
        return Array(Set([15, 24, 25, 30, 48, 50, 60, 90, 120, 144, 165, 240] + (current > 0 ? [current] : []))).sorted()
    }

}
