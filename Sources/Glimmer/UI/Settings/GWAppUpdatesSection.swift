import SwiftUI

private struct GWAppUpdaterEnvironmentKey: EnvironmentKey {
    static let defaultValue: GWAppUpdater? = nil
}

extension EnvironmentValues {
    var appUpdater: GWAppUpdater? {
        get { self[GWAppUpdaterEnvironmentKey.self] }
        set { self[GWAppUpdaterEnvironmentKey.self] = newValue }
    }
}

struct GWAppUpdatesSection: View {
    let updater: GWAppUpdater

    var body: some View {
        GWSettingsCard(title: "软件更新", systemImage: "arrow.triangle.2.circlepath") {
            HStack {
                Text("当前版本 \(GWSettingsBuildInfo.appVersion)")
                    .font(.callout)
                Spacer()
                Button("检查更新…") { updater.checkForUpdates() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(!updater.canCheckForUpdates)
            }
            Toggle("新版本提醒", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.setAutomaticallyChecksForUpdates($0) }))
                .toggleStyle(.switch)
                .disabled(!updater.isStarted)
            Text("启动时及每隔 24 小时检查新版本，发现更新后弹窗提醒。确认后直接在应用内下载、安装并重新启动。关闭提醒后仍可手动检查更新。")
                .font(.caption)
                .foregroundStyle(.secondary)
            GWSettingsFootnote(text: updater.statusMessage, isError: updater.hasError)
            if let lastCheck = updater.lastUpdateCheckDate {
                Text("上次检查：\(GWSettingsFormat.dateTime(lastCheck))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
