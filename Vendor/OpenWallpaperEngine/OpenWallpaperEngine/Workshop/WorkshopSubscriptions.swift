import Foundation

/// The user's Workshop lists, from `IPublishedFileService/GetUserFiles/v1`: subscriptions with
/// `type=mysubscriptions` (`subscribed` always answers `{"response":{}}`), and favourites with
/// `type=myfavorites`, the list Wallpaper Engine's heart writes (`setFavorited` in its UI, Steam's
/// favourited-items query in `wallpaperui.exe`). It needs the user's Web API key and SteamID64; an
/// empty answer is treated as "Steam didn't return the list".
enum WorkshopSubscriptions {
    /// Which of the account's lists GetUserFiles returns.
    enum List: String {
        case subscriptions = "mysubscriptions"
        case favorites = "myfavorites"
    }

    static let userFilesURL = URL(string: "https://api.steampowered.com/IPublishedFileService/GetUserFiles/v1/")!
    /// The probe's answer, kept so an account Steam returns nothing for doesn't show the option again.
    static let probeResultKey = "WorkshopSubscriptionsProbe.mysubscriptions"

    enum Outcome: Equatable {
        case items([String])
        /// Steam answered without any subscriptions.
        case empty
    }

    enum ProbeResult: String {
        case items
        case empty
    }

    /// The query of one GetUserFiles page. The key goes in the `x-webapi-key` header, never here.
    static func queryItems(steamID: String, page: Int, perPage: Int = 100,
                           list: List = .subscriptions) -> [URLQueryItem] {
        [
            URLQueryItem(name: "steamid", value: steamID),
            URLQueryItem(name: "appid", value: String(WorkshopAPIService.wallpaperEngineAppId)),
            URLQueryItem(name: "type", value: list.rawValue),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "numperpage", value: String(perPage)),
            URLQueryItem(name: "return_short_description", value: "false"),
        ]
    }

    /// The subscribed ids in a GetUserFiles response; `.empty` for `{"response":{}}` or no files.
    static func outcome(from data: Data) throws -> Outcome {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? [String: Any] else { return .empty }
        let files = response["publishedfiledetails"] as? [[String: Any]] ?? []
        let ids = files.compactMap { file -> String? in
            if let id = file["publishedfileid"] as? String { return id }
            return (file["publishedfileid"] as? NSNumber)?.stringValue
        }.filter(WorkshopCollection.isID)
        return ids.isEmpty ? .empty : .items(ids)
    }

    /// A SteamID64 of an individual account: 17 digits from 7656119….
    static func isSteamID64(_ text: String) -> Bool {
        text.count == 17 && text.hasPrefix("7656119") && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The SteamID64 of `account` from Steam's own files (SteamCMD's and the Steam client's
    /// `config/loginusers.vdf`, then `config/config.vdf` › Accounts), under each root in order.
    static func steamID64(forAccount account: String, steamRoots: [URL],
                          fileManager: FileManager = .default) -> String? {
        guard !account.isEmpty else { return nil }
        for root in steamRoots {
            let loginUsers = root.appending(path: "config/loginusers.vdf")
            if fileManager.fileExists(atPath: loginUsers.path), let id = readID(loginUsers, {
                steamID(inLoginUsers: $0, account: account)
            }) {
                return id
            }
            let config = root.appending(path: "config/config.vdf")
            if fileManager.fileExists(atPath: config.path), let id = readID(config, {
                steamID(inConfig: $0, account: account)
            }) {
                return id
            }
        }
        return nil
    }

    /// The account Steam last logged in with, when no account name is known: the user whose
    /// `MostRecent` is 1 in `config/loginusers.vdf`, or the only user listed, under each root in order.
    static func mostRecentSteamID64(steamRoots: [URL], fileManager: FileManager = .default) -> String? {
        for root in steamRoots {
            let loginUsers = root.appending(path: "config/loginusers.vdf")
            if fileManager.fileExists(atPath: loginUsers.path),
               let id = readID(loginUsers, mostRecentSteamID(inLoginUsers:)) {
                return id
            }
        }
        return nil
    }

    static func mostRecentSteamID(inLoginUsers entries: [ValveKeyValues.Entry]) -> String? {
        let users = (entries["users"]?.entries ?? []).filter { isSteamID64($0.key) }
        if let recent = users.first(where: { $0.value["MostRecent"]?.string == "1" }) { return recent.key }
        return users.count == 1 ? users[0].key : nil
    }

    /// The Steam folder a Wallpaper Engine install sits in (`<Steam>/steamapps/common/wallpaper_engine`,
    /// or a folder inside it): the parent of the nearest `steamapps` above `folder`.
    static func steamRoot(containing folder: URL) -> URL? {
        var url = folder.standardizedFileURL
        while url.pathComponents.count > 1 {
            if url.lastPathComponent.caseInsensitiveCompare("steamapps") == .orderedSame {
                return url.deletingLastPathComponent()
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    /// `"users" { "<SteamID64>" { "AccountName" "<account>" … } }`.
    static func steamID(inLoginUsers entries: [ValveKeyValues.Entry], account: String) -> String? {
        let users = entries["users"]?.entries ?? []
        return users.first { user in
            user.value["AccountName"]?.string?.caseInsensitiveCompare(account) == .orderedSame && isSteamID64(user.key)
        }?.key
    }

    /// `… "Accounts" { "<account>" { "SteamID" "<SteamID64>" } }`, wherever the block is nested.
    static func steamID(inConfig entries: [ValveKeyValues.Entry], account: String) -> String? {
        for entry in entries {
            if entry.key.caseInsensitiveCompare("Accounts") == .orderedSame,
               let id = entry.value[account]?["SteamID"]?.string, isSteamID64(id) {
                return id
            }
            if let id = steamID(inConfig: entry.value.entries, account: account) { return id }
        }
        return nil
    }

    private static func readID(_ url: URL, _ find: ([ValveKeyValues.Entry]) -> String?) -> String? {
        do {
            return find(try ValveKeyValues.parse(contentsOf: url))
        } catch {
            OWELog.error(.workshop, "Can't read \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    /// Where SteamCMD and the Steam client keep `config/`: next to the steamcmd executable, and
    /// `~/Library/Application Support/Steam`.
    static func steamRoots(steamCmdPath: String?,
                           home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var roots: [URL] = []
        if let steamCmdPath {
            roots.append(URL(fileURLWithPath: steamCmdPath).resolvingSymlinksInPath().deletingLastPathComponent())
        }
        roots.append(home.appending(path: "Library/Application Support/Steam", directoryHint: .isDirectory))
        return roots
    }
}
