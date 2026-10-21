import Foundation

/// The Installed tab's tag-based filters over a wallpaper's tags (project.json's merged with
/// Steam's, `InstalledWorkshopTags.merged`). Within a group any checked tag matches (OR), as on
/// the Workshop tab; a group with everything checked doesn't filter, and one with nothing checked
/// matches nothing, like the Type and Age Rating groups.
enum InstalledTagFilter {
    /// The checked options of `options`, as their `optionKeys` (option `i` is bit `1 << i`).
    static func checked<Option: FilterResultsModel>(_ options: Option) -> [String] {
        Option.optionKeys.indices
            .filter { options.contains(Option(rawValue: 1 << $0)) }
            .map { Option.optionKeys[$0] }
    }

    /// The genre tags of the checked `FRTag` options. `FRTag`'s options are WE's genres in
    /// `WorkshopTags.genres` order, with UI spellings ("PixelArt"); the tags are WE's ("Pixel art").
    static func genreTags(_ options: FRTag) -> [String] {
        FRTag.optionKeys.indices
            .filter { options.contains(FRTag(rawValue: 1 << $0)) && $0 < WorkshopTags.genres.count }
            .map { WorkshopTags.genres[$0] }
    }

    static func matchesGenres(_ tags: [String], checked options: FRTag) -> Bool {
        guard options != .all else { return true }
        return hasAny(of: genreTags(options), in: tags)
    }

    /// `checked` are the checked resolution tags of all resolution groups.
    static func matchesResolutions(_ tags: [String], checked: Set<String>) -> Bool {
        guard !Set(WEResolutionTags.all).isSubset(of: checked) else { return true }
        return hasAny(of: Array(checked), in: tags)
    }

    private static func hasAny(of wanted: [String], in tags: [String]) -> Bool {
        tags.contains { tag in wanted.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
    }
}
