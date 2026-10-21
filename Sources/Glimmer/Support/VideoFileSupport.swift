import Foundation
import CryptoKit
import UniformTypeIdentifiers

/// 视频文件判定与轻量指纹计算。
///
/// 设计要点：
/// - 只做「候选筛选」；真正能否播放必须由 AVFoundation 验证（见 VideoProbe）。
/// - 不加 shell；轻量指纹只筛选候选，重复导入需对已有副本逐块确认完整内容。
enum VideoFileSupport {
    /// 已确认可被 AVFoundation 打开的常见视频扩展名（不等于全部可播放，仍需验证）。
    static let knownVideoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "avi", "mkv", "webm", "mpg", "mpeg", "m2v",
        "wmv", "flv", "ts", "m2ts", "mts", "3gp", "3g2", "ogv", "vob", "asf", "divx"
    ]

    static var allowedContentTypes: [UTType] {
        var types: [UTType] = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        for ext in knownVideoExtensions {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return Array(Set(types))
    }

    static func isCandidateVideo(url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .movie) {
            return true
        }
        return knownVideoExtensions.contains(url.pathExtension.lowercased())
    }

    /// 轻量内容指纹：文件大小 + 头部 1 MiB 与尾部 64 KiB 的 SHA-256。
    ///
    /// 该指纹用于筛选重复候选，保持既有素材库格式兼容；相同大小的中部修改可能产生
    /// 相同指纹，因此已有文件仍须通过 haveIdenticalContents 确认完整内容。
    static func contentFingerprint(of url: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256Digest()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        hasher.update(string: "\(size):")

        let headLimit: Int64 = 1_048_576 // 1 MiB
        if let head = try handle.read(upToCount: Int(headLimit)), !head.isEmpty {
            hasher.update(data: head)
        }
        if size > headLimit + 65_536 {
            try handle.seek(toOffset: UInt64(max(0, size - 65_536)))
            if let tail = try handle.read(upToCount: 65_536) {
                hasher.update(data: tail)
            }
        }
        return hasher.finalize()
    }

    /// 有界内存的整文件比较。由导入服务在后台任务中调用，避免大视频阻塞界面。
    static func haveIdenticalContents(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let left = try FileHandle(forReadingFrom: lhs)
        defer { try? left.close() }
        let right = try FileHandle(forReadingFrom: rhs)
        defer { try? right.close() }
        let chunkSize = 1_048_576
        while true {
            try Task.checkCancellation()
            let leftChunk = try left.read(upToCount: chunkSize) ?? Data()
            let rightChunk = try right.read(upToCount: chunkSize) ?? Data()
            guard leftChunk == rightChunk else { return false }
            if leftChunk.isEmpty { return true }
        }
    }

    /// 递归扫描文件夹中的候选视频（限制深度，避免误扫大型目录树）。
    ///
    /// 显式跳过符号链接，避免跟随链接扫描到用户目录之外的路径。
    static func scanFolder(_ url: URL, maxDepth: Int = 3) -> [URL] {
        var results: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        for case let child as URL in enumerator {
            let depth = child.pathComponents.count - url.pathComponents.count
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            let values = try? child.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                continue
            }
            if values?.isDirectory == true || values?.isPackage == true {
                continue
            }
            if isCandidateVideo(url: child) {
                results.append(child)
            }
        }
        return results.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

/// 最小 SHA-256 封装：增量更新 + 十六进制摘要，供内容指纹使用。
struct SHA256Digest {
    private var hasher = SHA256()

    mutating func update(data: Data) {
        hasher.update(data: data)
    }

    mutating func update(string: String) {
        hasher.update(data: Data(string.utf8))
    }

    mutating func finalize() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
