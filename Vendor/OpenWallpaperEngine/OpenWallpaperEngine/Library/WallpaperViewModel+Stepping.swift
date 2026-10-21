import Foundation

/// Next and Previous Wallpaper (Playback menu and status menu). In a playlist they step through
/// it; otherwise Next picks a random wallpaper from the list the library shows and Previous goes
/// back through the display's history. Both act on the selected displays, like the playlist.
///
/// Each step applies at once on the main actor, so two quick ones step twice: the second reads
/// what the first applied. Every step moves to another wallpaper while there is one to move to.
extension WallpaperViewModel {
    /// Whether Next and Previous step through the active playlist: while it rotates, or while a
    /// selected display shows one of its items. Otherwise they pick randomly and walk history.
    var stepsThroughPlaylist: Bool {
        guard let playlist = activePlaylist, !playlist.items.isEmpty else { return false }
        if playlistEnabled { return true }
        let items = Set(playlist.items.map(\.wallpaper.identityPath))
        return selectedScreenIds.contains { items.contains(wallpaper(for: $0).identityPath) }
    }

    /// The display a playlist step reads its position from: the one selected in the UI when it is
    /// among the displays the step acts on, else the first of those.
    var steppingScreenId: String? {
        selectedScreenIds.contains(selectedScreenId) ? selectedScreenId : selectedScreenIds.min()
    }

    /// What the displays a step acts on show now.
    private var steppedWallpapers: [WEWallpaper] {
        selectedScreenIds.sorted().map { wallpaper(for: $0) }
    }

    func canStepToNextWallpaper(shown: [WEWallpaper]) -> Bool {
        stepsThroughPlaylist || Self.randomPick(from: Self.steppable(shown), excluding: steppedWallpapers) != nil
    }

    /// The wallpapers of `shown` Next may pick: never one that would wait on the trust prompt
    /// instead of changing the wallpaper.
    static func steppable(_ shown: [WEWallpaper]) -> [WEWallpaper] {
        shown.filter { !needsTrust($0) }
    }

    var canStepToPreviousWallpaper: Bool {
        stepsThroughPlaylist || selectedScreenIds.contains { screenId in
            wallpaperHistory.previous(for: screenId, showing: wallpaper(for: screenId)) != nil
        }
    }

    /// `shown`: the Installed list as filtered, searched and sorted now.
    func stepToNextWallpaper(shown: [WEWallpaper],
                             random: (Range<Int>) -> Int = { Int.random(in: $0) }) {
        if stepsThroughPlaylist {
            nextPlaylistWallpaper()
        } else if let pick = Self.randomPick(from: Self.steppable(shown), excluding: steppedWallpapers,
                                             random: random) {
            // Through `apply`, so safe restart still applies.
            apply(pick)
        }
    }

    func stepToPreviousWallpaper() {
        if stepsThroughPlaylist {
            previousPlaylistWallpaper()
            return
        }
        for screenId in layoutResolution.targets(of: selectedScreenIds) {
            guard let previous = wallpaperHistory.back(for: screenId, showing: wallpaper(for: screenId)),
                  confirmApply?(previous) ?? true else { continue }
            wallpapers[screenId] = previous
            addToRecents(previous)
        }
    }

    /// A random wallpaper of `shown` other than `current`; nil when there is none.
    static func randomPick(from shown: [WEWallpaper], excluding current: WEWallpaper,
                           random: (Range<Int>) -> Int = { Int.random(in: $0) }) -> WEWallpaper? {
        randomPick(from: shown, excluding: [current], random: random)
    }

    /// A random wallpaper of `shown` that none of `current` (what the stepped displays show) is;
    /// when they show every one of them, one that changes at least one display. Nil when there is
    /// none. Wallpapers compare by folder path, never by URL spelling.
    static func randomPick(from shown: [WEWallpaper], excluding current: [WEWallpaper],
                           random: (Range<Int>) -> Int = { Int.random(in: $0) }) -> WEWallpaper? {
        let currentPaths = current.map(\.identityPath)
        var seen: Set<String> = []
        let eligible = shown.filter { $0.project != .invalid && seen.insert($0.identityPath).inserted }
        var candidates = eligible.filter { !currentPaths.contains($0.identityPath) }
        if candidates.isEmpty {
            candidates = eligible.filter { pick in currentPaths.contains { $0 != pick.identityPath } }
        }
        guard !candidates.isEmpty else { return nil }
        return candidates[random(candidates.indices)]
    }
}
