import Foundation

/// The SteamCMD side of installing the Wallpaper Engine assets: the script that downloads the
/// user's own copy of the app (Windows depot, as the assets only ship there), and how its output
/// is read. Pure, so tests cover it without running SteamCMD.
enum WallpaperEngineAssetsDownload {
    enum Outcome: Equatable {
        case installed
        /// The account doesn't own the app.
        case notOwned
        /// SteamCMD has no cached login for the account.
        case loginRequired
        case failed(String)
    }

    struct Progress: Equatable {
        var fraction: Double
        var downloadedBytes: Int64?
        var totalBytes: Int64?
    }

    static var appID: Int { WorkshopAPIService.wallpaperEngineAppId }

    /// The folder SteamCMD downloads into, inside the Wallpaper Storage folder (the same volume as
    /// the cache, so nothing large lands on the startup disk). Deleted after the copy.
    static let downloadFolderName = ".owe-assets-download"

    static func downloadDirectory(in storage: URL) -> URL {
        storage.appending(path: downloadFolderName, directoryHint: .isDirectory)
    }

    /// Logs in with SteamCMD's cached session (no password: it fails instead of prompting) and
    /// installs the app's Windows depot into `installDirectory`, validating the files.
    static func script(installDirectory: URL, username: String) throws -> SteamCmdScript {
        var script = SteamCmdScript.withoutPasswordPrompt()
        try script.append("@sSteamCmdForcePlatformType", ["windows"])
        try script.append("force_install_dir", [installDirectory.path])
        try script.append("login", [username])
        try script.append("app_update", ["\(appID)", "validate"])
        return script
    }

    /// What a finished run came to: the files, if the `assets` folder is there, else the reason
    /// SteamCMD printed.
    static func outcome(output: String, exitCode: Int32, assetsPresent: Bool) -> Outcome {
        if output.contains("No subscription") { return .notOwned }
        if output.contains("Cached credentials not found") || output.contains("Login Failure")
            || output.contains("Invalid Password") || output.contains("password prompt disabled") {
            return .loginRequired
        }
        if assetsPresent { return .installed }
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        if let line = lines.first(where: { $0.contains("ERROR") || $0.contains("FAILED") }) {
            return .failed(line)
        }
        if exitCode != 0, let last = lines.last(where: { !$0.isEmpty }) {
            return .failed(last)
        }
        return .failed(String(localized: "steamcmd finished without downloading the item.",
                              comment: "Download error; steamcmd is a program name"))
    }

    /// `Update state (0x61) downloading, progress: 45.12 (123456 / 273456)`.
    static func progress(in chunk: String) -> Progress? {
        let pattern = #"progress:\s*([0-9]+(?:\.[0-9]+)?)(?:\s*\((\d+)\s*/\s*(\d+)\))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil } // constant pattern
        let range = NSRange(chunk.startIndex..., in: chunk)
        guard let match = regex.matches(in: chunk, range: range).last,
              let percentRange = Range(match.range(at: 1), in: chunk),
              let percent = Double(chunk[percentRange]) else { return nil }
        let number: (Int) -> Int64? = { index in
            Range(match.range(at: index), in: chunk).flatMap { Int64(chunk[$0]) }
        }
        return Progress(fraction: min(max(percent / 100, 0), 1), downloadedBytes: number(2), totalBytes: number(3))
    }

    /// Steam's build id from the app manifest SteamCMD writes (`"buildid" "12345"`).
    static func buildID(installDirectory: URL) -> String? {
        let manifest = installDirectory.appending(path: "steamapps/appmanifest_\(appID).acf")
        // No manifest just means no version to show.
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return nil }
        return buildID(manifest: text)
    }

    static func buildID(manifest: String) -> String? {
        for line in manifest.components(separatedBy: .newlines) {
            let fields = line.split(separator: "\"").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if fields.count == 2, fields[0].lowercased() == "buildid" { return fields[1] }
        }
        return nil
    }
}
