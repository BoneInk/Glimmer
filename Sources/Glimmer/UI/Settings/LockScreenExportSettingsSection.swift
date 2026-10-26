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
            Toggle("允许锁屏网页访问 HTTPS 网络", isOn: Binding(
                get: { coordinator.preferences.lockScreenExport.allowWebHTTPS },
                set: { value in coordinator.updatePreferences { $0.lockScreenExport.allowWebHTTPS = value } }
            ))
            .disabled(coordinator.preferences.lockScreenExport.projectPlayback != .live)
            .accessibilityIdentifier("lock-screen-web-network")
            Toggle("同步壁纸设置", isOn: Binding(
                get: { coordinator.preferences.lockScreenExport.syncWallpaperSettings },
                set: { value in coordinator.updatePreferences { $0.lockScreenExport.syncWallpaperSettings = value } }
            ))
            .accessibilityIdentifier("lock-screen-export-sync")
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
        }
    }

    private var lockScreenFrameRateChoices: [Int] {
        let current = coordinator.preferences.lockScreenExport.framesPerSecond
        return Array(Set([15, 24, 25, 30, 48, 50, 60, 90, 120, 144, 165, 240] + (current > 0 ? [current] : []))).sorted()
    }

}
