import AppKit

extension AppDelegate {
    /// Settings › Performance › Playback, evaluated for each display.
    func makeDisplayPlaybackMonitor() -> DisplayPlaybackMonitor {
        let wallpapers = wallpaperViewModel
        let sources = DisplayPlaybackSources.system(showsWebWallpaper: { [weak wallpapers] in
            guard let wallpapers else { return false }
            // A split display's regions each show their own wallpaper.
            return wallpapers.routedScreens.contains { (screen: String) -> Bool in
                let type: String = wallpapers.wallpaper(for: screen).project.type
                return type.lowercased() == "web"
            }
        })
        let monitor = DisplayPlaybackMonitor(sources: sources, onLoad: { [weak self] load in
            self?.applicationRuleLoader.update(load)
        }, onCoverage: { [weak wallpapers] covered in
            wallpapers?.coveredScreens = covered
        }, apply: { [weak self] states in
            self?.applyDisplayPlayback(states)
        })
        // A display hidden under windows stops drawing (`WallpaperViewModel.coveredScreens`).
        monitor.watchesCoverage = true
        return monitor
    }

    /// Application rules' "Load wallpaper", "Load playlist" and "Load profile".
    func makeApplicationRuleLoader() -> ApplicationRuleLoader<WallpaperRuleLoadTarget> {
        let target = WallpaperRuleLoadTarget(
            viewModel: wallpaperViewModel,
            library: { [weak self] in self?.contentViewModel.library.allWallpapers ?? [] },
            profiles: { [weak self] in self?.displayProfiles ?? UnavailableDisplayProfiles() })
        return ApplicationRuleLoader(target: target)
    }

    /// Advanced › "Pause when VRAM is exhausted": pauses every display through the playback rules.
    func makeVideoMemoryWatch() -> VideoMemoryWatch {
        VideoMemoryWatch(device: .system()) { [weak self] exhausted in
            self?.displayPlaybackMonitor.setVideoMemoryExhausted(exhausted)
        }
    }

    /// Hands each display's playback to its wallpaper, and hides the windows of stopped displays.
    private func applyDisplayPlayback(_ states: [String: DisplayPlayback]) {
        wallpaperViewModel.rulePlayback = states
        orderWallpaperWindowsFront()
    }

    /// Shows every display's wallpaper window except those the playback rules stop, whose desktop
    /// then shows the macOS wallpaper.
    func orderWallpaperWindowsFront() {
        for (screenId, window) in wallpaperWindows {
            let stopped = wallpaperViewModel.playback(onScreen: screenId).hidesWindow
            if stopped, window.isVisible {
                window.orderOut(nil)
            } else if !stopped, !window.isVisible {
                window.orderFront(nil)
            }
        }
    }
}
