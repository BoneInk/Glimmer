import AppKit

/// The macOS equivalents of WE's `ShellExecuteW`: a file opens in its default app (an app
/// launches, with the arguments), a folder in Finder, a website in the default browser, and a
/// command runs in the user's login shell (`/bin/zsh -l -c`, in the home folder).
///
/// Each check is synchronous, so `engine.openUserShortcut` returns what WE would; the opening
/// itself is handed to the main thread, so a slow Launch Services call never holds up the script
/// thread that asked.
struct WorkspaceUserShortcutOpener: UserShortcutOpening {
    func openFile(_ url: URL, arguments: String) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            OWELog.error(.script, "User shortcut: \(url.path) doesn't exist")
            return false
        }
        if url.pathExtension.lowercased() == "app" {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = Self.splitArguments(arguments)
            DispatchQueue.main.async {
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                    if let error { OWELog.error(.script, "User shortcut: \(url.path) didn't launch: \(error)") }
                }
            }
            return true
        }
        return open(url)
    }

    func openDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            OWELog.error(.script, "User shortcut: the folder \(url.path) doesn't exist")
            return false
        }
        return open(url)
    }

    func openWebsite(_ url: URL) -> Bool {
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            OWELog.error(.script, "User shortcut: no app opens \(url.scheme ?? "") links")
            return false
        }
        return open(url)
    }

    func runCommand(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            OWELog.error(.script, "User shortcut: the command didn't start: \(error)")
            return false
        }
    }

    private func open(_ url: URL) -> Bool {
        DispatchQueue.main.async {
            if !NSWorkspace.shared.open(url) { OWELog.error(.script, "User shortcut: \(url) didn't open") }
        }
        return true
    }

    /// `arguments` split as a shell would split plain words and quoted strings (no expansion).
    static func splitArguments(_ arguments: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var hasWord = false
        for character in arguments {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                hasWord = true
            } else if character.isWhitespace {
                if hasWord { words.append(current) }
                current = ""
                hasWord = false
            } else {
                current.append(character)
                hasWord = true
            }
        }
        if hasWord { words.append(current) }
        return words
    }
}
