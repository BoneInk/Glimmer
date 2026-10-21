import CryptoKit
import Foundation

/// 工坊预览图缓存（内存 + 磁盘）。
///
/// - 网络请求通过 URLSession 真实执行；失败时返回 nil 并由 UI 显示占位图。
/// - 磁盘缓存位于应用管理目录（`Workshop/PreviewCache`），可安全删除。
actor WorkshopPreviewCache {
    static let shared = WorkshopPreviewCache()

    private let memory = NSCache<NSString, NSData>()
    private let directoryOverride: URL?
    private var inFlight: [String: Task<Data?, Never>] = [:]

    init(directory: URL? = nil) {
        self.directoryOverride = directory
        memory.countLimit = 220
        memory.totalCostLimit = 96 * 1024 * 1024
    }

    private var cacheDirectory: URL {
        if let directoryOverride { return directoryOverride }
        return AppStorage().workshopDirectory
            .appendingPathComponent("PreviewCache", isDirectory: true)
    }

    func data(for url: URL) async -> Data? {
        let key = url.absoluteString
        if let cached = memory.object(forKey: key as NSString) {
            return cached as Data
        }
        if let task = inFlight[key] {
            return await task.value
        }
        let task = Task<Data?, Never> { [cacheDirectory] in
            if let disk = Self.readFromDisk(url: url, directory: cacheDirectory) {
                return disk
            }
            var request = URLRequest(url: url)
            request.setValue(SteamHTTPClient.defaultUserAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    return nil
                }
                if data.count > 12 * 1024 * 1024 { return nil }
                Self.writeToDisk(data: data, url: url, directory: cacheDirectory)
                return data
            } catch {
                return nil
            }
        }
        inFlight[key] = task
        let data = await task.value
        inFlight[key] = nil
        if let data {
            memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        }
        return data
    }

    func invalidateAll() {
        memory.removeAllObjects()
    }

    func cacheSizeOnDisk() -> Int64 {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    func clearDiskCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    // MARK: - 磁盘

    private nonisolated static func fileName(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".img"
    }

    private nonisolated static func readFromDisk(url: URL, directory: URL) -> Data? {
        let file = directory.appendingPathComponent(fileName(for: url))
        return try? Data(contentsOf: file)
    }

    private nonisolated static func writeToDisk(data: Data, url: URL, directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(fileName(for: url))
            try data.write(to: file, options: .atomic)
        } catch {
            WorkshopLog.info("预览图写入缓存失败：\(error.localizedDescription)")
        }
    }
}
