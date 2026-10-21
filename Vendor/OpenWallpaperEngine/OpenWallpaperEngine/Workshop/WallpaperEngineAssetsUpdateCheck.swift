import Foundation

/// Whether "Update from Steam" needs to download: the current public build of Wallpaper Engine,
/// looked up with SteamCMD's `app_info_print` (nothing is downloaded), against the build the
/// assets cache was filled from. Pure, so tests cover it without running SteamCMD.
enum WallpaperEngineAssetsUpdateCheck {
    /// What the lookup found.
    enum Lookup: Equatable {
        case build(String)
        /// SteamCMD has no cached login for the account.
        case loginRequired
        case failed(String)
    }

    enum Decision: Equatable {
        /// The installed assets are the current build and complete.
        case upToDate(build: String)
        case download
    }

    private static var appID: Int { WallpaperEngineAssetsDownload.appID }

    /// Whether to look the build up before downloading: only for a complete Steam copy of a known
    /// build. Anything else downloads straight away, as does "Re-download".
    static func needsLookup(force: Bool, installed: WallpaperEngineAssetsCache.Info?, assetsComplete: Bool) -> Bool {
        !force && assetsComplete && installed?.origin == .steam && !(installed?.steamBuildID ?? "").isEmpty
    }

    /// Skips the download when the installed build is the current one and the files are there.
    static func decision(installed: WallpaperEngineAssetsCache.Info?, assetsComplete: Bool, currentBuild: String) -> Decision {
        guard assetsComplete, installed?.origin == .steam, let build = installed?.steamBuildID, build == currentBuild else {
            return .download
        }
        return .upToDate(build: build)
    }

    /// Logs in with SteamCMD's cached session (no password prompt), refreshes the app info and
    /// prints Wallpaper Engine's.
    static func script(username: String) throws -> SteamCmdScript {
        var script = SteamCmdScript.withoutPasswordPrompt()
        try script.append("login", [username])
        try script.append("app_info_update", ["1"])
        try script.append("app_info_print", ["\(appID)"])
        return script
    }

    /// What a finished lookup came to.
    static func lookup(output: String, exitCode: Int32) -> Lookup {
        let login = SteamCmdService.loginOutcome(output: output)
        if login == .noCachedLogin || login == .invalidPassword || output.contains("Login Failure") {
            return .loginRequired
        }
        if let build = publicBuildID(appInfo: output) { return .build(build) }
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        if let line = lines.first(where: { $0.contains("ERROR") || $0.contains("FAILED") }) {
            return .failed(line)
        }
        return .failed(String(localized: "steamcmd didn't report the current build.",
                              comment: "Assets update check error; steamcmd is a program name"))
    }

    /// The public branch's `buildid` from `app_info_print` output: the app's KeyValues block
    /// (`"431960" { … "depots" { … "branches" { "public" { "buildid" "N" … } } } }`), the last one
    /// printed, among SteamCMD's other lines.
    static func publicBuildID(appInfo output: String) -> String? {
        guard let block = appBlock(in: output) else { return nil }
        let entries: [ValveKeyValues.Entry]
        do {
            entries = try ValveKeyValues.parse(block)
        } catch {
            OWELog.error(.workshop, "Can't read steamcmd's app info for \(appID): \(error.localizedDescription)")
            return nil
        }
        let build = entries["\(appID)"]?["depots"]?["branches"]?["public"]?["buildid"]?.string
        guard let build, !build.isEmpty, build.allSatisfy(\.isNumber) else { return nil }
        return build
    }

    /// The text from the last `"431960"` key that opens a block to the brace that closes it.
    private static func appBlock(in output: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #""\#(appID)"\s*\{"#) else { return nil } // constant pattern
        let text = output as NSString
        guard let match = regex.matches(in: output, range: NSRange(location: 0, length: text.length)).last else { return nil }
        let scalars = Array(text.substring(from: match.range.location).unicodeScalars)
        var depth = 0
        var inString = false
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if inString {
                if scalar == "\\" { index += 1 } else if scalar == "\"" { inString = false }
            } else if scalar == "\"" {
                inString = true
            } else if scalar == "{" {
                depth += 1
            } else if scalar == "}" {
                depth -= 1
                if depth == 0 {
                    var block = String.UnicodeScalarView()
                    block.append(contentsOf: scalars[...index])
                    return String(block)
                }
            }
            index += 1
        }
        return nil
    }
}
