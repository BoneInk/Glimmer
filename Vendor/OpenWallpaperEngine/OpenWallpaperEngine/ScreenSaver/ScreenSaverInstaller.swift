import AppKit

/// Installs the bundled screen saver (`Contents/Resources/Open Wallpaper Engine.saver`) into
/// `~/Library/Screen Savers` and removes it again. It never selects the saver: macOS keeps that
/// choice in the user's settings, so OWE only opens the settings that hold the screen savers
/// (`settingsURL`) for the user to pick it.
///
/// An isolated copy (`AppStorageLocation`) never installs or removes it: the saver belongs to the
/// user's session, like the desktop picture (`DesktopSnapshotCache.allowsDesktopPicture`).
struct ScreenSaverInstaller {
    static let saverName = "Open Wallpaper Engine.saver"
    /// System Settings' screen saver choice: its own pane where macOS still has one, else the
    /// Wallpaper pane, which holds the screen savers on newer macOS (no `ScreenSaver.appex`).
    static var settingsURL: URL {
        settingsURL(hasScreenSaverPane: FileManager.default.fileExists(
            atPath: "/System/Library/ExtensionKit/Extensions/ScreenSaver.appex"))
    }

    static func settingsURL(hasScreenSaverPane: Bool) -> URL {
        URL(string: hasScreenSaverPane
            ? "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension"
            : "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!
    }

    let bundledSaver: URL?
    let saversDirectory: URL
    let mayInstall: Bool

    static var current: ScreenSaverInstaller {
        ScreenSaverInstaller(
            bundledSaver: Bundle.main.resourceURL?.appending(path: saverName, directoryHint: .isDirectory),
            saversDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Screen Savers", directoryHint: .isDirectory),
            mayInstall: !AppStorageLocation.current.isIsolated)
    }

    var installedURL: URL { saversDirectory.appending(path: Self.saverName, directoryHint: .isDirectory) }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: installedURL.path(percentEncoded: false)) }

    /// Copies the bundled saver over any installed one. Blocking file IO: call it off the main thread.
    @discardableResult
    func install() -> Bool {
        guard mayInstall else { return false }
        guard let bundledSaver, FileManager.default.fileExists(atPath: bundledSaver.path(percentEncoded: false)) else {
            OWELog.error(.app, "Screen saver: the app has no bundled saver")
            return false
        }
        do {
            try FileManager.default.createDirectory(at: saversDirectory, withIntermediateDirectories: true)
            if isInstalled { try FileManager.default.removeItem(at: installedURL) }
            try FileManager.default.copyItem(at: bundledSaver, to: installedURL)
            OWELog.info(.app, "Screen saver installed in \(saversDirectory.path(percentEncoded: false))")
            return true
        } catch {
            OWELog.error(.app, "Screen saver: install failed: \(error)")
            return false
        }
    }

    /// Removes the installed saver. Blocking file IO: call it off the main thread.
    func uninstall() {
        guard mayInstall, isInstalled else { return }
        do {
            try FileManager.default.removeItem(at: installedURL)
            OWELog.info(.app, "Screen saver removed")
        } catch {
            OWELog.error(.app, "Screen saver: removing it failed: \(error)")
        }
    }

    /// Opens System Settings › Screen Saver so the user can choose the saver.
    @MainActor
    func openSettings() {
        guard mayInstall else { return }
        NSWorkspace.shared.open(Self.settingsURL)
    }
}
