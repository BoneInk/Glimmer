import Foundation

/// Something that already uses a shortcut being assigned to a playlist, a hotkey action, a
/// wallpaper or a display profile.
enum GlobalShortcutConflict: Equatable {
    /// Another playlist's shortcut.
    case playlist(id: UUID, name: String)
    /// A hotkey action's shortcut (Settings › General › Hotkeys).
    case action(GlobalHotKeyAction)
    /// A wallpaper's or a display profile's hotkey (`UserHotKey`); `title` names what it loads.
    case userHotKey(id: UUID, title: String, isProfile: Bool)
    /// One of this app's menu shortcuts (`AppShortcut.all`).
    case appMenu(AppShortcut.Name)
    /// A macOS shortcut: a symbolic hotkey or a standard menu shortcut. Nil name: one this app
    /// can't name.
    case macOS(name: LocalizedStringResource?)
    /// `RegisterEventHotKey` said the shortcut exists: another app holds it.
    case anotherApp

    static func == (lhs: GlobalShortcutConflict, rhs: GlobalShortcutConflict) -> Bool {
        switch (lhs, rhs) {
        case let (.playlist(a, x), .playlist(b, y)): return a == b && x == y
        case let (.action(a), .action(b)): return a == b
        case let (.userHotKey(a, x, p), .userHotKey(b, y, q)): return a == b && x == y && p == q
        case let (.appMenu(a), .appMenu(b)): return a == b
        case let (.macOS(a), .macOS(b)): return a?.key == b?.key
        case (.anotherApp, .anotherApp): return true
        default: return false
        }
    }

    /// One sentence for the warning alert, naming the conflict and what Use Anyway does about it,
    /// for a shortcut being given to a playlist.
    var message: String { message(forHotKey: false) }

    /// `message`, for a shortcut being given to a playlist or, with `forHotKey`, to a hotkey: an
    /// action's, a wallpaper's or a display profile's.
    func message(forHotKey: Bool) -> String {
        switch self {
        case let .playlist(_, name):
            return forHotKey
                ? String(localized: "The playlist \u{201C}\(name)\u{201D} uses this shortcut. Use Anyway moves it to this hotkey.")
                : String(localized: "The playlist \u{201C}\(name)\u{201D} uses this shortcut. Use Anyway moves it to this playlist.")
        case let .action(action):
            let title = String(localized: action.title)
            return forHotKey
                ? String(localized: "The hotkey \u{201C}\(title)\u{201D} uses this shortcut. Use Anyway moves it to this hotkey.")
                : String(localized: "The hotkey \u{201C}\(title)\u{201D} uses this shortcut. Use Anyway moves it to this playlist.")
        case let .userHotKey(_, title, isProfile):
            let what = isProfile
                ? String(localized: "The profile \u{201C}\(title)\u{201D} uses this shortcut as its hotkey.", comment: "Hotkey conflict, first sentence: a display profile's hotkey has the shortcut being assigned")
                : String(localized: "The wallpaper \u{201C}\(title)\u{201D} uses this shortcut as its hotkey.", comment: "Hotkey conflict, first sentence: a wallpaper's hotkey has the shortcut being assigned")
            let useAnyway = forHotKey
                ? String(localized: "Use Anyway moves it to this hotkey.", comment: "Hotkey conflict, second sentence, after one naming what has the shortcut")
                : String(localized: "Use Anyway moves it to this playlist.", comment: "Hotkey conflict, second sentence, after one naming what has the shortcut")
            return what + " " + useAnyway
        case let .appMenu(name):
            let title = String(localized: AppShortcut[name].title)
            return forHotKey
                ? String(localized: "The menu command \u{201C}\(title)\u{201D} uses this shortcut. Use Anyway gives it to this hotkey, and the menu command no longer responds to it.")
                : String(localized: "The menu command \u{201C}\(title)\u{201D} uses this shortcut. Use Anyway gives it to this playlist, and the menu command no longer responds to it.")
        case let .macOS(name?):
            let title = String(localized: name)
            return String(localized: "macOS uses this shortcut for \u{201C}\(title)\u{201D}. Use Anyway saves it and opens Keyboard Shortcuts in System Settings, where you can turn the macOS one off.")
        case .macOS(nil):
            return String(localized: "This is a macOS shortcut. Use Anyway saves it and opens Keyboard Shortcuts in System Settings, where you can turn the macOS one off.")
        case .anotherApp:
            return String(localized: "Another app uses this shortcut. Use Anyway saves it, but it may not work while that app holds it.")
        }
    }
}

/// Finds what already uses a shortcut. The sources are injected so tests can supply them.
struct GlobalShortcutConflictFinder {
    var appShortcuts: [AppShortcut] = AppShortcut.all
    /// The user's enabled symbolic hotkeys, read when asked (the user may change them any time).
    var symbolicHotKeys: () -> [MacOSShortcut] = { MacOSShortcuts.symbolicHotKeys() }
    var standardShortcuts: [MacOSShortcut] = MacOSShortcuts.standard

    /// What `shortcut` conflicts with as the playlist `playlistID`'s, in-app first, macOS after.
    /// `RegisterEventHotKey`'s answer (another app) is the caller's: only a registration can tell.
    func conflicts(for shortcut: GlobalShortcut, playlistID: UUID, playlists: [WallpaperPlaylist],
                   hotKeys: GlobalHotKeyBindings = GlobalHotKeyBindings(),
                   userHotKeys: [UserHotKey] = []) -> [GlobalShortcutConflict] {
        conflicts(for: shortcut, owner: .playlist(playlistID), playlists: playlists, hotKeys: hotKeys,
                  userHotKeys: userHotKeys)
    }

    /// What `shortcut` conflicts with as `action`'s hotkey. The menu command that does the same as
    /// the action (`GlobalHotKeyAction.menuCommand`) is no conflict.
    func conflicts(for shortcut: GlobalShortcut, action: GlobalHotKeyAction, playlists: [WallpaperPlaylist],
                   hotKeys: GlobalHotKeyBindings, userHotKeys: [UserHotKey] = []) -> [GlobalShortcutConflict] {
        conflicts(for: shortcut, owner: .action(action), playlists: playlists, hotKeys: hotKeys, userHotKeys: userHotKeys)
    }

    /// What `shortcut` conflicts with as the hotkey for `target`; `id` is that hotkey's when it
    /// has one already, which is no conflict.
    func conflicts(for shortcut: GlobalShortcut, userHotKey id: UUID?, target: UserHotKey.Target,
                   playlists: [WallpaperPlaylist], hotKeys: GlobalHotKeyBindings,
                   userHotKeys: [UserHotKey]) -> [GlobalShortcutConflict] {
        // The target's own hotkey, which this one replaces, is no conflict either.
        let replaced = userHotKeys.filter { $0.id == id || $0.target == target }.map(\.id)
        return conflicts(for: shortcut, owner: .user(Set(replaced)), playlists: playlists, hotKeys: hotKeys,
                         userHotKeys: userHotKeys)
    }

    private enum Owner: Equatable {
        case playlist(UUID)
        case action(GlobalHotKeyAction)
        /// A wallpaper's or profile's hotkey, replacing these.
        case user(Set<UUID>)
    }

    private func conflicts(for shortcut: GlobalShortcut, owner: Owner, playlists: [WallpaperPlaylist],
                           hotKeys: GlobalHotKeyBindings, userHotKeys: [UserHotKey]) -> [GlobalShortcutConflict] {
        var conflicts: [GlobalShortcutConflict] = []
        for playlist in playlists where owner != .playlist(playlist.id) && playlist.shortcut == shortcut {
            conflicts.append(.playlist(id: playlist.id, name: playlist.name))
        }
        for action in GlobalHotKeyAction.allCases where owner != .action(action) && hotKeys[action] == shortcut {
            conflicts.append(.action(action))
        }
        for hotKey in userHotKeys where hotKey.shortcut == shortcut {
            if case let .user(replaced) = owner, replaced.contains(hotKey.id) { continue }
            conflicts.append(.userHotKey(id: hotKey.id, title: hotKey.title, isProfile: hotKey.isProfile))
        }
        for app in appShortcuts where shortcut.matches(key: app.key, modifiers: app.modifiers) {
            if case let .action(action) = owner, action.menuCommand == app.name { continue }
            conflicts.append(.appMenu(app.name))
        }
        // One macOS conflict is enough; a named one beats an unnamed one.
        let macOS = (symbolicHotKeys() + standardShortcuts).filter { $0.matches(shortcut) }
        if let named = macOS.first(where: { $0.name != nil }) {
            conflicts.append(.macOS(name: named.name))
        } else if !macOS.isEmpty {
            conflicts.append(.macOS(name: nil))
        }
        return conflicts
    }
}
