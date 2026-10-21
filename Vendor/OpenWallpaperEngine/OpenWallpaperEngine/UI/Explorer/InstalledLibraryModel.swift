import AppKit
import Combine
import Observation

/// The Installed tab's list: the library's wallpapers, searched, filtered (`filters`) and sorted,
/// in pages, with the selection; its folders (`folders`, the one open in `currentFolderID`); and
/// deleting wallpapers from it.
@MainActor @Observable
final class InstalledLibraryModel {
    var sortingBy: WEWallpaperSortingMethod = InstalledLibraryModel.stored(Keys.sortingBy, default: .name) {
        didSet {
            UserDefaults.app.set(sortingBy.rawValue, forKey: Keys.sortingBy)
            invalidateSortedMemo()
        }
    }
    var sortingSequence: WEWallpaperSortingSequence = InstalledLibraryModel.stored(Keys.sortingSequence, default: .increase) {
        didSet {
            UserDefaults.app.set(sortingSequence.rawValue, forKey: Keys.sortingSequence)
            invalidateSortedMemo()
        }
    }

    var searchText = "" {
        didSet { invalidateSortedMemo() }
    }

    /// The Installed folders, saved in the settings.
    let folders: InstalledFolderStore

    /// The folder the grid shows; nil is the top level (WE's Home). The search and filters
    /// apply within it (`InstalledFolderScope`).
    var currentFolderID: UUID? {
        didSet {
            guard currentFolderID != oldValue else { return }
            clearSelection()
            invalidateSortedMemo()
        }
    }

    var selectedWallpapers = Set<URL>()
    @ObservationIgnored private var selectionAnchor: URL?

    /// Bumped when the library changed on disk, so the list's readers redraw.
    private var revision = 0

    private let filters: FilterResultsViewModel
    private let steamCmd: SteamCmdService
    private let presentation: ContentPresentation

    /// Re-reads only the wallpapers that changed on disk.
    private let library: InstalledLibraryCache = {
        let cache = InstalledLibraryCache()
        // Downloads and imports are prepared in the background for a warm first show.
        cache.onArrival = { LibraryPreparationScheduler.shared.prepare($0) }
        return cache
    }()
    /// `sortedWallpapers` for the current update: the Installed tab reads it many times per redraw
    /// (grid, selection). Cleared whenever the search, filters or sorting
    /// change, when favourites or stored preferences change, when the library changes, and after
    /// the current main-queue turn, so a redraw never sees stale data. Main thread only, like every
    /// reader of the list.
    @ObservationIgnored private var sortedMemo: [WEWallpaper]?
    @ObservationIgnored private var memoCancellables: [AnyCancellable] = []

    /// Reads the Steam tags of installed wallpapers whose project.json has too few.
    private let tagSync = InstalledWorkshopTagSync()

    /// The `UserDefaults.app` keys, as `@AppStorage` stored them.
    private enum Keys {
        static let sortingBy = "SortingBy"
        static let sortingSequence = "SortingSequence"
    }

    init(filters: FilterResultsViewModel, steamCmd: SteamCmdService, presentation: ContentPresentation,
         folders: InstalledFolderStore? = nil) {
        self.filters = filters
        self.steamCmd = steamCmd
        self.presentation = presentation
        let folders = folders ?? InstalledFolderStore()
        self.folders = folders
        filters.onChange = { [weak self] in self?.invalidateSortedMemo() }
        folders.onChange = { [weak self] in self?.invalidateSortedMemo() }
        memoCancellables = [
            FavoritesStore.shared.objectWillChange.sink { [weak self] _ in self?.invalidateSortedMemo() },
            // Steam tags arriving for installed wallpapers: the grid, Details and filters use them.
            DownloadedWallpaperIndex.shared.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            },
            // Other preferences (the library folders) change what the list holds.
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .sink { [weak self] _ in self?.invalidateSortedMemo() },
        ]
    }

    /// The stored value, as `@AppStorage` reads a raw-representable one.
    nonisolated private static func stored<Value: RawRepresentable>(_ key: String, default value: Value) -> Value {
        (UserDefaults.app.object(forKey: key) as? Value.RawValue).flatMap(Value.init(rawValue:)) ?? value
    }

    /// Changes can be announced on any thread; the memo is main-thread state.
    private nonisolated func invalidateSortedMemo() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { sortedMemo = nil }
        } else {
            DispatchQueue.main.async { [weak self] in self?.sortedMemo = nil }
        }
    }

    /// The library changed on disk: the next read lists and sorts it again.
    func refresh() {
        sortedMemo = nil
        revision &+= 1
    }

    /// The Installed wallpapers, before search and filters: the storage folder's and the library
    /// folders', without asset items or dependency-only items.
    var allWallpapers: [WEWallpaper] {
        _ = revision
        let wallpapers = library.wallpapers(in: FileManager.default.wallpapersDirectory,
                                            libraryFolders: LibraryFolders().folders,
                                            hiding: steamCmd.dependencyIndex.ids)
        tagSync.schedule(wallpapers)
        return wallpapers
    }

    /// The wallpaper's tags to show and filter by: project.json's, then the Workshop item's
    /// stored ones, without "Wallpaper".
    func tags(of wallpaper: WEWallpaper) -> [String] {
        _ = revision
        return InstalledWorkshopTags.tags(of: wallpaper, in: .shared)
    }

    /// A wallpaper was deleted: drops it from the library index and removes its loading snapshots
    /// and the repaired copies of its videos.
    func forgetDeletedWallpaper(at directory: URL) {
        DownloadedWallpaperIndex.shared.remove(directory: directory)
        let store = SceneLoadingSnapshotStore.current
        let repaired = RepairedVideoCache.current
        Task.detached(priority: .utility) {
            store.removeSnapshots(forWallpaperAt: directory)
            repaired.removeCopies(forSourcesIn: directory)
        }
    }

    /// Deletes the wallpapers' folders, or moves them to the Trash, off the main thread. Then each
    /// one that is gone is forgotten, every one leaves the screens showing it, and a failure is
    /// shown in an alert.
    func deleteWallpapers(at directories: [URL], toTrash: Bool, wallpaperViewModel: WallpaperViewModel) {
        Task { @MainActor in
            if let failure = await deleteWallpapersNow(at: directories, toTrash: toTrash, wallpaperViewModel: wallpaperViewModel) {
                presentation.deletionAlertError = failure
                presentation.deletionAlertPresented = true
            }
        }
    }

    /// `deleteWallpapers`' steps, awaited: returns the failure instead of showing it (the MCP
    /// `wallpaper_delete` tool answers with it).
    func deleteWallpapersNow(at directories: [URL], toTrash: Bool,
                             wallpaperViewModel: WallpaperViewModel) async -> WallpaperDeletion.Failure? {
        let libraries = [FileManager.default.wallpapersDirectory] + LibraryFolders().folders
        let result: (deleted: [URL], failure: WallpaperDeletion.Failure?) = await Task.detached(priority: .userInitiated) {
            WallpaperDeletion.delete(directories, toTrash: toTrash, libraries: libraries)
        }.value
        for directory in result.deleted { forgetDeletedWallpaper(at: directory) }
        for directory in directories { wallpaperViewModel.removeWallpaperFromAllScreens(directory: directory) }
        removeUnusedWorkshopDependencies()
        return result.failure
    }

    /// After wallpapers were deleted: removes the dependency-only items none of the remaining ones use.
    func removeUnusedWorkshopDependencies() {
        let library = FileManager.default.wallpapersDirectory
        let index = steamCmd.dependencyIndex
        Task.detached(priority: .utility) {
            let removed = WorkshopDependencyCleanup.removeOrphans(in: library, index: index)
            guard !removed.isEmpty else { return }
            await MainActor.run {
                for id in removed {
                    DownloadedWallpaperIndex.shared.remove(directory: library.appending(path: id))
                }
            }
        }
    }

    /// Whether `wallpaper` matches the search `query` (non-empty): its title, type, description,
    /// tags, Workshop id or folder name contains it, ignoring case and diacritics as Finder does.
    nonisolated static func matchesSearch(_ query: String, wallpaper: WEWallpaper, tags: [String]) -> Bool {
        let project = wallpaper.project
        return project.title.localizedStandardContains(query)
            || project.type.localizedStandardContains(query)
            || project.description?.localizedStandardContains(query) == true
            || tags.contains { $0.localizedStandardContains(query) }
            || project.workshopid?.rawValue.contains(query) == true
            || wallpaper.wallpaperDirectory.lastPathComponent.localizedStandardContains(query)
    }

    private var filteredWallpapers: [WEWallpaper] {
        let filters = self.filters
        let resolutionGroups: [[String]] = [
            InstalledTagFilter.checked(filters.widescreenResolution), InstalledTagFilter.checked(filters.ultraWidescreenResolution),
            InstalledTagFilter.checked(filters.dualscreenResolution), InstalledTagFilter.checked(filters.triplescreenResolution),
            InstalledTagFilter.checked(filters.potraitscreenResolution), InstalledTagFilter.checked(filters.miscResolution),
        ]
        let resolutions = Set<String>(resolutionGroups.joined())
        let query = searchText
        let checkedShowOnly = filters.showOnly, checkedType = filters.type, checkedCategory = filters.category
        let checkedAgeRating = filters.ageRating, checkedTags = filters.tag
        return scopedWallpapers.filter { wallpaper in
            let wallpaperTags = self.tags(of: wallpaper)
            guard query.isEmpty || Self.matchesSearch(query, wallpaper: wallpaper, tags: wallpaperTags) else { return false }

            // Show Only
            var showOnly = FRShowOnly.none
            if wallpaper.project.approved == true
                || wallpaperTags.contains(where: { $0.caseInsensitiveCompare(WorkshopTags.approved) == .orderedSame }) {
                showOnly.insert(.approved)
            }
            if FavoritesStore.shared.contains(wallpaper) { showOnly.insert(.myFavourites) }
            if wallpaper.isMobileCompatible { showOnly.insert(.mobileCompatible) }
            if wallpaper.isAudioResponsive { showOnly.insert(.audioResponsive) }
            if library.hasCustomizableProperties(wallpaper) { showOnly.insert(.customizable) }
            guard checkedShowOnly.isEmpty || !checkedShowOnly.intersection(showOnly).isEmpty else { return false }

            // Type
            var type = FRType.none
            switch wallpaper.project.type.lowercased() {
            case "video":
                type = .video
            case "scene":
                type = .scene
            case "web":
                type = .web
            case "application":
                type = .application
            default:
                break
            }
            guard checkedType.contains(type) else { return false }
            guard checkedCategory.contains(FRCategory.of(wallpaper)) else { return false }

            guard checkedAgeRating.contains(Self.ageRating(of: wallpaper, tags: wallpaperTags)) else { return false }

            guard InstalledTagFilter.matchesResolutions(wallpaperTags, checked: resolutions) else { return false }
            guard InstalledTagFilter.matchesGenres(wallpaperTags, checked: checkedTags) else { return false }

            // Finish Filtering
            return true
        }
    }

    /// A wallpaper's rating for the Installed filter: project.json's, else the Workshop tags'. A
    /// wallpaper made before WE had ratings has neither and is Everyone, as the Details panel
    /// shows it; rated "none" it matched no checkbox and never showed.
    nonisolated static func ageRating(of wallpaper: WEWallpaper, tags: [String]) -> FRAgeRating {
        switch wallpaper.project.contentrating ?? InstalledWorkshopTags.contentRating(in: tags) ?? "Everyone" {
        case "Everyone": return .everyone
        case "Questionable": return .partialNudity
        case "Mature": return .mature
        default: return .none
        }
    }

    private var sortedWallpapers: [WEWallpaper] {
        // Read every input first, so a view answered from the memo still observes them.
        _ = (revision, searchText, sortingBy, sortingSequence, currentFolderID, folders.tree)
        filters.observeAll()
        if let sortedMemo { return sortedMemo }
        let sorted = computeSortedWallpapers()
        sortedMemo = sorted
        DispatchQueue.main.async { [weak self] in self?.sortedMemo = nil }
        return sorted
    }

    private func computeSortedWallpapers() -> [WEWallpaper] {
        let sortingBy = self.sortingBy, sortingSequence = self.sortingSequence
        let wallpapers = filteredWallpapers
        // WE's Favorite and Last Updated sorts: a key per wallpaper, read once, then the title.
        let keys: [URL: Int]
        switch sortingBy {
        case .favorite:
            keys = Dictionary(wallpapers.map { ($0.wallpaperDirectory, FavoritesStore.shared.contains($0) ? 1 : 0) },
                              uniquingKeysWith: { first, _ in first })
        case .lastUpdated:
            keys = Dictionary(wallpapers.map { ($0.wallpaperDirectory, Self.lastUpdated(of: $0)) },
                              uniquingKeysWith: { first, _ in first })
        case .name, .rating, .fileSize, .dateAdded:
            keys = [:]
        }
        return wallpapers.sorted {
            switch sortingBy {
            case .favorite, .lastUpdated:
                return Self.precedes((keys[$0.wallpaperDirectory] ?? 0, $0.project.title),
                                     (keys[$1.wallpaperDirectory] ?? 0, $1.project.title), in: sortingSequence)
            case .name:
                return Self.precedes($0.project.title, $1.project.title, in: sortingSequence)
            case .rating:
                return Self.precedes(Self.ratingRank($0.project.contentrating),
                                     Self.ratingRank($1.project.contentrating), in: sortingSequence)
            case .fileSize:
                return Self.precedes(library.size(of: $0), library.size(of: $1), in: sortingSequence)
            case .dateAdded:
                let firstDate = DownloadedWallpaperIndex.shared.dateAdded(for: $0.wallpaperDirectory)
                let secondDate = DownloadedWallpaperIndex.shared.dateAdded(for: $1.wallpaperDirectory)
                if sortingSequence == .increase {
                    return firstDate < secondDate
                }
                return firstDate > secondDate
            }
        }
    }

    /// WE's order for its Favorite and Last Updated sorts: the larger key first (`.increase`, WE's
    /// ascending) or last, and equal keys by title, A to Z in WE's ascending.
    nonisolated static func precedes(_ lhs: (key: Int, title: String), _ rhs: (key: Int, title: String),
                                     in sequence: WEWallpaperSortingSequence) -> Bool {
        if lhs.key != rhs.key { return precedes(lhs.key, rhs.key, in: sequence) }
        let order = lhs.title.localizedStandardCompare(rhs.title)
        return sequence == .increase ? order == .orderedAscending : order == .orderedDescending
    }

    /// WE's `updatedate` of an installed wallpaper, in Unix seconds: Steam's `time_updated` of its
    /// Workshop item when known (from browsing or from reading its tags), else when its folder last
    /// changed (a Workshop download is rewritten on each update). 0 for a local wallpaper, which
    /// has none and sorts after the others, as in WE.
    nonisolated static func lastUpdated(of wallpaper: WEWallpaper,
                                        known: (String) -> Int? = InstalledLibraryModel.knownTimeUpdated) -> Int {
        guard let workshopId = InstalledWorkshopTags.workshopId(of: wallpaper) else { return 0 }
        if let time = known(workshopId) { return time }
        // A folder without a readable date counts as never updated.
        let modified = try? wallpaper.wallpaperDirectory.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        return modified.map { Int($0.timeIntervalSince1970) } ?? 0
    }

    /// Steam's `time_updated` of a Workshop item the app has read.
    nonisolated static func knownTimeUpdated(_ workshopId: String) -> Int? {
        WorkshopMetadataStore.shared.item(for: workshopId)?.timeUpdated
            ?? DownloadedWallpaperIndex.shared.workshopTags(for: workshopId)?.timeUpdated
    }

    /// The content rating's place in the Rating sort: Everyone, then Questionable (partial
    /// nudity), then Mature; no or an unknown rating comes before all of them.
    nonisolated static func ratingRank(_ contentRating: String?) -> Int {
        switch contentRating?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "everyone": return 1
        case "questionable": return 2
        case "mature": return 3
        default: return 0
        }
    }

    /// Whether `lhs` sorts before `rhs` for the title, rating and file size orders: `.increase` puts
    /// the larger value first and `.decrease` the smaller, as the library has always ordered them.
    nonisolated static func precedes<Value: Comparable>(_ lhs: Value, _ rhs: Value,
                                                        in sequence: WEWallpaperSortingSequence) -> Bool {
        switch sequence {
        case .increase: return lhs > rhs
        case .decrease: return lhs < rhs
        }
    }

    /// The Installed list as the grid shows it: filtered by the filters and the search, and
    /// sorted. The grid scrolls through all of it (lazily), so there are no pages.
    var autoRefreshWallpapers: [WEWallpaper] {
        sortedWallpapers
    }

    var displayedWallpapers: [WEWallpaper] {
        sortedWallpapers
    }

    func toggleSelection(for wallpaper: WEWallpaper) {
        ClickSelection.apply(.toggle, on: wallpaper.wallpaperDirectory, in: [],
                             selected: &selectedWallpapers, anchor: &selectionAnchor)
    }

    /// A click on a tile (`ClickSelection`): ⌘ toggles it, ⇧ selects the run from the anchor in
    /// `wallpapers`, and a plain click clears the selection and inspects it.
    func selectWallpaper(
        _ wallpaper: WEWallpaper,
        from wallpapers: [WEWallpaper],
        inspectingWith wallpaperViewModel: WallpaperViewModel,
        kind: ClickSelection.Kind = ClickSelection.current
    ) {
        let url = wallpaper.wallpaperDirectory
        guard !ClickSelection.apply(kind, on: url, in: wallpapers.map(\.wallpaperDirectory),
                                    selected: &selectedWallpapers, anchor: &selectionAnchor) else { return }
        clearSelection()
        wallpaperViewModel.inspect(wallpaper)
        selectionAnchor = url
    }

    /// Edit › Select All: every wallpaper the folder shown lists after the search and filters,
    /// as Finder selects every item its window shows. Folders have no selection.
    func selectAll() {
        let wallpapers = displayedWallpapers
        selectedWallpapers = Set(wallpapers.map(\.wallpaperDirectory))
        selectionAnchor = wallpapers.first?.wallpaperDirectory
    }

    func clearSelection() {
        selectedWallpapers.removeAll()
        selectionAnchor = nil
    }

    func isSelected(_ wallpaper: WEWallpaper) -> Bool {
        selectedWallpapers.contains(wallpaper.wallpaperDirectory)
    }

    func selectedWallpaperItems() -> [WEWallpaper] {
        autoRefreshWallpapers.filter { selectedWallpapers.contains($0.wallpaperDirectory) }
    }
}
