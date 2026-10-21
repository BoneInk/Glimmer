import Combine
import Foundation

/// The Discover tab's lists (`WorkshopDiscover.home`): each loads its first page when it comes into
/// view and the next one when its end does, so the home and an opened list scroll on without
/// end. Downloads, previews and favourites go through the Workshop tab's model, as WE's Discover
/// shares its browser.
@MainActor
final class WorkshopDiscoverViewModel: ObservableObject {
    struct Row: Equatable {
        var items: [WorkshopItem] = []
        var nextPage = 1
        var isLoading = false
        var reachedEnd = false
        var error: String?

        var isEmptyAfterLoading: Bool { reachedEnd && items.isEmpty }

        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.items.map(\.id) == rhs.items.map(\.id) && lhs.nextPage == rhs.nextPage
                && lhs.isLoading == rhs.isLoading && lhs.reachedEnd == rhs.reachedEnd && lhs.error == rhs.error
        }
    }

    /// One QueryFiles page of a section.
    typealias PageFetch = (WorkshopDiscoverSection, _ page: Int, _ perPage: Int) async throws -> [WorkshopItem]

    static let pageSize = 30
    /// QueryFiles pages read in a row when what a page returns is all filtered out here.
    static let maxEmptyPages = 5

    let sections: [WorkshopDiscoverSection]
    @Published private(set) var rows: [String: Row] = [:]
    /// The list "See More" opened, shown as a grid; nil shows the home.
    @Published var openSection: WorkshopDiscoverSection?
    /// Discover's queries need the Web API key the Workshop tab asks for.
    @Published private(set) var needsAPIKey = false

    private let fetch: PageFetch
    private let blockList: WorkshopBlockList
    private var blockListCancellable: AnyCancellable?
    /// Bumped by `reload`, so pages requested before it don't land in the new rows.
    private var generation = 0

    init(sections: [WorkshopDiscoverSection] = WorkshopDiscover.home,
         blockList: WorkshopBlockList = WorkshopBlockList(),
         fetch: PageFetch? = nil) {
        self.sections = sections
        let service = WorkshopAPIService()
        self.fetch = fetch ?? { section, page, perPage in
            try await service.discoverItems(section, page: page, perPage: perPage)
        }
        self.blockList = blockList
        // A newly blocked item or author leaves the lists at once; unblocked ones come back on Refresh.
        blockListCancellable = blockList.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.removeHiddenItems() } }
        }
    }

    func row(_ section: WorkshopDiscoverSection) -> Row {
        rows[section.id] ?? Row()
    }

    /// The sections the home shows: all but those that turned out empty.
    var visibleSections: [WorkshopDiscoverSection] {
        sections.filter { !row($0).isEmptyAfterLoading }
    }

    /// The cards Discover shows: the list See More opened, else every row of the home, in order.
    var shownItems: [WorkshopItem] {
        let lists = openSection.map { [row($0).items] } ?? visibleSections.map { row($0).items }
        var seen = Set<String>()
        return lists.joined().filter { seen.insert($0.id).inserted }
    }

    /// Loads the section's first page unless it has one.
    func loadIfNeeded(_ section: WorkshopDiscoverSection) async {
        let current = row(section)
        guard current.items.isEmpty, !current.reachedEnd, current.error == nil else { return }
        await loadMore(section)
    }

    /// Loads the section's next page; a no-op while one loads or after the last.
    func loadMore(_ section: WorkshopDiscoverSection) async {
        var current = row(section)
        guard !current.isLoading, !current.reachedEnd else { return }
        let started = generation
        current.isLoading = true
        current.error = nil
        rows[section.id] = current
        do {
            var added: [WorkshopItem] = []
            var emptyPages = 0
            // A page whose items are all filtered here would stop the scrolling: read on.
            while added.isEmpty, !current.reachedEnd, emptyPages < Self.maxEmptyPages {
                let page = try await fetch(section, current.nextPage, Self.pageSize)
                guard started == generation else { return }
                current.nextPage += 1
                current.reachedEnd = page.count < Self.pageSize
                added = WorkshopDiscover.shownItems(page, of: section, after: current.items, hidden: blockList.isBlocked)
                if added.isEmpty { emptyPages += 1 }
            }
            current.items += added
            needsAPIKey = false
        } catch {
            guard started == generation else { return }
            if case WorkshopAPIError.noAPIKey = error { needsAPIKey = true }
            if case WorkshopAPIError.invalidAPIKey = error { needsAPIKey = true }
            current.error = error.localizedDescription
        }
        current.isLoading = false
        rows[section.id] = current
    }

    /// Forgets every list, so they load again (a new API key, or the block list changed).
    func reload() {
        generation += 1
        rows = [:]
        needsAPIKey = false
    }

    /// Takes hidden items out of the loaded lists without reloading them.
    func removeHiddenItems() {
        for (id, row) in rows {
            var row = row
            row.items.removeAll(where: blockList.isBlocked)
            rows[id] = row
        }
    }
}
