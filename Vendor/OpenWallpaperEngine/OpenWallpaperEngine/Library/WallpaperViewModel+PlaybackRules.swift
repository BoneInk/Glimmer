import SwiftUI
import AVKit
import Combine

extension WallpaperViewModel {
    /// Whether windows hide `screenId`, or the display a region of it (a split display) is on.
    func isCovered(_ screenId: String) -> Bool {
        if coveredScreens.contains(screenId) { return true }
        return layoutResolution.regions.contains { screen, regions in
            coveredScreens.contains(screen) && regions.contains { $0.id == screenId }
        }
    }

    /// Merges the displays' mute into the playback rules' states; a split display's regions take
    /// its state.
    func refreshDisplayPlayback() {
        var states = rulePlayback
        for screen in layoutResolution.muted { states[screen] = max(states[screen] ?? .run, .mute) }
        for (screen, regions) in layoutResolution.regions {
            guard let state = states[screen] else { continue }
            for region in regions { states[region.id] = state }
        }
        guard states != displayPlayback else { return }
        displayPlayback = states
        let summary = states.keys.sorted().map { "\($0)=\(states[$0] ?? .run)" }.joined(separator: ", ")
        OWELog.debug(.app, "Display playback with mute: \(summary.isEmpty ? "all run" : summary)")
    }

    /// `screenId`'s own playback: whether its view draws new frames.
    func playback(onScreen screenId: String) -> DisplayPlayback {
        persistsWallpapers ? displayPlayback[screenId] ?? .run : .run
    }

    /// What the displays showing the instance `key` agree on: whether it renders
    /// (`DisplayPlaybackRouting.instance`).
    func playback(of key: WallpaperInstanceKey) -> DisplayPlayback {
        guard persistsWallpapers else { return .run }
        return DisplayPlaybackRouting.instance(key, instanceKeys: instanceKeys, enabledScreens: routedScreens,
                                               states: displayPlayback)
    }

    /// What the displays showing `key`'s wallpaper agree on, whatever their properties: whether its
    /// sound plays (`DisplayPlaybackRouting.wallpaper`).
    func wallpaperPlayback(of key: WallpaperInstanceKey) -> DisplayPlayback {
        guard persistsWallpapers else { return .run }
        return DisplayPlaybackRouting.wallpaper(key, instanceKeys: instanceKeys, enabledScreens: routedScreens,
                                                states: displayPlayback)
    }

    func audibleCandidates(of key: WallpaperInstanceKey) -> Set<String> {
        DisplayPlaybackRouting.audibleCandidates(of: key, instanceKeys: instanceKeys, enabledScreens: routedScreens,
                                                 states: displayPlayback)
    }
}
