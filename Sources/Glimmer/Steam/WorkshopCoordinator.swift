import AppKit
import Foundation
import Observation

typealias WorkshopDownloadOperation = @Sendable (WorkshopDownloadItem, String?,
    @escaping @Sendable (WorkshopDownloadState) -> Void,
    @escaping @Sendable (String) -> Void) async throws -> WorkshopVideoProject

typealias WorkshopContentDownloadOperation = @Sendable (WorkshopDownloadItem, String?,
    @escaping @Sendable (WorkshopDownloadState) -> Void,
    @escaping @Sendable (String) -> Void) async throws -> WorkshopResolvedProject

/// B02 对外协调器（F11–F16 的门面）。
///
/// 主 App 只需：
/// ```swift
/// let workshop = WorkshopCoordinator()          // @MainActor @Observable
/// workshop.onImportVideo = { url, metadata in   // 主控接 ImportService
///     await importService.importURLs([url])
/// }
/// // 在 SwiftUI 中：WorkshopView(coordinator: workshop)
/// ```
///
/// 说明：
/// - 与 B01 的类型解耦：本模块不引用 `WallpaperItem` / `ImportService` / `VideoLibraryStore`。
/// - 搜索/详情走公开 HTTP；下载必须真实 SteamCMD 登录（网页登录无效）。
/// - 所有可观察状态都在主线程更新；长任务在 actor 内执行。
@MainActor
@Observable
final class WorkshopCoordinator {

    // MARK: - 对外回调

    /// 下载 + 校验完成后的回调：把真实视频文件 URL 与元数据交给主 App 导入。
    /// 返回错误信息（nil 表示成功）会显示在界面上。
    var onImportProject: (@MainActor (WorkshopResolvedProject, WorkshopMetadata) async -> String?)?
    var onImportVideo: (@MainActor (URL, WorkshopMetadata) async -> String?)?

    /// 独立于下载/预览/自动导入，仅由用户明确点击「设为壁纸」触发。
    var onApplyWallpaper: (@MainActor (URL, WorkshopMetadata, WorkshopWallpaperTarget) async -> WorkshopWallpaperApplyResult)?
    private(set) var isApplyingWallpaper = false
    /// Explicit apply request; main App imports then starts the shared inline workflow.
    var onRequestDynamicLockScreen: (@MainActor (URL, WorkshopMetadata) async -> String?)?
    var isDynamicLockScreenBusy: (@MainActor () -> Bool)?
    private var resolvingDynamicLockScreen = false
    var isPreparingDynamicLockScreen: Bool { resolvingDynamicLockScreen || isDynamicLockScreenBusy?() == true }
    var onDeleteWallpaper: (@MainActor (String) async -> String?)?
    var deletionIsSimulated = false
    private(set) var deletingWallpaperIDs: Set<String> = []
    private(set) var importingItemIDs: Set<String> = []
    /// 主 App 仅导入/复用 UUID 后打开统一详情，不设桌面或注册锁屏。
    var onOpenWallpaperDetails: (@MainActor (URL, WorkshopMetadata) async -> String?)?
    private(set) var openingDetailsItemID: String?
    private(set) var wallpaperDetailsError: String?
    private var detailsRequest: Task<String?, Never>?
    private var detailsGeneration = UUID()
    private var detailsImportRequests: [String: Set<UUID>] = [:]
    /// 包含已取消但真实导入尚未返回的旧请求；不能仅依赖当前打开项。
    var detailsImportItemIDs: Set<String> { Set(detailsImportRequests.keys) }

    // MARK: - 搜索状态（F11）

    private(set) var isSearching = false
    private(set) var searchError: String?
    private(set) var results: [WorkshopSearchResult] = []
    private(set) var totalCount: Int = 0
    private(set) var totalPages: Int?
    private(set) var lastDiscoveryPath: String?
    private(set) var lastSearchDuration: TimeInterval?
    private(set) var lastSearchedAt: Date?

    /// 最近一次成功搜索的请求参数（用于翻页/重试）。
    private(set) var lastRequest = WorkshopSearchRequest()

    /// 查询输入（界面绑定；搜索在用户显式触发时执行）。
    var searchText: String = ""
    var sort: WorkshopSearchSort = .trend
    var pageSize: Int = 24
    var filters = WorkshopSearchFilters()

    // MARK: - 详情解析状态（F12）

    private(set) var isResolvingItem = false
    private(set) var resolveError: String?
    private(set) var resolvedDetail: WorkshopItemDetail?
    /// 用户正在输入的链接或 ID。
    var lookupText: String = ""

    // MARK: - 下载（F15）

    let downloadProgress = WorkshopDownloadProgressModel()
    private(set) var downloadBanner: String?
    private(set) var isDownloadQueuePaused = false
    private(set) var queueRestoreState: WorkshopDownloadQueueRestoreState = .notStarted
    private(set) var queuePersistenceError: String?
    /// Only queued work is eligible for the scheduling gate; an item pause is separate.
    var hasQueuedDownloads: Bool {
        downloadProgress.items.contains { $0.state == .queued && $0.id != downloadProgress.activeItemID }
    }
    func isWaitingForQueue(itemID: String) -> Bool {
        isDownloadQueuePaused && downloadProgress.activeItemID != itemID &&
            downloadProgress.items.contains { $0.id == itemID && $0.state == .queued }
    }
    private var pauseRequestedIDs: Set<String> = []
    /// 本会话内通过下载导入过的作品 ID（用于界面提示）。
    private(set) var importedItemIDs: Set<String> = []

    // MARK: - 子服务

    let account: SteamAccountManager
    private let service: WorkshopService
    private var downloadService: WorkshopDownloadService?
    private var searchTask: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var activeDownloadGeneration: UUID?
    private var isShuttingDown = false
    private var automaticImportTasks: [UUID: Task<Void, Never>] = [:]
    private let queueStore: WorkshopDownloadQueueStore
    private var queueWriteTask: Task<Void, Never>?
    private var queueLoadTask: Task<Void, Never>?
    private var downloadedItemsReloadTask: Task<Void, Never>?
    private var queueRestoreReady = false
    private var queueMutationRevision: UInt64 = 0
    private var hasUnloadedQueueMutations = false
    private var queuePauseChangedBeforeRestore = false
    private var itemActionRevisions: [String: UInt64] = [:]
    private var deletedDownloadIDs: Set<String> = []
    var hasDownloadLifecycleWork: Bool {
        downloadTask != nil || !automaticImportTasks.isEmpty
    }

    private var browserStore: WorkshopBrowserStore
    private var hasStartedDiscovery = false
    private var hasSuccessfulCurrentSearch = false
    private let searchOperation: @Sendable (WorkshopSearchRequest) async throws -> WorkshopSearchPage
    private let contentDownloadOperation: WorkshopContentDownloadOperation?
    private let downloadOperation: WorkshopDownloadOperation?
    private let downloadPreflight: (@MainActor () -> String?)?

    init(account: SteamAccountManager? = nil, browserStore: WorkshopBrowserStore? = nil,
         searchOperation: (@Sendable (WorkshopSearchRequest) async throws -> WorkshopSearchPage)? = nil,
         downloadOperation: WorkshopDownloadOperation? = nil,
         downloadPreflight: (@MainActor () -> String?)? = nil,
         contentDownloadOperation: WorkshopContentDownloadOperation? = nil,
         queuePersistence: WorkshopDownloadQueuePersistenceConfiguration = .automatic) {
        let account = account ?? SteamAccountManager()
        let service = WorkshopService()
        self.account = account
        self.service = service
        self.browserStore = browserStore ?? WorkshopBrowserStore(persistenceURL:
            account.layout.root.deletingLastPathComponent().appendingPathComponent("browser-preferences.json"))
        self.searchOperation = searchOperation ?? { request in try await service.search(request) }
        self.contentDownloadOperation = contentDownloadOperation
        self.downloadOperation = downloadOperation
        self.downloadPreflight = downloadPreflight
        let workshopRoot = account.layout.root.deletingLastPathComponent()
        switch queuePersistence {
        case .automatic:
            self.queueStore = WorkshopDownloadQueueStore(
                persistenceURL: workshopRoot.appendingPathComponent("download-queue.json"),
                permittedRoot: workshopRoot
            )
        case .disabled:
            self.queueStore = WorkshopDownloadQueueStore(persistenceURL: nil)
            self.queueRestoreReady = true
        case .file(let url):
            self.queueStore = WorkshopDownloadQueueStore(persistenceURL: url, permittedRoot: url.deletingLastPathComponent())
        }
        account.onDownloadSessionReady = { [weak self] in self?.startNextDownloadIfIdle() }
    }

    var recentSearches: [String] { browserStore.recentSearches }
    var savedResults: [WorkshopSearchResult] { browserStore.savedResults }
    func clearSearchHistory() { browserStore.clearSearchHistory() }
    func removeRecentSearch(_ query: String) { browserStore.removeRecentSearch(query) }
    func isSaved(_ itemID: String) -> Bool { browserStore.isSaved(itemID) }
    func toggleSaved(_ result: WorkshopSearchResult) { browserStore.toggleSaved(result) }

    /// A single cancellable discovery request per coordinator; route changes never auto-retry it.
    func ensureDiscoveryLoaded() {
        guard !hasStartedDiscovery, lastSearchedAt == nil, !isSearching else { return }
        hasStartedDiscovery = true
        searchText = ""
        sort = .trend
        performSearch(WorkshopSearchRequest(query: "", sort: .trend, page: 1,
                                            pageSize: max(6, min(pageSize, 30)), filters: filters))
    }

    // MARK: - 生命周期

    /// 首次进入界面时的轻量初始化：探测 SteamCMD 能力 + 恢复已下载条目。
    func prepareIfNeeded() {
        guard !hasPrepared else { return }
        hasPrepared = true
        Task { [weak self] in
            guard let self else { return }
            async let accountPreparation: Void = self.account.prepareForDownloads()
            await self.loadDownloadQueueIfNeeded()
            await accountPreparation
            self.startNextDownloadIfIdle()
        }
    }

    private var hasPrepared = false
    private var searchGeneration = UUID()

    // MARK: - F11 搜索

    var canGoToPreviousPage: Bool { !isSearching && hasSuccessfulCurrentSearch && lastRequest.page > 1 }
    var canGoToNextPage: Bool {
        guard !isSearching, hasSuccessfulCurrentSearch else { return false }
        if let totalPages { return lastRequest.page < totalPages }
        return results.count >= lastRequest.pageSize
    }

    func search(resetPage: Bool = true) {
        var request = lastRequest
        request.query = searchText
        request.sort = sort
        request.filters = filters
        request.pageSize = max(6, min(pageSize, 30))
        if resetPage { request.page = 1 }
        performSearch(request, recordHistory: true)
    }

    /// The UI edits a local draft; only Apply commits and makes a real request.
    func setFiltersAndSearch(_ filters: WorkshopSearchFilters) {
        self.filters = filters
        search(resetPage: true)
    }

    func applyFilters(_ filters: WorkshopSearchFilters) { setFiltersAndSearch(filters) }
    func applyFilters() { search(resetPage: true) }
    func resetFilters() { setFiltersAndSearch(WorkshopSearchFilters(trendPeriod: filters.trendPeriod)) }
    func selectTrendPeriod(_ period: WorkshopTrendPeriod) {
        filters.trendPeriod = period
        sort = .trend
        search(resetPage: true)
    }
    func selectSearchSort(_ value: WorkshopSearchSort) {
        sort = value
        search(resetPage: true)
    }

    /// Explicit retry preserves the failed/cancelled query, sort, page and page size.
    /// A successful nonempty retry also records that explicit search in local history.
    func retrySearch() {
        performSearch(lastRequest, recordHistory: true)
    }

    func goToPage(_ page: Int) {
        guard page >= 1 else { return }
        guard !isSearching else { return }
        guard page == 1 || (hasSuccessfulCurrentSearch && (canGoToNextPage || page <= lastRequest.page)) else { return }
        var request = lastRequest
        request.page = page
        performSearch(request)
    }

    func nextPage() {
        guard canGoToNextPage else { return }
        goToPage(lastRequest.page + 1)
    }

    func previousPage() {
        guard canGoToPreviousPage else { return }
        goToPage(lastRequest.page - 1)
    }

    func cancelSearch() {
        searchGeneration = UUID()
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    private func performSearch(_ request: WorkshopSearchRequest, recordHistory: Bool = false) {
        searchTask?.cancel()
        let generation = UUID()
        searchGeneration = generation
        lastRequest = request
        // Results and pagination always describe exactly lastRequest, including while it is pending.
        results = []
        totalCount = 0
        totalPages = nil
        lastDiscoveryPath = nil
        lastSearchDuration = nil
        hasSuccessfulCurrentSearch = false
        isSearching = true
        searchError = nil
        let startedAt = Date()
        searchTask = Task { [weak self, searchOperation] in
            do {
                let page = try await searchOperation(request)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard !Task.isCancelled, let self, self.searchGeneration == generation, self.lastRequest == request else { return }
                    guard page.request == request else {
                        self.isSearching = false; self.searchError = "Steam 返回的搜索条件与当前请求不一致，请重试。"; return
                    }
                    if recordHistory { self.browserStore.recordSuccessfulSearch(request.query) }
                    self.hasSuccessfulCurrentSearch = true
                    self.results = page.results
                    self.totalCount = page.totalCount
                    self.totalPages = page.totalPages
                    self.lastDiscoveryPath = page.discoveryPath
                    self.lastSearchDuration = Date().timeIntervalSince(startedAt)
                    self.lastSearchedAt = Date()
                    self.isSearching = false
                    self.searchError = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                let message = Self.describe(error)
                await MainActor.run { [weak self] in
                    guard !Task.isCancelled, let self, self.searchGeneration == generation, self.lastRequest == request else { return }
                    self.isSearching = false
                    self.searchError = message
                    self.lastSearchDuration = Date().timeIntervalSince(startedAt)
                    WorkshopLog.notice("工坊搜索失败：\(message)")
                }
            }
        }
    }

    // MARK: - F12 解析链接 / ID

    func resolveLookup() {
        resolveTask?.cancel()
        resolveError = nil
        resolvedDetail = nil
        isResolvingItem = true
        let input = lookupText
        resolveTask = Task { [weak self, service] in
            do {
                let detail = try await service.resolve(input: input)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.resolvedDetail = detail
                    self.resolveError = nil
                    self.isResolvingItem = false
                }
            } catch {
                let message = Self.describe(error)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.resolveError = message
                    self.isResolvingItem = false
                }
            }
        }
    }

    func resolve(itemID: WorkshopItemID) {
        lookupText = itemID.value
        resolveLookup()
    }

    func openSourcePage(for itemID: String) {
        guard let id = WorkshopItemID(itemID) else { return }
        NSWorkspaceOpener.open(id.detailsURL)
    }

    func openSourcePage(for result: WorkshopSearchResult) {
        guard let id = WorkshopItemID(result.publishedFileID) else { return }
        NSWorkspaceOpener.open(id.detailsURL)
    }

    // MARK: - F15 下载

    var isDownloading: Bool { downloadTask != nil }

    var isSignedIn: Bool { account.isSignedIn }

    /// 把搜索结果加入下载队列并立即开始（串行执行）。
    func enqueueDownload(_ result: WorkshopSearchResult) {
        let item = WorkshopDownloadItem(
            publishedFileID: result.publishedFileID,
            title: result.title,
            kind: result.declaredTypeTag.map(WorkshopItemKind.fromTag) ?? .video,
            declaredTags: result.tags,
            previewImageURLString: result.previewURL?.absoluteString,
            fileSizeBytes: result.fileSizeBytes
        )
        enqueueDownload(item)
    }

    func enqueueDownload(_ detail: WorkshopItemDetail) {
        let item = WorkshopDownloadItem(
            publishedFileID: detail.publishedFileID,
            title: detail.title,
            kind: detail.kind,
            declaredTags: detail.tags.map(\.value),
            previewImageURLString: detail.previewImageURL?.absoluteString,
            fileSizeBytes: nil
        )
        enqueueDownload(item)
    }

    func enqueueDownload(_ item: WorkshopDownloadItem) {
        guard !deletingWallpaperIDs.contains(item.id) else { return }
        markItemAction(item.id)
        deletedDownloadIDs.remove(item.id)
        if let index = downloadProgress.items.firstIndex(where: { $0.publishedFileID == item.publishedFileID }) {
            // 已有条目：只有终态（失败/取消）才允许重新排队。
            if downloadProgress.activeItemID != item.id, Self.isRetryable(downloadProgress.items[index].state) {
                downloadProgress.items[index].state = .queued
            }
        } else {
            downloadProgress.items.append(item)
        }
        persistQueue()
        startNextDownloadIfIdle()
    }

    /// The cover control's visible pause/play glyph is an actual user action.
    func performDownloadAction(_ result: WorkshopSearchResult) {
        if handleExistingDownloadAction(itemID: result.id) { return }
        enqueueDownload(result)
    }

    private func handleExistingDownloadAction(itemID: String) -> Bool {
        guard let item = downloadProgress.items.first(where: { $0.id == itemID }) else { return false }
        switch item.state {
        case .downloading: pauseDownload(itemID: itemID); return true
        case .paused: resumeDownload(itemID: itemID); return true
        case .pausing, .validating, .completed, .queued: return true
        default: return false
        }
    }

    func setDownloadQueuePaused(_ paused: Bool) {
        isDownloadQueuePaused = paused
        if queueRestoreState == .notStarted { queuePauseChangedBeforeRestore = true }
        persistQueue()
        if !paused { startNextDownloadIfIdle() }
    }

    func pauseDownload(itemID: String) {
        guard let index = downloadProgress.items.firstIndex(where: { $0.id == itemID }) else { return }
        switch downloadProgress.items[index].state {
        case .queued:
            markItemAction(itemID)
            downloadProgress.items[index].state = .paused
        case .downloading where downloadProgress.activeItemID == itemID:
            markItemAction(itemID)
            pauseRequestedIDs.insert(itemID)
            downloadProgress.items[index].state = .pausing
            downloadTask?.cancel()
        default: return
        }
        persistQueue()
    }

    func resumeDownload(itemID: String) {
        guard let index = downloadProgress.items.firstIndex(where: { $0.id == itemID }),
              downloadProgress.items[index].state == .paused else { return }
        markItemAction(itemID)
        downloadProgress.items[index].state = .queued
        persistQueue()
        startNextDownloadIfIdle()
    }

    func retryDownload(itemID: String) {
        guard !deletingWallpaperIDs.contains(itemID) else { return }
        guard let index = downloadProgress.items.firstIndex(where: { $0.publishedFileID == itemID }) else { return }
        guard downloadProgress.activeItemID != itemID,
              Self.isRetryable(downloadProgress.items[index].state) else { return }
        markItemAction(itemID)
        downloadProgress.items[index].state = .queued
        persistQueue()
        startNextDownloadIfIdle()
    }

    private static func isRetryable(_ state: WorkshopDownloadState) -> Bool {
        switch state {
        case .failed, .cancelled: return true
        default: return false
        }
    }

    func retryFailedDownloads() {
        for index in downloadProgress.items.indices where
            downloadProgress.items[index].id != downloadProgress.activeItemID &&
            Self.isRetryable(downloadProgress.items[index].state) &&
            !deletingWallpaperIDs.contains(downloadProgress.items[index].id) {
            markItemAction(downloadProgress.items[index].id)
            downloadProgress.items[index].state = .queued
        }
        persistQueue()
        startNextDownloadIfIdle()
    }

    func cancelQueuedDownloads() {
        for index in downloadProgress.items.indices where
            downloadProgress.items[index].state == .queued &&
            downloadProgress.items[index].id != downloadProgress.activeItemID {
            markItemAction(downloadProgress.items[index].id)
            downloadProgress.items[index].state = .cancelled
        }
        persistQueue()
    }

    /// Swaps only queued slots on the main actor, leaving active/completed entries untouched.
    func moveQueuedDownload(itemID: String, direction: WorkshopQueueMoveDirection) {
        let indices = downloadProgress.items.indices.filter {
            downloadProgress.items[$0].state == .queued && downloadProgress.items[$0].id != downloadProgress.activeItemID
        }
        guard let position = indices.firstIndex(where: { downloadProgress.items[$0].id == itemID }) else { return }
        let neighbor = direction == .up ? position - 1 : position + 1
        guard indices.indices.contains(neighbor) else { return }
        markItemAction(downloadProgress.items[indices[position]].id)
        markItemAction(downloadProgress.items[indices[neighbor]].id)
        downloadProgress.items.swapAt(indices[position], indices[neighbor])
        persistQueue()
    }

    func localPreview(for itemID: String) -> WorkshopLocalVideoPreview? {
        guard !deletingWallpaperIDs.contains(itemID), let item = downloadProgress.items.first(where: { $0.id == itemID }),
              item.state == .completed, let project = item.validatedProject?.videoProject,
              project.projectType.lowercased() == "video", project.probe.isPlayable,
              project.videoURL.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: project.videoURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return WorkshopLocalVideoPreview(id: item.id, title: project.projectTitle ?? item.title,
                                         fileURL: project.videoURL)
    }

    /// A completed Web project has a real HTML entry, without a video probe.
    func localWallpaperURL(for itemID: String) -> URL? {
        guard !deletingWallpaperIDs.contains(itemID),
              let item = downloadProgress.items.first(where: { $0.id == itemID }),
              item.state == .completed, let project = item.validatedProject else { return nil }
        switch project {
        case .video: return localPreview(for: itemID)?.fileURL
        case .web(let web):
            guard web.workshopID == itemID,
                  let root = try? WebProjectPaths.canonical(web.downloadRoot),
                  let descriptor = try? WebWallpaperProjectDescriptor(projectURL: web.projectJSONURL),
                  descriptor.root.path == root.path || descriptor.root.path.hasPrefix(root.path + "/"),
                  descriptor.entryURL == (try? WebProjectPaths.canonical(web.entryURL)) else { return nil }
            return descriptor.projectURL
        case .scene(let scene):
            // Completion already performed full texture/dependency inspection.
            // Do not decode every texture again while drawing each UI card;
            // the real import/apply boundary revalidates the complete subset.
            guard scene.workshopID == itemID,
                  let root = try? WebProjectPaths.canonical(scene.downloadRoot),
                  let projectURL = try? WebProjectPaths.canonical(scene.projectJSONURL),
                  projectURL.path.hasPrefix(root.path + "/"),
                  let entry = try? WebProjectPaths.canonical(scene.entryURL),
                  entry.path.hasPrefix(projectURL.deletingLastPathComponent().path + "/"),
                  (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? WebProjectPaths.readProject(projectURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["type"] as? String)?.lowercased() == "scene" else { return nil }
            return projectURL
        }
    }

    func hasLocalWallpaper(itemID: String) -> Bool { localWallpaperURL(for: itemID) != nil }

    func applyWallpaper(itemID: String, target: WorkshopWallpaperTarget) async -> WorkshopWallpaperApplyResult {
        guard !Task.isCancelled else { return .failed("已取消设置壁纸") }
        guard !isApplyingWallpaper else { return .failed("正在设置壁纸，请稍候") }
        guard let sourceURL = localWallpaperURL(for: itemID),
              let item = downloadProgress.items.first(where: { $0.id == itemID }),
              let metadata = item.metadata else {
            return .failed("请先完成壁纸下载与校验，再设为壁纸")
        }
        guard let onApplyWallpaper else { return .failed("设置壁纸暂不可用，请重新打开应用") }
        isApplyingWallpaper = true
        defer { isApplyingWallpaper = false }
        return await onApplyWallpaper(sourceURL, metadata, target)
    }

    func cancelOpeningWallpaperDetails() {
        detailsGeneration = UUID()
        detailsRequest?.cancel()
        detailsRequest = nil
        openingDetailsItemID = nil
    }

    @discardableResult
    func openWallpaperDetails(itemID: String) async -> String? {
        guard !Task.isCancelled else { return "已取消打开详情" }
        guard !isApplyingWallpaper, !isPreparingDynamicLockScreen else {
            return detailsFailure("正在处理壁纸应用操作，请完成后再打开详情")
        }
        guard !deletingWallpaperIDs.contains(itemID) else { return detailsFailure("这张壁纸正在删除，请稍候") }
        guard let sourceURL = localWallpaperURL(for: itemID),
              let metadata = downloadProgress.items.first(where: { $0.id == itemID })?.metadata else {
            return detailsFailure("请先完成壁纸下载与校验，再打开本地详情与设置")
        }
        guard let onOpenWallpaperDetails else { return detailsFailure("详情与设置当前不可用") }
        cancelOpeningWallpaperDetails()
        let ticket = detailsGeneration
        detailsImportRequests[itemID, default: []].insert(ticket)
        defer {
            detailsImportRequests[itemID]?.remove(ticket)
            if detailsImportRequests[itemID]?.isEmpty == true { detailsImportRequests.removeValue(forKey: itemID) }
        }
        openingDetailsItemID = itemID
        wallpaperDetailsError = nil
        let request = Task { @MainActor in await onOpenWallpaperDetails(sourceURL, metadata) }
        detailsRequest = request
        let error = await withTaskCancellationHandler {
            await request.value
        } onCancel: { request.cancel() }
        guard detailsGeneration == ticket else { return "已切换到另一张壁纸" }
        detailsRequest = nil
        openingDetailsItemID = nil
        guard !Task.isCancelled, !request.isCancelled else { return "已取消打开详情" }
        if let error { return detailsFailure(error) }
        return nil
    }

    private func detailsFailure(_ message: String) -> String {
        wallpaperDetailsError = message
        downloadBanner = "无法打开详情：\(message)"
        return message
    }

    func requestDynamicLockScreen(itemID: String) async -> String? {
        guard !Task.isCancelled else { return "已取消锁屏请求" }
        guard !isPreparingDynamicLockScreen else { return "锁屏正在处理，请稍候" }
        guard let preview = localPreview(for: itemID),
              let metadata = downloadProgress.items.first(where: { $0.id == itemID })?.metadata else {
            return "动态锁屏目前仅支持已完成下载的视频壁纸"
        }
        guard let onRequestDynamicLockScreen else { return "动态锁屏当前不可用" }
        resolvingDynamicLockScreen = true
        defer { resolvingDynamicLockScreen = false }
        return await onRequestDynamicLockScreen(preview.fileURL, metadata)
    }

    /// 真正删除由主 App 的管理目录/废纸篓边界执行；仅成功后移除记录。
    /// Library entries imported from an external Steam library may have no queue row.
    /// Carry an unqueued seed only through the same durable tombstone and drain transaction.
    func deleteLibraryWallpaper(itemID: String, title: String) async -> String? {
        if downloadProgress.items.contains(where: { $0.id == itemID }) {
            return await deleteDownloadedWallpaper(itemID: itemID)
        }
        guard WorkshopItemID(itemID) != nil else { return "作品 ID 无效" }
        let seed = WorkshopDownloadItem(publishedFileID: itemID, title: title,
                                        kind: .unknown, declaredTags: [])
        return await deleteDownloadedWallpaper(itemID: itemID, librarySeed: seed)
    }

    @discardableResult
    func deleteDownloadedWallpaper(itemID: String) async -> String? {
        await deleteDownloadedWallpaper(itemID: itemID, librarySeed: nil)
    }

    private func deleteDownloadedWallpaper(itemID: String, librarySeed: WorkshopDownloadItem?) async -> String? {
        guard !Task.isCancelled else { return "已取消删除" }
        guard !deletingWallpaperIDs.contains(itemID) else {
            downloadBanner = "正在删除，请稍候"
            return downloadBanner
        }
        guard let item = downloadProgress.items.first(where: { $0.id == itemID }) ?? librarySeed else {
            downloadBanner = "没有找到这项下载"
            return downloadBanner
        }
        if case .validating = item.state {
            downloadBanner = "正在校验下载，请完成或取消后再删除"
            return downloadBanner
        }
        guard !detailsImportItemIDs.contains(itemID) else {
            downloadBanner = "正在打开这张壁纸的详情，请稍候再删除"
            return downloadBanner
        }
        guard !importingItemIDs.contains(itemID) else {
            downloadBanner = "视频正在导入，请完成后再删除"
            return downloadBanner
        }
        guard !isApplyingWallpaper, !isPreparingDynamicLockScreen else {
            downloadBanner = "请先完成当前应用或锁屏准备操作"
            return downloadBanner
        }
        guard let onDeleteWallpaper else {
            downloadBanner = "删除下载当前不可用"
            return downloadBanner
        }
        deletingWallpaperIDs.insert(itemID)
        defer { deletingWallpaperIDs.remove(itemID) }
        if downloadProgress.activeItemID == itemID {
            switch item.state {
            case .downloading, .pausing:
                pauseRequestedIDs.remove(itemID)
                let active = downloadTask
                active?.cancel()
                downloadBanner = "正在停止下载并准备删除…"
                await active?.value
            default:
                downloadBanner = "下载写入仍在进行，未删除任何文件"
                return downloadBanner
            }
        }
        guard !Task.isCancelled else { return "已取消删除" }
        guard let drained = downloadProgress.items.first(where: { $0.id == itemID }) ?? librarySeed,
              downloadProgress.activeItemID != itemID else {
            downloadBanner = "下载尚未完全停止，未删除任何文件"
            return downloadBanner
        }
        if case .validating = drained.state {
            downloadBanner = "正在校验下载，请完成或取消后再删除"
            return downloadBanner
        }
        guard !detailsImportItemIDs.contains(itemID), !importingItemIDs.contains(itemID),
              !isApplyingWallpaper, !isPreparingDynamicLockScreen else {
            downloadBanner = "下载已停止，但相关导入、详情或壁纸操作仍在进行，请稍后再删除"
            return downloadBanner
        }
        // Commit the user's delete intent before touching managed files. If this
        // durable barrier fails, no external delete is attempted and a restart
        // cannot accidentally turn the stale queued record into a fresh download.
        deletedDownloadIDs.insert(itemID)
        await persistQueueAndWait()
        if let queuePersistenceError {
            deletedDownloadIDs.remove(itemID)
            downloadBanner = "未能保存删除意图，未删除任何文件：\(queuePersistenceError)"
            return downloadBanner
        }
        if let error = await onDeleteWallpaper(itemID) {
            deletedDownloadIDs.remove(itemID)
            await persistQueueAndWait()
            downloadBanner = "未能删除：\(error)"
            return error
        }
        downloadProgress.items.removeAll { $0.id == itemID }
        importedItemIDs.remove(itemID)
        await persistQueueAndWait()
        downloadBanner = deletionIsSimulated ? "隔离演示：已移入临时模拟废纸篓" : "已将下载的壁纸及相关管理副本移到废纸篓"
        return nil
    }

    func cancelActiveDownload() {
        if let id = downloadProgress.activeItemID { cancelDownload(itemID: id) }
        downloadBanner = "正在取消当前下载…"
    }

    func cancelDownload(itemID: String) {
        pauseRequestedIDs.remove(itemID)
        if let index = downloadProgress.items.firstIndex(where: { $0.publishedFileID == itemID }),
           !downloadProgress.items[index].state.isTerminal {
            markItemAction(itemID)
            downloadProgress.items[index].state = .cancelled
        }
        if downloadProgress.activeItemID == itemID {
            downloadTask?.cancel()
        }
        persistQueue()
    }

    func clearFinishedDownloads() {
        downloadProgress.items.removeAll { $0.state.isTerminal && $0.state.isSuccess && !deletingWallpaperIDs.contains($0.id) }
        persistQueue()
    }

    /// 关闭界面上的下载提示条。
    func dismissDownloadBanner() {
        downloadBanner = nil
    }

    func revealDownloadInFinder(itemID: String) {
        guard let item = downloadProgress.items.first(where: { $0.publishedFileID == itemID }),
              let directoryPath = item.validatedProject?.projectRoot.path ?? item.downloadDirectoryPath else { return }
        NSWorkspaceOpener.reveal(URL(fileURLWithPath: directoryPath))
    }

    /// Removes a terminal record for this session only; downloaded files remain on disk.
    /// A later disk reload can rediscover it. Library import state and downloaded files are unchanged;
    /// actual deletion uses the separate confirmed deleteDownloadedWallpaper transaction.
    func removeDownload(itemID: String) {
        guard !deletingWallpaperIDs.contains(itemID) else { return }
        guard let item = downloadProgress.items.first(where: { $0.publishedFileID == itemID }),
              item.state.isTerminal, downloadProgress.activeItemID != itemID else { return }
        downloadProgress.items.removeAll { $0.publishedFileID == itemID }
        persistQueue()
    }

    /// 串行下载：始终只跑一个 SteamCMD 下载任务（认证下载需要已登录的账号会话）。
    private func startNextDownloadIfIdle() {
        guard !isShuttingDown else { return }
        guard queueRestoreReady else { return }
        guard downloadTask == nil else { return }
        guard !isDownloadQueuePaused else { return }
        guard downloadProgress.items.contains(where: {
            $0.state == .queued && !deletingWallpaperIDs.contains($0.id)
        }) else { return }
        if let downloadPreflight {
            if let message = downloadPreflight() { downloadBanner = message; return }
        } else {
        guard !account.loginState.isActive else {
            downloadBanner = "正在恢复或验证 Steam 连接，连接完成后会继续队列。"
            return
        }
        guard account.isSignedIn else {
            downloadBanner = "请先连接 Steam；连接完成后会继续队列。"
            return
        }
        guard account.isNativeContentReady || account.isReady else {
            downloadBanner = "请先在登录弹窗准备兼容组件。"
            return
        }
        guard account.isNativeContentReady || account.canAttemptAuthenticatedDownload else {
            downloadBanner = "请先连接 Steam 账号。"
            return
        }
        }
        guard let index = downloadProgress.items.firstIndex(where: {
            $0.state == .queued && !deletingWallpaperIDs.contains($0.id)
        }) else { return }

        downloadProgress.items[index].attempts += 1
        let item = downloadProgress.items[index]
        downloadProgress.activeItemID = item.publishedFileID
        downloadProgress.items[index].state = .downloading(fraction: nil, text: "准备中")
        persistQueue()
        downloadBanner = nil

        let operation: WorkshopContentDownloadOperation
        if let contentDownloadOperation { operation = contentDownloadOperation }
        else if let downloadOperation {
            operation = { item, username, progress, log in .video(try await downloadOperation(item, username, progress, log)) }
        } else if account.isNativeContentReady, let broker = account.nativeContentBroker {
            let delivery = SteamContentProjectDelivery(layout: account.layout)
            operation = { [weak account] item, _, progress, log in
                guard let account else { throw SteamContentBrokerError.cancelled }
                return try await Self.downloadNativeContent(item: item, broker: broker, account: account,
                    delivery: delivery, progress: progress, logLine: log)
            }
        } else {
            let service = downloadServiceForCurrentExecutable()
            operation = { item, username, progress, log in
                try await service.download(item: item, username: username, progress: progress, logLine: log)
            }
        }
        let publishedFileID = item.publishedFileID
        let generation = UUID()
        activeDownloadGeneration = generation
        let progressBridge = DownloadProgressBridge(
            onState: { [weak self] state in
                self?.updateItemState(itemID: publishedFileID, generation: generation, state: state)
            },
            onLine: { [weak self] line in
                guard let self, self.activeDownloadGeneration == generation else { return }
                self.downloadProgress.appendStatus(line)
            }
        )
        downloadTask = Task { [weak self] in
            let result: Result<WorkshopResolvedProject, Error>
            do {
                let username = await MainActor.run { self?.account.transientAccountNameForDownload }
                let project = try await operation(item, username, progressBridge.progressHandler, progressBridge.logHandler)
                result = .success(project)
            } catch {
                result = .failure(error)
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.finishDownload(itemID: publishedFileID, generation: generation, result: result)
            }
        }
    }

    private func downloadServiceForCurrentExecutable() -> WorkshopDownloadService {
        if let downloadService { return downloadService }
        let created = WorkshopDownloadService(layout: account.layout, executable: account.executableURL)
        downloadService = created
        return created
    }

    private static func downloadNativeContent(item: WorkshopDownloadItem, broker: SteamContentBroker,
                                              account: SteamAccountManager,
                                              delivery: SteamContentProjectDelivery,
                                              progress: @escaping @Sendable (WorkshopDownloadState) -> Void,
                                              logLine: @escaping @Sendable (String) -> Void) async throws -> WorkshopResolvedProject {
        var presentation = SteamContentTransferPresentation()
        progress(.downloading(fraction: nil, text: "正在获取文件清单"))
        var activeBroker = broker
        var recoveredAuthentication = false
        do {
            let result: SteamContentDownloadResult
            while true {
                do {
                    result = try await activeBroker.download(publishedFileID: item.id) { measured in
                        progress(presentation.state(for: measured))
                    }
                    break
                } catch {
                    try Task.checkCancellation()
                    guard !recoveredAuthentication, SteamContentBroker.isAuthenticationLoss(error),
                          activeBroker.hasSavedSession else { throw error }
                    guard let restored = await account.recoverNativeContentSessionAfterAuthenticationLoss(from: activeBroker) else {
                        try Task.checkCancellation()
                        throw error
                    }
                    recoveredAuthentication = true
                    activeBroker = restored
                    progress(.downloading(fraction: nil, text: "Steam 连接已恢复，正在继续下载"))
                }
            }
            try Task.checkCancellation()
            guard result.validationRequired else { throw SteamContentBrokerError.protocolViolation }
            var usesUniversalSceneBackend = false
            #if GW_UNIVERSAL_SCENE_BACKEND
            usesUniversalSceneBackend = SceneBackendAvailability.isInstalled
            if usesUniversalSceneBackend {
                let project = try await WorkshopProjectResolver.resolve(workshopID: item.id,
                    directory: result.contentURL, declaredTags: item.declaredTags)
                if case .scene = project {
                    let hasAssets = await Task.detached { (try? SceneRuntimeAssetRegistry.loadRegisteredBundle()) != nil }.value
                    if !hasAssets {
                        progress(.validating("正在准备 Scene 公共资源"))
                        var assetsPresentation = SteamContentTransferPresentation()
                        let assets = try await activeBroker.sceneRuntimeAssets { measured in
                            progress(assetsPresentation.state(for: measured))
                        }
                        try Task.checkCancellation()
                        try await Task.detached { try SceneRuntimeAssetRegistry.registerVerifiedSteamBundle(assets) }.value
                    }
                }
            }
            #endif
            if !usesUniversalSceneBackend, let sceneProject = try await sceneProjectRequiringBuiltinAssets(contentURL: result.contentURL, item: item) {
                progress(.validating("正在准备 Scene 内置资源"))
                var enginePresentation = SteamContentTransferPresentation()
                let bundle = try await activeBroker.engineAssets(
                    desiredResources: SteamContentBroker.sceneEngineAssetResources
                ) { measured in
                    progress(enginePresentation.state(for: measured))
                }
                try Task.checkCancellation()
                try SceneEngineAssetResolver.registerVerifiedSteamBundle(bundle)
                try Task.checkCancellation()
                let retry = try SceneWallpaperInspector.inspectUsingAvailableEngineAssets(projectURL: sceneProject)
                guard retry.isRenderableSubset else {
                    throw WorkshopDownloadError.validationFailed(reason: "Scene 内置资源未能满足项目依赖")
                }
            }
            try Task.checkCancellation()
            progress(.validating("正在校验壁纸项目"))
            return try await delivery.deliver(contentURL: result.contentURL, item: item, progress: progress)
        } catch SteamContentBrokerError.cancelled {
            throw WorkshopDownloadError.cancelled
        } catch is CancellationError {
            throw WorkshopDownloadError.cancelled
        } catch {
            if let diagnostics = activeBroker.lastCDNDirectoryDiagnostics {
                logLine("Steam 下载节点：候选 \(diagnostics.total)，可用 \(diagnostics.accepted)")
                for group in diagnostics.groups {
                    logLine("节点分类 \(group.type)/\(group.httpsCapability)/\(group.rejection)：\(group.count)")
                }
            }
            throw error
        }
    }

    /// Returns a Scene project only when the ordinary resolver cannot deliver the
    /// download and its typed diagnostics contain nothing except missing resources
    /// from the fixed Wallpaper Engine builtin allowlist.
    static func sceneProjectRequiringBuiltinAssets(contentURL: URL,
                                                    item: WorkshopDownloadItem,
                                                    resolveProject: (String, URL, [String]) async throws -> WorkshopResolvedProject = {
                                                        try await WorkshopProjectResolver.resolve(
                                                            workshopID: $0, directory: $1, declaredTags: $2
                                                        )
                                                    },
                                                    inspectProject: (URL) throws -> SceneWallpaperInspection = {
                                                        try SceneWallpaperInspector.inspect(projectURL: $0)
                                                    },
                                                    resolveAvailableAssets: (URL) throws -> SceneEngineAssetResolver.Resolution = {
                                                        try SceneEngineAssetResolver.production.resolve(projectURL: $0)
                                                    }) async throws -> URL? {
        do {
            _ = try await resolveProject(item.id, contentURL, item.declaredTags)
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The resolver error is deliberately not used as an authorization signal.
        }

        for projectURL in WorkshopProjectResolver.findProjectJSONFiles(in: contentURL) {
            try Task.checkCancellation()
            guard let baseline = try? inspectProject(projectURL),
                  requiredSceneEngineResources(for: baseline) != nil else { continue }

            let available = try resolveAvailableAssets(projectURL)
            if available.inspection.isRenderableSubset { return nil }
            if available.engineAssets != nil,
               requiredSceneEngineResources(for: available.inspection) == nil {
                continue
            }
            return projectURL
        }
        return nil
    }

    /// A pure policy seam used by focused fixtures. Messages never grant download
    /// authority; only structured severity and exact normalized resource paths do.
    static func requiredSceneEngineResources(for inspection: SceneWallpaperInspection) -> Set<String>? {
        guard !inspection.isRenderableSubset, !inspection.diagnostics.isEmpty else { return nil }
        let allowed = Set(SteamContentBroker.sceneEngineAssetResources)
        var missing = Set<String>()
        for diagnostic in inspection.diagnostics {
            guard diagnostic.severity == .missing, allowed.contains(diagnostic.path) else { return nil }
            missing.insert(diagnostic.path)
        }
        return missing.isEmpty ? nil : missing
    }

    /// Quit closes the scheduling gate, drains the active transfer and its importer,
    /// then stops the owned native session. No queued work starts during teardown.
    func shutdownDownloads() async {
        isShuttingDown = true
        await queueLoadTask?.value
        await downloadedItemsReloadTask?.value
        if let id = downloadProgress.activeItemID,
           let index = downloadProgress.items.firstIndex(where: { $0.id == id }) {
            if downloadProgress.items[index].state != .cancelled {
                downloadProgress.items[index].state = pauseRequestedIDs.contains(id) ? .paused : .queued
            }
        }
        downloadTask?.cancel()
        let active = downloadTask
        await active?.value
        let pendingImports = Array(automaticImportTasks.values)
        for task in pendingImports { await task.value }
        await persistQueueAndWait()
        await account.shutdownNativeContent()
    }

    private func updateItemState(itemID: String, generation: UUID, state: WorkshopDownloadState) {
        guard let index = downloadProgress.items.firstIndex(where: { $0.publishedFileID == itemID }) else { return }
        guard activeDownloadGeneration == generation, downloadProgress.activeItemID == itemID,
              downloadProgress.items[index].state != .cancelled,
              downloadProgress.items[index].state != .pausing else { return }
        switch state {
        case .downloading(let fraction, let text):
            downloadProgress.items[index].progressFraction = fraction
            downloadProgress.items[index].progressText = text
        case .validating(let text):
            downloadProgress.items[index].progressText = text
        default:
            break
        }
        downloadProgress.items[index].state = state
        if case .validating = state { persistQueue() }
    }

    private func finishDownload(itemID: String, generation: UUID, result: Result<WorkshopResolvedProject, Error>) {
        guard activeDownloadGeneration == generation else { return }
        activeDownloadGeneration = nil
        let requestedPause = pauseRequestedIDs.remove(itemID) != nil
        downloadTask = nil
        downloadProgress.activeItemID = nil

        switch result {
        case .success(let project):
            if let index = downloadProgress.items.firstIndex(where: { $0.publishedFileID == itemID }) {
                downloadProgress.items[index].resolvedProject = project
                downloadProgress.items[index].project = project.videoProject
                downloadProgress.items[index].kind = project.kind
                downloadProgress.items[index].downloadDirectoryPath = project.projectRoot.path
                downloadProgress.items[index].state = .completed
                downloadProgress.items[index].completedAt = Date()
                downloadProgress.items[index].progressFraction = nil
                if let metadata = downloadProgress.items[index].metadata,
                   !deletingWallpaperIDs.contains(itemID) {
                    let importID = UUID()
                    automaticImportTasks[importID] = Task { [weak self] in
                        guard let self else { return }
                        await self.performImport(project: project, metadata: metadata)
                        self.automaticImportTasks.removeValue(forKey: importID)
                    }
                }
            }
        case .failure(let error):
            let wasCancelled = (error as? WorkshopDownloadError) == .cancelled || error is CancellationError
            let message = wasCancelled ? WorkshopDownloadError.cancelled.localizedDescription : Self.describe(error)
            if let index = downloadProgress.items.firstIndex(where: { $0.publishedFileID == itemID }) {
                if wasCancelled {
                    if isShuttingDown {
                        if downloadProgress.items[index].state != .cancelled {
                            downloadProgress.items[index].state = requestedPause ? .paused : .queued
                        }
                    } else {
                        downloadProgress.items[index].state = requestedPause ? .paused : .cancelled
                    }
                } else {
                    downloadProgress.items[index].state = .failed(message: message)
                    // 账号/凭据类失败：如实标记会话需要重新登录（不伪造）。
                    switch error {
                    case WorkshopDownloadError.sessionExpired,
                         WorkshopDownloadError.invalidCredentials,
                         WorkshopDownloadError.guardRequired:
                        account.markSessionExpired(reason: message)
                    default:
                        break
                    }
                }
            }
            if requestedPause, downloadProgress.items.first(where: { $0.id == itemID })?.state == .paused {
                downloadBanner = "下载已暂停；已有数据保留，继续时由 SteamCMD 重新校验并复用。"
            } else {
                downloadBanner = message
                if !wasCancelled { WorkshopLog.notice("工坊下载失败：\(message)") }
            }
        }
        persistQueue()
        startNextDownloadIfIdle()
    }

    private func performImport(project: WorkshopResolvedProject, metadata: WorkshopMetadata) async {
        let url = project.videoProject?.videoURL ?? project.projectJSONURL
        let handler: (@MainActor () async -> String?)?
        if let onImportProject { handler = { await onImportProject(project, metadata) } }
        else if let onImportVideo, project.videoProject != nil { handler = { await onImportVideo(url, metadata) } }
        else { handler = nil }
        guard let handler else {
            downloadBanner = "下载与校验已完成：\(PathRedaction.short(url))。素材导入当前未启用，可在下载目录中查看文件。"
            return
        }
        guard !deletingWallpaperIDs.contains(metadata.publishedFileID) else { return }
        importingItemIDs.insert(metadata.publishedFileID)
        defer { importingItemIDs.remove(metadata.publishedFileID) }
        let error = await handler()
        if let error {
            downloadBanner = "下载完成，但导入素材库失败：\(error)"
        } else {
            importedItemIDs.insert(metadata.publishedFileID)
            downloadBanner = "已下载并导入：\(metadata.title)"
        }
    }

    /// 恢复磁盘上已有的下载（重启后仍可用于导入）。
    func reloadDownloadedItems() async {
        if let downloadedItemsReloadTask {
            await downloadedItemsReloadTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performDownloadedItemsReconciliation()
        }
        downloadedItemsReloadTask = task
        await task.value
        downloadedItemsReloadTask = nil
    }

    /// Loads durable intent and freshly verifies managed downloads before the scheduler opens.
    /// Kept callable for isolated tests and non-UI startup hosts that do not prepare an account.
    func loadDownloadQueueIfNeeded() async {
        if let queueLoadTask {
            await queueLoadTask.value
            return
        }
        guard queueRestoreState == .notStarted else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performDownloadQueueLoad()
        }
        queueLoadTask = task
        await task.value
        queueLoadTask = nil
    }

    private func performDownloadQueueLoad() async {
        queueRestoreState = .loading
        let revisionAtStart = queueMutationRevision
        do {
            if let snapshot = try await queueStore.load() {
                let restoredDeletions = Set(snapshot.removedItemIDs)
                let restored = snapshot.items.map(Self.restoredItem)
                    .filter { !restoredDeletions.contains($0.id) }
                if !hasUnloadedQueueMutations && queueMutationRevision == revisionAtStart {
                    deletedDownloadIDs = restoredDeletions
                    isDownloadQueuePaused = snapshot.queuePaused
                    downloadProgress.items = restored
                } else {
                    // Explicit actions made while the file was loading win for
                    // those IDs; untouched durable tombstones remain effective.
                    deletedDownloadIDs.formUnion(restoredDeletions.subtracting(downloadProgress.items.map(\.id)))
                    var merged = restored
                    for current in downloadProgress.items {
                        if let index = merged.firstIndex(where: { $0.id == current.id }) { merged[index] = current }
                        else { merged.append(current) }
                    }
                    downloadProgress.items = merged
                    if !queuePauseChangedBeforeRestore { isDownloadQueuePaused = snapshot.queuePaused }
                }
            }
            queuePersistenceError = nil
        } catch {
            let message = Self.describe(error)
            queuePersistenceError = message
            queueRestoreState = .failed(message)
        }
        await reloadDownloadedItems()
        // A persisted completion is only real after a fresh disk verification.
        downloadProgress.items.removeAll { $0.state == .completed && $0.validatedProject == nil }
        queueRestoreReady = true
        hasUnloadedQueueMutations = false
        queuePauseChangedBeforeRestore = false
        if case .failed = queueRestoreState {} else { queueRestoreState = .ready }
        if queueRestoreState == .ready { await persistQueueAndWait() }
    }

    private func performDownloadedItemsReconciliation() async {
        let manager = FileManager.default
        let root = account.layout.downloadsURL
            .appendingPathComponent(String(WorkshopInputValidator.wallpaperEngineAppID), isDirectory: true)
        guard let directories = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        let service = downloadServiceForCurrentExecutable()
        for directory in directories {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let itemID = directory.lastPathComponent
            guard let id = WorkshopItemID(itemID) else { continue }
            guard !deletedDownloadIDs.contains(id.value) else { continue }
            let existingIndex = downloadProgress.items.firstIndex(where: { $0.publishedFileID == id.value })
            let existedBeforeVerification = existingIndex != nil
            let actionRevision = itemActionRevisions[id.value, default: 0]
            let seed = existingIndex.map { downloadProgress.items[$0] } ?? WorkshopDownloadItem(
                publishedFileID: id.value,
                title: "工坊作品 \(id.value)",
                kind: .video,
                declaredTags: [],
                previewImageURLString: nil,
                fileSizeBytes: nil
            )
            guard let verified = await service.verifyExisting(item: seed) else { continue }
            guard !deletedDownloadIDs.contains(id.value), !deletingWallpaperIDs.contains(id.value),
                  downloadProgress.activeItemID != id.value,
                  itemActionRevisions[id.value, default: 0] == actionRevision else { continue }
            if let currentIndex = downloadProgress.items.firstIndex(where: { $0.publishedFileID == id.value }) {
                // A user pause/cancel/retry while verification was suspended wins;
                // replacing at the freshly resolved index also preserves queue moves.
                guard downloadProgress.items[currentIndex].state == seed.state else { continue }
                downloadProgress.items[currentIndex] = verified
            } else if !existedBeforeVerification {
                downloadProgress.items.append(verified)
            }
        }
    }

    private static func restoredItem(_ record: WorkshopDownloadQueueRecord) -> WorkshopDownloadItem {
        var item = WorkshopDownloadItem(
            publishedFileID: record.publishedFileID,
            title: record.title,
            kind: WorkshopItemKind(rawValue: record.kind) ?? .unknown,
            declaredTags: record.declaredTags,
            previewImageURLString: record.previewImageURLString,
            fileSizeBytes: record.fileSizeBytes,
            attempts: record.attempts,
            queuedAt: record.queuedAt,
            completedAt: record.completedAt
        )
        switch record.state {
        case .queued, .downloading, .validating: item.state = .queued
        case .pausing, .paused: item.state = .paused
        case .completed: item.state = .completed
        case .failed(let message): item.state = .failed(message: message)
        case .cancelled: item.state = .cancelled
        }
        item.progressFraction = nil
        item.progressText = ""
        return item
    }

    private func queueSnapshot() -> WorkshopDownloadQueueSnapshot {
        WorkshopDownloadQueueSnapshot(queuePaused: isDownloadQueuePaused, items: downloadProgress.items.map { item in
            let state: WorkshopDownloadQueueRecord.State
            switch item.state {
            case .queued: state = .queued
            case .downloading: state = .downloading
            case .pausing: state = .pausing
            case .paused: state = .paused
            case .validating: state = .validating
            case .completed: state = .completed
            case .failed(let message): state = .failed(message)
            case .cancelled: state = .cancelled
            }
            return WorkshopDownloadQueueRecord(
                publishedFileID: item.id, title: item.title, kind: item.kind.rawValue,
                declaredTags: item.declaredTags, previewImageURLString: item.previewImageURLString,
                fileSizeBytes: item.fileSizeBytes, state: state, attempts: item.attempts,
                queuedAt: item.queuedAt, completedAt: item.completedAt
            )
        }, removedItemIDs: deletedDownloadIDs.sorted())
    }

    private func markItemAction(_ itemID: String) {
        itemActionRevisions[itemID, default: 0] &+= 1
    }

    private func persistQueue() {
        queueMutationRevision &+= 1
        if queueRestoreState == .notStarted { hasUnloadedQueueMutations = true }
        guard hasPrepared || queueRestoreState != .notStarted else { return }
        guard queueRestoreState != .loading else { return }
        let snapshot = queueSnapshot()
        let previous = queueWriteTask
        queueWriteTask = Task { [weak self, queueStore] in
            await previous?.value
            do {
                try await queueStore.save(snapshot)
                await MainActor.run { self?.queuePersistenceError = nil }
            } catch {
                let message = WorkshopCoordinator.describe(error)
                await MainActor.run {
                    self?.queuePersistenceError = message
                    self?.downloadBanner = "下载队列未能保存：\(message)"
                }
            }
        }
    }

    private func persistQueueAndWait() async {
        persistQueue()
        await queueWriteTask?.value
    }

    func flushDownloadQueuePersistence() async {
        await persistQueueAndWait()
    }

    // MARK: - 错误信息

    static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let message = localized.errorDescription, !message.isEmpty {
            return WorkshopLog.sanitize(message)
        }
        return WorkshopLog.sanitize(error.localizedDescription)
    }
}

/// 下载回调桥：把 actor 回调转成 Sendable 闭包，避免在 Sendable 闭包中捕获 non-Sendable 的 self。
@MainActor
private final class DownloadProgressBridge {
    private let onState: @MainActor @Sendable (WorkshopDownloadState) -> Void
    private let onLine: @MainActor @Sendable (String) -> Void

    init(
        onState: @escaping @MainActor @Sendable (WorkshopDownloadState) -> Void,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.onState = onState
        self.onLine = onLine
    }

    var progressHandler: @Sendable (WorkshopDownloadState) -> Void {
        let deliver = onState
        return { state in
            Task { @MainActor in
                deliver(state)
            }
        }
    }

    var logHandler: @Sendable (String) -> Void {
        let deliver = onLine
        return { line in
            Task { @MainActor in
                deliver(line)
            }
        }
    }
}

/// 打开外部链接/文件的小封装（便于集中审查）。
enum NSWorkspaceOpener {
    static func open(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    static func reveal(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }
}
