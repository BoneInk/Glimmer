import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut, as a playlist stores it: the physical key, the character it
/// types with no modifiers (to compare with menu key equivalents) and the modifiers.
struct GlobalShortcut: Codable, Hashable {
    /// The virtual key code (`kVK_…`), what Carbon registers and the symbolic hotkeys list.
    var keyCode: UInt16
    /// The character the key types without modifiers, lowercased, as `NSMenuItem.keyEquivalent`
    /// takes it (arrows as their function-key characters).
    var key: String
    /// Raw `NSEvent.ModifierFlags`, only ⌃ ⌥ ⇧ ⌘.
    var modifierFlags: UInt

    static let modifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(keyCode: UInt16, key: String, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.key = key.lowercased()
        self.modifierFlags = modifiers.intersection(Self.modifierMask).rawValue
    }

    /// The shortcut a key press makes; nil for a press with no key character.
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let key = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
        guard !key.isEmpty else { return nil }
        self.init(keyCode: event.keyCode, key: key, modifiers: event.modifierFlags)
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }

    /// A global shortcut needs ⌘, ⌥ or ⌃; ⇧ alone would take a character from every app.
    var isValid: Bool { !modifiers.intersection([.command, .option, .control]).isEmpty }

    /// The modifiers as Carbon's `RegisterEventHotKey` takes them.
    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    /// Whether this is `key` with `modifiers`, compared the way menus compare key equivalents.
    func matches(key other: String, modifiers otherModifiers: NSEvent.ModifierFlags) -> Bool {
        key == other.lowercased() && modifiers == otherModifiers.intersection(Self.modifierMask)
    }

    /// Whether this is `keyCode` with `modifiers` (the symbolic hotkeys' form).
    func matches(keyCode other: UInt16, modifiers otherModifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == other && modifiers == otherModifiers.intersection(Self.modifierMask)
    }

    /// The keys as menus print them, modifiers first in Apple's order: ⌃ ⌥ ⇧ ⌘ then the key.
    var keys: [String] {
        var keys: [String] = []
        if modifiers.contains(.control) { keys.append("⌃") }
        if modifiers.contains(.option) { keys.append("⌥") }
        if modifiers.contains(.shift) { keys.append("⇧") }
        if modifiers.contains(.command) { keys.append("⌘") }
        keys.append(Self.keyNames[Int(keyCode)] ?? key.uppercased())
        return keys
    }

    /// The shortcut as menus print it, e.g. "⇧⌘1".
    var symbols: String { keys.joined() }

    private static let keyNames: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "␣", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓",
        kVK_UpArrow: "↑", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_ANSI_KeypadEnter: "⌤",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
}
