import Foundation

// B03（F09 电源策略 / F19 播放列表轮播）模块共享支撑。
//
// 设计约束：
// - 存储位于应用管理目录（Application Support/Glimmer），与主应用一致；
//   但使用独立 JSON 文件，绝不触碰主控维护的 library.json / LibraryDocument。
// - 所有写入为原子替换；解析失败的文件隔离重命名，便于诊断，不静默丢弃用户配置。
// - 本文件不依赖任何仍可能变化的 B01/B02 类型，可独立编译与验证。

/// 应用托管存储路径（B03 私有副本）。
///
/// 目录名与 `AppConstants.applicationSupportFolderName` 保持一致，
/// 这里保留独立常量，避免与仍在并行变化的 B01 代码产生编译耦合。
struct GWPersistencePaths: Sendable, Equatable {
    static let applicationSupportFolderName = AppConstants.applicationSupportFolderName
    static let policyFileName = "power-policy.json"
    static let playlistFileName = "playlist.json"

    /// 应用托管根目录。
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot
    }

    static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(applicationSupportFolderName, isDirectory: true)
    }

    var policyFile: URL { root.appendingPathComponent(Self.policyFileName, isDirectory: false) }
    var playlistFile: URL { root.appendingPathComponent(Self.playlistFileName, isDirectory: false) }

    /// 创建根目录（失败时抛出具名错误，供设置页展示）。
    func prepareRoot() throws {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw GWStorageError.storageUnavailable(error.localizedDescription)
        }
    }
}

/// B03 存储相关错误（中文说明，可直接用于诊断页/设置页）。
enum GWStorageError: LocalizedError, Equatable {
    case storageUnavailable(String)
    case unsupportedSchema(found: Int, supported: Int)
    case corrupted(String)

    var errorDescription: String? {
        switch self {
        case .storageUnavailable(let detail):
            return "配置目录不可用：\(detail)"
        case .unsupportedSchema(let found, let supported):
            return "配置文件版本 \(found) 高于当前应用支持的版本 \(supported)，请升级应用。"
        case .corrupted(let detail):
            return "配置文件无法解析：\(detail)"
        }
    }
}

/// 带版本号的 JSON 文档协议（schemaVersion 必须可读写）。
protocol GWVersionedDocument: Codable {
    static var currentSchemaVersion: Int { get }
    var schemaVersion: Int { get }
}

/// 通用 JSON 文件读写：ISO8601 日期、排序键、原子写入。
enum GWJSONFileStore {
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

    /// 读取文档；文件不存在返回 nil；版本过高或解析失败抛出具名错误。
    static func load<T: GWVersionedDocument>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw GWStorageError.corrupted("无法读取文件：\(error.localizedDescription)")
        }
        if data.isEmpty { return nil }
        do {
            let document = try makeDecoder().decode(T.self, from: data)
            guard document.schemaVersion <= T.currentSchemaVersion else {
                throw GWStorageError.unsupportedSchema(found: document.schemaVersion, supported: T.currentSchemaVersion)
            }
            return document
        } catch let error as GWStorageError {
            throw error
        } catch {
            throw GWStorageError.corrupted(error.localizedDescription)
        }
    }

    /// 原子写入，返回写入字节数。
    @discardableResult
    static func save<T: GWVersionedDocument>(_ document: T, to url: URL) throws -> Int {
        let data: Data
        do {
            data = try makeEncoder().encode(document)
        } catch {
            throw GWStorageError.corrupted("无法编码配置：\(error.localizedDescription)")
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw GWStorageError.storageUnavailable(error.localizedDescription)
        }
        return data.count
    }

    /// 把损坏/不受支持的配置文件移到旁路文件名，保留数据用于诊断。
    @discardableResult
    static func quarantine(_ url: URL) -> URL? {
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

/// 诊断辅助：只显示文件名，避免记录完整用户路径。
enum GWPathRedaction {
    static func short(_ url: URL) -> String {
        url.lastPathComponent.isEmpty ? "(空路径)" : url.lastPathComponent
    }
}
