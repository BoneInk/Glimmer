//
//  WorkshopItemAvailability.swift
//  Open Wallpaper Engine
//
//  Whether a Workshop item can still be downloaded, read from the keyless
//  `ISteamRemoteStorage/GetPublishedFileDetails/v1`. An item its author deleted or made private
//  answers `result: 9`; steamcmd reports the same item as `File Not Found`. Pure parsing, so tests
//  run on fixture JSON without the network.
//

import Foundation

enum WorkshopItemAvailability: Equatable {
    case available
    case unavailable(Reason)

    enum Reason: String, Codable, Equatable {
        /// `result` isn't 1 (9: deleted, or private to its author).
        case removedOrPrivate
        /// Steam banned the item.
        case banned
        /// The item was published for another app than Wallpaper Engine.
        case otherApp

        /// What the dependency list shows in place of steamcmd's error.
        var message: String {
            switch self {
            case .removedOrPrivate:
                return String(localized: "This Workshop item was removed or made private by its author.")
            case .banned:
                return String(localized: "Steam has banned this Workshop item.")
            case .otherApp:
                return String(localized: "This Workshop item belongs to another app.")
            }
        }
    }

    static let detailsURL = URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!

    /// The item's page on the Steam Workshop.
    static func workshopPageURL(for id: String) -> URL? {
        guard WorkshopCollection.isID(id) else { return nil }
        return URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")
    }

    /// The item's page in the Steam client.
    static func steamClientPageURL(for id: String) -> URL? {
        guard WorkshopCollection.isID(id) else { return nil }
        return URL(string: "steam://url/CommunityFilePage/\(id)")
    }

    /// The POST body of GetPublishedFileDetails for `ids` (at most `WorkshopCollection.detailsBatchSize`).
    static func detailsBody(ids: [String]) -> Data {
        var parts = ["itemcount=\(ids.count)"]
        for (index, id) in ids.enumerated() { parts.append("publishedfileids[\(index)]=\(id)") }
        return Data(parts.joined(separator: "&").utf8)
    }

    /// Each item the response describes. An id the response leaves out isn't in the result, and
    /// the caller treats it as unknown.
    static func parse(_ data: Data) throws -> [String: WorkshopItemAvailability] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? [String: Any],
              let files = response["publishedfiledetails"] as? [[String: Any]] else { return [:] }
        var result: [String: WorkshopItemAvailability] = [:]
        for file in files {
            guard let id = string(file["publishedfileid"]), WorkshopCollection.isID(id) else { continue }
            result[id] = availability(of: file)
        }
        return result
    }

    /// One `publishedfiledetails` entry.
    static func availability(of file: [String: Any]) -> WorkshopItemAvailability {
        guard (file["result"] as? NSNumber)?.intValue == 1 else { return .unavailable(.removedOrPrivate) }
        if (file["banned"] as? NSNumber)?.boolValue == true { return .unavailable(.banned) }
        if let app = file["consumer_app_id"] as? NSNumber, app.intValue != WorkshopAPIService.wallpaperEngineAppId {
            return .unavailable(.otherApp)
        }
        return .available
    }

    /// Whether steamcmd's output says the item doesn't exist for this account
    /// (`ERROR! Download item <id> failed (File Not Found).`).
    static func steamCmdReportsNotFound(_ output: String) -> Bool {
        output.range(of: "File Not Found", options: .caseInsensitive) != nil
    }

    /// Steam sends ids as strings, older responses as numbers.
    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
