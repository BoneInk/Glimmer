import SwiftUI
import AVKit
import Combine

extension WallpaperViewModel {
    /// Syncing starts from what the displays ran: each wallpaper's shared store takes the
    /// properties of the display `WallpaperPropertyGroups.sharingDisplays` picks.
    func shareDisplayedProperties() {
        let assignments = displayedWallpapers.mapValues { WallpaperInstanceKey($0) }
        for (key, screen) in WallpaperPropertyGroups.sharingDisplays(assignments: assignments, selected: selectedScreenId) {
            settingsIdentity(directory: key.directory)?.share(.display(screen))
        }
    }

    /// The instance `screenId` shows.
    func instanceKey(for screenId: String) -> WallpaperInstanceKey {
        if let previewPropertyScope { return WallpaperInstanceKey(wallpaper(for: screenId), properties: previewPropertyScope) }
        return instanceKeys[screenId] ?? WallpaperInstanceKey(wallpaper(for: screenId))
    }

    /// Whose properties editing `screenId`'s wallpaper changes: the shared store while synced
    /// (and in the Workshop preview, which has no real display), else the display's own.
    /// A display in a clone or stretch edits and runs its source display's.
    func propertyScope(for screenId: String) -> WallpaperPropertyScope {
        if let previewPropertyScope { return previewPropertyScope }
        return syncsPropertiesAcrossDisplays || !persistsWallpapers ? .shared : .display(layoutResolution.source(of: screenId))
    }

    /// The scopes an edit of `wallpaper`'s properties in the sidebar or inspector goes to: the
    /// selected display's, then those of the other selected displays showing it. The first is shown.
    func editedPropertyScopes(of wallpaper: WEWallpaper) -> [WallpaperPropertyScope] {
        let others = selectedScreenIds.sorted().filter {
            $0 != selectedScreenId && self.wallpaper(for: $0).wallpaperDirectory == wallpaper.wallpaperDirectory
        }
        var scopes: [WallpaperPropertyScope] = []
        for screen in [selectedScreenId] + others where !screen.isEmpty {
            let scope = propertyScope(for: screen)
            if !scopes.contains(scope) { scopes.append(scope) }
        }
        return scopes.isEmpty ? [.shared] : scopes
    }

    /// Regroups the displays by their properties. Each display showing a wallpaper with properties
    /// unsynced gets its own store, started from the shared one (`WallpaperSettingsIdentity.seed`).
    func refreshInstanceKeys() {
        let synced = syncsPropertiesAcrossDisplays || !persistsWallpapers
        let assignments = displayedWallpapers.mapValues { WallpaperInstanceKey($0) }
        var keys = WallpaperPropertyGroups.instanceKeys(assignments: assignments, synced: synced) { [self] key, scope in
            guard let identity = settingsIdentity(directory: key.directory) else { return [:] }
            identity.seed(scope)
            return identity.stored(.userProperties, scope: scope) as? [String: String] ?? [:]
        }
        // A clone or a stretch runs once: its members show their source display's instance,
        // whatever their own properties (WE renders a clone or a span once).
        for (member, source) in layoutResolution.sources {
            if let key = keys[source] { keys[member] = key }
        }
        if keys != instanceKeys { instanceKeys = keys }
    }

    /// The settings identity of the wallpaper in `directory`, resolved once; nil for a folder
    /// without a project.json (the placeholder), which has no properties.
    private func settingsIdentity(directory: String) -> WallpaperSettingsIdentity? {
        if let identity = settingsIdentities[directory] { return identity }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        guard WEProject.exists(in: url) else { return nil }
        let identity = WallpaperSettingsIdentity.resolve(directory: url)
        settingsIdentities[directory] = identity
        return identity
    }

    /// Whether `screenId`'s view of its wallpaper plays the sound, for wallpapers that keep a view
    /// per display (web): only the one on the wallpaper's audible display does.
    func shouldPlayAudio(on screenId: String) -> Bool {
        guard audioOutputEnabled else { return false }
        guard persistsWallpapers else { return true }
        let key = WallpaperInstanceKey(wallpaper(for: screenId))
        let audible = WallpaperAudioRouting.audibleScreen(
            of: key, assignments: displayedWallpapers.mapValues { WallpaperInstanceKey($0) },
            enabledScreens: audibleCandidates(of: key), mainScreen: NSScreen.main.map(Self.screenId(for:)))
        return audible == screenId
    }

    /// Turns wallpapers on `screenId` (a display, or the display a region is on) on or off.
    func toggleScreen(_ id: String) {
        let screenId = DisplayLayoutResolution.screen(of: id)
        if enabledScreens.contains(screenId) {
            enabledScreens.remove(screenId)
        } else {
            enabledScreens.insert(screenId)
        }
        onScreenEnabledChange?(screenId)
    }

    /// Turns wallpapers on for the displays in `connected` never connected before, and remembers
    /// them; a display seen before keeps its choice. Returns the displays turned on.
    @discardableResult
    func enableNewDisplays(_ connected: Set<String>) -> Set<String> {
        let new = knownDisplays.recordConnected(connected)
        guard !new.isEmpty else { return [] }
        enabledScreens.formUnion(new)
        if persistsWallpapers { knownDisplays.save(to: .app) }
        return new
    }

    /// Remove a wallpaper from all screens (e.g., when unsubscribing).
    func removeWallpaperFromAllScreens(directory: URL) {
        // One assignment: each change saves and refreshes the instances.
        let shown = wallpapers.filter { $0.value.wallpaperDirectory == directory }.keys
        guard !shown.isEmpty else { return }
        var updated = wallpapers
        for key in shown { updated[key] = Self.defaultWallpaper }
        wallpapers = updated
    }
}
