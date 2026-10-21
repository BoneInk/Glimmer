import SwiftUI

// F09 电源与睡眠策略的 SwiftUI 设置组件。
//
// 接入方式（主控后续放入 F17 设置窗口）：
// ```
// let policy = GWPolicyController(autoStartMonitoring: true)
// policy.onPolicyChanged = { transition in
//     // 连接 B01 播放控制器：transition.effectiveIsPlaying ? resumeAll() : pauseAll()
//     // 并调用 playlist.setTimerSuspended(!transition.effectiveIsPlaying, reason: transition.summary)
// }
// GWPolicySettingsView(controller: policy)
// ```
// 预览/验证入口：`GWPolicyController(autoStartMonitoring: false)`（不观察系统通知，可自由注入事件）。
struct GWPolicySettingsView: View {
    let controller: GWPolicyController
    var showsResetButton: Bool = true

    var body: some View {
        GWSettingsCard(
            title: "电源与睡眠策略",
            systemImage: "moon.zzz"
        ) {
            if controller.isPolicyBlockingPlayback || !status.isMonitoring || controller.lastErrorMessage != nil {
                statusRow
                Divider().opacity(0.35)
            }
            togglesSection
            Divider().opacity(0.35)
            batterySection
            Divider().opacity(0.35)
            resumeSection
            if showsResetButton {
                resetRow
            }
        }
        .accessibilityIdentifier("gw.policy.settingsCard")
    }

    // MARK: - 状态

    private var status: GWPolicyStatusSnapshot { controller.status }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.isPolicyBlockingPlayback {
                Label(status.headlineText, systemImage: "pause.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            if !status.isMonitoring {
                Label("自动暂停监控未运行", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = controller.lastErrorMessage {
                GWSettingsFootnote(text: error, isError: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(policyFeedbackAccessibility)
    }

    private var policyFeedbackAccessibility: String {
        var parts: [String] = []
        if controller.isPolicyBlockingPlayback { parts.append(status.headlineText) }
        if !status.isMonitoring { parts.append("自动暂停监控未运行") }
        if let error = controller.lastErrorMessage { parts.append(error) }
        return parts.joined(separator: "。")
    }

    // MARK: - 开关

    private var togglesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            toggleRow(
                "系统睡眠时暂停",
                systemImage: "moon.zzz",
                isOn: bind(\.pauseOnSystemSleep),
                hint: "系统唤醒后，仅在你的播放意图仍是播放时恢复。",
                identifier: "gw.policy.toggle.systemSleep"
            )
            toggleRow(
                "屏幕锁定时暂停",
                systemImage: "lock",
                isOn: bind(\.pauseOnScreenLock),
                hint: "解锁后按播放意图恢复；唤醒时若仍未解锁则继续保持暂停。",
                identifier: "gw.policy.toggle.screenLock"
            )
            toggleRow(
                "切换到其他用户会话时暂停",
                systemImage: "person.2",
                isOn: bind(\.pauseOnSessionInactive),
                hint: "快速用户切换离开本会话时暂停，返回后恢复。",
                identifier: "gw.policy.toggle.session"
            )
            toggleRow(
                "显示器睡眠时暂停",
                systemImage: "display",
                isOn: bind(\.pauseOnDisplaySleep),
                hint: "屏幕休眠（显示器断电）时暂停，唤醒显示器后恢复。",
                identifier: "gw.policy.toggle.displaySleep"
            )
            toggleRow(
                "低电量模式下暂停",
                systemImage: "battery.25",
                isOn: bind(\.pauseOnLowPowerMode),
                hint: "系统低电量模式开启期间暂停；关闭后按播放意图恢复。",
                identifier: "gw.policy.toggle.lowPower"
            )
        }
    }

    private func toggleRow(
        _ title: String,
        systemImage: String,
        isOn: Binding<Bool>,
        hint: String,
        identifier: String
    ) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .contentShape(Rectangle())
        .help(hint)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - 电池阈值

    private var batterySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            toggleRow(
                "电池电量低于阈值时暂停",
                systemImage: "battery.25",
                isOn: bind(\.pauseOnBatteryBelowThreshold),
                hint: "仅使用电池时生效；接通电源后按恢复设置处理。",
                identifier: "gw.policy.toggle.batteryThreshold"
            )

            HStack(spacing: 10) {
                Text("电量阈值")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(value: thresholdBinding, in: GWPolicySettings.batteryThresholdRange, step: 5) {
                    Text("\(controller.settings.batteryThresholdPercentage)%")
                        .font(.callout.monospacedDigit())
                }
                .disabled(!controller.settings.pauseOnBatteryBelowThreshold)
                .accessibilityLabel("电池暂停阈值，当前 \(controller.settings.batteryThresholdPercentage)%")
            }
        }
    }

    // MARK: - 恢复策略

    private var resumeSection: some View {
        toggleRow(
            "策略解除后自动恢复",
            systemImage: "arrow.clockwise",
            isOn: bind(\.resumeWhenPolicyLifts),
            hint: "关闭后唤醒或解锁不会自动恢复；手动暂停始终优先。",
            identifier: "gw.policy.toggle.autoResume"
        )
    }

    private var resetRow: some View {
        HStack {
            Button("恢复默认策略") {
                controller.resetSettings()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .accessibilityIdentifier("gw.policy.reset")
            Spacer()
        }
    }

    // MARK: - 绑定

    private func bind(_ keyPath: WritableKeyPath<GWPolicySettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { controller.settings[keyPath: keyPath] },
            set: { newValue in
                controller.updateSettings { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private var thresholdBinding: Binding<Int> {
        Binding(
            get: { controller.settings.batteryThresholdPercentage },
            set: { newValue in
                controller.updateSettings { $0.batteryThresholdPercentage = newValue }
            }
        )
    }
}
