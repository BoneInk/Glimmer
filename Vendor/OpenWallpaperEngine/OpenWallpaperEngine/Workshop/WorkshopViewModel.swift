import Foundation
import SwiftUI
import Combine

/// The wallpaper whose Workshop presets the browser lists (WE's "Browsing presets for: <title>").
struct WorkshopPresetBase: Equatable {
    let id: String
    let title: String
}

class WorkshopViewModel: ObservableObject {
    @Published var items: [WorkshopItem] = []
    @Published var searchText = ""
    /// WE's "Exact phrase": the search is sent quoted, so Steam matches it as a phrase
    /// (`WorkshopSearchText`). Not saved, as in WE.
    @Published private(set) var exactPhrase = false
    @Published var authorId: String?
    /// Lists this wallpaper's presets instead of searching (WE's "Browse Presets").
    @Published private(set) var presetBase: WorkshopPresetBase?
    @Published var sortOrder: WorkshopSortOrder = .default
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentPage = 1
    @Published private(set) var filter = WorkshopFilter()
    @Published private(set) var hasNextPage = false
    @Published var selectedItemIds = Set<String>()
    @Published var isBatchDownloadConfirming = false
    private var selectedItems: [String: WorkshopItem] = [:]

    @Published private(set) var itemsPerPage = 21

    let steamCmd: SteamCmdService
    /// Wallpapers and authors hidden from the results (`WorkshopBlockList`).
    let blockList: WorkshopBlockList
    /// The cards' preview images, cached and decoded at card size for the Workshop and Discover tabs.
    let thumbnails = WorkshopThumbnailLoader()
    /// Brings the Workshop browser to the front: "Related Wallpapers" from another tab opens there.
    var showsBrowser: () -> Void = {}
    /// The menus' Set as Wallpaper and Set as Screen Saver (`attach(setAs:)`); nil until the app attaches it.
    private(set) var setAs: WorkshopSetAsFlow?
    private var setAsCancellable: AnyCancellable?
    private let api = WorkshopAPIService()
    /// Where Hide Anime is saved.
    private let defaults: UserDefaults
    static let hidesAnimeKey = "WorkshopHidesAnime"
    /// One QueryFiles page: search text, filter, sort, page, page size.
    typealias PageSearch = (String, WorkshopQuery, WorkshopSortOrder, Int, Int) async throws -> [WorkshopItem]
    private let searchPage: PageSearch
    /// Bumped by every search, so a search that a newer one overtook doesn't show its results.
    private var searchGeneration = 0
    private var cancellable: AnyCancellable?
    private var downloadedIndexCancellable: AnyCancellable?
    private var favoritesCancellable: AnyCancellable?
    private var blockListCancellable: AnyCancellable?
    private var cachedPages: [Int: [WorkshopItem]] = [:]
    /// QueryFiles result pages for the current search, so later pages and client-side filtering
    /// don't request the same source pages again.
    private var cachedSourcePages: [Int: [WorkshopItem]] = [:]
    private var cachedSearchKey = ""
    private var selectionAnchorId: String?

    /// How many QueryFiles pages one displayed page may read when results are filtered here
    /// (Show Only options Steam can't express): 2,000 items.
    static let maxSourcePages = 40

    init(steamCmd: SteamCmdService, blockList: WorkshopBlockList = WorkshopBlockList(), searchPage: PageSearch? = nil,
         defaults: UserDefaults = .app) {
        self.steamCmd = steamCmd
        self.blockList = blockList
        self.defaults = defaults
        let service = WorkshopAPIService()
        self.searchPage = searchPage ?? { text, query, sortOrder, page, perPage in
            try await service.searchItems(query: text, filter: query, sortOrder: sortOrder, page: page, perPage: perPage)
        }
        filter.hidesAnime = defaults.bool(forKey: Self.hidesAnimeKey)
        // Forward steamCmd changes (e.g. downloadProgress) to trigger view updates
        self.cancellable = steamCmd.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        self.downloadedIndexCancellable = DownloadedWallpaperIndex.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.cachedPages.removeAll()
                self?.objectWillChange.send()
            }
        }
        // "My Favourites" is checked on the results, so its pages go stale when favourites change.
        self.favoritesCancellable = FavoritesStore.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.filter.showOnly.contains(.favourites) else { return }
                self.cachedPages.removeAll()
            }
        }
        // Blocking or unblocking changes what the pages show; the source pages stay valid.
        self.blockListCancellable = blockList.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cachedPages.removeAll()
                self.items.removeAll(where: self.blockList.isBlocked)
                // Only a browser that has searched shows the change; it reads no new pages for it.
                guard !self.cachedSearchKey.isEmpty || self.authorId != nil else { return }
                Task { @MainActor in await self.search() }
            }
        }
    }

    /// Shows the current page for the current search text, sort and filter. Searches overlap
    /// (every filter click starts one); only the newest one shows its results or its error, and
    /// pages are cached only under the search they were read for.
    @MainActor
    func search() async {
        searchGeneration += 1
        let generation = searchGeneration
        isLoading = true
        errorMessage = nil
        if let authorId {
            let query = WorkshopQuery(filter)
            do {
                let results = try await api.getAuthorWorkshopItems(steamId: authorId)
                guard generation == searchGeneration else { return }
                // The author's items come unfiltered; the whole filter is checked here.
                items = results.filter { query.matchesAllTags($0, isFavorite: isFavorite) && !blockList.isBlocked($0) }
                preloadThumbnails(items)
            } catch {
                guard generation == searchGeneration else { return }
                errorMessage = error.localizedDescription
            }
            isLoading = false
            return
        }
        let searchKey = "\(steamSearchText)|\(sortOrder.rawValue)|\(filter.cacheKey)|\(itemsPerPage)|\(presetBase?.id ?? "")"

        if cachedSearchKey != searchKey {
            cachedPages.removeAll()
            cachedSourcePages.removeAll()
            cachedSearchKey = searchKey
        }

        let page = currentPage
        do {
            let results = try await pageItems(for: page, searchKey: searchKey)
            guard generation == searchGeneration else { return }
            items = results
            preloadThumbnails(results)
            await preloadAdjacentPages(for: page, searchKey: searchKey)
        } catch {
            guard generation == searchGeneration else { return }
            errorMessage = error.localizedDescription
        }

        guard generation == searchGeneration else { return }
        isLoading = false
    }

    func download(item: WorkshopItem) {
        steamCmd.downloadWorkshopItem(
            workshopId: item.id,
            title: item.title,
            previewURL: item.previewImageURL,
            creatorId: item.creatorId,
            subscriptions: item.subscriptions,
            fileSize: item.fileSize
        )
    }

    /// The cards redraw as the flow's runs move on.
    @MainActor
    func attach(setAs flow: WorkshopSetAsFlow) {
        setAs = flow
        setAsCancellable = flow.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func showAuthor(_ steamId: String) {
        authorId = steamId
        presetBase = nil
        searchText = ""
        currentPage = 1
        cachedPages.removeAll()
        showsBrowser()
        Task { @MainActor in await search() }
    }

    /// Lists the presets published for `base` (WE's "Browse Presets").
    func showPresets(of base: WorkshopPresetBase) {
        presetBase = base
        authorId = nil
        searchText = ""
        currentPage = 1
        cachedPages.removeAll()
        showsBrowser()
        Task { @MainActor in await search() }
    }

    func clearPresetFilter() {
        presetBase = nil
        currentPage = 1
        cachedPages.removeAll()
        Task { @MainActor in await search() }
    }

    /// The wallpaper whose presets "Browse Presets" lists for `item`, as WE offers it: a scene or
    /// web wallpaper's own, and for a preset its base's. Nil for other items.
    func presetBase(for item: WorkshopItem) -> WorkshopPresetBase? {
        if item.isPreset {
            guard let baseId = item.dependencyIds?.first else { return nil }
            return WorkshopPresetBase(id: baseId, title: WorkshopMetadataStore.shared.item(for: baseId)?.title ?? baseId)
        }
        let presetTypes = ["Scene", "Web"]
        guard item.tags.contains(where: { tag in presetTypes.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } })
        else { return nil }
        return WorkshopPresetBase(id: item.id, title: item.title)
    }

    /// The author's persona name when known, else their Steam id.
    func authorName(of steamId: String) -> String {
        SteamPlayerStore.shared.player(for: steamId)?.personaName ?? steamId
    }

    func clearAuthorFilter() {
        authorId = nil
        presetBase = nil
        currentPage = 1
        cachedPages.removeAll()
        Task { @MainActor in await search() }
    }

    func downloadSelectedItems() {
        for item in selectedItems.values {
            download(item: item)
        }
        clearSelection()
    }

    /// Downloads the item, then adds it to the given playlist once steamcmd finishes copying it into the library.
    func downloadAndAddToPlaylist(_ item: WorkshopItem, playlistID: UUID, wallpaperViewModel: WallpaperViewModel) {
        steamCmd.downloadWorkshopItem(
            workshopId: item.id,
            title: item.title,
            previewURL: item.previewImageURL,
            creatorId: item.creatorId,
            subscriptions: item.subscriptions,
            fileSize: item.fileSize
        ) { destination in
            guard let destination,
                  let project = OWELog.attempt(.workshop, "Add to playlist: project.json of \(destination.lastPathComponent)", {
                      try WEProject.read(in: destination)
                  }) else { return }
            // steamcmd invokes this completion off the main thread.
            DispatchQueue.main.async {
                wallpaperViewModel.addToPlaylist(WEWallpaper(using: project, where: destination), playlistID: playlistID)
            }
        }
    }

    func preview(item: WorkshopItem) {
        steamCmd.previewWorkshopItem(workshopId: item.id)
    }

    func downloadState(for item: WorkshopItem) -> SteamCmdService.DownloadState? {
        if isDownloaded(item) {
            return .completed
        }
        return steamCmd.downloadProgress[item.id]
    }

    var visibleItems: [WorkshopItem] {
        items
    }

    /// In the library as the user's own item. A dependency-only copy doesn't count, so the user can
    /// still download it to make it theirs.
    func isDownloaded(_ item: WorkshopItem) -> Bool {
        DownloadedWallpaperIndex.shared.contains(item.id) && !steamCmd.dependencyIndex.contains(item.id)
    }

    /// Key namespace for Workshop items (as opposed to local wallpapers) in `FavoritesStore`.
    func favoriteKey(for item: WorkshopItem) -> String { "workshop-\(item.id)" }

    func toggleFavorite(_ item: WorkshopItem) {
        FavoritesStore.shared.toggle(favoriteKey(for: item))
    }

    func isFavorite(_ item: WorkshopItem) -> Bool {
        FavoritesStore.shared.contains(favoriteKey(for: item))
    }

    func isPreviewLoading(_ item: WorkshopItem) -> Bool {
        steamCmd.previewProgress.contains(item.id)
    }

    /// Changes the filter and searches again from the first page.
    func updateFilter(_ change: (inout WorkshopFilter) -> Void) {
        var updated = filter
        change(&updated)
        guard updated != filter else { return }
        filter = updated
        currentPage = 1
        // The shown results no longer match: show the search in progress instead of them.
        items = []
        Task { @MainActor in await search() }
    }

    /// Back to the default filter, Hide Anime kept (WE applies it again on every reset).
    func resetFilters() {
        updateFilter { filter in
            let hidesAnime = filter.hidesAnime
            filter = WorkshopFilter()
            filter.hidesAnime = hidesAnime
        }
    }

    /// WE's Show Anime / Hide Anime, saved for the next launch.
    func setHidesAnime(_ hides: Bool) {
        defaults.set(hides, forKey: Self.hidesAnimeKey)
        updateFilter { $0.hidesAnime = hides }
    }

    /// Turns "Exact phrase" on or off and searches again from the first page.
    func setExactPhrase(_ isOn: Bool) {
        guard isOn != exactPhrase else { return }
        exactPhrase = isOn
        currentPage = 1
        guard !searchText.isEmpty else { return }
        items = []
        Task { @MainActor in await search() }
    }

    /// The search text QueryFiles gets: quoted for "Exact phrase".
    var steamSearchText: String {
        WorkshopSearchText.steamText(searchText, exactPhrase: exactPhrase)
    }

    @MainActor
    func updateItemsPerPage(for size: CGSize, itemSize: CGFloat) async {
        let spacing: CGFloat = 13
        let columns = max(1, Int((size.width + spacing) / (itemSize + spacing)))
        let rows = max(1, Int((size.height + spacing) / (itemSize + spacing)))
        let pageSize = columns * rows
        guard itemsPerPage != pageSize else { return }
        itemsPerPage = pageSize
        currentPage = 1
        cachedPages.removeAll()
        await search()
    }

    /// A click on a card (`ClickSelection`): a plain click selects it alone, ⌘ toggles it and ⇧
    /// selects the run from the anchor in `order`, the list the card is in (the Workshop grid's
    /// page by default, a Discover row or grid otherwise).
    func selectItem(_ item: WorkshopItem, in order: [WorkshopItem]? = nil,
                    kind: ClickSelection.Kind = ClickSelection.current) {
        let order = order ?? items
        var selected = selectedItemIds
        if !ClickSelection.apply(kind, on: item.id, in: order.map(\.id), selected: &selected, anchor: &selectionAnchorId) {
            selected = [item.id]
            selectionAnchorId = item.id
        }
        // Keep the items the selection names, for Download Selected; one selected in another
        // list stays as it was.
        var known = Dictionary(order.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        known[item.id] = item
        selectedItems = Dictionary(uniqueKeysWithValues: selected.compactMap { id in
            (known[id] ?? selectedItems[id]).map { (id, $0) }
        })
        selectedItemIds = selected
    }

    /// Edit › Select All: every card in `list` (the Workshop grid's page by default).
    func selectAll(_ list: [WorkshopItem]? = nil) {
        let list = list ?? items
        selectedItems = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        selectedItemIds = Set(selectedItems.keys)
        selectionAnchorId = list.first?.id
    }

    func clearSelection() {
        selectedItemIds.removeAll()
        selectedItems.removeAll()
        selectionAnchorId = nil
    }

    @MainActor
    private func pageItems(for page: Int, searchKey: String) async throws -> [WorkshopItem] {
        if let cachedItems = cachedPages[page] {
            return cachedItems
        }

        let results = try await displayedPageItems(for: page, searchKey: searchKey)
        if cachedSearchKey == searchKey {
            cachedPages[page] = results
        }
        return results
    }

    /// Displayed page `displayedPage`: QueryFiles pages are read in order and what passes the
    /// client-side Show Only check is counted, so a displayed page starts where the previous one
    /// ended whatever was filtered out.
    @MainActor
    private func displayedPageItems(for displayedPage: Int, searchKey: String) async throws -> [WorkshopItem] {
        let sourcePageSize = 50
        let query = browseQuery
        let text = steamSearchText
        let sortOrder = sortOrder
        let itemsPerPage = itemsPerPage
        var sourcePage = 1
        var skippedItems = (displayedPage - 1) * itemsPerPage
        var visibleItems: [WorkshopItem] = []

        while visibleItems.count < itemsPerPage, sourcePage <= Self.maxSourcePages {
            let sourceItems = try await sourceItems(page: sourcePage, pageSize: sourcePageSize, text: text,
                                                    sortOrder: sortOrder, query: query, searchKey: searchKey)
            guard !sourceItems.isEmpty else { break }

            for item in sourceItems where query.matches(item, isFavorite: isFavorite) && !blockList.isBlocked(item) {
                if skippedItems > 0 {
                    skippedItems -= 1
                } else {
                    visibleItems.append(item)
                    if visibleItems.count == itemsPerPage {
                        break
                    }
                }
            }

            guard sourceItems.count == sourcePageSize else { break }
            sourcePage += 1
        }

        return visibleItems
    }

    /// The filter's query, narrowed to `presetBase`'s presets when the browser lists them.
    var browseQuery: WorkshopQuery {
        var query = WorkshopQuery(filter)
        if let presetBase {
            query.childOf = presetBase.id
            if !query.excludedTags.contains("Wallpaper") { query.excludedTags.append("Wallpaper") }
        }
        return query
    }

    @MainActor
    private func sourceItems(page: Int, pageSize: Int, text: String, sortOrder: WorkshopSortOrder,
                             query: WorkshopQuery, searchKey: String) async throws -> [WorkshopItem] {
        if cachedSearchKey == searchKey, let cached = cachedSourcePages[page] { return cached }
        let items = try await searchPage(text, query, sortOrder, page, pageSize)
        if cachedSearchKey == searchKey {
            cachedSourcePages[page] = items
        }
        return items
    }

    @MainActor
    private func preloadAdjacentPages(for page: Int, searchKey: String) async {
        let adjacentPages = [page - 1, page + 1].filter { $0 > 0 }
        for adjacentPage in adjacentPages {
            do {
                let adjacentItems = try await pageItems(for: adjacentPage, searchKey: searchKey)
                guard cachedSearchKey == searchKey, currentPage == page else { return }
                preloadThumbnails(adjacentItems)
                if adjacentPage == page + 1 {
                    // A short last page is still a page.
                    hasNextPage = !adjacentItems.isEmpty
                }
            } catch {
                guard cachedSearchKey == searchKey, currentPage == page else { return }
                if adjacentPage == page + 1 {
                    hasNextPage = false
                }
            }
        }
    }

    private func preloadThumbnails(_ items: [WorkshopItem]) {
        for item in items {
            guard let url = item.previewImageURL else { continue }
            URLSession.shared.dataTask(with: url).resume()
        }
    }
}
