import Foundation

/// 素材库与设置的持久化载体（JSON 文档，带 schemaVersion）。
struct LibraryDocument: Codable, Sendable {
    var schemaVersion: Int
    var appVersion: String
    var updatedAt: Date
    var items: [WallpaperItem]
    /// 显示器 UUID → 当前指定的素材 ID。
    var assignments: [String: UUID]
    /// 显示器 UUID → 播放设置。
    var displaySettings: [String: DisplayPlaybackSettings]
    var appSettings: AppSettings

    init(
        schemaVersion: Int = AppConstants.librarySchemaVersion,
        appVersion: String = AppConstants.version,
        updatedAt: Date = Date(),
        items: [WallpaperItem] = [],
        assignments: [String: UUID] = [:],
        displaySettings: [String: DisplayPlaybackSettings] = [:],
        appSettings: AppSettings = .default
    ) {
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.updatedAt = updatedAt
        self.items = items
        self.assignments = assignments
        self.displaySettings = displaySettings
        self.appSettings = appSettings
    }
}

enum LibraryStoreError: LocalizedError {
    case unsupportedSchema(Int)
    case corrupted(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "配置文件版本 \(version) 高于当前应用支持的版本 \(AppConstants.librarySchemaVersion)，请升级应用。"
        case .corrupted(let detail):
            return "配置文件无法解析：\(detail)"
        }
    }
}

/// JSON 读写：只做磁盘 IO，不持有运行时状态。
enum LibraryPersistence {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func load(from url: URL) throws -> LibraryDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LibraryDocument()
        }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return LibraryDocument() }
        do {
            let document = try makeDecoder().decode(LibraryDocument.self, from: data)
            guard document.schemaVersion <= AppConstants.librarySchemaVersion else {
                throw LibraryStoreError.unsupportedSchema(document.schemaVersion)
            }
            return document
        } catch let error as LibraryStoreError {
            throw error
        } catch {
            throw LibraryStoreError.corrupted(error.localizedDescription)
        }
    }

    /// 原子写入，避免中途失败破坏已有配置。返回写入的字节数。
    @discardableResult
    static func save(_ document: LibraryDocument, to url: URL) throws -> Int {
        var document = document
        document.updatedAt = Date()
        let data = try makeEncoder().encode(document)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        return data.count
    }

    /// 将损坏的配置移动到旁路文件，便于诊断（不直接删除用户数据）。
    @discardableResult
    static func quarantineCorruptedFile(at url: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let target = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).corrupted-\(stamp)")
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }
}
