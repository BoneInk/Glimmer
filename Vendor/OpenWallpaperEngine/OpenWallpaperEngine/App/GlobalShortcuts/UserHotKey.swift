import Foundation

/// A hotkey that loads something the user chose, as Wallpaper Engine's `hotkeys` list keeps them
/// beside the actions': a wallpaper on one display (`action` "wallpaper", assigned from the
/// wallpaper's context menu) or a display profile (`action` "profile", assigned where profiles are
/// saved and loaded). Playlists keep theirs on the playlist (`WallpaperPlaylist.shortcut`).
struct UserHotKey: Codable, Equatable, Identifiable {
    enum Target: Codable, Equatable {
        /// `wallpaper` on the display at `location`: a display's identity (`DisplayIdentity.identity`),
        /// or a split display's region (`<identity>/L`…), as profiles keep displays, so the hotkey
        /// finds its display again whatever id it has now.
        case wallpaper(WEWallpaper, location: String)
        /// The display profile of that name (`DisplayProfiles`).
        case profile(name: String)

        static func == (lhs: Target, rhs: Target) -> Bool {
            switch (lhs, rhs) {
            case let (.wallpaper(a, x), .wallpaper(b, y)): return a.isSameWallpaper(as: b) && x == y
            case let (.profile(a), .profile(b)): return a == b
            default: return false
            }
        }
    }

    var id = UUID()
    var shortcut: GlobalShortcut
    var target: Target

    var isProfile: Bool {
        if case .profile = target { return true }
        return false
    }

    /// What the hotkey loads, as lists and warnings name it: the wallpaper's title or the
    /// profile's name.
    var title: String {
        switch target {
        case let .wallpaper(wallpaper, _): return wallpaper.project.displayTitle
        case let .profile(name): return name
        }
    }
}

extension UserHotKey {
    /// The location (`Target.wallpaper`) of the display or region `screenId`, on the `connected`
    /// displays; nil when its display isn't connected.
    static func location(ofScreen screenId: String, connected: [DisplayIdentity]) -> String? {
        let screen = DisplayLayoutResolution.screen(of: screenId)
        guard let display = connected.first(where: { $0.screenId == screen }) else { return nil }
        return display.identity + screenId.dropFirst(screen.count)
    }

    /// The display or region id of `location` on the `connected` displays; nil when its display
    /// isn't connected.
    static func screenId(ofLocation location: String, connected: [DisplayIdentity]) -> String? {
        let identity = DisplayLayoutConfiguration.display(of: location)
        guard let display = connected.first(where: { $0.identity == identity }) else { return nil }
        return display.screenId + location.dropFirst(identity.count)
    }
}

/// The user's wallpaper and profile hotkeys, stored as JSON in the app's defaults.
enum UserHotKeyStore {
    static let defaultsKey = "UserHotKeys"

    private struct File: Codable {
        var hotKeys: [UserHotKey]

        init(hotKeys: [UserHotKey]) { self.hotKeys = hotKeys }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // One by one, so one that can't be read doesn't drop the others.
            hotKeys = container.decodeElements(UserHotKey.self, forKey: .hotKeys, userInfo: decoder.userInfo) ?? []
        }
    }

    /// The hotkeys stored in `defaults`; none when nothing or nothing readable is stored.
    static func load(from defaults: UserDefaults) -> [UserHotKey] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        do {
            return try JSONDecoder().decode(File.self, from: data).hotKeys
        } catch {
            OWELog.error(.settings, "Wallpaper and profile hotkeys can't be read; none are set: \(error)")
            return []
        }
    }

    static func save(_ hotKeys: [UserHotKey], to defaults: UserDefaults) {
        do {
            defaults.set(try JSONEncoder().encode(File(hotKeys: hotKeys)), forKey: defaultsKey)
        } catch {
            OWELog.error(.settings, "Wallpaper and profile hotkeys can't be saved: \(error)")
        }
    }
}
