import AppKit
import Carbon.HIToolbox

/// A shortcut macOS uses: one of the user's enabled symbolic hotkeys (System Settings › Keyboard ›
/// Keyboard Shortcuts) or a standard menu shortcut every app shares.
struct MacOSShortcut: Equatable {
    /// What System Settings calls it; nil when the id isn't one this app knows.
    var name: LocalizedStringResource?
    /// Set for symbolic hotkeys, which name the physical key.
    var keyCode: UInt16?
    /// Set for menu shortcuts, which name the character.
    var key: String?
    var modifiers: NSEvent.ModifierFlags

    static func == (lhs: MacOSShortcut, rhs: MacOSShortcut) -> Bool {
        lhs.name?.key == rhs.name?.key && lhs.keyCode == rhs.keyCode && lhs.key == rhs.key
            && lhs.modifiers == rhs.modifiers
    }

    func matches(_ shortcut: GlobalShortcut) -> Bool {
        if let keyCode { return shortcut.matches(keyCode: keyCode, modifiers: modifiers) }
        if let key { return shortcut.matches(key: key, modifiers: modifiers) }
        return false
    }
}

enum MacOSShortcuts {
    /// Where macOS keeps the user's symbolic hotkeys.
    static var symbolicHotKeysURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Preferences/com.apple.symbolichotkeys.plist")
    }

    /// The enabled symbolic hotkeys in the plist at `url`; none when it can't be read.
    static func symbolicHotKeys(at url: URL = symbolicHotKeysURL) -> [MacOSShortcut] {
        // No plist: no system shortcuts set. One that can't be read logs once.
        guard let plist = OWELog.attempt(.app, "macOS shortcuts: \(url.lastPathComponent)", quietIfMissing: true, {
            try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        }) as? [String: Any] else { return [] }
        return symbolicHotKeys(from: plist)
    }

    /// The enabled entries of `AppleSymbolicHotKeys`. Each is
    /// `{enabled, value: {parameters: [character, keyCode, modifierFlags], type}}`; a key code of
    /// 65535 means no key is assigned.
    static func symbolicHotKeys(from plist: [String: Any]) -> [MacOSShortcut] {
        guard let hotKeys = plist["AppleSymbolicHotKeys"] as? [String: Any] else { return [] }
        return hotKeys.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.compactMap { id in
            guard let entry = hotKeys[id] as? [String: Any],
                  (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3 else { return nil }
            let keyCode = parameters[1].intValue
            guard keyCode >= 0, keyCode < 0xFFFF else { return nil }
            let modifiers = NSEvent.ModifierFlags(rawValue: UInt(parameters[2].uint64Value))
                .intersection(GlobalShortcut.modifierMask)
            return MacOSShortcut(name: Int(id).flatMap(name(ofSymbolicHotKey:)),
                                 keyCode: UInt16(keyCode), key: nil, modifiers: modifiers)
        }
    }

    /// What System Settings › Keyboard Shortcuts calls a symbolic hotkey, by its id.
    static func name(ofSymbolicHotKey id: Int) -> LocalizedStringResource? {
        switch id {
        case 7, 8, 9, 10, 11, 12, 13, 27, 57, 98: return "Keyboard Navigation"
        case 15...26: return "Accessibility"
        case 28, 29, 30, 31, 184: return "Screenshots"
        case 32, 34: return "Mission Control"
        case 33, 35: return "Application Windows"
        case 36, 37: return "Show Desktop"
        case 52: return "Turn Dock Hiding On/Off"
        case 60, 61: return "Input Sources"
        case 64, 65: return "Spotlight"
        case 79, 80, 81, 82: return "Move Between Spaces"
        case 118...133: return "Switch to a Desktop"
        case 160: return "Launchpad"
        case 163: return "Notification Center"
        case 175: return "Do Not Disturb"
        case 190: return "Quick Note"
        default: return nil
        }
    }

    /// Shortcuts every Mac app's menus share, and the ones macOS keeps for itself (app switching,
    /// Force Quit, lock screen…), which no symbolic hotkey lists.
    static let standard: [MacOSShortcut] = [
        menu("Quit", "q", .command),
        menu("Close Window", "w", .command),
        menu("Hide", "h", .command),
        menu("Hide Others", "h", [.command, .option]),
        menu("Minimize", "m", .command),
        menu("New", "n", .command),
        menu("Open", "o", .command),
        menu("Save", "s", .command),
        menu("Print", "p", .command),
        menu("Undo", "z", .command),
        menu("Redo", "z", [.command, .shift]),
        menu("Cut", "x", .command),
        menu("Copy", "c", .command),
        menu("Paste", "v", .command),
        menu("Select All", "a", .command),
        menu("Find…", "f", .command),
        menu("Settings…", ",", .command),
        menu("Switch Apps", "\t", .command),
        menu("Switch Apps", "\t", [.command, .shift]),
        menu("Switch Windows", "`", .command),
        menu("Force Quit", "\u{1b}", [.command, .option]),
        menu("Lock Screen", "q", [.command, .control]),
        menu("Log Out", "q", [.command, .shift]),
        menu("Emoji & Symbols", " ", [.command, .control]),
        menu("Enter Full Screen", "f", [.command, .control]),
    ] + AppShortcut.reservedBySystem.map { MacOSShortcut(name: nil, keyCode: nil, key: $0.key, modifiers: $0.modifiers) }

    private static func menu(_ name: LocalizedStringResource, _ key: String,
                             _ modifiers: NSEvent.ModifierFlags) -> MacOSShortcut {
        MacOSShortcut(name: name, keyCode: nil, key: key, modifiers: modifiers)
    }
}
