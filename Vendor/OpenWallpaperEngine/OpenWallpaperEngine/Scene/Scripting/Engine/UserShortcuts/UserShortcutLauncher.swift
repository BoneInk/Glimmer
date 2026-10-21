import Foundation

/// What opening a user shortcut does on this Mac; `WorkspaceUserShortcutOpener` in the app, a
/// recorder in tests. Each returns whether the open started, as WE returns whether
/// `ShellExecuteW` started it (its result above 32).
protocol UserShortcutOpening {
    func openFile(_ url: URL, arguments: String) -> Bool
    func openDirectory(_ url: URL) -> Bool
    func openWebsite(_ url: URL) -> Bool
    func runCommand(_ command: String) -> Bool
}

/// Opens the shortcut a user bound to a `usershortcut` property, for `engine.openUserShortcut`
/// and the bind sheet's Test. As in wallpaper64.exe: nothing bound, or bound on another machine
/// (the hash isn't this one's: "User shortcut blocked."), opens nothing and returns false.
struct UserShortcutLauncher {
    let opener: UserShortcutOpening
    /// This machine's `UserShortcutSystemHash`.
    let systemHash: String

    /// Opens `storedValue` (the property's value as the store keeps it); true when it started.
    func open(_ storedValue: String) -> Bool {
        guard let binding = UserShortcutBinding(storedValue: storedValue) else { return false }
        guard binding.systemHash == systemHash else {
            OWELog.info(.script, "User shortcut blocked: it was bound on another machine")
            return false
        }
        switch binding.kind {
        case .file:
            return opener.openFile(URL(fileURLWithPath: binding.path), arguments: binding.arguments)
        case .directory:
            return opener.openDirectory(URL(fileURLWithPath: binding.path, isDirectory: true))
        case .web:
            guard let url = Self.websiteURL(binding.path) else {
                OWELog.error(.script, "User shortcut: \(binding.path) isn't a URL")
                return false
            }
            return opener.openWebsite(url)
        case .cmd:
            return opener.runCommand(binding.path)
        }
    }

    /// The URL of a website shortcut; one WE stores without a scheme (`www.…`) is opened as https.
    static func websiteURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return nil }
        if url.scheme?.isEmpty == false { return url }
        return URL(string: "https://" + trimmed)
    }
}
