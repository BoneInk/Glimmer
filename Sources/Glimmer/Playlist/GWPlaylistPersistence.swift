import Foundation

// F19 播放列表的独立持久化（versioned + atomic）。
// 与 library.json 完全分离，主控后续只需调用加载/保存接口。

/// 播放列表配置文档。
struct GWPlaylistDocument: GWVersionedDocument {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var updatedAt: Date
    /// 写入时的应用版本（仅诊断用，可为空）。
    var appVersion: String?
    var settings: GWPlaylistSettings

    init(settings: GWPlaylistSettings, appVersion: String? = nil, updatedAt: Date = Date()) {
        self.schemaVersion = Self.currentSchemaVersion
        self.updatedAt = updatedAt
        self.appVersion = appVersion ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        self.settings = settings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
        settings = try container.decodeIfPresent(GWPlaylistSettings.self, forKey: .settings) ?? .default
    }
}

/// 播放列表持久化：加载失败不崩溃；损坏文件隔离后回退默认值。
enum GWPlaylistPersistence {
    static func load(from url: URL) throws -> GWPlaylistDocument? {
        try GWJSONFileStore.load(GWPlaylistDocument.self, from: url)
    }

    @discardableResult
    static func save(_ settings: GWPlaylistSettings, to url: URL) throws -> Int {
        let document = GWPlaylistDocument(settings: settings.normalized())
        return try GWJSONFileStore.save(document, to: url)
    }

    @discardableResult
    static func quarantine(_ url: URL) -> URL? {
        GWJSONFileStore.quarantine(url)
    }
}
