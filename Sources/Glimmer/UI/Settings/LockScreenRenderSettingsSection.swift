import SwiftUI

struct LockScreenRenderSettingsSection: View {
    let coordinator: GWSettingsCoordinator

    var body: some View {
        GWSettingsCard(title: "锁屏画质", systemImage: "lock.rectangle") {
            Toggle("同步壁纸设置", isOn: Binding(
                get: { coordinator.preferences.lockScreenRender.syncWallpaperSettings },
                set: { value in coordinator.updatePreferences { $0.lockScreenRender.syncWallpaperSettings = value } }
            ))
            .accessibilityIdentifier("lock-screen-render-sync")
            Picker("渲染分辨率", selection: Binding(
                get: { coordinator.preferences.lockScreenRender.resolution },
                set: { value in coordinator.updatePreferences { $0.lockScreenRender.resolution = value } }
            )) {
                ForEach(GWLockScreenRenderResolution.allCases) { resolution in
                    Text(resolution.title).tag(resolution)
                }
            }
            .accessibilityIdentifier("lock-screen-render-resolution")
            .disabled(coordinator.preferences.lockScreenRender.syncWallpaperSettings)
            Picker("渲染帧率", selection: Binding(
                get: { coordinator.preferences.lockScreenRender.framesPerSecond },
                set: { value in coordinator.updatePreferences { $0.lockScreenRender.framesPerSecond = value } }
            )) {
                Text("原始帧率").tag(0)
                ForEach(lockScreenFrameRateChoices, id: \.self) { fps in Text("\(fps) FPS").tag(fps) }
            }
            .accessibilityIdentifier("lock-screen-render-fps")
            .disabled(coordinator.preferences.lockScreenRender.syncWallpaperSettings)
        }
    }

    private var lockScreenFrameRateChoices: [Int] {
        let current = coordinator.preferences.lockScreenRender.framesPerSecond
        return Array(Set([15, 24, 25, 30, 48, 50, 60, 90, 120, 144, 165, 240] + (current > 0 ? [current] : []))).sorted()
    }

}
