import SwiftUI

// F18 存储清理界面：清点结果、可勾选的清理范围、明确的确认与结果。
//
// - 清理项通过「移到废纸篓」完成，可从废纸篓恢复；
// - 原始导入文件、正在播放或仍被引用的文件、应用管理目录之外的路径、
//   SteamCMD 运行时与登录缓存都不会被删除（服务层每次删除前实时复核）。

struct GWStorageCleanupView: View {
    let controller: GWStorageCleanupController

    @GlassState private var selection: Set<GWCleanupCategory> = []
    @GlassState private var hasTouchedSelection = false
    @GlassState private var showsConfirmation = false
    @GlassState private var showsSamples = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let inventory = controller.inventory {
                categoryList(inventory)
                if showsSamples {
                    sampleList(inventory)
                }
                actionRow
                if let result = controller.lastResult {
                    resultSection(result)
                }
            } else if controller.isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在统计存储占用…").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("尚未统计存储占用。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let error = controller.lastError {
                GWSettingsFootnote(text: error, isError: true)
            }
        }
        .task {
            if controller.inventory == nil {
                await controller.refreshInventory()
            }
        }
        .onChange(of: controller.inventory) { _, _ in
            reconcileSelection()
        }
        .confirmationDialog(
            "清理所选项目？",
            isPresented: $showsConfirmation,
            titleVisibility: .visible
        ) {
            Button(confirmationButtonTitle, role: .destructive) {
                Task { await performCleanup() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所选文件会被移到废纸篓，可从废纸篓恢复。原始导入文件、正在播放或仍被引用的文件不会被删除；SteamCMD 与登录缓存不会被触碰。")
        }
    }

    // MARK: - 分类勾选

    private func categoryList(_ inventory: GWStorageInventory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(inventory.categories) { entry in
                Toggle(isOn: binding(for: entry.category)) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(entry.category.displayName, systemImage: entry.category.symbolName)
                                .font(.callout)
                        }
                        Spacer(minLength: 12)
                        Text(entry.isAvailable ? "\(GWSettingsFormat.fileCount(entry.fileCount)) · \(entry.sizeText)" : "目录尚未创建")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!entry.isAvailable || controller.isCleaning)
                .accessibilityLabel("\(entry.category.displayName)：\(entry.category.scopeDescription)")
                .help(entry.category.scopeDescription)
                .accessibilityValue(
                    entry.isAvailable
                        ? "\(GWSettingsFormat.fileCount(entry.fileCount))，共 \(entry.sizeText)"
                        : "目录尚未创建"
                )
            }
        }
    }

    private func binding(for category: GWCleanupCategory) -> Binding<Bool> {
        Binding(
            get: { selection.contains(category) },
            set: { newValue in
                hasTouchedSelection = true
                if newValue {
                    selection.insert(category)
                } else {
                    selection.remove(category)
                }
            }
        )
    }

    private func reconcileSelection() {
        guard let inventory = controller.inventory else { return }
        let available = Set(inventory.categories.filter(\.isAvailable).map(\.category))
        if hasTouchedSelection {
            selection.formIntersection(available)
        } else {
            selection = available
        }
    }

    // MARK: - 文件样本

    private func sampleList(_ inventory: GWStorageInventory) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(inventory.categories.filter { $0.isAvailable && $0.fileCount > 0 }) { entry in
                if !entry.samples.isEmpty {
                    Text("\(entry.category.displayName)：")
                        .font(.caption.weight(.semibold))
                    ForEach(entry.samples) { sample in
                        HStack {
                            Text(sample.name)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(GWSettingsFormat.bytes(sample.bytes))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(sample.name)，\(GWSettingsFormat.bytes(sample.bytes))")
                    }
                    if entry.fileCount > entry.samples.count {
                        Text("…另有 \(entry.fileCount - entry.samples.count) 个文件")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 信息与操作

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button("重新统计") {
                    Task { await controller.refreshInventory() }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(controller.isScanning || controller.isCleaning)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .help("重新扫描应用管理目录的占用情况")

                Button("清理所选项目…") {
                    showsConfirmation = true
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(preview.count == 0 || controller.isCleaning)
                .help("把所选文件移到废纸篓（可恢复）")

                if controller.isCleaning {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text(previewText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button(showsSamples ? "隐藏文件列表" : "查看将要清理的文件") {
                showsSamples.toggle()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .accessibilityHint("展开后显示部分文件名与大小，仅用于确认清理范围")
        }
    }

    private var preview: (count: Int, bytes: Int64) {
        controller.preview(for: selection)
    }

    private var previewText: String {
        let preview = preview
        guard preview.count > 0 else { return "未选择清理项目" }
        return "将清理 \(GWSettingsFormat.fileCount(preview.count)) · \(GWSettingsFormat.bytes(preview.bytes))"
    }

    private var confirmationButtonTitle: String {
        let preview = preview
        if preview.count == 0 { return "移到废纸篓" }
        return "移到废纸篓（\(preview.count) 个文件 · \(GWSettingsFormat.bytes(preview.bytes))）"
    }

    private func performCleanup() async {
        await controller.performCleanup(categories: selection)
    }

    private func resultSection(_ result: GWCleanupResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(result.summaryText, systemImage: result.failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(result.failures.isEmpty ? Color.primary : Color.orange)
                .accessibilityElement(children: .combine)

            if !result.skippedReasons.isEmpty {
                ForEach(result.skippedReasons.prefix(5), id: \.self) { reason in
                    Text("跳过：\(reason)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !result.failures.isEmpty {
                ForEach(result.failures.prefix(5)) { failure in
                    Text("失败：\(failure.name)：\(failure.message)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
