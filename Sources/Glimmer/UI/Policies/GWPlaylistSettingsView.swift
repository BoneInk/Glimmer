import SwiftUI

// F19 播放列表轮播的 SwiftUI 设置组件。
//
// 接入方式（主控后续放入 F17 设置窗口或侧栏）：
// ```
// let playlist = GWPlaylistRotator()
// playlist.isItemPlayable = { id in store.item(withID: id)?.fileExists == true }
// playlist.onSelectWallpaper = { id in /* 连接 B01 apply(item:) */ }
// GWPlaylistSettingsView(
//     rotator: playlist,
//     titleProvider: { store.item(withID: $0)?.displayTitle },
//     availableItemsProvider: { store.items.map { ($0.id, $0.displayTitle) } }
// )
// ```
// 预览/验证入口：`GWPlaylistRotator(settings: ..., persistenceEnabled: false)`。
struct GWPlaylistSettingsView: View {
    let rotator: GWPlaylistRotator
    /// 素材标题解析（主控注入；缺省显示 UUID 前缀）。
    var titleProvider: ((UUID) -> String)?
    /// 可加入轮播的素材（主控注入；缺省隐藏「添加素材」菜单）。
    var availableItemsProvider: (() -> [(id: UUID, title: String)])?
    /// 保留嵌入方参数兼容；现在控制明确的清空列表入口。
    var showsResetButton: Bool = true
    @GlassState private var showsClearConfirmation = false

    var body: some View {
        GWSettingsCard(
            title: "自动轮播",
            systemImage: "rectangle.stack.badge.play"
        ) {
            enableRow
            configurationRow
            Divider().opacity(0.35)
            if !rotator.settings.itemIDs.isEmpty, case .stopped(let reason) = rotator.status {
                Label(reason, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            listSection
            footerRow
        }
        .accessibilityIdentifier("gw.playlist.settingsCard")
        .confirmationDialog("清空播放列表？", isPresented: $showsClearConfirmation, titleVisibility: .visible) {
            Button("清空播放列表", role: .destructive) {
                rotator.clearPlaylist()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅移除轮播列表中的条目，保留顺序模式、切换间隔和自动轮播开关；不会删除素材或更改当前桌面壁纸。")
        }
    }

    // MARK: - 开关与配置

    private var enableRow: some View {
        Toggle(isOn: enabledBinding) {
            Label("启用自动轮播", systemImage: "clock.arrow.circlepath")
                .font(.callout)
        }
        .toggleStyle(.switch)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("关闭时保留列表；播放暂停时停止计时。")
        .accessibilityHint("开启后按设定间隔自动切换到播放列表中的下一项")
        .accessibilityIdentifier("gw.playlist.toggle.enabled")
    }

    private var configurationRow: some View {
        HStack(spacing: 18) {
            HStack(spacing: 8) {
                Label("轮播顺序", systemImage: "arrow.left.arrow.right")
                    .font(.callout)
                Picker("轮播顺序", selection: modeBinding) {
                    ForEach(GWPlaylistMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
                .accessibilityIdentifier("gw.playlist.picker.mode")
            }

            HStack(spacing: 8) {
                Label("切换间隔", systemImage: "timer")
                    .font(.callout)
                Picker("切换间隔", selection: intervalBinding) {
                    ForEach(intervalOptions, id: \.self) { option in
                        Text(GWPlaylistSettings.formatInterval(option)).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                .accessibilityIdentifier("gw.playlist.picker.interval")
            }
            Spacer()
        }
    }

    // MARK: - 列表

    @ViewBuilder
    private var listSection: some View {
        if rotator.settings.itemIDs.isEmpty {
            Text("列表为空")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rotator.settings.itemIDs.enumerated()), id: \.element) { index, id in
                    entryRow(index: index, id: id)
                }
            }
        }
    }

    private func entryRow(index: Int, id: UUID) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
            Text(title(for: id))
                .font(.callout)
                .lineLimit(1)
            if id == rotator.currentItemID {
                GWStatusPill(text: "当前", systemImage: "play.fill", tint: .green)
            }
            if !rotator.isPlayable(id) {
                GWStatusPill(text: "缺失", systemImage: "exclamationmark.triangle.fill", tint: .orange)
            }
            Spacer()
            Button {
                rotator.moveItem(fromIndex: index, toIndex: index - 1)
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(index == 0)
            .help("上移")
            .accessibilityLabel("上移第 \(index + 1) 项")

            Button {
                rotator.moveItem(fromIndex: index, toIndex: index + 1)
            } label: {
                Image(systemName: "arrow.down")
            }
            .disabled(index >= rotator.settings.itemIDs.count - 1)
            .help("下移")
            .accessibilityLabel("下移第 \(index + 1) 项")

            Button(role: .destructive) {
                rotator.removeItem(id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .help("从轮播移除（不会删除文件）")
            .accessibilityLabel("从轮播移除 \(title(for: id))")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    // MARK: - 底部操作

    private var footerRow: some View {
        HStack(spacing: 10) {
            if let availableItemsProvider {
                Menu {
                    let available = availableItemsProvider().filter { !rotator.settings.itemIDs.contains($0.id) }
                    if available.isEmpty {
                        Text("没有可添加的素材")
                    } else {
                        ForEach(available, id: \.id) { entry in
                            Button(entry.title) {
                                rotator.addItem(entry.id)
                            }
                        }
                    }
                } label: {
                    Label("添加素材", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier("gw.playlist.addMenu")
            }

            if !rotator.settings.itemIDs.isEmpty {
                Button {
                    rotator.advanceNow()
                } label: {
                    Label("下一张", systemImage: "forward.end")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("切换全部显示器到下一张壁纸")
                .accessibilityLabel("切换全部显示器到下一张壁纸")
                .accessibilityIdentifier("gw.playlist.advanceNow")
            }

            Spacer()

            if showsResetButton && !rotator.settings.itemIDs.isEmpty {
                Button("清空播放列表…") {
                    showsClearConfirmation = true
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityIdentifier("gw.playlist.clear")
            }
        }
    }

    // MARK: - 辅助

    private func title(for id: UUID) -> String {
        titleProvider?(id) ?? String(id.uuidString.prefix(8))
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { rotator.settings.isEnabled },
            set: { newValue in
                if newValue {
                    rotator.startRotation()
                } else {
                    rotator.stopRotation()
                }
            }
        )
    }

    private var modeBinding: Binding<GWPlaylistMode> {
        Binding(
            get: { rotator.settings.mode },
            set: { newValue in
                rotator.updateSettings { $0.mode = newValue }
            }
        )
    }

    private var intervalOptions: [TimeInterval] {
        var options = GWPlaylistSettings.intervalPresets
        let current = rotator.settings.intervalSeconds
        if !options.contains(where: { abs($0 - current) < 0.5 }) {
            options.append(current)
            options.sort()
        }
        return options
    }

    private var intervalBinding: Binding<TimeInterval> {
        Binding(
            get: { rotator.settings.intervalSeconds },
            set: { newValue in
                rotator.updateSettings { $0.intervalSeconds = newValue }
            }
        )
    }
}
