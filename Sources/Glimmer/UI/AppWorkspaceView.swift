import AppKit
import SwiftUI

private struct WorkspaceContentTopInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 10
}
extension EnvironmentValues {
    /// Align fixed content toolbars with the sidebar without shortening the
    /// right-column scroll viewport or the immersive detail background.
    var workspaceContentTopInset: CGFloat {
        get { self[WorkspaceContentTopInsetKey.self] }
        set { self[WorkspaceContentTopInsetKey.self] = newValue }
    }
}

private enum AppWorkspaceColumn: Hashable {
    case sidebar
    case detail
}

private struct AppWorkspaceColumnTopPreferenceKey: PreferenceKey {
    static let defaultValue: [AppWorkspaceColumn: CGFloat] = [:]

    static func reduce(value: inout [AppWorkspaceColumn: CGFloat], nextValue: () -> [AppWorkspaceColumn: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private enum AppWorkspaceLayout {
    static let firstSurfaceTopPadding: CGFloat = 10
}

/// 应用主导航目的地（单侧边栏）。
enum AppDestination: Hashable {
    case library(LibraryFilter)
    case workshop
    case downloads
    case playlist
    case settings

    var isLibrary: Bool {
        if case .library = self { return true }
        return false
    }
}

/// 主管理界面：一个侧边栏承载素材库、创意工坊、下载管理、播放列表与设置。
///
/// 布局约定（integration-contract）：
/// - 侧边栏只有这一处；点击封面后，详情在右侧完整内容区展开，关闭即回到保留的浏览树；
/// - 工坊、下载管理、播放列表、设置使用完整内容区，不再嵌套第二套导航；
/// - 空素材库给出「导入视频」「浏览创意工坊」两个直接入口。
struct AppWorkspaceView: View {
    let store: VideoLibraryStore
    let importService: ImportService
    let playback: DesktopPlaybackController
    let displays: DisplayRegistry
    let workshop: WorkshopCoordinator
    let policy: GWPolicyController
    let playlist: GWPlaylistRotator
    let settings: GWSettingsCoordinator
    let cleanup: GWStorageCleanupController
    let loginItem: GWLoginItemService

    /// 打开桌面预览窗口（不影响真实桌面）。
    let onOpenPreview: () -> Void

    var onOpenDynamicLockScreen: ((WallpaperItem) -> Void)? = nil
    var onOpenWallpaperDetails: ((WallpaperItem) -> Void)? = nil
    var initialDestination: AppDestination = .library(.all)
    var navigation: AppWorkspaceNavigation? = nil
    var wallpaperDetails: WorkspaceWallpaperDetails? = nil
    var avatarTransition: WorkshopCreatorAvatarTransition? = nil
    @GlassState private var internalWallpaperDetails = WorkspaceWallpaperDetails()
    private var detailPresentation: WorkspaceWallpaperDetails { wallpaperDetails ?? internalWallpaperDetails }
    @GlassState private var didSetInitialDestination = false
    @GlassState private var columnTopOrigins: [AppWorkspaceColumn: CGFloat] = [:]

    @GlassState private var destination: AppDestination = .library(.all)
    @GlassState private var searchText = ""
    @GlassState private var sort: LibrarySort = .recentlyAdded
    @GlassState private var sortAscending = false
    @GlassState private var selectedItemID: UUID?
    @GlassState private var errorMessage: String?
    @GlassState private var authorGallery: WorkshopAuthorGallerySession?
    @GlassState private var internalAvatarTransition = WorkshopCreatorAvatarTransition()
    private var creatorAvatarTransition: WorkshopCreatorAvatarTransition { avatarTransition ?? internalAvatarTransition }
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.windowGlassReduceMotionOverride) private var reviewReduceMotion
    @GlassState private var authorReturnItem: WallpaperItem?
    @GlassState private var authorReturnResult: WorkshopSearchResult?

    @MainActor
    init(store: VideoLibraryStore, importService: ImportService,
         playback: DesktopPlaybackController, displays: DisplayRegistry,
         workshop: WorkshopCoordinator, policy: GWPolicyController,
         playlist: GWPlaylistRotator, settings: GWSettingsCoordinator,
         cleanup: GWStorageCleanupController, loginItem: GWLoginItemService,
         onOpenPreview: @escaping () -> Void,
         onOpenDynamicLockScreen: ((WallpaperItem) -> Void)? = nil,
         onOpenWallpaperDetails: ((WallpaperItem) -> Void)? = nil,
         initialDestination: AppDestination = .library(.all),
         navigation: AppWorkspaceNavigation? = nil,
         wallpaperDetails: WorkspaceWallpaperDetails? = nil,
         avatarTransition: WorkshopCreatorAvatarTransition? = nil) {
        let internalDetails = WorkspaceWallpaperDetails()
        internalDetails.configureScenePreview(
            storage: store.storage, wallpaperFPS: settings.preferences.wallpaperFPS)
        wallpaperDetails?.configureScenePreview(
            storage: store.storage, wallpaperFPS: settings.preferences.wallpaperFPS)
        let localLookup: @MainActor (String) -> WallpaperItem? = { [weak store] id in
            store?.items.first { $0.workshopID == id && $0.fileExists }
        }
        internalDetails.localWallpaperLookup = localLookup
        wallpaperDetails?.localWallpaperLookup = localLookup
        self.store = store
        self.importService = importService
        self.playback = playback
        self.displays = displays
        self.workshop = workshop
        self.policy = policy
        self.playlist = playlist
        self.settings = settings
        self.cleanup = cleanup
        self.loginItem = loginItem
        self.onOpenPreview = onOpenPreview
        self.onOpenDynamicLockScreen = onOpenDynamicLockScreen
        self.onOpenWallpaperDetails = onOpenWallpaperDetails
        self.initialDestination = initialDestination
        self.navigation = navigation
        self.wallpaperDetails = wallpaperDetails
        self.avatarTransition = avatarTransition
        _internalWallpaperDetails = GlassState(wrappedValue: internalDetails)
    }

    private var currentFilter: LibraryFilter {
        if case .library(let filter) = destination { return filter }
        return .all
    }

    private var filterBinding: Binding<LibraryFilter> {
        Binding(
            get: { currentFilter },
            set: { destination = .library($0) }
        )
    }

    var body: some View {
        GeometryReader { windowContent in
            WorkspaceWallpaperDetailsHost(presentation: detailPresentation) {
                HStack(spacing: 0) {
                    alignedColumn(.sidebar) { sidebar }
                        .frame(width: 220)
                    alignedColumn(.detail) {
                        detailContent.frame(minWidth: 720, minHeight: 560)
                    }
                }
                // The retained browser keeps its original safe-area viewport.
                // Only the detail canvas extends under the native titlebar.
                .padding(.top, windowContent.safeAreaInsets.top)
                .padding(.bottom, windowContent.safeAreaInsets.bottom)
            } detail: { route in
                immersiveDetail(route)
            }
            .environment(\.wallpaperDetailChromeTopInset, windowContent.safeAreaInsets.top)
            .environment(\.workshopCreatorNavigation, { author in
                authorGallery?.cancel()
                let gallery = WorkshopAuthorGallerySession(author: author)
                gallery.load()
                authorReturnItem = detailPresentation.route?.item
                authorReturnResult = detailPresentation.route?.result
                creatorAvatarTransition.begin(authorID: author.id, reduceMotion: systemReduceMotion || reviewReduceMotion)
                authorGallery = gallery
                workshop.cancelOpeningWallpaperDetails()
                detailPresentation.dismissForCreatorNavigation()
            })
            .ignoresSafeArea(.container)
        }
        .modifier(WorkshopCreatorAvatarTransitionHost(transition: creatorAvatarTransition))
        .frame(minWidth: 1000, minHeight: 640)
        .containerBackground(.clear, for: .window)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .background {
            WallpaperWorkspaceBackdrop(playback: playback, displays: displays,
                brightness: settings.preferences.backgroundBrightness,
                blurAmount: settings.preferences.backgroundBlur)
        }
        .onPreferenceChange(AppWorkspaceColumnTopPreferenceKey.self) { origins in
            if origins != columnTopOrigins { columnTopOrigins = origins }
        }
        .onAppear {
            detailPresentation.configureScenePreview(
                storage: store.storage, wallpaperFPS: settings.preferences.wallpaperFPS)
            guard !didSetInitialDestination else { return }
            didSetInitialDestination = true
            destination = navigation?.route?.destination ?? initialDestination
        }
        .onChange(of: settings.preferences.wallpaperFPS) { _, wallpaperFPS in
            detailPresentation.configureScenePreview(
                storage: store.storage, wallpaperFPS: wallpaperFPS)
        }
        .onChange(of: detailPresentation.downloadedItemForCurrentResult?.id, initial: true) { _, id in
            if id != nil { detailPresentation.promoteDownloadedResult() }
        }
        .onChange(of: detailPresentation.closing) { _, closing in
            if closing { workshop.cancelOpeningWallpaperDetails() }
        }
        .onChange(of: destination) { _, _ in
            creatorAvatarTransition.cancel(); authorGallery?.cancel(); authorGallery = nil
            authorReturnItem = nil; authorReturnResult = nil
            if detailPresentation.route != nil { detailPresentation.dismiss() }
        }
        .onChange(of: navigation?.route) { _, route in
            if let route { destination = route.destination }
        }
        .onDisappear { authorGallery?.cancel() }
    }

    private func alignedColumn<Content: View>(
        _ column: AppWorkspaceColumn,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        GeometryReader { geometry in
            let originY = geometry.frame(in: .global).minY
            let targetY = columnTopOrigins.count == 2
                ? (columnTopOrigins.values.max() ?? originY) + AppWorkspaceLayout.firstSurfaceTopPadding
                : originY + AppWorkspaceLayout.firstSurfaceTopPadding

            let topInset = max(0, targetY - originY)
            content()
                .padding(.top, column == .sidebar ? topInset : 0)
                .environment(\.workspaceContentTopInset, topInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .preference(key: AppWorkspaceColumnTopPreferenceKey.self, value: [column: originY])
        }
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 14) {
                sidebarNavigation
                    .workshopNavigationSurface(cornerRadius: 24)
                if !playback.sessions.isEmpty {
                    sidebarFooter
                        .workshopNavigationSurface(cornerRadius: 22)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private var sidebarNavigation: some View {
        List(selection: $destination) {
            Section("素材库") {
                libraryRow(.all, title: "全部壁纸")
                libraryRow(.favorites, title: "收藏")
            }
            Section("来源") {
                libraryRow(.source(.local), title: "本地文件")
                libraryRow(.source(.steamWorkshop), title: "来自创意工坊")
            }
            Section("Steam 创意工坊") {
                navigationRow(.workshop, title: "发现壁纸", systemImage: "storefront")
                navigationRow(.downloads, title: "下载管理", systemImage: "arrow.down.circle")
            }
            Section("播放") {
                navigationRow(.playlist, title: "播放列表", systemImage: "rectangle.stack.badge.play")
            }
            Section("应用") {
                navigationRow(.settings, title: "设置", systemImage: "gearshape")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .padding(.vertical, 6)
    }

    private var sidebarFooter: some View {
        desktopSection
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func libraryRow(_ filter: LibraryFilter, title: String) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text("\(count(for: filter))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: filter.symbolName)
        }
        .tag(AppDestination.library(filter))
    }

    private func navigationRow(_ target: AppDestination, title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .tag(target)
    }

    @ViewBuilder
    private var desktopSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(playback.sessions.sorted { $0.key < $1.key }, id: \.key) { entry in
                let displayName = entry.value.display.localizedName
                // Read the observable saved intent: AVPlayer.rate is not an observed
                // property of this view and must not drive the button's next action.
                let isPaused = store.settings(for: entry.key).isPaused
                let actionName = isPaused ? "播放" : "暂停"
                HStack(spacing: 8) {
                    Text(displayName)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(displayName)
                    Spacer(minLength: 4)
                    Button {
                        playback.playPause(displayID: entry.key)
                    } label: {
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.borderless)
                    .background(.primary.opacity(0.055), in: Circle())
                    .help(playback.isPolicySuspended
                          ? "系统策略正在暂停播放；此按钮只将\(displayName)的保存意图设为\(actionName)，不会绕过策略。"
                          : "\(actionName)\(displayName)上的桌面壁纸")
                    .accessibilityLabel("\(actionName)\(displayName)上的桌面壁纸")
                    .accessibilityValue(playback.isPolicySuspended
                                        ? (isPaused ? "用户意图已暂停；系统策略暂停中" : "用户意图为播放；系统策略暂停中")
                                        : (isPaused ? "已暂停" : "正在播放"))
                    .accessibilityHint(playback.isPolicySuspended
                                       ? "只更改保存的播放意图，不会绕过系统策略"
                                       : "只控制这台显示器")
                    .accessibilityIdentifier("sidebar-display-play-pause-\(entry.key)")
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func count(for filter: LibraryFilter) -> Int {
        switch filter {
        case .all: return store.items.count
        case .favorites: return store.favoriteItems.count
        case .recent: return store.items.filter { $0.lastPlayedAt != nil }.count
        case .source(let source): return store.items.filter { $0.source == source }.count
        case .missing: return store.missingItemIDs.count
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private func immersiveDetail(_ route: WorkspaceWallpaperDetails.Route) -> some View {
        if let item = route.item {
            WallpaperDetailsWindowContent(
                store: store, selection: WallpaperDetailsSelection(itemID: item.id),
                displays: displays, playback: playback,
                onClose: { workshop.cancelOpeningWallpaperDetails(); detailPresentation.dismiss() },
                policy: policy, onOpenDynamicLockScreen: onOpenDynamicLockScreen,
                immersive: true, wallpaperFPS: settings.preferences.wallpaperFPS)
                .id(route.id)
        } else if let result = route.result {
            GlassStyleReader { style in
                WorkshopSearchResultDetail(result: result, coordinator: workshop, style: style,
                    onClose: { detailPresentation.dismiss() }, immersive: true)
            }
            .id(route.id)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let gallery = authorGallery {
            WorkshopAuthorGalleryView(session: gallery, coordinator: workshop, onBack: {
                creatorAvatarTransition.cancel(); gallery.cancel(); authorGallery = nil
                if let item = authorReturnItem { detailPresentation.open(item) }
                else if let result = authorReturnResult { detailPresentation.open(result) }
                authorReturnItem = nil; authorReturnResult = nil
            }).id(gallery.author.id)
        } else {
        switch destination {
        case .library:
            LibraryWorkspaceView(
                store: store,
                importService: importService,
                playback: playback,
                displays: displays,
                policyReasonText: policy.isPolicyBlockingPlayback ? policy.status.reasonListText : nil,
                filter: filterBinding,
                searchText: $searchText,
                sort: $sort,
                sortAscending: $sortAscending,
                selectedItemID: $selectedItemID,
                errorMessage: $errorMessage,
                onBrowseWorkshop: { destination = .workshop },
                onOpenDynamicLockScreen: onOpenDynamicLockScreen,
                onOpenWallpaperDetails: { item in
                    workshop.cancelOpeningWallpaperDetails()
                    detailPresentation.configureScenePreview(
                        storage: store.storage, wallpaperFPS: settings.preferences.wallpaperFPS)
                    detailPresentation.open(item)
                }
            )
        case .workshop:
            WorkshopView(coordinator: workshop)
        case .downloads:
            WorkshopAccountDownloadsPane(coordinator: workshop)
        case .playlist:
            PlaylistPane(
                store: store,
                playlist: playlist,
                policy: policy
            )
        case .settings:
            SettingsPane(
                store: store,
                playback: playback,
                workshop: workshop,
                policy: policy,
                playlist: playlist,
                settings: settings,
                cleanup: cleanup,
                loginItem: loginItem,
                onOpenPlaylist: { destination = .playlist }
            )
        }
        }
    }
}

// MARK: - 下载管理

/// 下载队列由侧栏直接进入；账号弹窗仍由下载工具栏统一触发。
struct WorkshopAccountDownloadsPane: View {
    @Bindable var coordinator: WorkshopCoordinator
    @GlassState private var showsAccountDialog = false

    var body: some View {
        GlassStyleReader { style in
            WorkshopDownloadsView(coordinator: coordinator, style: style,
                                  onOpenAccount: { showsAccountDialog = true })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)
        }
        .sheet(isPresented: $showsAccountDialog) {
            WorkshopAccountDialog(coordinator: coordinator)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { coordinator.prepareIfNeeded() }
    }
}

// MARK: - 播放列表

/// 播放列表路由：完整的轮播设置页。
struct PlaylistPane: View {
    @Environment(\.workspaceContentTopInset) private var contentTopInset
    let store: VideoLibraryStore
    let playlist: GWPlaylistRotator
    let policy: GWPolicyController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GWPlaylistSettingsView(
                    rotator: playlist,
                    titleProvider: { store.item(withID: $0)?.displayTitle ?? "已移除的素材" },
                    availableItemsProvider: { store.items.map { (id: $0.id, title: $0.displayTitle) } }
                )

                if policy.isPolicyBlockingPlayback {
                    Label("已因\(policy.status.reasonListText)暂停", systemImage: "pause.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, contentTopInset)
            .padding(.bottom, 18)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - 设置

/// 设置路由：实际设置界面（与「设置」场景共用同一实现与同一批控制器）。
struct SettingsPane: View {
    let store: VideoLibraryStore
    let playback: DesktopPlaybackController
    let workshop: WorkshopCoordinator
    let policy: GWPolicyController
    let playlist: GWPlaylistRotator
    let settings: GWSettingsCoordinator
    let cleanup: GWStorageCleanupController
    let loginItem: GWLoginItemService
    var onOpenPlaylist: (() -> Void)? = nil

    var body: some View {
        GWSettingsView(
            coordinator: settings,
            cleanup: cleanup,
            loginItem: loginItem,
            policy: policy,
            playlist: playlist,
            playlistTitleProvider: { store.item(withID: $0)?.displayTitle ?? "已移除的素材" },
            playlistItemsProvider: { store.items.map { (id: $0.id, title: $0.displayTitle) } },
            libraryInfoProvider: {
                AppSettingsWiring.libraryInfo(store: store, playback: playback)
            },
            onOpenPlaylist: onOpenPlaylist
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
