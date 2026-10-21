import Foundation

/// Public browsing metadata only. A nil URL provides an entirely in-memory store.
struct WorkshopBrowserStore {
    static let historyLimit = 12
    static let savedLimit = 200
    private(set) var recentSearches: [String] = []
    private(set) var savedResults: [WorkshopSearchResult] = []
    private let persistenceURL: URL?

    private struct Snapshot: Codable {
        var schemaVersion = 1
        var recentSearches: [String]
        var savedResults: [WorkshopSearchResult]
    }

    init(persistenceURL: URL?) {
        self.persistenceURL = persistenceURL
        guard let persistenceURL,
              let size = try? persistenceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 10_000_000,
              let data = try? Data(contentsOf: persistenceURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.schemaVersion == 1 else { return }
        var queries = Set<String>()
        recentSearches = snapshot.recentSearches.compactMap(Self.normalizedQuery)
            .filter { queries.insert($0.lowercased()).inserted }
            .prefix(Self.historyLimit).map { $0 }
        var ids = Set<String>()
        savedResults = snapshot.savedResults.compactMap(Self.validatedResult)
            .filter { ids.insert($0.id).inserted }
            .prefix(Self.savedLimit).map { $0 }
    }

    mutating func recordSuccessfulSearch(_ query: String) {
        guard let query = Self.normalizedQuery(query) else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        recentSearches.insert(query, at: 0)
        recentSearches = Array(recentSearches.prefix(Self.historyLimit))
        persist()
    }

    mutating func clearSearchHistory() {
        recentSearches.removeAll()
        persist()
    }

    mutating func removeRecentSearch(_ query: String) {
        recentSearches.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        persist()
    }

    func isSaved(_ itemID: String) -> Bool {
        guard let id = WorkshopItemID(itemID) else { return false }
        return savedResults.contains { $0.id == id.value }
    }

    mutating func toggleSaved(_ result: WorkshopSearchResult) {
        guard let result = Self.validatedResult(result) else { return }
        if isSaved(result.id) {
            savedResults.removeAll { $0.id == result.id }
        } else {
            savedResults.insert(result, at: 0)
            savedResults = Array(savedResults.prefix(Self.savedLimit))
        }
        persist()
    }

    private static func normalizedQuery(_ query: String) -> String? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 200,
              !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return query
    }

    private static func validatedResult(_ input: WorkshopSearchResult) -> WorkshopSearchResult? {
        guard let id = WorkshopItemID(input.id),
              !input.isCollection, input.childCount == 0, input.declaredKind != .collection,
              input.consumerAppID == nil || input.consumerAppID == WorkshopInputValidator.wallpaperEngineAppID else { return nil }
        var result = input
        result.publishedFileID = id.value
        result.title = String(result.title.prefix(512))
        result.shortDescription = String(result.shortDescription.prefix(4_000))
        let type = result.declaredTypeTag
        let remaining = result.tags.filter { tag in type.map { tag.caseInsensitiveCompare($0) != .orderedSame } ?? true }
        result.tags = (type.map { [$0] } ?? []) + Array(remaining.prefix(type == nil ? 32 : 31)).map { String($0.prefix(128)) }
        if let url = result.previewURL {
            // Thumbnail URLs are public HTTPS metadata, never local paths or authenticated URLs.
            let host = url.host?.lowercased() ?? ""
            let trusted = ["steamstatic.com", "steamusercontent.com", "steamuserimages-a.akamaihd.net"]
                .contains { host == $0 || host.hasSuffix("." + $0) }
            if url.absoluteString.count > 2_048 || url.scheme?.lowercased() != "https" || url.user != nil || url.password != nil || !trusted {
                result.previewURL = nil
            }
        }
        return result
    }

    private func persist() {
        guard let persistenceURL else { return }
        do {
            let data = try JSONEncoder().encode(Snapshot(recentSearches: recentSearches, savedResults: savedResults))
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            // Keep the in-memory changes usable when storage is unavailable.
            WorkshopLog.notice("无法保存工坊浏览偏好。")
        }
    }
}
