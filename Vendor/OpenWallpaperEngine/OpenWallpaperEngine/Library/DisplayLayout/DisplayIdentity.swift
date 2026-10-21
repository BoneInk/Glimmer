import AppKit

/// A connected display: its id (`CGDirectDisplayID` as a string, what per-display wallpapers and
/// settings are keyed by), its identity, the UUID macOS derives from the display's vendor, model
/// and serial number, which stays the same across reboots, reconnections and ports, as WE's
/// "Device Path" monitor identification does, and its desktop rect. Display layouts name displays
/// by identity.
struct DisplayIdentity: Hashable {
    let screenId: String
    let identity: String
    /// The display's rect on the desktop in global points (AppKit's, origin bottom-left): what a
    /// stretch's canvas and a split's regions are measured in.
    var frame: CGRect = .zero

    func hash(into hasher: inout Hasher) {
        hasher.combine(screenId)
        hasher.combine(identity)
    }

    /// The connected displays, the main display (the one with the menu bar) first.
    @MainActor
    static func connected() -> [DisplayIdentity] {
        NSScreen.screens.map { screen in
            let screenId = WallpaperViewModel.screenId(for: screen)
            return DisplayIdentity(screenId: screenId, identity: identity(of: CGDirectDisplayID(screenId) ?? 0),
                                   frame: screen.frame)
        }
    }

    /// `display`'s UUID; its id when macOS has none for it (a virtual display).
    static func identity(of display: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) as String? else { return "display-\(display)" }
        return string
    }
}
