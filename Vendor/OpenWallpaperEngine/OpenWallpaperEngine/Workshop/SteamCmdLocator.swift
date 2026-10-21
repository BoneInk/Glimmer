import Foundation

/// Where to look for a steamcmd, in order: the path the user chose, the copy Open Wallpaper Engine
/// installed from Valve, the Homebrew prefixes, the Steam client's folders, then the usual places
/// people extract Valve's package to. Only an executable file counts.
///
/// A GUI app starts with a minimal `PATH`, so `which` can't find Homebrew's steamcmd; the prefixes
/// are checked directly instead, and `SteamCmdService` asks a login shell last.
struct SteamCmdLocator {
    /// Redirects every search location except the user's path and the app's own copy under this
    /// folder, so a development copy can be tried as if no steamcmd were installed.
    static let searchRootEnvironmentKey = "OWE_STEAMCMD_SEARCH_ROOT"
    /// `UserDefaults.app` key of the steamcmd the user chose.
    static let customPathKey = "SteamCmdPath"

    let customPath: String?
    /// The folder `SteamCmdInstaller` extracts Valve's package into.
    let ownInstallDirectory: URL
    let homeDirectory: URL
    /// The folder `/opt/homebrew`, `/usr/local` and `/Applications` live in: `/` normally.
    let systemRoot: URL

    /// The locator of this process: the user's defaults, the app's support folder and the real
    /// system, unless `OWE_STEAMCMD_SEARCH_ROOT` redirects the search.
    static func standard(defaults: UserDefaults = .app,
                         environment: [String: String] = ProcessInfo.processInfo.environment) -> SteamCmdLocator {
        let own = SteamCmdInstaller.defaultInstallDirectory
        if let root = searchRoot(environment: environment) {
            return SteamCmdLocator(customPath: defaults.string(forKey: customPathKey), ownInstallDirectory: own,
                                   homeDirectory: root.appending(path: "home", directoryHint: .isDirectory),
                                   systemRoot: root)
        }
        return SteamCmdLocator(customPath: defaults.string(forKey: customPathKey), ownInstallDirectory: own,
                               homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                               systemRoot: URL(fileURLWithPath: "/", isDirectory: true))
    }

    static func searchRoot(environment: [String: String]) -> URL? {
        guard let value = environment[searchRootEnvironmentKey], !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    /// The executable of the app's own copy.
    static func ownExecutable(in installDirectory: URL) -> URL {
        installDirectory.appending(path: "steamcmd.sh")
    }

    /// Every candidate path, in search order.
    var candidates: [String] {
        let home = homeDirectory.path
        let root = systemRoot.path == "/" ? "" : systemRoot.path
        var paths: [String] = []
        if let customPath, !customPath.isEmpty { paths.append(customPath) }
        paths.append(Self.ownExecutable(in: ownInstallDirectory).path)
        paths += Self.homebrewPrefixes.map { "\(root)\($0)/steamcmd" }
        paths += [
            "\(root)/usr/bin/steamcmd",
            // Steam client / SDK locations
            "\(home)/Library/Application Support/Steam/steamcmd/steamcmd.sh",
            "\(home)/Library/Application Support/Steam/steamcmd/steamcmd",
            "\(home)/Library/Application Support/Steam/steamcmd.sh",
            // Valve's package extracted by hand
            "\(home)/steamcmd/steamcmd.sh",
            "\(home)/steamcmd/steamcmd",
            "\(home)/Downloads/steamcmd/steamcmd.sh",
            "\(home)/Downloads/steamcmd/steamcmd",
            "\(root)/Applications/steamcmd/steamcmd.sh",
            "\(root)/Applications/steamcmd/steamcmd",
        ]
        return paths
    }

    /// Apple silicon, then Intel Homebrew.
    static let homebrewPrefixes = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// The first executable candidate.
    func locate(fileManager: FileManager = .default) -> String? {
        candidates.first { Self.isExecutableFile($0, fileManager: fileManager) }
    }

    /// An executable regular file, not a folder that happens to have the name.
    static func isExecutableFile(_ path: String, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && fileManager.isExecutableFile(atPath: path)
    }

    /// Asks the user's login shell, whose `PATH` includes what their shell profile adds, for
    /// `steamcmd`. Blocks for up to `timeout`; call off the main thread.
    static func loginShellLookup(timeout: TimeInterval = 5) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v steamcmd"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            OWELog.error(.workshop, "Can't ask the login shell for steamcmd: \(error)")
            return nil
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        if process.isRunning, exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            OWELog.info(.workshop, "The login shell didn't answer for steamcmd within \(Int(timeout))s")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline).last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard process.terminationStatus == 0, path.hasPrefix("/"), isExecutableFile(path) else { return nil }
        return path
    }
}
