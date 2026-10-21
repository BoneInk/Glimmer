import Foundation

/// The bytes a folder's files take on disk. Blocking file IO: call it off the main thread.
enum CacheFolderSize {
    static func allocatedSize(of folder: URL) -> Int64 {
        ThreadGuards.assertNotMainThread("CacheFolderSize.allocatedSize")
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                              errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            // Optional: a file removed while listing takes no space.
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
