import Foundation

/// What the Playlists tab shows about a playlist besides its items: the cover, how long each item
/// shows and how long a round takes, and a one-line summary of its timing.
enum PlaylistSummary {
    /// The most previews a cover shows, as Music's playlist mosaics.
    static let coverLimit = 4

    /// The cover's previews: the first items with a preview, up to `coverLimit`, each wallpaper
    /// once (a playlist may list a folder twice).
    static func coverURLs(of playlist: WallpaperPlaylist) -> [URL] {
        var seen = Set<URL>()
        var urls: [URL] = []
        for item in playlist.items where urls.count < coverLimit {
            guard seen.insert(item.wallpaper.wallpaperDirectory).inserted,
                  let url = previewURL(for: item.wallpaper) else { continue }
            urls.append(url)
        }
        return urls
    }

    /// A wallpaper's preview: a remote wallpaper's own URL, else its preview file.
    static func previewURL(for wallpaper: WEWallpaper) -> URL? {
        let type = wallpaper.project.type.lowercased()
        if type == "remote-video" || type == "remote-image", let url = URL(string: wallpaper.project.file) {
            return url
        }
        return wallpaper.previewURL
    }

    /// How an item gets its turn, under the playlist's timing.
    enum ItemShare: Equatable {
        /// Shows for this long (on a timer; on a time-of-day playlist, the length of its slot).
        case duration(TimeInterval)
        /// Shows on this many days of the week (a day-of-week playlist).
        case days(Int)
        /// Not timed: at login, never, or past a day-of-week playlist's seventh item.
        case untimed
    }

    static func share(ofItemAt index: Int, in playlist: WallpaperPlaylist) -> ItemShare {
        guard playlist.items.indices.contains(index) else { return .untimed }
        switch playlist.timing {
        case .timer:
            // "First wallpaper played at startup only": the rotation leaves it out.
            if index == 0 && playlist.leavesOutFirstItem { return .untimed }
            return .duration(playlist.duration)
        case .daytime:
            let slot = PlaylistSchedule.daySlots(ends: playlist.daytimeEnds)[index]
            return .duration(((slot.end - slot.start) * 86_400).rounded())
        case .dayofweek:
            let slots = PlaylistSchedule.weekSlots(itemCount: playlist.items.count)
            return slots.indices.contains(index) ? .days(slots[index].count) : .untimed
        case .logon, .never:
            return .untimed
        }
    }

    /// How long one round of the playlist takes: on a timer, every item it rotates through; a
    /// time-of-day playlist fills a day and a day-of-week one a week. Nil when it isn't timed.
    static func totalDuration(of playlist: WallpaperPlaylist) -> TimeInterval? {
        guard !playlist.items.isEmpty else { return nil }
        switch playlist.timing {
        case .timer:
            let rotating = playlist.items.count - (playlist.leavesOutFirstItem ? 1 : 0)
            return Double(rotating) * playlist.duration
        case .daytime: return 86_400
        case .dayofweek: return 7 * 86_400
        case .logon, .never: return nil
        }
    }

    /// The transition's name for the header, nil when the playlist has none.
    static func transitionTitle(_ settings: WallpaperTransitionSettings) -> LocalizedStringResource? {
        switch settings.choice {
        case .none, .noneReducingFlicker: return nil
        case .random: return LocalizedStringResource("Random transition", comment: "Playlist header: each change picks a transition at random")
        case .kind(let kind): return kind.title
        }
    }
}
