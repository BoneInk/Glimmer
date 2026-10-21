import Foundation

/// A command with a system-wide hotkey, as Wallpaper Engine's Settings › Hotkeys lists them
/// (`ui_settings_hotkeys_action_*`; the raw values are the `action` names WE stores in its
/// `hotkeys` config). Wallpapers, playlists and profiles get their own hotkeys elsewhere (playlists:
/// `PlaylistShortcutController`; wallpapers and profiles: `UserHotKeyController`).
///
/// Added: Previous Wallpaper, which the app's menus already have.
enum GlobalHotKeyAction: String, CaseIterable, Identifiable, Codable {
    case pause
    case stop
    case mute
    case nextWallpaper = "nextwallpaper"
    case previousWallpaper = "previouswallpaper"
    case toggleRecording = "togglerecord"
    case toggleIcons = "toggleicons"
    case screenshot
    case startScreensaver = "screensaver"
    case windowBrowser = "windowbrowser"
    case windowSettings = "windowsettings"
    case windowEditor = "windoweditor"

    var id: Self { self }

    /// WE's groups of the list, in its order.
    enum Group: CaseIterable {
        case playback, general, windows

        var title: LocalizedStringResource {
            switch self {
            case .playback: return LocalizedStringResource("Playback", comment: "Hotkeys group: pause, mute, next wallpaper")
            case .general: return LocalizedStringResource("General", comment: "Hotkeys group: audio recording, desktop icons, screenshot, screen saver")
            case .windows: return LocalizedStringResource("Windows", comment: "Hotkeys group: commands that open the app's windows")
            }
        }

        var actions: [GlobalHotKeyAction] { GlobalHotKeyAction.allCases.filter { $0.group == self } }
    }

    var group: Group {
        switch self {
        case .pause, .stop, .mute, .nextWallpaper, .previousWallpaper: return .playback
        case .toggleRecording, .toggleIcons, .screenshot, .startScreensaver: return .general
        case .windowBrowser, .windowSettings, .windowEditor: return .windows
        }
    }

    /// WE's label for the action.
    var title: LocalizedStringResource {
        switch self {
        case .pause: return LocalizedStringResource("Pause wallpapers", comment: "Hotkey action: pauses or resumes every wallpaper")
        case .stop: return LocalizedStringResource("Stop wallpapers", comment: "Hotkey action: stops every wallpaper (unloads them, freeing memory, and shows the desktop picture), or loads them again")
        case .mute: return LocalizedStringResource("Mute wallpapers", comment: "Hotkey action: mutes or unmutes every wallpaper")
        case .nextWallpaper: return LocalizedStringResource("Next wallpaper", comment: "Hotkey action")
        case .previousWallpaper: return LocalizedStringResource("Previous wallpaper", comment: "Hotkey action")
        case .toggleRecording: return LocalizedStringResource("Toggle audio recording", comment: "Hotkey action: turns the system audio capture for audio-reactive wallpapers on or off")
        case .toggleIcons: return LocalizedStringResource("Hide desktop icons", comment: "Hotkey action: shows the wallpaper above the desktop icons, or below them again")
        case .screenshot: return LocalizedStringResource("Take screenshot", comment: "Hotkey action: saves a picture of the current wallpaper")
        case .startScreensaver: return LocalizedStringResource("Start screensaver", comment: "Hotkey action")
        case .windowBrowser: return LocalizedStringResource("Browse wallpapers", comment: "Hotkey action: opens the main window")
        case .windowSettings: return LocalizedStringResource("Settings", comment: "Hotkey action: opens the Settings window")
        case .windowEditor: return LocalizedStringResource("Wallpaper Editor", comment: "Hotkey action: opens the displayed wallpaper in the Wallpaper Editor")
        }
    }

    /// The menu command that does the same, whose shortcut is therefore no conflict.
    var menuCommand: AppShortcut.Name? {
        switch self {
        case .pause: return .pauseResume
        case .mute: return .muteUnmute
        case .nextWallpaper: return .nextWallpaper
        case .previousWallpaper: return .previousWallpaper
        case .windowBrowser: return .wallpaperExplorer
        case .windowSettings: return .settings
        case .windowEditor: return .wallpaperEditor
        case .stop, .toggleRecording, .toggleIcons, .screenshot, .startScreensaver: return nil
        }
    }
}

/// The hotkey of every action that has one, as stored in `UserDefaults.app` (`GlobalHotKeys`).
/// None by default, as in WE.
struct GlobalHotKeyBindings: Codable, Equatable {
    var shortcuts: [GlobalHotKeyAction: GlobalShortcut] = [:]

    static let defaultsKey = "GlobalHotKeys"

    init(shortcuts: [GlobalHotKeyAction: GlobalShortcut] = [:]) {
        self.shortcuts = shortcuts
    }

    subscript(action: GlobalHotKeyAction) -> GlobalShortcut? {
        get { shortcuts[action] }
        set { shortcuts[action] = newValue }
    }

    /// Stored as `{action: shortcut}`, read entry by entry: an unknown action or an unreadable
    /// shortcut is dropped and logged, and the others are kept.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        for key in container.allKeys {
            guard let action = GlobalHotKeyAction(rawValue: key.stringValue) else {
                OWELog.error(.settings, "Hotkey for unknown action \(key.stringValue) dropped")
                continue
            }
            do {
                shortcuts[action] = try container.decode(GlobalShortcut.self, forKey: key)
            } catch {
                OWELog.error(.settings, "Hotkey for \(action.rawValue) can't be read and is dropped: \(error)")
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        for (action, shortcut) in shortcuts {
            try container.encode(shortcut, forKey: AnyKey(stringValue: action.rawValue))
        }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// The bindings stored in `defaults`; none when nothing or nothing readable is stored.
    static func load(from defaults: UserDefaults) -> GlobalHotKeyBindings {
        guard let data = defaults.data(forKey: defaultsKey) else { return GlobalHotKeyBindings() }
        do {
            return try JSONDecoder().decode(GlobalHotKeyBindings.self, from: data)
        } catch {
            OWELog.error(.settings, "Hotkeys can't be read; none are set: \(error)")
            return GlobalHotKeyBindings()
        }
    }

    func save(to defaults: UserDefaults) {
        do {
            defaults.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey)
        } catch {
            OWELog.error(.settings, "Hotkeys can't be saved: \(error)")
        }
    }
}
