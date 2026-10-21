import Foundation

/// The wallpapers each display was set to, newest last, so Previous can walk back through them.
/// The top of a display's stack is the wallpaper it shows; going back drops it and returns the
/// one below.
struct WallpaperHistory: Codable, Equatable {
    static let capacity = 20

    private(set) var stacks: [String: [WEWallpaper]] = [:]

    static func == (lhs: WallpaperHistory, rhs: WallpaperHistory) -> Bool {
        lhs.stacks.mapValues { $0.map(\.identityPath) } == rhs.stacks.mapValues { $0.map(\.identityPath) }
    }

    /// Records `wallpaper` as set on `screenId`. Setting the wallpaper already on top does nothing.
    mutating func push(_ wallpaper: WEWallpaper, for screenId: String) {
        guard wallpaper.project != .invalid else { return }
        var stack = stacks[screenId] ?? []
        if stack.last?.isSameWallpaper(as: wallpaper) == true { return }
        stack.append(wallpaper)
        if stack.count > Self.capacity { stack.removeFirst(stack.count - Self.capacity) }
        stacks[screenId] = stack
    }

    /// The wallpaper `back(for:showing:)` would return.
    func previous(for screenId: String, showing current: WEWallpaper) -> WEWallpaper? {
        Self.trimmed(stacks[screenId] ?? [], showing: current).last
    }

    /// Drops what `screenId` shows and returns the wallpaper before it, which becomes the top.
    mutating func back(for screenId: String, showing current: WEWallpaper) -> WEWallpaper? {
        let stack = Self.trimmed(stacks[screenId] ?? [], showing: current)
        stacks[screenId] = stack
        return stack.last
    }

    /// The stack without the entries for the wallpaper shown now.
    private static func trimmed(_ stack: [WEWallpaper], showing current: WEWallpaper) -> [WEWallpaper] {
        var stack = stack
        while stack.last?.isSameWallpaper(as: current) == true { stack.removeLast() }
        return stack
    }
}

extension WallpaperHistory {
    private static let defaultsKey = "WallpaperHistory"

    /// The saved history in `defaults` (`UserDefaults.app`, isolated per `AppStorageLocation`).
    static func load(from defaults: UserDefaults) -> WallpaperHistory {
        guard let data = defaults.data(forKey: defaultsKey) else { return WallpaperHistory() }
        do {
            return try JSONDecoder().decode(WallpaperHistory.self, from: data)
        } catch {
            OWELog.error(.library, "Reading the wallpaper history failed: \(error)")
            return WallpaperHistory()
        }
    }

    func save(to defaults: UserDefaults) {
        do {
            defaults.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey)
        } catch {
            OWELog.error(.library, "Saving the wallpaper history failed: \(error)")
        }
    }
}
