import AppKit

/// The system desktop picture of each display on the current Space (`DesktopPictureSync`); tests
/// pass their own.
@MainActor
protocol DesktopPictureSetting: AnyObject {
    /// The picture `display` shows on the current Space.
    func picture(for display: CGDirectDisplayID) -> URL?
    /// Sets the picture of `display` on the current Space (macOS has no call for the others).
    /// `ownPicture` is one of OWE's, drawn at the display's size: it fills, on black.
    func setPicture(_ url: URL, for display: CGDirectDisplayID, ownPicture: Bool) throws
}

/// The desktop pictures through `NSWorkspace`.
@MainActor
final class SystemDesktopPictures: DesktopPictureSetting {
    private func screen(_ display: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { DesktopSnapshotCache.displayID($0) == display }
    }

    func picture(for display: CGDirectDisplayID) -> URL? {
        screen(display).flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
    }

    func setPicture(_ url: URL, for display: CGDirectDisplayID, ownPicture: Bool) throws {
        guard let screen = screen(display) else { return }
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = ownPicture ? [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
            .fillColor: NSColor.black,
        ] : [:]
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
    }
}
