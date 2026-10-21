import Foundation

/// A Steam Workshop collection, read with the keyless `ISteamRemoteStorage/GetCollectionDetails/v1`
/// (its children) and `GetPublishedFileDetails/v1` (titles, previews, tags). Pure parsing, so tests
/// run on fixture JSON without the network.
enum WorkshopCollection {
    static let detailsURL = URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/")!
    /// GetPublishedFileDetails takes this many ids per request.
    static let detailsBatchSize = 100

    /// Steam's `filetype` of a collection child: an item (0) or a nested collection (2).
    enum ChildType: Int {
        case item = 0
        case collection = 2
    }

    struct Child: Equatable {
        let id: String
        let type: ChildType?
    }

    enum Failure: LocalizedError, Equatable {
        case invalidInput
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .invalidInput:
                return String(localized: "Paste a Workshop collection link or its number.")
            case .notFound(let id):
                return String(localized: "Steam has no public collection \(id).", comment: "%@ is a Workshop collection id")
            }
        }
    }

    /// The collection id in what the user pasted: the number itself, or a Steam link with `?id=`
    /// (`https://steamcommunity.com/sharedfiles/filedetails/?id=123`, `…/workshop/filedetails/?id=123`).
    static func collectionID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isID(trimmed) { return trimmed }
        guard let components = URLComponents(string: trimmed),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              isID(id) else { return nil }
        return id
    }

    static func isID(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 20 && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The POST body of GetCollectionDetails for one collection.
    static func detailsBody(collectionID: String) -> Data {
        Data("collectioncount=1&publishedfileids[0]=\(collectionID)".utf8)
    }

    /// The children of `collectionID` in a GetCollectionDetails response, in Steam's sort order;
    /// nil when the response doesn't have that collection (private, deleted, or not a collection).
    static func children(of collectionID: String, in data: Data) throws -> [Child]? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? [String: Any],
              let details = response["collectiondetails"] as? [[String: Any]],
              let collection = details.first(where: { string($0["publishedfileid"]) == collectionID }),
              (collection["result"] as? Int ?? 1) == 1
        else { return nil }
        let children = collection["children"] as? [[String: Any]] ?? []
        return children
            .enumerated()
            .sorted { ($0.element["sortorder"] as? Int ?? $0.offset) < ($1.element["sortorder"] as? Int ?? $1.offset) }
            .compactMap { _, child -> Child? in
                guard let id = string(child["publishedfileid"]), isID(id) else { return nil }
                return Child(id: id, type: (child["filetype"] as? Int).flatMap(ChildType.init(rawValue:)))
            }
    }

    /// Steam sends ids as strings, older responses as numbers.
    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}

/// A Workshop item offered for import, with what the checklist needs to show and filter it.
struct WorkshopImportCandidate: Identifiable, Equatable {
    let id: String
    var title: String
    var previewURL: URL?
    /// A local preview (folder imports); `previewURL` is the remote one.
    var previewFile: URL?
    /// "Everyone", "Questionable" or "Mature"; nil when the item has none.
    var contentRating: String?
    /// "Scene", "Video", "Web", "Application", or nil (asset items).
    var type: String?
    /// Already in the Wallpaper Storage folder.
    var isInLibrary = false

    var isApplication: Bool { type?.caseInsensitiveCompare("application") == .orderedSame }

    /// Shown under the rating filter. An item without a rating is always shown, as the Installed
    /// tab's rating filter does (`InstalledLibraryModel`); only a known Questionable or Mature rating
    /// hides an item.
    func isAllowed(byRatings ratings: Set<String>) -> Bool {
        guard let contentRating else { return true }
        return ratings.contains(contentRating)
    }

    init(id: String, title: String, previewURL: URL? = nil, previewFile: URL? = nil,
         contentRating: String? = nil, type: String? = nil, isInLibrary: Bool = false) {
        self.id = id
        self.title = title
        self.previewURL = previewURL
        self.previewFile = previewFile
        self.contentRating = contentRating
        self.type = type
        self.isInLibrary = isInLibrary
    }

    init(item: WorkshopItem, isInLibrary: Bool) {
        self.init(id: item.id, title: item.title, previewURL: item.previewImageURL,
                  contentRating: InstalledWorkshopTags.contentRating(in: item.tags),
                  type: item.tags.first { tag in WorkshopTags.types.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } },
                  isInLibrary: isInLibrary)
    }

    init(item: SteamLibraryImport.Item, isInLibrary: Bool) {
        self.init(id: item.id, title: item.title, previewFile: item.preview, contentRating: item.contentRating,
                  type: item.type.isEmpty ? nil : item.type.capitalized, isInLibrary: isInLibrary)
    }
}
