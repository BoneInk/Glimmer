import AppKit

/// WE's "Stop wallpapers" (`WallpaperViewModel.isStopped`): every display's wallpaper is unloaded
/// (its scene, page or player torn down, freeing CPU, GPU and memory) and its window closed, so the
/// desktop shows the macOS desktop picture, as an application rule's Stop shows it. Resume or Play
/// loads each display's wallpaper again; the displays keep their wallpapers meanwhile, so what
/// comes back is what was shown.
///
/// The user's Stop wins over the rules until the user resumes: rules keep evaluating, and a
/// rule's load changes what a display will show, but nothing loads while stopped. On resume the
/// rules in force apply at once (a display a rule stops stays hidden, a rule's wallpaper shows).
extension AppDelegate {
    @objc func stopWallpapers() {
        wallpaperViewModel.stopWallpapers()
    }

    /// The menus' and the hotkey's Stop or Resume. Resuming also unpauses, as WE's Play does.
    @objc func toggleStopWallpapers() {
        if wallpaperViewModel.isStopped { resume() } else { stopWallpapers() }
    }

    /// Follows `isStopped`: closes the wallpaper windows, or makes them again.
    func observeStoppedState() {
        wallpaperViewModel.onStoppedChange = { [weak self] stopped in
            guard let self else { return }
            if stopped {
                Self.closeWallpaperWindows(wallpaperWindows)
                wallpaperWindows.removeAll()
            } else {
                setWallpaperWindows()
                orderWallpaperWindowsFront()
            }
            showStoppedState()
            OWELog.info(.app, stopped ? "Wallpapers stopped" : "Wallpapers resumed from stop")
        }
    }

    /// The menu bar icon dims while the wallpapers are stopped, and its tooltip says so.
    func showStoppedState() {
        guard let button = statusItem?.button else { return }
        let stopped = wallpaperViewModel.isStopped
        button.appearsDisabled = stopped
        button.toolTip = stopped ? String(localized: "Wallpapers stopped", comment: "Menu bar icon tooltip while every wallpaper is stopped") : nil
    }
}
