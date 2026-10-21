import AppKit
import SwiftUI

struct WorkshopSearchView: View {
    @Bindable var coordinator: WorkshopCoordinator
    let style: GlassStyle
    let onOpenAccount: () -> Void
    @Environment(\.workspaceContentTopInset) private var contentTopInset
    @Environment(\.workspaceWallpaperDetails) private var wallpaperDetails
    @GlassState private var searchStopped = false
    @GlassState private var toast: TransientToast?

    private var isDiscovery: Bool {
        coordinator.lastRequest.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    filterGroups
                    if !coordinator.recentSearches.isEmpty { recentSearches }
                    if isDiscovery && !coordinator.savedResults.isEmpty { savedShelf }
                    resultsHeader
                    if let error = coordinator.searchError, coordinator.results.isEmpty { errorBanner(error) }
                    resultsContent
                    if !coordinator.results.isEmpty { pagination }
                }
                .padding(.horizontal, WallpaperCardLayout.horizontalPadding)
                .padding(.top, WallpaperCardLayout.topPadding)
                .padding(.bottom, WallpaperCardLayout.bottomPadding)
                .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            searchBar.padding(.top, contentTopInset)
        }
        .background { WorkshopAtmosphere() }
        .task { coordinator.ensureDiscoveryLoaded() }
        .onChange(of: coordinator.searchError) { _, error in
            guard let error, !coordinator.results.isEmpty else { return }
            toast = TransientToast(
                "刷新失败：\(WorkshopDisplayMessage.redacted(error))",
                tone: .warning,
                symbol: "wifi.exclamationmark"
            )
        }
        .transientToast($toast)
    }

    private var searchBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                searchToolbar
                accountButton
            }
            VStack(alignment: .trailing, spacing: 10) {
                searchToolbar
                accountButton
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 2)
    }

    private var searchToolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    searchField
                    searchActions
                }
                VStack(alignment: .leading, spacing: 10) {
                    searchField
                    searchActions
                }
            }
        }
        .padding(12)
        .workshopNavigationSurface(cornerRadius: 24)
        .frame(maxWidth: .infinity)

    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索壁纸、风格或主题", text: $coordinator.searchText)
                .textFieldStyle(.plain)
                .onSubmit { startSearch(resetPage: true) }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    if !coordinator.isSearching { startSearch(resetPage: true) }
                    return .handled
                }
                .accessibilityLabel("搜索创意工坊壁纸")
            if !coordinator.searchText.isEmpty {
                Button {
                    coordinator.searchText = ""
                    startSearch(resetPage: true)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清空并返回发现")
                .accessibilityLabel("清空搜索并返回发现")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.primary.opacity(0.035), in: Capsule())
        .frame(minWidth: 240, maxWidth: .infinity)
    }

    private var searchActions: some View {
        HStack(spacing: 8) {
            if coordinator.isSearching {
                Button("取消") { stopSearch() }.buttonStyle(.borderless)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var accountButton: some View {
        Button(action: onOpenAccount) {
            WorkshopConnectionBadge(account: coordinator.account)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .workshopNavigationSurface(cornerRadius: 20, interactive: true)
        }
        .buttonStyle(.plain)
        .help("打开 Steam 登录")
        .accessibilityLabel("打开 Steam 登录")
    }

    private var filterGroups: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                WorkshopFilterLabel(title: "排序")
                sortPicker
                Spacer(minLength: 0)
            }
            WorkshopHorizontalFilterGroup(title: "类型") {
                WorkshopChoiceChip(title: "全部", selected: coordinator.filters.types.isEmpty, tint: .gray) {
                    updateFilters { $0.types = [] }
                }
                ForEach(WorkshopSearchType.selectableCases) { type in
                    WorkshopChoiceChip(title: type.title, selected: coordinator.filters.types.contains(type), tint: WorkshopChipPalette.type(type)) {
                        updateFilters { filters in
                            if filters.types.contains(type) { filters.types.remove(type) }
                            else { filters.types.insert(type) }
                            if filters.types.count == WorkshopSearchType.selectableCases.count {
                                filters.types = []
                            }
                        }
                    }
                }
            }
            if coordinator.sort == .trend {
                WorkshopHorizontalFilterGroup(title: "热榜时间") {
                    ForEach(WorkshopTrendPeriod.allCases) { period in
                        WorkshopChoiceChip(title: period.title, selected: coordinator.filters.trendPeriod == period, tint: .orange) {
                            searchStopped = false
                            coordinator.selectTrendPeriod(period)
                        }
                        .help(period.detail)
                    }
                }
            }
            WorkshopHorizontalFilterGroup(title: "主题") {
                WorkshopChoiceChip(title: "不限", selected: coordinator.filters.genre == nil) {
                    updateFilters { $0.genre = nil }
                }
                ForEach(WorkshopGenre.allCases) { genre in
                    WorkshopChoiceChip(title: genre.title, selected: coordinator.filters.genre == genre, tint: WorkshopChipPalette.genre(genre)) {
                        updateFilters { $0.genre = genre }
                    }
                }
            }
            WorkshopHorizontalFilterGroup(title: "分辨率") {
                WorkshopChoiceChip(title: "不限", selected: coordinator.filters.resolution == nil) {
                    updateFilters { $0.resolution = nil }
                }
                ForEach(WorkshopResolution.allCases) { resolution in
                    WorkshopChoiceChip(title: resolution.title, selected: coordinator.filters.resolution == resolution, tint: .cyan) {
                        updateFilters { $0.resolution = resolution }
                    }
                }
            }
            WorkshopHorizontalFilterGroup(title: "分级") {
                WorkshopChoiceChip(title: "不限", selected: coordinator.filters.ageRating == nil) {
                    updateFilters { $0.ageRating = nil }
                }
                ForEach(WorkshopAgeRating.allCases) { rating in
                    WorkshopChoiceChip(title: rating.title, selected: coordinator.filters.ageRating == rating, tint: WorkshopChipPalette.rating(rating)) {
                        updateFilters { $0.ageRating = rating }
                    }
                }
            }
        }
    }

    private func updateFilters(_ mutation: (inout WorkshopSearchFilters) -> Void) {
        var filters = coordinator.filters
        mutation(&filters)
        searchStopped = false
        coordinator.applyFilters(filters)
    }

    private var recentSearches: some View {
        HStack(alignment: .center, spacing: 10) {
            WorkshopFilterLabel(title: "最近搜索")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(coordinator.recentSearches, id: \.self) { query in
                        WorkshopHistoryChip(
                            query: query,
                            onReuse: { search(query) },
                            onRemove: { coordinator.removeRecentSearch(query) }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            Button("清除") { coordinator.clearSearchHistory() }
                .buttonStyle(.borderless).controlSize(.small).font(.caption).foregroundStyle(.secondary)
                .help("清除本机搜索历史")
        }
    }

    private var savedShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("稍后查看", systemImage: "bookmark").font(.headline)
                Text("\(coordinator.savedResults.count) 项").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .workshopGlassSurface(cornerRadius: 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(coordinator.savedResults) { result in
                        resultCard(result, location: "saved").frame(width: 260)
                    }
                }
                .padding(3)
            }
        }
    }

    private var resultsHeader: some View {
        resultsTitle
    }

    private var resultsTitle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(isDiscovery ? "精选" : "“\(coordinator.lastRequest.query)”")
                .font(.title3.weight(.semibold))
            if coordinator.isSearching, !coordinator.results.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 2)
    }

    private var sortPicker: some View {
        Picker("排序", selection: Binding(get: { coordinator.sort }, set: { value in
            searchStopped = false
            coordinator.selectSearchSort(value)
        })) {
            ForEach(WorkshopSearchSort.allCases) { entry in
                Label(entry.title, systemImage: entry.symbolName).tag(entry)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .buttonStyle(.borderless)
        .frame(width: 142)
    }

    @ViewBuilder private var resultsContent: some View {
        if !coordinator.results.isEmpty {
            LazyVGrid(columns: WallpaperCardLayout.columns, spacing: WallpaperCardLayout.spacing) {
                ForEach(coordinator.results) { result in resultCard(result) }
            }
        } else if coordinator.isSearching {
            ProgressView("搜索中…")
                .frame(maxWidth: .infinity, minHeight: 240)
        } else if coordinator.searchError == nil {
            ContentUnavailableView {
                Label(searchStopped ? "搜索已停止" : "没有找到作品", systemImage: searchStopped ? "pause.circle" : "magnifyingglass")
            } description: {
                Text("试试其他关键词")
            } actions: {
                Button("浏览热门作品") { search("") }.buttonStyle(.glass)
            }
            .frame(minHeight: 220)
        }
    }

    private func resultCard(_ result: WorkshopSearchResult, location: String = "results") -> some View {
        WorkshopResultCard(
            result: result,
            isSaved: coordinator.isSaved(result.id),
            downloadItem: coordinator.downloadProgress.items.first { $0.publishedFileID == result.id },
            onSelect: {
                wallpaperDetails?.prepareSource("workshop:\(result.id):\(location)")
                if coordinator.hasLocalWallpaper(itemID: result.id) {
                    Task { await coordinator.openWallpaperDetails(itemID: result.id) }
                } else {
                    coordinator.cancelOpeningWallpaperDetails()
                    wallpaperDetails?.open(result)
                }
            },
            onSave: { coordinator.toggleSaved(result) },
            onDownload: { coordinator.performDownloadAction(result) },
            onOpenSource: { coordinator.openSourcePage(for: result) },
            detailSourceKey: "workshop:\(result.id):\(location)"
        )
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("暂时无法获取作品").font(.callout.weight(.medium))
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button("重试") {
                searchStopped = false
                coordinator.retrySearch()
            }
                .buttonStyle(.glass).disabled(coordinator.isSearching)
        }
        .padding(16)
        .workshopGlassSurface(cornerRadius: 18, tint: .orange.opacity(0.07))
    }

    private var pagination: some View {
        HStack(spacing: 12) {
            Text("第 \(coordinator.lastRequest.page) 页 · 本页 \(coordinator.results.count) 项 · 共 \(WorkshopMetric.compact(coordinator.totalCount)) 项")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Button { coordinator.previousPage() } label: { Label("上一页", systemImage: "chevron.left") }
                .disabled(!coordinator.canGoToPreviousPage || coordinator.isSearching)
            Button { coordinator.nextPage() } label: { Label("下一页", systemImage: "chevron.right") }
                .disabled(!coordinator.canGoToNextPage || coordinator.isSearching)
        }
        .buttonStyle(.glass)
        .padding(12)
        .workshopGlassSurface(cornerRadius: 22)
    }

    private func startSearch(resetPage: Bool) {
        searchStopped = false
        coordinator.search(resetPage: resetPage)
    }

    private func stopSearch() {
        coordinator.cancelSearch()
        searchStopped = true
    }

    private func search(_ query: String) {
        coordinator.searchText = query
        startSearch(resetPage: true)
    }
}
