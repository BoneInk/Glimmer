import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct LibraryReviewShowInspectorKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 仅供隔离界面验证使用；正常启动始终收起详情。
    var libraryReviewShowInspector: Bool {
        get { self[LibraryReviewShowInspectorKey.self] }
        set { self[LibraryReviewShowInspectorKey.self] = newValue }
    }
}

struct WallpaperDeletionAction {
    let perform: @MainActor (WallpaperItem) async -> String?

    static func confirmationMessage(for item: WallpaperItem) -> String {
        if item.source == .steamWorkshop {
            return "下载文件及应用内副本将移到废纸篓，并移除素材库和播放列表记录。该壁纸的桌面播放会停止。原始文件会保留。"
        }
        return "应用内副本将移到废纸篓，并移除素材库和播放列表记录。该壁纸的桌面播放会停止。原始文件会保留。"
    }
}

private struct WallpaperDeletionActionKey: EnvironmentKey {
    static let defaultValue: WallpaperDeletionAction? = nil
}

extension EnvironmentValues {
    var wallpaperDeletionAction: WallpaperDeletionAction? {
        get { self[WallpaperDeletionActionKey.self] }
        set { self[WallpaperDeletionActionKey.self] = newValue }
    }
}

/// 素材库：单击封面打开详情，应用桌面始终由独立按钮显式触发。
struct LibraryWorkspaceView: View {
    let store: VideoLibraryStore
    let importService: ImportService
    let playback: DesktopPlaybackController
    let displays: DisplayRegistry
    /// 电源策略正在挂起播放时的提示（只读说明；不代表用户设置变化）。
    var policyReasonText: String? = nil

    @Binding var filter: LibraryFilter
    @Binding var searchText: String
    @Binding var sort: LibrarySort
    @Binding var sortAscending: Bool
    @Binding var selectedItemID: UUID?
    @Binding var errorMessage: String?

    /// 空素材库时进入创意工坊。
    let onBrowseWorkshop: () -> Void
    var onOpenDynamicLockScreen: ((WallpaperItem) -> Void)? = nil
    var onOpenWallpaperDetails: ((WallpaperItem) -> Void)? = nil

    @Environment(\.workspaceContentTopInset) private var contentTopInset
    @Environment(\.libraryReviewShowInspector) private var reviewShowInspector
    @Environment(\.wallpaperDeletionAction) private var deletionAction
    @GlassState private var showingSteamLibraryImport = false
    @GlassState private var pendingDeletion: WallpaperItem?
    @GlassState private var deletingItemID: UUID?
    @GlassState private var toast: TransientToast?

    private var query: LibraryQuery {
        LibraryQuery(text: searchText, filter: filter, sort: sort, ascending: sortAscending)
    }

    private var filteredItems: [WallpaperItem] {
        query.apply(to: store.items, missingIDs: store.missingItemIDs)
    }

    private var selectedItem: WallpaperItem? {
        guard let selectedItemID else { return nil }
        return store.item(withID: selectedItemID)
    }

    var body: some View {
        GlassStyleReader { style in
            LibraryGridView(
                items: filteredItems, missingIDs: store.missingItemIDs,
                selection: selectedItemID, query: query, isLibraryEmpty: store.items.isEmpty,
                importService: importService, errorMessage: nil, style: style,
                onSelect: { selectedItemID = $0 },
                onApply: { apply($0) },
                onToggleFavorite: { store.toggleFavorite(id: $0.id) },
                onDismissError: {},
                onImportAction: { Task { await presentImportPanel() } },
                onBrowseWorkshop: onBrowseWorkshop,
                onOpenDetails: { item in selectedItemID = item.id; onOpenWallpaperDetails?(item) },
                onDelete: deletionAction == nil ? nil : { pendingDeletion = $0 }
            )
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        librarySearchField
                        libraryHeaderControls
                    }
                    VStack(alignment: .trailing, spacing: 10) {
                        librarySearchField
                        libraryHeaderControls
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .workshopNavigationSurface(cornerRadius: 22)
                .padding(.horizontal, 24).padding(.top, contentTopInset).padding(.bottom, 2)
            }
            .frame(minWidth: 720, minHeight: 560)
            .onAppear {
                store.refreshMissingState()
                if selectedItemID == nil { selectedItemID = filteredItems.first?.id }
                if reviewShowInspector, let item = selectedItem ?? filteredItems.first { onOpenWallpaperDetails?(item) }
                if let error = store.lastError { errorMessage = error }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                store.refreshMissingState()
            }
            .onChange(of: filter) { _, _ in clampSelection() }
            .onChange(of: searchText) { _, _ in clampSelection() }
            .onChange(of: errorMessage, initial: true) { _, message in
                guard let message, !message.isEmpty else { return }
                toast = TransientToast(shortToastText(message), tone: .error)
            }
            .onChange(of: importService.lastSummary) { _, summary in
                presentImportFailureSummary(summary)
            }
            .transientToast(Binding(
                get: { toast },
                set: { value in
                    toast = value
                    if value == nil { errorMessage = nil }
                }
            ))
            .sheet(isPresented: $showingSteamLibraryImport) {
                SteamLibraryImportView(store: store, importer: importService,
                    onClose: { showingSteamLibraryImport = false },
                    onImported: { item in filter = .all; searchText = ""; selectedItemID = item.id },
                    onOpenDetails: { item in
                        showingSteamLibraryImport = false
                        onOpenWallpaperDetails?(item)
                    })
            }
            .confirmationDialog("删除这张壁纸？", isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }),
                titleVisibility: .visible, presenting: pendingDeletion) { item in
                Button("移到废纸篓", role: .destructive) { delete(item) }
                    .disabled(deletingItemID != nil)
                Button("取消", role: .cancel) {}
            } message: { item in
                Text(WallpaperDeletionAction.confirmationMessage(for: item))
            }
        }
    }

    // MARK: - 页内工具栏

    private var librarySearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索素材库", text: $searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("搜索素材库")
                .accessibilityIdentifier("library-search")
                .help("搜索标题、文件名、备注或创意工坊 ID")
            if !searchText.isEmpty {
                Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("清除素材库搜索")
                    .help("清除搜索")
            }
        }
        .frame(minWidth: 240, maxWidth: .infinity)
    }

    private var libraryHeaderControls: some View {
        HStack(spacing: 8) {
            Menu {
                Button("视频文件或文件夹…") { Task { await presentImportPanel() } }
                Button("Web 壁纸项目…") { Task { await presentWebImportPanel() } }
                Button("Scene 壁纸项目…") { Task { await presentSceneImportPanel() } }
                Divider()
                Button("从 Steam 本地库导入…") { showingSteamLibraryImport = true }
            } label: {
                Label("导入", systemImage: "plus").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .help("导入视频、Web 或受支持的 Scene 项目")
            .accessibilityLabel("导入壁纸")

            Menu {
                Picker("排序方式", selection: $sort) {
                    ForEach(LibrarySort.allCases) { entry in
                        Label(entry.title, systemImage: entry.symbolName).tag(entry)
                    }
                }
                .pickerStyle(.inline)
                Toggle("升序", isOn: $sortAscending)
            } label: {
                Label("排序", systemImage: "arrow.up.arrow.down").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .help("排序：\(sort.title)")
            .accessibilityLabel("排序：\(sort.title)")


        }
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - 行为

    private func shortToastText(_ value: String, limit: Int = 180) -> String {
        let text = value
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    private func presentImportFailureSummary(_ summary: String?) {
        guard let summary,
              let range = summary.range(of: #"失败 \d+ 个"#, options: .regularExpression) else { return }
        let countText = summary[range].filter(\.isNumber)
        guard let count = Int(countText), count > 0 else { return }
        let reasons = importService.jobs.reversed().compactMap { job -> String? in
            guard case .failed(let reason) = job.state else { return nil }
            if reason.contains("读取视频轨道失败") || reason.contains("OSStatus") {
                return "无法读取视频，请选择可播放的视频文件。"
            }
            return shortToastText(reason, limit: 96)
        }
        let recentReasons = Array(reasons.prefix(count))
        guard let firstReason = recentReasons.first else {
            toast = TransientToast("\(count) 项导入失败", tone: .error)
            return
        }
        let hasMoreReasons = Set(recentReasons).count > 1
        let message = count == 1
            ? "导入失败：\(firstReason)"
            : "\(count) 项导入失败：\(firstReason)\(hasMoreReasons ? " 等" : "")"
        toast = TransientToast(message, tone: .error)
    }

    private func apply(_ item: WallpaperItem) {
        Task { @MainActor in
            errorMessage = await playback.applyAndWait(item: item, to: nil)
        }
    }

    private func delete(_ item: WallpaperItem) {
        guard let deletionAction, deletingItemID == nil else { return }
        deletingItemID = item.id
        Task { @MainActor in
            let error = await deletionAction.perform(item)
            deletingItemID = nil
            if let error { errorMessage = "未能删除：\(error)"; return }
            if selectedItemID == item.id { selectedItemID = filteredItems.first?.id }
            errorMessage = nil
        }
    }

    private func clampSelection() {
        if let selectedItemID, store.item(withID: selectedItemID) != nil {
            if !filteredItems.contains(where: { $0.id == selectedItemID }) {
                self.selectedItemID = filteredItems.first?.id
            }
        } else {
            selectedItemID = filteredItems.first?.id
        }
    }

    private func presentImportPanel() async {
        let panel = NSOpenPanel()
        panel.title = "导入视频壁纸"
        panel.message = "选择视频文件或包含视频的文件夹（原始文件不会被移动或修改）"
        panel.prompt = "导入"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = VideoFileSupport.allowedContentTypes
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first

        let response = await panel.begin()
        guard response == .OK else { return }
        await importService.importURLs(panel.urls)
    }

    private func presentWebImportPanel() async {
        let panel = NSOpenPanel()
        panel.title = "导入 Web 壁纸项目文件夹"
        panel.message = "选择包含 project.json 的项目文件夹，授权读取完整本地资源。项目将复制到素材库。"
        panel.prompt = "导入项目"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do {
            let outcome = await importService.importLocalWebProject(url)
            let id: UUID
            switch outcome {
            case .imported(let itemID), .duplicated(let itemID, _): id = itemID
            case .failed(let message): throw WebProjectError.invalid(message)
            }
            guard let item = store.item(withID: id) else { throw WebProjectError.invalid("导入的项目已不可用") }
            selectedItemID = item.id
            errorMessage = nil
            onOpenWallpaperDetails?(item)
        } catch { errorMessage = error.localizedDescription }
    }

    private func presentSceneImportPanel() async {
        let panel = NSOpenPanel()
        panel.title = "导入 Scene 壁纸项目文件夹"
        panel.message = "选择包含 project.json 的完整项目。导入前会检查所用功能，不兼容的项目会显示具体诊断。项目将复制到素材库。"
        panel.prompt = "验证并导入"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard await panel.begin() == .OK, let url = panel.url else { return }
        switch await importService.importLocalSceneProject(url) {
        case .imported(let id), .duplicated(let id, _):
            guard let item = store.item(withID: id) else { errorMessage = "导入的 Scene 项目已不可用"; return }
            filter = .all
            searchText = ""
            selectedItemID = id
            errorMessage = nil
            onOpenWallpaperDetails?(item)
        case .failed(let message): errorMessage = message
        }
    }

    private func relink(_ item: WallpaperItem) async {
        guard item.isVideoWallpaper else { errorMessage = "请重新导入完整壁纸项目。"; return }
        let panel = NSOpenPanel()
        panel.title = "重新定位视频文件"
        panel.message = "为「\(item.displayTitle)」选择新的文件位置"
        panel.prompt = "使用此文件"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = VideoFileSupport.allowedContentTypes

        let response = await panel.begin()
        guard response == .OK, let url = panel.url else { return }
        do {
            let probe = try await VideoProbe.probe(url: url)
            store.relink(id: item.id, to: url, probe: probe)
            errorMessage = nil
        } catch {
            errorMessage = "重新定位失败：\(error.localizedDescription)"
        }
    }
}
