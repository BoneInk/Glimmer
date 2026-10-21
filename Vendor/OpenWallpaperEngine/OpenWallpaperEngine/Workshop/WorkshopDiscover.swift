import Foundation

/// One list of the Discover tab, as WE's `getStaticExploreQueries` defines them: a sort, the
/// tags every item has (`tags`, AND-ed) and the tags none has.
struct WorkshopDiscoverSection: Identifiable, Equatable {
    enum Title: Equatable {
        case popularRightNow
        case mostPopularWeek
        case recentApproved
        case topRated
        case popularApproved
        /// "Popular <genre> Wallpapers", the genre a Workshop tag.
        case popularGenre(String)
    }

    let id: String
    let title: Title
    let sort: WorkshopSortOrder
    let tags: [String]
    var excludedTags: [String] = []

    /// The section as QueryFiles can ask it. WE adds `Wallpaper` and `Everyone` to every Discover
    /// list's tags; QueryFiles can't AND required tags (see `WorkshopQuery`), and the category and
    /// rating groups are exclusive, so those two are sent as the exclusion of their siblings. The
    /// first of `tags` is required, the others are checked on the results.
    var query: WorkshopQuery {
        let implied = WorkshopTags.categories.filter { $0 != "Wallpaper" }
            + WorkshopTags.ratings.filter { $0 != "Everyone" }
        var excluded = excludedTags
        for tag in implied where !excluded.contains(tag) { excluded.append(tag) }
        return WorkshopQuery(requiredTags: Array(tags.prefix(1)), matchAllTags: true, excludedTags: excluded,
                             clientRequiredTags: Array(tags.dropFirst()))
    }
}

enum WorkshopDiscover {
    /// WE leaves portrait wallpapers out of its Approved lists.
    static let portraitTags = WEResolutionTags.groups.first { $0.title == "Portrait Monitor / Phone" }?.tags ?? []

    /// WE's genre lists: its most popular wallpapers of each genre (`top_rated`), MMD with Anime.
    static let genreTags: [[String]] = [
        ["Abstract"], ["Animal"], ["Anime"], ["Cartoon"], ["Cyberpunk"], ["Fantasy"], ["Game"], ["Landscape"],
        ["Medieval"], ["MMD", "Anime"], ["Nature"], ["Pixel art"], ["Retro"], ["Sci-Fi"], ["Sports"],
        ["Technology"], ["Vehicle"], ["Memes"],
    ]

    /// The Discover home: WE's pinned Approved lists, the week's most popular and the top rated,
    /// then WE's audio-responsive and genre lists.
    static let home: [WorkshopDiscoverSection] = {
        var sections = [
            WorkshopDiscoverSection(id: "popular-now", title: .popularRightNow, sort: .trendMonth,
                                    tags: [WorkshopTags.approved], excludedTags: portraitTags),
            WorkshopDiscoverSection(id: "popular-week", title: .mostPopularWeek, sort: .trendWeek, tags: []),
            WorkshopDiscoverSection(id: "recent-approved", title: .recentApproved, sort: .mostRecent,
                                    tags: [WorkshopTags.approved], excludedTags: portraitTags),
            WorkshopDiscoverSection(id: "top-rated", title: .topRated, sort: .topRated, tags: []),
            WorkshopDiscoverSection(id: "popular-approved", title: .popularApproved, sort: .trendYear,
                                    tags: [WorkshopTags.approved], excludedTags: portraitTags),
            WorkshopDiscoverSection(id: "popular-audio", title: .popularGenre(WorkshopTags.audioResponsive),
                                    sort: .trendYear, tags: [WorkshopTags.audioResponsive],
                                    excludedTags: ["Relaxing", "Anime", "CGI", "Game"]),
        ]
        for tags in genreTags {
            sections.append(WorkshopDiscoverSection(id: "genre-" + tags.joined(separator: "+"),
                                                    title: .popularGenre(tags[0]), sort: .topRated, tags: tags))
        }
        return sections
    }()

    /// QueryFiles' parameters for one page of `section`.
    static func queryItems(for section: WorkshopDiscoverSection, page: Int, perPage: Int) -> [URLQueryItem] {
        var items = WorkshopAPIService.queryItems(queryType: section.sort.queryType, filter: section.query,
                                                  page: page, perPage: perPage)
        if let days = section.sort.trendDays {
            items.append(URLQueryItem(name: "days", value: "\(days)"))
        }
        return items
    }

    /// The items of a page `section` shows: what passes the checks Steam couldn't make, minus
    /// `hidden` ones and those already shown.
    static func shownItems(_ page: [WorkshopItem], of section: WorkshopDiscoverSection, after shown: [WorkshopItem],
                           hidden: (WorkshopItem) -> Bool) -> [WorkshopItem] {
        let query = section.query
        var seen = Set(shown.map(\.id))
        return page.filter { item in
            guard query.matches(item, isFavorite: { _ in false }), !hidden(item) else { return false }
            return seen.insert(item.id).inserted
        }
    }
}
