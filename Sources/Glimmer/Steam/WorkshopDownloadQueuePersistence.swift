import Foundation

enum WorkshopDownloadQueuePersistenceConfiguration: Sendable {
    case automatic
    case disabled
    case file(URL)
}

enum WorkshopDownloadQueueRestoreState: Sendable, Equatable {
    case notStarted
    case loading
    case ready
    case failed(String)
}

struct WorkshopDownloadQueueSnapshot: Codable, Sendable, Equatable {
    static let currentVersion = 1
    static let maximumItems = 500

    var version: Int = currentVersion
    var queuePaused: Bool
    var items: [WorkshopDownloadQueueRecord]
    var removedItemIDs: [String] = []

    private enum CodingKeys: String, CodingKey { case version, queuePaused, items, removedItemIDs }

    init(version: Int = currentVersion, queuePaused: Bool, items: [WorkshopDownloadQueueRecord],
         removedItemIDs: [String] = []) {
        self.version = version
        self.queuePaused = queuePaused
        self.items = items
        self.removedItemIDs = removedItemIDs
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        version = try box.decode(Int.self, forKey: .version)
        queuePaused = try box.decode(Bool.self, forKey: .queuePaused)
        items = try box.decode([WorkshopDownloadQueueRecord].self, forKey: .items)
        removedItemIDs = try box.decodeIfPresent([String].self, forKey: .removedItemIDs) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(version, forKey: .version)
        try box.encode(queuePaused, forKey: .queuePaused)
        try box.encode(items, forKey: .items)
        try box.encode(removedItemIDs, forKey: .removedItemIDs)
    }
}

struct WorkshopDownloadQueueRecord: Codable, Sendable, Equatable {
    enum State: Codable, Sendable, Equatable {
        case queued
        case downloading
        case pausing
        case paused
        case validating
        case completed
        case failed(String)
        case cancelled

        private enum CodingKeys: String, CodingKey { case kind, message }
        private enum Kind: String, Codable { case queued, downloading, pausing, paused, validating, completed, failed, cancelled }

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            switch try box.decode(Kind.self, forKey: .kind) {
            case .queued: self = .queued
            case .downloading: self = .downloading
            case .pausing: self = .pausing
            case .paused: self = .paused
            case .validating: self = .validating
            case .completed: self = .completed
            case .failed: self = .failed(try box.decodeIfPresent(String.self, forKey: .message) ?? "下载失败")
            case .cancelled: self = .cancelled
            }
        }

        func encode(to encoder: Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .queued: try box.encode(Kind.queued, forKey: .kind)
            case .downloading: try box.encode(Kind.downloading, forKey: .kind)
            case .pausing: try box.encode(Kind.pausing, forKey: .kind)
            case .paused: try box.encode(Kind.paused, forKey: .kind)
            case .validating: try box.encode(Kind.validating, forKey: .kind)
            case .completed: try box.encode(Kind.completed, forKey: .kind)
            case .failed(let message):
                try box.encode(Kind.failed, forKey: .kind)
                try box.encode(message, forKey: .message)
            case .cancelled: try box.encode(Kind.cancelled, forKey: .kind)
            }
        }
    }

    var publishedFileID: String
    var title: String
    var kind: String
    var declaredTags: [String]
    var previewImageURLString: String?
    var fileSizeBytes: Int64?
    var state: State
    var attempts: Int
    var queuedAt: Date
    var completedAt: Date?
}

enum WorkshopDownloadQueueStoreError: LocalizedError {
    case unsafeLocation
    case oversized
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsafeLocation: return "下载队列文件位置不安全，未读取或写入。"
        case .oversized: return "下载队列文件异常过大，已忽略。"
        case .unsupportedVersion(let version): return "下载队列版本 \(version) 暂不支持，已忽略。"
        }
    }
}

actor WorkshopDownloadQueueStore {
    static let maximumBytes = 512 * 1024

    private let persistenceURL: URL?
    private let permittedRoot: URL?
    private let manager: FileManager

    init(persistenceURL: URL?, permittedRoot: URL? = nil, manager: FileManager = .default) {
        self.persistenceURL = persistenceURL
        self.permittedRoot = permittedRoot
        self.manager = manager
    }

    var isEnabled: Bool { persistenceURL != nil }

    func load() throws -> WorkshopDownloadQueueSnapshot? {
        guard let url = try checkedURL() else { return nil }
        guard manager.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw WorkshopDownloadQueueStoreError.unsafeLocation }
        guard (values.fileSize ?? 0) <= Self.maximumBytes else { throw WorkshopDownloadQueueStoreError.oversized }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= Self.maximumBytes else { throw WorkshopDownloadQueueStoreError.oversized }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(WorkshopDownloadQueueSnapshot.self, from: data)
        guard snapshot.version == WorkshopDownloadQueueSnapshot.currentVersion else {
            throw WorkshopDownloadQueueStoreError.unsupportedVersion(snapshot.version)
        }
        return Self.sanitized(snapshot)
    }

    func save(_ snapshot: WorkshopDownloadQueueSnapshot) throws {
        guard let url = try checkedURL() else { return }
        if manager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw WorkshopDownloadQueueStoreError.unsafeLocation
            }
        }
        let clean = Self.sanitized(snapshot)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(clean)
        guard data.count <= Self.maximumBytes else { throw WorkshopDownloadQueueStoreError.oversized }
        let parent = url.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func checkedURL() throws -> URL? {
        guard let persistenceURL else { return nil }
        guard persistenceURL.isFileURL else { throw WorkshopDownloadQueueStoreError.unsafeLocation }
        let url = persistenceURL.standardizedFileURL
        guard url.lastPathComponent == "download-queue.json" else { throw WorkshopDownloadQueueStoreError.unsafeLocation }
        if let permittedRoot {
            let literalRoot = permittedRoot.standardizedFileURL
            if manager.fileExists(atPath: literalRoot.path),
               (try literalRoot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw WorkshopDownloadQueueStoreError.unsafeLocation
            }
            let root = literalRoot.resolvingSymlinksInPath()
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
            guard parent.path == root.path else { throw WorkshopDownloadQueueStoreError.unsafeLocation }
        }
        return url
    }

    private static func sanitized(_ snapshot: WorkshopDownloadQueueSnapshot) -> WorkshopDownloadQueueSnapshot {
        var seen = Set<String>()
        let records = snapshot.items.prefix(WorkshopDownloadQueueSnapshot.maximumItems).compactMap { source -> WorkshopDownloadQueueRecord? in
            guard let id = WorkshopItemID(source.publishedFileID)?.value, seen.insert(id).inserted else { return nil }
            var record = source
            record.publishedFileID = id
            record.title = clean(source.title, limit: 300, fallback: "工坊作品 \(id)")
            record.kind = clean(source.kind, limit: 30, fallback: "unknown")
            record.declaredTags = Array(source.declaredTags.prefix(40)).map { clean($0, limit: 100, fallback: "") }.filter { !$0.isEmpty }
            if let raw = source.previewImageURLString, let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                record.previewImageURLString = String(raw.prefix(2_048))
            } else { record.previewImageURLString = nil }
            if let size = source.fileSizeBytes, size <= 0 || size > Int64.max / 2 { record.fileSizeBytes = nil }
            record.attempts = min(max(source.attempts, 0), 10_000)
            if case .failed(let message) = source.state {
                let sanitized = SteamLoginSession.sanitize(WorkshopLog.sanitize(message), limit: 300)
                record.state = .failed(clean(sanitized, limit: 300, fallback: "下载失败"))
            }
            return record
        }
        var removedSeen = Set<String>()
        let removed = snapshot.removedItemIDs.prefix(WorkshopDownloadQueueSnapshot.maximumItems).compactMap { value -> String? in
            guard let id = WorkshopItemID(value)?.value, removedSeen.insert(id).inserted else { return nil }
            return id
        }
        return WorkshopDownloadQueueSnapshot(version: WorkshopDownloadQueueSnapshot.currentVersion,
                                             queuePaused: snapshot.queuePaused, items: records,
                                             removedItemIDs: removed)
    }

    private static func clean(_ value: String, limit: Int, fallback: String) -> String {
        let text = value.replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : String(text.prefix(limit))
    }
}
