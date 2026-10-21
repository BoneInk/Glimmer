import AppKit
import SwiftUI
import UniformTypeIdentifiers

// F17 设置主界面：外观、启动、电源策略与播放列表（嵌入 B03 组件）、
// 素材库与存储（含 F18 清理）、配置导入导出、诊断（F20）、登录项与恢复默认。
//
// 主控接入方式（B04）：
// ```
// let settings = GWSettingsCoordinator(external: GWSettingsExternalActions(
//     readStartupRestoration: { store.appSettings.autoApplyOnLaunch },
//     writeStartupRestoration: { store.updateAppSettings { s in s.autoApplyOnLaunch = $0 } },
//     makePlaybackExport: { ... },
//     applyPlaybackImport: { ... },
//     readPolicySettings: { policy.settings },
//     applyPolicySettings: { policy.updateSettings { s in s = $0 } },
//     readPlaylistSettings: { playlist.settings },
//     applyPlaylistSettings: { playlist.updateSettings($0) },
//     resetAdditionalSettings: { policy.resetSettings(); playlist.resetSettings() }
// ))
// let cleanup = GWStorageCleanupController(protectedURLsProvider: {
//     Set(store.items.map(\.fileURL) + playback.sessions.values.map(\.item.fileURL))
// })
// GWSettingsView(coordinator: settings, cleanup: cleanup, loginItem: GWLoginItemService(), ...)
// ```
struct GWSettingsView: View {
    @Environment(\.workspaceContentTopInset) private var contentTopInset
    let coordinator: GWSettingsCoordinator
    let cleanup: GWStorageCleanupController
    let loginItem: GWLoginItemService

    /// 电源策略保留直接设置；播放列表只提供同一控制器的摘要与导航。
    var policy: GWPolicyController?
    var playlist: GWPlaylistRotator?
    var playlistTitleProvider: ((UUID) -> String)?
    var playlistItemsProvider: (() -> [(id: UUID, title: String)])?

    /// 素材库信息（主控注入；nil 时隐藏素材库信息区）。
    var libraryInfoProvider: (() -> GWSettingsLibraryInfo)?
    var onOpenPlaylist: (() -> Void)?

    @GlassState private var pendingImport: GWValidatedConfiguration?
    @GlassState private var transferMessage: String?
    @GlassState private var transferError: String?
    @GlassState private var showsResetConfirmation = false
    @GlassState private var maintenanceExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                appearanceCard
                performanceCard
                LockScreenExportSettingsSection(coordinator: coordinator)
                launchCard
                if let policy { GWPolicySettingsView(controller: policy, showsResetButton: false) }
                if let playlist { playlistEntry(playlist) }
                DisclosureGroup("存储与高级工具", isExpanded: $maintenanceExpanded) {
                    VStack(alignment: .leading, spacing: 14) {
                        libraryStorageCard
                        configurationCard
                        LockScreenMaintenanceSection()
                        resetCard
                    }
                    .padding(.top, 12)
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 24)
            .padding(.top, contentTopInset)
            .padding(.bottom, 18)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .frame(minWidth: 640, minHeight: 640)
        .onAppear {
            loginItem.refreshStatus()
        }
        .alert(
            "导入配置",
            isPresented: Binding(
                get: { pendingImport != nil },
                set: { if !$0 { pendingImport = nil } }
            )
        ) {
            Button("导入并应用") { commitPendingImport() }
            Button("取消", role: .cancel) { pendingImport = nil }
        } message: {
            Text(importSummaryText)
        }
    }

    private var importSummaryText: String {
        guard let pendingImport else { return "" }
        return "已完整校验，将应用：\(pendingImport.sectionNames.joined(separator: "、"))。\n不会迁移素材、不会删除文件、不会改变 Steam 登录状态。"
    }

    // MARK: - 外观

    private var appearanceCard: some View {
        GWSettingsCard(
            title: "外观",
            systemImage: "paintbrush"
        ) {
            HStack(spacing: 10) {
                Picker("外观模式", selection: appearanceBinding) {
                    ForEach(GWAppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                .accessibilityLabel("外观模式")
                .accessibilityValue(coordinator.preferences.appearance.displayName)
                .accessibilityHint(coordinator.preferences.appearance.hintText)
                .help(coordinator.preferences.appearance.hintText)

                Spacer(minLength: 8)

                Button {
                    coordinator.updatePreferences {
                        $0.appearance = GWPreferencesSettings.default.appearance
                        $0.backgroundBrightness = GWPreferencesSettings.default.backgroundBrightness
                        $0.backgroundBlur = GWPreferencesSettings.default.backgroundBlur
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityLabel("重置外观设置")
                .help("重置外观模式、背景明暗与模糊")
            }

            backgroundBrightnessRow
            backgroundBlurRow
        }
    }

    private var backgroundBrightnessRow: some View {
        HStack(spacing: 10) {
            Text("背景明暗")
                .font(.callout)
                .frame(width: 76, alignment: .leading)
            Spacer(minLength: 12)
            Image(systemName: "moon.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: backgroundBrightnessBinding, in: 0...1)
                .frame(maxWidth: 280)
                .accessibilityLabel("背景明暗")
                .accessibilityValue(backgroundPercentage(coordinator.preferences.backgroundBrightness))
            Image(systemName: "sun.max.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(backgroundPercentage(coordinator.preferences.backgroundBrightness))
                .font(.callout.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var backgroundBlurRow: some View {
        HStack(spacing: 10) {
            Text("背景模糊")
                .font(.callout)
                .frame(width: 76, alignment: .leading)
            Spacer(minLength: 12)
            Slider(value: backgroundBlurBinding, in: 0...1)
                .frame(maxWidth: 340)
                .accessibilityLabel("背景模糊")
                .accessibilityValue(backgroundPercentage(coordinator.preferences.backgroundBlur))
            Text(backgroundPercentage(coordinator.preferences.backgroundBlur))
                .font(.callout.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var appearanceBinding: Binding<GWAppearanceMode> {
        Binding(
            get: { coordinator.preferences.appearance },
            set: { newValue in
                coordinator.updatePreferences { $0.appearance = newValue }
            }
        )
    }

    private var backgroundBrightnessBinding: Binding<Double> {
        Binding(
            get: { coordinator.preferences.backgroundBrightness },
            set: { newValue in
                coordinator.updatePreferences { $0.backgroundBrightness = newValue }
            }
        )
    }

    private var backgroundBlurBinding: Binding<Double> {
        Binding(
            get: { coordinator.preferences.backgroundBlur },
            set: { newValue in
                coordinator.updatePreferences { $0.backgroundBlur = newValue }
            }
        )
    }

    private func backgroundPercentage(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private var performanceCard: some View {
        GWSettingsCard(title: "性能", systemImage: "gauge.with.dots.needle.67percent") {
            HStack(spacing: 10) {
                Text("帧率上限")
                    .font(.callout)
                    .frame(width: 76, alignment: .leading)
                Spacer(minLength: 12)
                Slider(value: wallpaperFPSBinding, in: 1...240)
                    .frame(maxWidth: 340)
                    .accessibilityLabel("壁纸帧率上限")
                    .accessibilityValue("\(coordinator.preferences.wallpaperFPS) FPS")
                    .accessibilityHint("限制 Scene 与 Web 壁纸帧率；视频保持素材原始帧率")
                    .help("限制 Scene 与 Web 壁纸帧率；视频保持素材原始帧率")
                Text("\(coordinator.preferences.wallpaperFPS) FPS")
                    .font(.callout.monospacedDigit())
                    .frame(width: 58, alignment: .trailing)
            }
        }
    }

    private var wallpaperFPSBinding: Binding<Double> {
        Binding(
            get: { Double(coordinator.preferences.wallpaperFPS) },
            set: { value in coordinator.updatePreferences { $0.wallpaperFPS = Int(value.rounded()) } }
        )
    }

    // MARK: - 启动

    private var launchCard: some View {
        GWSettingsCard(
            title: "启动与恢复",
            systemImage: "power"
        ) {
            loginItemControls
            Divider().opacity(0.35)
            Toggle(isOn: startupRestorationBinding) {
                Label("启动时恢复上次的桌面壁纸", systemImage: "arrow.clockwise.circle")
                    .font(.callout)
            }
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("启动时恢复上次的桌面壁纸")
            .accessibilityHint("关闭后启动应用不会自动开始桌面播放，仍可从素材库手动应用。")

            if let error = coordinator.lastError {
                GWSettingsFootnote(text: error, isError: true)
            }
        }
    }

    private var startupRestorationBinding: Binding<Bool> {
        Binding(
            get: { coordinator.startupRestorationEffectiveValue },
            set: { newValue in coordinator.setStartupRestoration(newValue) }
        )
    }

    private func playlistEntry(_ playlist: GWPlaylistRotator) -> some View {
        GWSettingsCard(title: "播放列表", systemImage: "rectangle.stack.badge.play") {
            HStack(spacing: 12) {
                Text("\(playlist.itemCount) 个壁纸")
                    .font(.callout)
                Spacer(minLength: 8)
                if let onOpenPlaylist {
                    Button(action: onOpenPlaylist) {
                        Label("管理", systemImage: "arrow.right")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .accessibilityIdentifier("settings-open-playlist")
                }
            }
        }
    }

    // MARK: - 素材库与存储

    private var libraryStorageCard: some View {
        GWSettingsCard(
            title: "素材库与存储",
            systemImage: "internaldrive"
        ) {
            libraryInfoSection
            if libraryInfoProvider != nil {
                Divider().opacity(0.35)
            }
            GWStorageCleanupView(controller: cleanup)
        }
    }

    @ViewBuilder
    private var libraryInfoSection: some View {
        if let info = libraryInfoProvider?() {
            VStack(alignment: .leading, spacing: 6) {
                GWSettingsKeyValueRow(
                    title: "素材数量",
                    value: "\(info.itemCount) 个",
                    systemImage: "film"
                )
                if info.missingCount > 0 {
                    GWSettingsKeyValueRow(
                        title: "待处理的素材",
                        value: "\(info.missingCount) 个文件缺失",
                        systemImage: "exclamationmark.triangle"
                    )
                }
                GWSettingsKeyValueRow(
                    title: "媒体副本占用",
                    value: GWSettingsFormat.bytes(info.totalMediaBytes),
                    systemImage: "externaldrive"
                )
                GWSettingsKeyValueRow(
                    title: "已分配显示器",
                    value: "\(info.assignedDisplayCount) 台",
                    systemImage: "display"
                )
            }
        }
    }

    // MARK: - 配置导入与导出

    private var configurationCard: some View {
        GWSettingsCard(
            title: "配置导入与导出",
            systemImage: "square.and.arrow.up.on.square"
        ) {
            HStack(spacing: 10) {
                Button {
                    Task { await exportConfiguration() }
                } label: {
                    Label("导出配置…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                Button {
                    Task { await importConfiguration() }
                } label: {
                    Label("导入配置…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("导入前会完整校验文件；校验不通过不会应用任何设置")

                Spacer()
            }

            if let transferMessage {
                GWSettingsFootnote(text: transferMessage)
            }
            if let transferError {
                GWSettingsFootnote(text: transferError, isError: true)
            }
        }
    }

    private func exportConfiguration() async {
        let panel = NSSavePanel()
        panel.title = "导出配置"
        panel.message = "导出文件不包含素材、账号、登录或令牌信息。"
        panel.prompt = "导出"
        panel.nameFieldStringValue = "Glimmer配置-\(GWSettingsFormat.fileStamp()).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let response = await panel.begin()
        guard response == .OK, let url = panel.url else { return }
        do {
            let bytes = try coordinator.exportConfiguration(to: url)
            transferMessage = "已导出配置（\(GWSettingsFormat.bytes(Int64(bytes)))）。"
            transferError = nil
        } catch {
            transferError = error.localizedDescription
            transferMessage = nil
        }
    }

    private func importConfiguration() async {
        let panel = NSOpenPanel()
        panel.title = "导入配置"
        panel.message = "选择之前从Glimmer导出的配置文件；导入前会完整校验。"
        panel.prompt = "校验并查看"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        let response = await panel.begin()
        guard response == .OK, let url = panel.url else { return }
        do {
            pendingImport = try coordinator.validateImport(contentsOf: url)
            transferError = nil
            transferMessage = nil
        } catch {
            pendingImport = nil
            transferError = error.localizedDescription
            transferMessage = nil
        }
    }

    private func commitPendingImport() {
        guard let pendingImport else { return }
        do {
            let sections = try coordinator.commitImport(pendingImport)
            transferMessage = "已导入：\(sections.joined(separator: "、"))。"
            transferError = nil
        } catch {
            transferError = error.localizedDescription
            transferMessage = nil
        }
        self.pendingImport = nil
    }

    // MARK: - 登录项

    @ViewBuilder
    private var loginItemControls: some View {
            if loginItem.isSupported {
                Toggle(isOn: loginItemBinding) {
                    Label("登录时启动Glimmer", systemImage: "power")
                        .font(.callout)
                }
                .toggleStyle(.switch)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("登录时启动Glimmer")
                .accessibilityValue(loginItem.isToggleOn ? "已开启" : "已关闭")
                .accessibilityHint("开启后需要系统允许时，会提示你前往系统设置确认")

                if loginItemNeedsAttention {
                    GWSettingsFootnote(text: loginItem.statusText, isError: loginItemStatusIsError)
                    Button("打开「登录项」系统设置") {
                        loginItem.openSystemSettingsLoginItems()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("在系统设置中查看或调整登录项授权")
                }
            } else {
                GWSettingsFootnote(text: loginItem.statusText, isError: true)
            }
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { loginItem.isToggleOn },
            set: { newValue in
                Task { await loginItem.setEnabled(newValue) }
            }
        )
    }

    private var loginItemStatusIsError: Bool {
        if case .failed = loginItem.status { return true }
        return false
    }

    private var loginItemNeedsAttention: Bool {
        switch loginItem.status {
        case .requiresApproval, .failed: return true
        case .unsupported, .notRegistered, .enabled: return false
        }
    }

    // MARK: - 恢复默认

    private var resetCard: some View {
        GWSettingsCard(
            title: "恢复默认设置",
            systemImage: "arrow.counterclockwise"
        ) {
            HStack {
                Button("恢复默认设置…") {
                    showsResetConfirmation = true
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityHint("恢复前会再次确认；不会删除任何素材文件")
                Spacer()
            }
        }
        .confirmationDialog(
            "恢复默认设置？",
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("恢复默认设置", role: .destructive) {
                coordinator.resetAllSettings()
                transferMessage = "已恢复默认设置。"
                transferError = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("外观、启动偏好、电源策略与播放列表将回到默认值；素材库、原始文件与 Steam 登录状态不受影响。")
        }
    }

    // MARK: - 键盘提示

}
