import Foundation

/// A Workshop wallpaper's tags as Steam lists them, stored with the installed ids in
/// `DownloadedWallpaperIndex` so the Installed tab shows and filters by them offline.
///
/// Many project.json files carry one tag (the genre, or only the type), while the Workshop item
/// has the full set: type, rating, resolution, genres, Approved, Audio responsive and so on.
struct InstalledWorkshopTags: Codable, Equatable {
    /// Bump when what is stored changes meaning; entries of another revision are read again.
    static let currentRevision = 1

    var tags: [String]
    /// Steam's `time_updated` when the tags were read; nil when Steam didn't return the item
    /// (removed or private), which is stored too so it isn't asked for again.
    var timeUpdated: Int?
    var revision: Int = InstalledWorkshopTags.currentRevision

    /// The tags to show and filter by: project.json's first, in their order, then Steam's that
    /// aren't among them (compared ignoring case and surrounding spaces). "Wallpaper", which every
    /// Workshop wallpaper has, is left out, as on the Workshop cards.
    static func merged(project: [String]?, workshop: [String]?) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in (project ?? []) + (workshop ?? []) {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, key != "wallpaper", seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// The tags to show and filter `wallpaper` by, with its Workshop item's from `index`.
    static func tags(of wallpaper: WEWallpaper, in index: DownloadedWallpaperIndex) -> [String] {
        let workshop = workshopId(of: wallpaper).flatMap { index.workshopTags(for: $0)?.tags }
        return merged(project: wallpaper.project.tags, workshop: workshop)
    }

    /// Whether project.json has too few tags to go by (none, or one besides "Wallpaper"), so the
    /// Workshop item's tags are worth reading.
    static func projectNeedsWorkshopTags(_ project: WEProject) -> Bool {
        merged(project: project.tags, workshop: nil).count <= 1
    }

    /// The wallpaper's Workshop id: project.json's `workshopid`, else a numeric folder name (what
    /// steamcmd names it); nil for local wallpapers.
    static func workshopId(of wallpaper: WEWallpaper) -> String? {
        if let id = wallpaper.project.workshopid?.rawValue, !id.isEmpty, id.allSatisfy(\.isNumber), id != "0" {
            return id
        }
        let folder = wallpaper.wallpaperDirectory.lastPathComponent
        return !folder.isEmpty && folder.allSatisfy(\.isNumber) ? folder : nil
    }

    /// The age rating among `tags` (WE's rating tags), spelled as project.json's `contentrating`.
    static func contentRating(in tags: [String]) -> String? {
        tags.lazy.compactMap { tag in
            WorkshopTags.ratings.first { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }.first
    }
}
