import Foundation

// F09 电源策略的独立持久化（versioned + atomic）。
// 与 library.json 完全分离，主控后续只需调用加载/保存接口。

/// 电源策略配置文档。
struct GWPolicyDocument: GWVersionedDocument {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var updatedAt: Date
    /// 写入时的应用版本（仅诊断用，可为空）。
    var appVersion: String?
    var settings: GWPolicySettings

    init(settings: GWPolicySettings, appVersion: String? = nil, updatedAt: Date = Date()) {
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
        settings = try container.decodeIfPresent(GWPolicySettings.self, forKey: .settings) ?? .default
    }
}

/// 电源策略持久化：加载失败不崩溃；损坏文件隔离后回退默认值。
enum GWPolicyPersistence {
    /// 读取配置；文件不存在返回 nil；版本过高/损坏时抛出并（由调用方决定是否）隔离。
    static func load(from url: URL) throws -> GWPolicyDocument? {
        try GWJSONFileStore.load(GWPolicyDocument.self, from: url)
    }

    /// 原子保存，返回写入字节数。
    @discardableResult
    static func save(_ settings: GWPolicySettings, to url: URL) throws -> Int {
        let document = GWPolicyDocument(settings: settings.normalized())
        return try GWJSONFileStore.save(document, to: url)
    }

    /// 隔离不可解析/版本过高的配置文件（保留原文便于诊断）。
    @discardableResult
    static func quarantine(_ url: URL) -> URL? {
        GWJSONFileStore.quarantine(url)
    }
}
