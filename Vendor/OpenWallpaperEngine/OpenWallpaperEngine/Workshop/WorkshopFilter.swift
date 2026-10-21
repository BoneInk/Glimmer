import Foundation

/// Wallpaper Engine's Workshop tags, spelled as WE's browser sends them (wallpaperui.exe and
/// `ui/dist/scripts/scripts.js`). The UI shows them through `LocalizedLabels.filterOption`.
enum WorkshopTags {
    static let ratings = ["Everyone", "Questionable", "Mature"]
    static let types = ["Scene", "Video", "Web", "Application"]
    /// WE's Category filter: every Workshop item has one of these tags, `Preset` for a preset of
    /// another wallpaper (its base is the item's dependency, `WorkshopItem.dependencyIds`).
    static let categories = ["Wallpaper", "Preset"]
    static let genres = [
        "Abstract", "Animal", "Anime", "Cartoon", "CGI", "Cyberpunk", "Fantasy", "Game", "Girls", "Guys",
        "Landscape", "Medieval", "Memes", "MMD", "Music", "Nature", "Pixel art", "Relaxing", "Retro",
        "Sci-Fi", "Sports", "Technology", "Television", "Vehicle", "Unspecified",
    ]

    /// The genres WE's Hide Anime leaves out of the Workshop (`xe` in its `scripts.js`).
    static let hiddenByHideAnime = ["Anime", "MMD", "Girls", "Guys", "Music"]

    static let approved = "Approved"
    static let audioResponsive = "Audio responsive"
    static let customizable = "Customizable"

    /// WE's mobile filter: items published under the Workshop EULA version that allows the mobile
    /// app (a key/value tag, not a tag), and never web or application wallpapers.
    static let mobileKVKey = "app_workshop_eula_version"
    static let mobileKVValue = "3"
    static let mobileExcludedTypes = ["Application", "Web"]
}

/// WE's resolution tags in its filter's groups; shared by the Installed and Workshop filters. The
/// UI shows the titles and tags through `LocalizedLabels.filterOption`.
enum WEResolutionTags {
    struct Group: Identifiable {
        let title: String
        let tags: [String]
        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "Widescreen", tags: ["Standard Definition", "1280 x 720", "1366 x 768", "1920 x 1080",
                                          "2560 x 1440", "3840 x 2160"]),
        Group(title: "Ultra Widescreen", tags: ["Ultrawide Standard Definition", "Ultrawide 2560 x 1080",
                                                "Ultrawide 3440 x 1440"]),
        Group(title: "Dual Monitor", tags: ["Dual Standard Definition", "Dual 3840 x 1080", "Dual 5120 x 1440",
                                            "Dual 7680 x 2160"]),
        Group(title: "Triple Monitor", tags: ["Triple Standard Definition", "Triple 4096 x 768",
                                              "Triple 5760 x 1080", "Triple 7680 x 1440", "Triple 11520 x 2160"]),
        Group(title: "Portrait Monitor / Phone", tags: ["Portrait Standard Definition", "Portrait 720 x 1280",
                                                        "Portrait 1080 x 1920", "Portrait 1440 x 2560",
                                                        "Portrait 2160 x 3840"]),
        Group(title: "Other", tags: ["Other resolution", "Dynamic resolution"]),
    ]

    static let all: [String] = groups.flatMap(\.tags)
}

/// The Workshop tab's "Show only" options, in the Installed tab's order (`FRShowOnly.options`).
enum WorkshopShowOnly: Int, CaseIterable, Hashable {
    case approved, favourites, mobileCompatible, audioResponsive, customizable

    /// The Workshop tag the option stands for; nil for favourites (local) and mobile (a key/value tag).
    var tag: String? {
        switch self {
        case .approved: return WorkshopTags.approved
        case .audioResponsive: return WorkshopTags.audioResponsive
        case .customizable: return WorkshopTags.customizable
        case .favourites, .mobileCompatible: return nil
        }
    }
}

/// How the selected genres combine.
enum WorkshopTagMatch: String, Hashable {
    /// Every selected genre (AND).
    case all
    /// At least one selected genre (OR).
    case any
}

/// What the Workshop tab's filter sidebar asks for. Within Show Only, Rating, Type, Category and
/// Resolution a result needs any one of the checked options (OR); genres combine by `genreMatch`;
/// the groups narrow the results together (AND). A group with nothing or everything checked
/// doesn't filter.
struct WorkshopFilter: Equatable {
    var showOnly: Set<WorkshopShowOnly> = []
    var ratings: Set<String> = ["Everyone"]
    var types: Set<String> = []
    var categories: Set<String> = []
    var resolutions: Set<String> = []
    var genres: Set<String> = []
    var genreMatch: WorkshopTagMatch = .all
    /// WE's Hide Anime (its Workshop Filter Settings): the genres `WorkshopTags.hiddenByHideAnime`
    /// are left out, all but those checked in `genres`. A setting of its own, which Reset Filters
    /// keeps, as WE applies it again on every reset.
    var hidesAnime = false

    /// Changes whenever the results would.
    var cacheKey: String {
        [showOnly.map { String($0.rawValue) }.sorted().joined(separator: ","),
         ratings.sorted().joined(separator: ","), types.sorted().joined(separator: ","),
         categories.sorted().joined(separator: ","),
         resolutions.sorted().joined(separator: ","), genres.sorted().joined(separator: ","),
         genreMatch.rawValue, hidesAnime ? "hide-anime" : ""].joined(separator: "|")
    }
}

/// A `WorkshopFilter` as one QueryFiles request plus what has to be checked on the results.
///
/// The OR groups are sent the way WE's own browser sends them: the unchecked tags of a group
/// become `excludedtags` (Rating, Type, Category, Resolution are exclusive groups, so "none of the
/// unchecked" is "any of the checked").
///
/// QueryFiles over the Web API doesn't AND tags: with `match_all_tags=true` and two or more
/// `requiredtags` it returns next to nothing (Anime + Girls: a total of 4, against 649,855 for Anime
/// alone and 988,033 for either; `taggroups` is ignored). So at most one tag is ever required with
/// `match_all_tags=true`, and any further AND-ed tags are checked on the results. OR-ed genres go
/// to Steam as `requiredtags` with `match_all_tags=false`, which works.
///
/// Show Only options aren't exclusive, so they can't be exclusions: a single tag option is one
/// more AND-ed tag when the genres are AND-ed, and anything else (several options, mobile,
/// favourites, or a tag option next to OR-ed genres) is checked on the results. Results checked
/// here are paged by `WorkshopViewModel`, which counts pages over what passes.
struct WorkshopQuery: Equatable {
    var requiredTags: [String] = []
    var matchAllTags = true
    var excludedTags: [String] = []
    /// Tags every result must also have, checked here because Steam can't AND them.
    var clientRequiredTags: [String] = []
    /// Show Only options checked on each result (any one passes); empty checks nothing.
    var clientShowOnly: Set<WorkshopShowOnly> = []
    /// Only items that require this one (QueryFiles `child_publishedfileid`): a wallpaper's presets.
    var childOf: String?

    init(requiredTags: [String] = [], matchAllTags: Bool = true, excludedTags: [String] = [],
         clientRequiredTags: [String] = [], clientShowOnly: Set<WorkshopShowOnly> = []) {
        self.requiredTags = requiredTags
        self.matchAllTags = matchAllTags
        self.excludedTags = excludedTags
        self.clientRequiredTags = clientRequiredTags
        self.clientShowOnly = clientShowOnly
    }

    init(_ filter: WorkshopFilter) {
        func exclusions(_ checked: Set<String>, of group: [String]) -> [String] {
            let inGroup = group.filter(checked.contains)
            guard !inGroup.isEmpty, inGroup.count < group.count else { return [] }
            return group.filter { !checked.contains($0) }
        }
        excludedTags = exclusions(filter.ratings, of: WorkshopTags.ratings)
            + exclusions(filter.types, of: WorkshopTags.types)
            + exclusions(filter.categories, of: WorkshopTags.categories)
            + exclusions(filter.resolutions, of: WEResolutionTags.all)
        // WE unchecks these genres, which sends them as excluded tags; a genre the user checks
        // again is shown.
        if filter.hidesAnime {
            excludedTags += WorkshopTags.hiddenByHideAnime.filter { !filter.genres.contains($0) }
        }

        let genres = WorkshopTags.genres.filter(filter.genres.contains)
        let genresAreAND = filter.genreMatch == .all || genres.count <= 1
        var andTags: [String] = []
        if genresAreAND {
            andTags = genres
        } else {
            requiredTags = genres
            matchAllTags = false
        }

        if filter.showOnly.count == 1, let option = filter.showOnly.first {
            if let tag = option.tag, genresAreAND {
                andTags.append(tag)
            } else if option == .mobileCompatible {
                for type in WorkshopTags.mobileExcludedTypes where !excludedTags.contains(type) {
                    excludedTags.append(type)
                }
                clientShowOnly = [option]
            } else {
                clientShowOnly = [option]
            }
        } else {
            clientShowOnly = filter.showOnly
        }

        // One AND-ed tag goes to Steam; the rest are checked on its results.
        if let first = andTags.first {
            requiredTags = [first]
            matchAllTags = true
            clientRequiredTags = Array(andTags.dropFirst())
        }
    }

    /// Whether `item` passes the whole query, the part Steam would check included: for results
    /// that didn't come from QueryFiles (an author's items).
    func matchesAllTags(_ item: WorkshopItem, isFavorite: (WorkshopItem) -> Bool) -> Bool {
        func has(_ tag: String) -> Bool {
            item.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
        guard !excludedTags.contains(where: has) else { return false }
        if !requiredTags.isEmpty {
            guard matchAllTags ? requiredTags.allSatisfy(has) : requiredTags.contains(where: has) else { return false }
        }
        return matches(item, isFavorite: isFavorite)
    }

    /// Whether `item` passes the options that are checked on the results.
    func matches(_ item: WorkshopItem, isFavorite: (WorkshopItem) -> Bool) -> Bool {
        func has(_ tag: String) -> Bool {
            item.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
        guard clientRequiredTags.allSatisfy(has) else { return false }
        guard !clientShowOnly.isEmpty else { return true }
        return clientShowOnly.contains { option in
            switch option {
            case .favourites:
                return isFavorite(item)
            case .mobileCompatible:
                return item.kvTags?[WorkshopTags.mobileKVKey] == WorkshopTags.mobileKVValue
                    && !WorkshopTags.mobileExcludedTypes.contains(where: has)
            case .approved, .audioResponsive, .customizable:
                return option.tag.map(has) ?? false
            }
        }
    }
}
