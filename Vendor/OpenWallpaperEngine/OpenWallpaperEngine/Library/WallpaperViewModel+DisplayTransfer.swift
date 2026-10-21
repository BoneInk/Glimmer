import Foundation

/// WE's "Copy to" and "Swap with" (`ui_browse_monitors_copy_to`, `ui_browse_monitors_swap_with`
/// in its monitor menu, `ui/dist/scripts/scripts.js`). Under a wallpaper per display, a display
/// (or a split display's region) that shows a wallpaper can copy it, with its properties and display
/// options there, to another display that shows one of its own (not a clone or stretch member), or
/// swap wallpapers with it. A swap takes each wallpaper's settings along; one wallpaper on both
/// swaps its two sets of settings; and a display without a wallpaper leaves the other without one.
/// WE's playlists per monitor move along too; here playlists aren't per display, so none move.
extension WallpaperViewModel {
    /// The displays and regions `id`'s wallpaper can be copied to or swapped with, in display order.
    /// Empty unless the layout is a wallpaper per display, there are two or more of them, and `id`
    /// shows a wallpaper.
    func transferTargets(from id: String) -> [String] {
        guard displayLayout.layout == .perDisplay, shownWallpaper(on: id) != nil else { return [] }
        let shown = layoutResolution.shownDisplays(connectedDisplays().map(\.screenId))
        guard shown.count > 1 else { return [] }
        return shown.filter { $0 != id && !isCloned($0) && !isStretched($0) }
    }

    /// Copies `source`'s wallpaper, its properties and display options there, to `destination`.
    func copyWallpaper(from source: String, to destination: String) {
        guard let wallpaper = shownWallpaper(on: source) else { return }
        transferSettings(of: wallpaper, from: source, to: destination)
        setWallpaper(wallpaper, for: [destination])
    }

    /// Swaps the wallpapers of `first` and `second`, each with its settings.
    func swapWallpapers(_ first: String, _ second: String) {
        let firstWallpaper = shownWallpaper(on: first), secondWallpaper = shownWallpaper(on: second)
        if let firstWallpaper, let secondWallpaper, firstWallpaper.isSameWallpaper(as: secondWallpaper) {
            swapSettings(of: firstWallpaper, first, second)
        } else {
            if let firstWallpaper { transferSettings(of: firstWallpaper, from: first, to: second) }
            if let secondWallpaper { transferSettings(of: secondWallpaper, from: second, to: first) }
        }
        place(firstWallpaper, on: second)
        place(secondWallpaper, on: first)
    }

    /// The wallpaper `id` shows, nil for none (the placeholder).
    private func shownWallpaper(on id: String) -> WEWallpaper? {
        guard let wallpaper = wallpapers[layoutResolution.source(of: id)], wallpaper.project != .invalid else { return nil }
        return wallpaper
    }

    /// Sets `wallpaper` on `id`, or takes `id`'s away when there is none.
    private func place(_ wallpaper: WEWallpaper?, on id: String) {
        if let wallpaper {
            setWallpaper(wallpaper, for: [id])
        } else {
            wallpapers.removeValue(forKey: layoutResolution.source(of: id))
        }
    }

    private func transferSettings(of wallpaper: WEWallpaper, from source: String, to destination: String) {
        displayOptions.copy(for: wallpaper, from: source, to: destination)
        guard persistsWallpapers else { return }
        let identity = WallpaperSettingsIdentity.resolve(wallpaper)
        let scope = propertyScope(for: destination)
        let values = WallpaperPropertyTransfer.copy(identity, from: propertyScope(for: source), to: scope)
        propertiesTransferred(of: wallpaper, [(scope, values)])
    }

    private func swapSettings(of wallpaper: WEWallpaper, _ first: String, _ second: String) {
        displayOptions.swap(for: wallpaper, first, second)
        guard persistsWallpapers else { return }
        let identity = WallpaperSettingsIdentity.resolve(wallpaper)
        let firstScope = propertyScope(for: first), secondScope = propertyScope(for: second)
        let values = WallpaperPropertyTransfer.swap(identity, firstScope, secondScope)
        propertiesTransferred(of: wallpaper, [(firstScope, values.first), (secondScope, values.second)])
    }

    /// Hands the new values to the stores already running and lets the displays regroup by them.
    private func propertiesTransferred(of wallpaper: WEWallpaper, _ stores: [(WallpaperPropertyScope, [String: String])]) {
        for (scope, values) in stores {
            WallpaperPropertyTargets.publishReplacing(scope.runtimeKey(directory: wallpaper.settingsDirectory), values)
        }
        NotificationCenter.default.post(name: .wallpaperPropertiesDidSave, object: wallpaper.settingsDirectory.path)
    }
}
