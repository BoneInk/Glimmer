import CryptoKit
import Darwin
import Foundation

/// Shared bounded tree inspection for Workshop Web and Scene downloads.
///
/// The two project kinds intentionally keep distinct path ordering so their
/// existing content fingerprints remain stable. Safety policy, metadata checks
/// and the digest construction are shared.
struct WorkshopProjectTreeEntry: Equatable {
    let path: String
    let bytes: Int64
    let device: Int32
    let inode: UInt64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
}

struct WorkshopProjectTreeValidation {
    let entries: [WorkshopProjectTreeEntry]
    let contentFingerprint: String
    let totalByteSize: Int64
    let largeFileCount: Int
}

enum WorkshopProjectTreeOrdering {
    /// Preserve the existing Web fingerprint's Swift String ordering.
    case string
    /// Preserve the existing Scene fingerprint's UTF-8 byte ordering.
    case utf8
}

enum WorkshopProjectTreeValidator {
    static let maximumBytes: Int64 = 2_147_483_648
    static let maximumEntries = 20_000
    static let largeFileThreshold: Int64 = 32 * 1024 * 1024

    static func validate(root: URL, excluded: URL, label: String,
                         ordering: WorkshopProjectTreeOrdering) throws -> WorkshopProjectTreeValidation {
        try validate(root: root, excluded: [excluded], label: label, ordering: ordering)
    }

    static func validate(root: URL, excluded: [URL], label: String,
                         ordering: WorkshopProjectTreeOrdering) throws -> WorkshopProjectTreeValidation {
        // Host annotations are optional. A not-yet-created manifest contributes
        // no tree entry, so it cannot be excluded from an existing inventory.
        let excludedPaths = Set(excluded.compactMap { try? WebProjectPaths.canonical($0).path })
        let inventory = try entries(root: root, excludedPaths: excludedPaths, label: label, ordering: ordering)
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw invalid("无法读取 \(label) 项目目录") }
        defer { close(rootFD) }

        var tree = SHA256()
        var total: Int64 = 0
        var largeFiles = 0
        for entry in inventory {
            try Task.checkCancellation()
            let descriptorFD = try openRelative(entry.path, rootFD: rootFD, label: label)
            let handle = FileHandle(fileDescriptor: descriptorFD, closeOnDealloc: true)
            defer { try? handle.close() }
            var before = stat()
            guard fstat(descriptorFD, &before) == 0,
                  before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  before.st_dev == entry.device, before.st_ino == entry.inode else {
                throw invalid("\(label) 资源在校验期间被替换")
            }
            var hash = SHA256()
            var count: Int64 = 0
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                count += Int64(chunk.count)
                total += Int64(chunk.count)
                guard total <= maximumBytes else { throw invalid("\(label) 项目超过 2 GB") }
                hash.update(data: chunk)
            }
            var after = stat()
            guard fstat(descriptorFD, &after) == 0,
                  count == entry.bytes,
                  after.st_size == before.st_size,
                  after.st_mtimespec.tv_sec == entry.modifiedSeconds,
                  after.st_mtimespec.tv_nsec == entry.modifiedNanoseconds else {
                throw invalid("\(label) 资源在校验期间发生变化")
            }
            if count > largeFileThreshold { largeFiles += 1 }
            tree.update(data: Data(entry.path.utf8))
            tree.update(data: Data([0]))
            tree.update(data: Data(hash.finalize()))
        }
        guard try entries(root: root, excludedPaths: excludedPaths, label: label, ordering: ordering) == inventory else {
            throw invalid("\(label) 项目目录在校验期间发生变化")
        }
        return WorkshopProjectTreeValidation(
            entries: inventory,
            contentFingerprint: tree.finalize().map { String(format: "%02x", $0) }.joined(),
            totalByteSize: total,
            largeFileCount: largeFiles
        )
    }

    private static func entries(root: URL, excludedPaths: Set<String>, label: String,
                                ordering: WorkshopProjectTreeOrdering) throws -> [WorkshopProjectTreeEntry] {
        var traversalError: Error?
        guard let iterator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, error in traversalError = error; return false }
        ) else {
            throw invalid("无法枚举 \(label) 项目资源")
        }
        var result: [WorkshopProjectTreeEntry] = []
        var visited = 0
        var total: Int64 = 0
        for case let url as URL in iterator {
            try Task.checkCancellation()
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                throw invalid("\(label) 资源不可访问")
            }
            let type = metadata.st_mode & mode_t(S_IFMT)
            guard type == mode_t(S_IFREG) || type == mode_t(S_IFDIR) else {
                throw invalid("\(label) 项目包含符号链接或特殊文件")
            }
            let canonical = try WebProjectPaths.canonical(url)
            guard canonical.path.hasPrefix(root.path + "/") else {
                throw invalid("\(label) 资源超出项目目录")
            }
            if type == mode_t(S_IFREG), excludedPaths.contains(canonical.path) { continue }
            visited += 1
            guard visited <= maximumEntries else {
                throw invalid("\(label) 项目超过 20,000 个目录项")
            }
            if type == mode_t(S_IFREG) {
                total += Int64(metadata.st_size)
                guard metadata.st_size >= 0, total <= maximumBytes else {
                    throw invalid("\(label) 项目超过 2 GB")
                }
                result.append(WorkshopProjectTreeEntry(
                    path: String(canonical.path.dropFirst(root.path.count + 1)),
                    bytes: Int64(metadata.st_size),
                    device: metadata.st_dev,
                    inode: metadata.st_ino,
                    modifiedSeconds: metadata.st_mtimespec.tv_sec,
                    modifiedNanoseconds: metadata.st_mtimespec.tv_nsec
                ))
            }
        }
        if let traversalError { throw traversalError }
        return result.sorted { areInIncreasingOrder($0.path, $1.path, ordering: ordering) }
    }

    static func areInIncreasingOrder(_ lhs: String, _ rhs: String,
                                     ordering: WorkshopProjectTreeOrdering) -> Bool {
        switch ordering {
        case .string: return lhs < rhs
        case .utf8: return lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
        }
    }

    private static func openRelative(_ path: String, rootFD: Int32, label: String) throws -> Int32 {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else {
            throw invalid("\(label) 资源路径无效")
        }
        var current = dup(rootFD)
        guard current >= 0 else { throw invalid("无法打开 \(label) 项目目录") }
        for (index, part) in parts.enumerated() {
            let next = openat(
                current, part,
                O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
                    | (index == parts.count - 1 ? 0 : O_DIRECTORY)
            )
            close(current)
            guard next >= 0 else {
                throw invalid("无法读取 \(label) 资源或路径已被替换")
            }
            current = next
        }
        return current
    }

    private static func invalid(_ text: String) -> WorkshopDownloadError {
        .validationFailed(reason: text)
    }
}
