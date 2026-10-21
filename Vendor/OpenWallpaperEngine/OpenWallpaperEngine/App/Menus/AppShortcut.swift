import AppKit
import SwiftUI

/// A keyboard shortcut of the app's menus. The menus, the help tooltips and the list in
/// Settings › General › Keyboard Shortcuts all read `AppShortcut.all`, so they can't disagree.
///
/// The shortcuts follow the macOS Human Interface Guidelines: the standard ones keep their
/// standard keys, and the app's own use ⌥⌘ or ⇧⌘ combinations macOS doesn't reserve.
struct AppShortcut: Identifiable, Equatable {
    enum Name: String, CaseIterable {
        case settings, hide, hideOthers, quit, checkForUpdates
        case importFolder, closeWindow
        case undo, redo, cut, copy, paste, selectAll, find
        case installed, workshop, downloads, playlists, showFilters, fullScreen
        case pauseResume, muteUnmute, nextWallpaper, previousWallpaper
        case minimize, wallpaperExplorer, sceneInspector, wallpaperEditor
        case help
    }

    /// The menu a shortcut lives in, for the grouped list in Settings.
    enum Menu: CaseIterable {
        case app, file, edit, view, playback, window, help

        var title: LocalizedStringResource {
            switch self {
            case .app: return "Open Wallpaper Engine"
            case .file: return "File"
            case .edit: return "Edit"
            case .view: return "View"
            case .playback: return "Playback"
            case .window: return "Window"
            case .help: return "Help"
            }
        }
    }

    let name: Name
    let title: LocalizedStringResource
    let menu: Menu
    /// The key as `NSMenuItem.keyEquivalent` takes it (lowercase letters; arrows as their
    /// function-key characters).
    let key: String
    let modifiers: NSEvent.ModifierFlags

    var id: Name { name }

    static func == (lhs: AppShortcut, rhs: AppShortcut) -> Bool { lhs.name == rhs.name }

    /// The shortcut as menus print it, e.g. "⌥⌘P".
    var symbols: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)): text += "←"
        case String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)): text += "→"
        default: text += key.uppercased()
        }
        return text
    }

    /// `symbols` split into its keys, modifiers first (⌥, ⌘, U).
    var keys: [String] { symbols.map(String.init) }

    /// A key and its modifiers, to compare shortcuts.
    var combination: String { "\(modifiers.intersection(.deviceIndependentFlagsMask).rawValue)-\(key.lowercased())" }

    private static let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
    private static let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))

    static let all: [AppShortcut] = [
        AppShortcut(name: .settings, title: "Settings…", menu: .app, key: ",", modifiers: .command),
        AppShortcut(name: .checkForUpdates, title: "Check for Updates…", menu: .app, key: "u", modifiers: [.command, .option]),
        AppShortcut(name: .hide, title: "Hide Open Wallpaper Engine", menu: .app, key: "h", modifiers: .command),
        AppShortcut(name: .hideOthers, title: "Hide Others", menu: .app, key: "h", modifiers: [.command, .option]),
        AppShortcut(name: .quit, title: "Quit Open Wallpaper Engine", menu: .app, key: "q", modifiers: .command),

        AppShortcut(name: .importFolder, title: "Import Wallpaper from Folder…", menu: .file, key: "i", modifiers: .command),
        AppShortcut(name: .closeWindow, title: "Close Window", menu: .file, key: "w", modifiers: .command),

        AppShortcut(name: .undo, title: "Undo", menu: .edit, key: "z", modifiers: .command),
        AppShortcut(name: .redo, title: "Redo", menu: .edit, key: "z", modifiers: [.command, .shift]),
        AppShortcut(name: .cut, title: "Cut", menu: .edit, key: "x", modifiers: .command),
        AppShortcut(name: .copy, title: "Copy", menu: .edit, key: "c", modifiers: .command),
        AppShortcut(name: .paste, title: "Paste", menu: .edit, key: "v", modifiers: .command),
        AppShortcut(name: .selectAll, title: "Select All", menu: .edit, key: "a", modifiers: .command),
        AppShortcut(name: .find, title: "Find…", menu: .edit, key: "f", modifiers: .command),

        AppShortcut(name: .installed, title: "Installed", menu: .view, key: "1", modifiers: .command),
        AppShortcut(name: .workshop, title: "Workshop", menu: .view, key: "2", modifiers: .command),
        AppShortcut(name: .downloads, title: "Downloads", menu: .view, key: "3", modifiers: .command),
        AppShortcut(name: .playlists, title: "Playlists", menu: .view, key: "4", modifiers: .command),
        AppShortcut(name: .showFilters, title: "Show Filter Results", menu: .view, key: "s", modifiers: [.command, .control]),
        AppShortcut(name: .fullScreen, title: "Enter Full Screen", menu: .view, key: "f", modifiers: [.command, .control]),

        AppShortcut(name: .pauseResume, title: "Pause or Resume Wallpapers", menu: .playback, key: "p", modifiers: [.command, .option]),
        AppShortcut(name: .muteUnmute, title: "Mute or Unmute", menu: .playback, key: "m", modifiers: [.command, .shift]),
        AppShortcut(name: .nextWallpaper, title: "Next Wallpaper in Playlist", menu: .playback, key: right, modifiers: [.command, .option]),
        AppShortcut(name: .previousWallpaper, title: "Previous Wallpaper in Playlist", menu: .playback, key: left, modifiers: [.command, .option]),

        AppShortcut(name: .minimize, title: "Minimize", menu: .window, key: "m", modifiers: .command),
        AppShortcut(name: .wallpaperExplorer, title: "Wallpaper Explorer", menu: .window, key: "1", modifiers: [.command, .shift]),
        AppShortcut(name: .sceneInspector, title: "Scene Edit / Export", menu: .window, key: "i", modifiers: [.command, .option]),
        AppShortcut(name: .wallpaperEditor, title: "Wallpaper Editor", menu: .window, key: "e", modifiers: [.command, .option]),

        AppShortcut(name: .help, title: "Open Wallpaper Engine Help", menu: .help, key: "?", modifiers: .command),
    ]

    static subscript(_ name: Name) -> AppShortcut {
        all.first { $0.name == name }!
    }

    /// Shortcuts macOS itself uses system-wide (Spotlight, screenshots, app switching, lock
    /// screen, Mission Control…). No app shortcut may take one.
    static let reservedBySystem: [(key: String, modifiers: NSEvent.ModifierFlags)] = [
        (" ", .command), (" ", [.command, .option]), (" ", [.command, .control]),
        ("\t", .command), ("\t", [.command, .shift]), ("`", .command),
        ("3", [.command, .shift]), ("4", [.command, .shift]), ("5", [.command, .shift]), ("6", [.command, .shift]),
        ("q", [.command, .control]), ("q", [.command, .shift]), ("q", [.command, .shift, .option]),
        ("d", [.command, .option]), ("\u{1b}", [.command, .option]), ("f", [.command, .shift, .control]),
        ("t", [.command, .control]), ("n", [.command, .control]), (" ", [.control]),
        ("h", [.command, .option, .shift]), ("m", [.command, .option]), ("w", [.command, .option]),
    ]
}

extension NSMenuItem {
    /// A menu item with a shortcut from `AppShortcut.all`.
    convenience init(_ shortcut: AppShortcut, action: Selector?, target: AnyObject? = nil) {
        self.init(title: String(localized: shortcut.title), action: action, keyEquivalent: shortcut.key)
        keyEquivalentModifierMask = shortcut.modifiers
        self.target = target
    }

    /// Gives an item the key and modifiers of `shortcut`, keeping its title.
    func use(_ shortcut: AppShortcut) {
        keyEquivalent = shortcut.key
        keyEquivalentModifierMask = shortcut.modifiers
    }
}

extension View {
    /// A tooltip that names the action and its keyboard shortcut, e.g. "Scene Edit / Export (⌥⌘I)".
    func help(_ title: LocalizedStringKey, shortcut name: AppShortcut.Name) -> some View {
        help(Text("\(Text(title)) (\(AppShortcut[name].symbols))",
                  comment: "A tooltip: an action followed by its keyboard shortcut, e.g. Scene Edit / Export (⌥⌘I)"))
    }
}
