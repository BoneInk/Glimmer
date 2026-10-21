import AppKit
import SwiftUI

/// Download controls remain bound to the coordinator; artwork is a visual surface only.
struct WorkshopDownloadsView: View {
    @Environment(\.workspaceContentTopInset) private var contentTopInset
    @Bindable var coordinator: WorkshopCoordinator
    let style: GlassStyle
    var onOpenAccount: () -> Void = {}
    @GlassState private var filter: DownloadFilter = .all
    @GlassState private var searchText = ""
    @GlassState private var preview: WorkshopLocalVideoPreview?
    @GlassState private var pendingDeletion: WorkshopDownloadItem?
    @GlassState private var showDeleteConfirmation = false
    @GlassState private var toast: TransientToast?
    @FocusState private var searchIsFocused: Bool

    private enum DownloadFilter: String, CaseIterable, Identifiable {
        case all = "全部", active = "进行中", paused = "已暂停", completed = "已完成", failed = "失败"
        var id: String { rawValue }
        func includes(_ item: WorkshopDownloadItem) -> Bool {
            switch self {
            case .all: return true
            case .active: return item.state.isActiveWork
            case .paused: return item.state == .paused
            case .completed: return item.state.isSuccess
            case .failed: if case .failed = item.state { return true }; return false
            }
        }
    }
    private var items: [WorkshopDownloadItem] { coordinator.downloadProgress.items }
    private var searchQuery: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasSearchQuery: Bool { !searchQuery.isEmpty }
    private var visibleItems: [WorkshopDownloadItem] {
        items.filter { filter.includes($0) && matchesSearch($0) }
    }
    private var completedCount: Int { items.filter(DownloadFilter.completed.includes).count }
    private var retryableCount: Int { items.filter { $0.state.isTerminal && !$0.state.isSuccess }.count }

    private var queuePersistenceNotice: String? {
        let prefix: String
        let message: String
        switch coordinator.queueRestoreState {
        case .failed(let failure):
            prefix = "下载队列恢复失败"
            message = failure
        case .notStarted, .loading, .ready:
            guard let failure = coordinator.queuePersistenceError else { return nil }
            prefix = "下载队列未能保存"
            message = failure
        }
        if let banner = coordinator.downloadBanner,
           !message.isEmpty,
           (banner.contains(message) || message.contains(banner)) {
            return nil
        }
        let redacted = WorkshopDisplayMessage.redacted(message, limit: 600)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return redacted.isEmpty ? prefix : "\(prefix)：\(redacted)"
    }

    private func matchesSearch(_ item: WorkshopDownloadItem) -> Bool {
        guard hasSearchQuery else { return true }
        return item.title.localizedStandardContains(searchQuery)
            || item.validatedProject?.projectTitle?.localizedStandardContains(searchQuery) == true
            || item.publishedFileID.localizedStandardContains(searchQuery)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if items.contains(where: { $0.state.isActiveWork }),
                   !coordinator.account.isSignedIn ||
                    (coordinator.account.nativeContentAvailable && !coordinator.account.isNativeContentReady) { accountNotice }
                if let persistenceNotice = queuePersistenceNotice {
                    Label(persistenceNotice, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .accessibilityIdentifier("download-queue-persistence-error")
                }
                if items.isEmpty {
                    if coordinator.queueRestoreState == .loading {
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small)
                            Text("正在恢复下载队列…")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 10)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("download-queue-restoring")
                    } else {
                        ContentUnavailableView {
                            Label("暂无下载", systemImage: "arrow.down.circle")
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 28)
                    }
                } else if visibleItems.isEmpty {
                    noMatchingDownloads
                        .frame(maxWidth: .infinity).padding(.vertical, 28)
                } else {
                    LazyVGrid(
                        columns: WallpaperCardLayout.columns,
                        alignment: .leading, spacing: WallpaperCardLayout.spacing
                    ) {
                        ForEach(visibleItems) { downloadRow($0) }
                    }
                }
            }
            .padding(.horizontal, WallpaperCardLayout.horizontalPadding)
            .padding(.top, WallpaperCardLayout.topPadding)
            .padding(.bottom, WallpaperCardLayout.bottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            toolbar
                .padding(.horizontal, 24)
                .padding(.top, contentTopInset)
                .padding(.bottom, 2)
        }
        .background(Color.clear)
        .onChange(of: coordinator.downloadBanner, initial: true) { _, message in
            guard let message, !message.isEmpty else { return }
            let redacted = WorkshopDisplayMessage.redacted(message)
            toast = TransientToast(redacted, tone: downloadToastTone(message))
        }
        .transientToast(Binding(
            get: { toast },
            set: { value in
                toast = value
                if value == nil { coordinator.dismissDownloadBanner() }
            }
        ))
        .background {
            Button("聚焦下载搜索") { searchIsFocused = true }
                .keyboardShortcut("f", modifiers: [.command])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .sheet(item: $preview) { WorkshopVideoPreviewSheet(preview: $0, coordinator: coordinator) }
        .confirmationDialog("删除壁纸？", isPresented: $showDeleteConfirmation,
                            titleVisibility: .visible, presenting: pendingDeletion) { item in
            Button(coordinator.deletionIsSimulated ? "移入模拟废纸篓" : "移到废纸篓", role: .destructive) {
                Task { await coordinator.deleteDownloadedWallpaper(itemID: item.id) }
            }
            Button("取消", role: .cancel) {}
        } message: { item in
            Text(coordinator.deletionIsSimulated
                 ? "隔离演示：只将「\(item.title)」的临时素材移到演示目录，不使用系统废纸篓。"
                 : "「\(item.validatedProject?.projectTitle ?? item.title)」的下载文件及已导入的管理副本将移到废纸篓，可恢复。正在使用它的桌面会话会停止；原始本地文件和独立锁屏副本会保留。")
        }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                filters
                downloadSearchField.frame(minWidth: 220, idealWidth: 280, maxWidth: 340)
                Spacer(minLength: 8)
                batchActions
            }
            VStack(alignment: .leading, spacing: 10) {
                filters
                HStack(spacing: 12) {
                    downloadSearchField.frame(minWidth: 220, maxWidth: .infinity)
                    batchActions
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                filters
                downloadSearchField.frame(maxWidth: .infinity)
                batchActions
            }
        }
        .padding(8)
        .workshopNavigationSurface(cornerRadius: 18, interactive: true)
    }

    private func downloadToastTone(_ message: String) -> TransientToast.Tone {
        if message.hasPrefix("已下载并导入：") || message.hasPrefix("已将下载的壁纸") || message.hasPrefix("隔离演示：已移入") {
            return .success
        }
        if message.contains("失败") || message.contains("无法") || message.contains("未能") || message.contains("不可用") {
            return .error
        }
        if message.hasPrefix("请先") || message.contains("稍候") || message.contains("暂停") {
            return .warning
        }
        return .info
    }

    private var downloadSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索下载", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchIsFocused)
                .accessibilityLabel("搜索下载")
                .accessibilityHint("按标题、项目真实标题或 Workshop ID 筛选当前下载")
                .accessibilityIdentifier("download-search")
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除下载搜索")
                .accessibilityLabel("清除下载搜索")
                .accessibilityIdentifier("download-search-clear")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(.primary.opacity(0.045), in: Capsule())
        .help("搜索标题、项目真实标题或 Workshop ID（⌘F）")
    }

    private var noMatchingDownloads: some View {
        ContentUnavailableView {
            Label(hasSearchQuery ? "没有匹配的下载" : "没有\(filter.rawValue)的下载",
                  systemImage: hasSearchQuery ? "magnifyingglass" : "line.3.horizontal.decrease.circle")
        } description: {
            if hasSearchQuery {
                Text("没有找到“\(searchQuery)”\(filter == .all ? "" : "且状态为“\(filter.rawValue)”")的任务。")
            }
        } actions: {
            HStack(spacing: 8) {
                if hasSearchQuery {
                    Button("清除搜索") { searchText = "" }
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("download-empty-clear-search")
                }
                if filter != .all {
                    Button("显示全部状态") { filter = .all }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("download-empty-clear-filter")
                }
            }
        }
    }

    private var filters: some View {
        Picker("下载筛选", selection: $filter) {
            ForEach(DownloadFilter.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(minWidth: 260, maxWidth: 390)
    }

    private var batchActions: some View {
        HStack(spacing: 10) {
            if coordinator.hasQueuedDownloads || coordinator.isDownloadQueuePaused {
                Button {
                    coordinator.setDownloadQueuePaused(!coordinator.isDownloadQueuePaused)
                } label: {
                    Label(coordinator.isDownloadQueuePaused ? "继续队列" : "暂停后续下载",
                          systemImage: coordinator.isDownloadQueuePaused ? "play.fill" : "pause")
                }
                .buttonStyle(.borderless).controlSize(.small)
                .help("只控制后续任务的启动；已单独暂停的项目不会自动继续")
                .accessibilityIdentifier("download-queue-toggle")
            }
            Menu {
                Button("重试失败和已取消项") { coordinator.retryFailedDownloads() }.disabled(retryableCount == 0)
                Button("取消排队项") { coordinator.cancelQueuedDownloads() }
                    .disabled(!items.contains { $0.state == .queued })
                Button("本次隐藏已完成项") { coordinator.clearFinishedDownloads() }
                    .help("保留文件与素材库；重新读取下载目录后会再次显示。")
                    .disabled(completedCount == 0)
            } label: { Label("批量操作", systemImage: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 8)
            Button(action: onOpenAccount) {
                Image(systemName: "person.crop.circle")
            }
            .buttonStyle(.borderless).controlSize(.small)
            .help("Steam 账号")
            .accessibilityLabel("打开 Steam 账号")
        }
    }

    private var accountNotice: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { accountMessage; Spacer(minLength: 8); accountButton }
            VStack(alignment: .leading, spacing: 10) { accountMessage; accountButton }
        }
        .padding(14).workshopGlassSurface(cornerRadius: 18)
    }
    private var accountMessage: some View {
        let presentation = WorkshopAccountPresentation(account: coordinator.account)
        return Label(presentation.message, systemImage: presentation.symbol)
            .font(.caption).foregroundStyle(presentation.color).fixedSize(horizontal: false, vertical: true)
    }
    private var accountButton: some View {
        Button(WorkshopAccountPresentation(account: coordinator.account).actionTitle, action: onOpenAccount)
            .buttonStyle(.glass).controlSize(.small).fixedSize()
            .accessibilityHint("打开 Steam 账号弹窗，不会重复启动登录")
    }

    private func downloadRow(_ item: WorkshopDownloadItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            Button { openDetails(item) } label: {
                WorkshopDownloadArtwork(
                    remoteURL: item.previewImageURL ?? coordinator.results.first(where: { $0.publishedFileID == item.publishedFileID })?.previewURL,
                    localVideoURL: item.state.isSuccess && item.validatedProject?.videoProject?.probe.isPlayable == true ? item.validatedProject?.videoProject?.videoURL : nil,
                    detailSourceKey: "workshop:\(item.id)"
                )
                .overlay {
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.08), location: 0),
                        .init(color: .black.opacity(0.18), location: 0.35),
                        .init(color: .black.opacity(style.reduceTransparency ? 1 : 0.94), location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!coordinator.hasLocalWallpaper(itemID: item.id) || coordinator.openingDetailsItemID == item.id)
            .accessibilityLabel("打开\(item.title)的详情与设置")

            VStack(alignment: .leading, spacing: 6) {
                Button { openDetails(item) } label: {
                    Text(item.validatedProject?.projectTitle ?? item.title)
                        .font(.system(size: 16, weight: .semibold)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .disabled(!coordinator.hasLocalWallpaper(itemID: item.id) || coordinator.openingDetailsItemID == item.id)
                .help(item.validatedProject?.projectTitle ?? item.title)
                .accessibilityLabel("打开\(item.title)的详情")
                .accessibilityIdentifier("download-cover-details")
                projectSummary(item)
                progress(item)
                HStack(spacing: 8) {
                    rowActions(item)
                    Spacer(minLength: 0)
                }
                .frame(height: 30)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .aspectRatio(WallpaperCardLayout.aspectRatio, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            stateBadge(item)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(.black.opacity(style.reduceTransparency ? 1 : 0.65), in: Capsule())
                .padding(12)
                .help(failureMessage(item) ?? item.state.displayText)
        }
        .foregroundStyle(.white)
        .background(.black.opacity(0.85))
        .wallpaperCoverSource("workshop:\(item.id)",
            remoteURL: item.previewImageURL ?? coordinator.results.first(where: { $0.publishedFileID == item.publishedFileID })?.previewURL, geometryPriority: 1)
        .clipShape(RoundedRectangle(cornerRadius: WallpaperCardLayout.cornerRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: WallpaperCardLayout.cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.14), radius: 12, x: 0, y: 5)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .disabled(coordinator.deletingWallpaperIDs.contains(item.id))
    }

    private func failureMessage(_ item: WorkshopDownloadItem) -> String? {
        guard case .failed(let message) = item.state else { return nil }
        return WorkshopDisplayMessage.redacted(message, limit: 2_000)
    }

    @ViewBuilder
    private func projectSummary(_ item: WorkshopDownloadItem) -> some View {
        if let project = item.validatedProject {
            switch project {
            case .video(let video):
                Text("视频 · \(video.probe.resolutionText) · \(video.probe.durationText) · \(ByteCountFormatter.string(fromByteCount: video.videoByteSize, countStyle: .file))")
                    .font(.caption2).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
            case .scene(let scene):
                Text("Scene · \(ByteCountFormatter.string(fromByteCount: scene.totalByteSize, countStyle: .file))")
                    .font(.caption2).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
            case .web(let web):
                Text("Web · \(ByteCountFormatter.string(fromByteCount: web.totalByteSize, countStyle: .file))")
                    .font(.caption2).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
            }
        } else if let size = item.fileSizeText {
            Text(size).font(.caption2).foregroundStyle(.white.opacity(0.72))
        }
    }

    @ViewBuilder
    private func progress(_ item: WorkshopDownloadItem) -> some View {
        if item.state.isActiveWork, item.state != .queued {
            HStack {
                if !item.progressText.isEmpty {
                    Text(WorkshopDisplayMessage.redacted(item.progressText)).lineLimit(1)
                } else {
                    Text("正在处理壁纸")
                }
                Spacer(minLength: 8)
                if let fraction = downloadFraction(item) {
                    Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                }
            }
            .font(.caption).foregroundStyle(.white.opacity(0.9))
            if let fraction = downloadFraction(item) {
                ProgressView(value: fraction).progressViewStyle(.linear).tint(.white)
            } else {
                ProgressView().progressViewStyle(.linear).tint(.white)
            }
        } else if item.state == .paused, !item.progressText.isEmpty {
            HStack(spacing: 8) {
                Text(WorkshopDisplayMessage.redacted(item.progressText))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let fraction = item.progressFraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                }
            }
            .font(.caption).foregroundStyle(.white.opacity(0.76))
        }
    }

    private func downloadFraction(_ item: WorkshopDownloadItem) -> Double? {
        // Validation is a separate phase; a previous download fraction is not validation progress.
        guard case .downloading(let fraction, _) = item.state else { return nil }
        return fraction ?? item.progressFraction
    }

    private func openDetails(_ item: WorkshopDownloadItem) {
        Task { await coordinator.openWallpaperDetails(itemID: item.id) }
    }

    private func canRequestDeletion(_ item: WorkshopDownloadItem) -> Bool {
        switch item.state {
        case .queued, .downloading, .paused, .completed, .failed, .cancelled: true
        case .pausing, .validating: false
        }
    }

    @ViewBuilder
    private func rowActions(_ item: WorkshopDownloadItem) -> some View {
        if case .downloading = item.state {
            Button { coordinator.pauseDownload(itemID: item.id) } label: { Label("暂停", systemImage: "pause") }
                .buttonStyle(.glass).controlSize(.small).help("保留已有数据，继续时重新校验并复用")
        } else if item.state == .paused {
            Button { coordinator.resumeDownload(itemID: item.id) } label: { Label("继续", systemImage: "play.fill") }
                .buttonStyle(.glassProminent).controlSize(.small)
                .help(coordinator.isDownloadQueuePaused ? "将此项加入等待队列；后续下载仍暂停，可在卡片上继续队列" : "重新校验并复用已有下载数据")
        } else if coordinator.isWaitingForQueue(itemID: item.id) {
            Button { coordinator.setDownloadQueuePaused(false) } label: { Label("继续队列", systemImage: "play.fill") }
                .buttonStyle(.glassProminent).controlSize(.small)
                .help("按顺序启动排队项目；其他单独暂停的项目仍保持暂停")
                .accessibilityIdentifier("download-resume-queue")
        }
        if item.state == .cancelled || failureMessage(item) != nil {
            Button { coordinator.retryDownload(itemID: item.publishedFileID) } label: {
                Label("重试", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glassProminent).controlSize(.small)
            .accessibilityLabel("重试：\(item.title)")
        }
        if !item.state.isTerminal {
            Button { coordinator.cancelDownload(itemID: item.publishedFileID) } label: {
                Label("取消", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass).controlSize(.small)
            .help("取消")
            .accessibilityLabel("取消下载：\(item.title)")
        }
        if canRequestDeletion(item) {
            Menu {
                if let message = failureMessage(item) {
                    Button("复制错误信息") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message, forType: .string)
                    }
                    .help(message)
                    if !coordinator.account.isSignedIn ||
                        (coordinator.account.nativeContentAvailable && !coordinator.account.isNativeContentReady) {
                        Button("连接 Steam", action: onOpenAccount)
                    }
                    Divider()
                }
                if item.state == .queued {
                    Button("在队列中上移") { coordinator.moveQueuedDownload(itemID: item.publishedFileID, direction: .up) }
                    Button("在队列中下移") { coordinator.moveQueuedDownload(itemID: item.publishedFileID, direction: .down) }
                }
                if item.state.isSuccess {
                    Button("在访达中显示") { coordinator.revealDownloadInFinder(itemID: item.publishedFileID) }
                }
                if canRequestDeletion(item) {
                    Button("删除壁纸…", role: .destructive) {
                        pendingDeletion = item
                        showDeleteConfirmation = true
                    }
                    .disabled(coordinator.deletingWallpaperIDs.contains(item.id) || coordinator.importingItemIDs.contains(item.id) ||
                              coordinator.detailsImportItemIDs.contains(item.id) ||
                              coordinator.isApplyingWallpaper || coordinator.isPreparingDynamicLockScreen)
                    .help("将下载文件与相关管理副本移到废纸篓，可恢复")
                    Divider()
                    Button("本次隐藏") { coordinator.removeDownload(itemID: item.publishedFileID) }
                        .help("保留文件、素材库与已导入标记；重新读取下载目录后会再次显示。")
                }
            } label: { Label("更多操作", systemImage: "ellipsis") }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(7)
            .workshopGlassSurface(cornerRadius: 14, interactive: true)
            .help("更多操作")
            .accessibilityLabel("更多操作：\(item.title)")
        }
    }

    @ViewBuilder
    private func stateBadge(_ item: WorkshopDownloadItem) -> some View {
        if coordinator.deletingWallpaperIDs.contains(item.id) {
            badgeLabel("正在删除", symbol: "trash", color: .orange)
        } else {
        switch item.state {
        case .paused: badgeLabel("已暂停", symbol: "pause.circle", color: .white)
        case .pausing: badgeLabel("正在暂停", symbol: "pause", color: .yellow)
        case .queued: badgeLabel(coordinator.isWaitingForQueue(itemID: item.id) ? "等待继续队列" : "排队中", symbol: "clock", color: .white.opacity(0.85))
        case .downloading: badgeLabel("下载中", symbol: "arrow.down.circle.fill", color: .cyan)
        case .validating: badgeLabel("正在校验壁纸", symbol: "checkmark.shield", color: .yellow)
        case .completed: badgeLabel("已完成", symbol: "checkmark.circle.fill", color: .mint)
        case .failed: badgeLabel("下载失败", symbol: "exclamationmark.circle.fill", color: .orange)
        case .cancelled: badgeLabel("已取消", symbol: "slash.circle", color: .white.opacity(0.65))
        }
        }
    }
    private func badgeLabel(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol).font(.caption.weight(.medium)).foregroundStyle(color).lineLimit(1)
    }
}

/// 远程图片视图（带缓存，失败显示占位）。
struct WorkshopRemoteImage: View {
    let url: URL
    var detailSourceKey: String? = nil
    @GlassState private var data: Data?

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .wallpaperCoverSource(detailSourceKey, data: data, remoteURL: url)
        .task(id: url) {
            data = await WorkshopPreviewCache.shared.data(for: url)
        }
    }
}

/// Keep account/session sanitization and local filesystem details out of normal Workshop copy.
enum WorkshopDisplayMessage {
    static func redacted(_ value: String, limit: Int = 240) -> String {
        let text = value.replacingOccurrences(
            of: #"(?:file://)?/(?:Users|private|var|Volumes|Applications|Library|tmp)/[^\s，。；;]*"#,
            with: "本地文件", options: .regularExpression
        )
        return SteamLoginSession.sanitize(text, limit: limit)
    }
}
