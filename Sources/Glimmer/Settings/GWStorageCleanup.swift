import Foundation
import Observation

// F18 托管存储清点与清理。
//
// 范围与安全边界（固定不变）：
// - 只处理应用管理目录内的两类缓存与「未被引用的媒体副本」+ 创意工坊预览缓存；
// - 原始导入文件位于用户选择的位置，不在应用管理目录内，清理永不访问；
// - SteamCMD 运行时、登录缓存与创意工坊下载目录只统计、永不清理（只读文件元数据）；
// - 符号链接不跟随、不删除；每次删除前重新校验：文件仍是普通文件、仍在允许目录内、
//   当前未被播放/引用（通过注入的 protectedURLs 提供者实时读取）；
// - 删除采用「移到废纸篓」，可从废纸篓恢复；删除前再读取一次真实大小用于结果统计。

/// 清理分类。
enum GWCleanupCategory: String, CaseIterable, Identifiable, Sendable {
    /// 素材库不再引用的应用管理媒体副本。
    case unreferencedMedia
    /// 界面缩略图缓存（可自动重建）。
    case thumbnailCache
    /// 创意工坊预览图缓存（可自动重新下载）。
    case workshopPreviewCache

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unreferencedMedia: return "未被引用的媒体副本"
        case .thumbnailCache: return "缩略图缓存"
        case .workshopPreviewCache: return "创意工坊预览缓存"
        }
    }

    var symbolName: String {
        switch self {
        case .unreferencedMedia: return "film.stack"
        case .thumbnailCache: return "photo.on.rectangle"
        case .workshopPreviewCache: return "storefront"
        }
    }

    var scopeDescription: String {
        switch self {
        case .unreferencedMedia:
            return "素材库记录不再引用、当前也没有在播放或预览的应用管理副本。原始导入文件与外部路径不在此范围。"
        case .thumbnailCache:
            return "素材卡片缩略图缓存。删除后会自动重建，不影响素材与桌面播放。"
        case .workshopPreviewCache:
            return "创意工坊搜索结果与作品页的预览图缓存。删除后会在浏览时重新下载。"
        }
    }
}

/// 托管存储路径（默认与应用数据目录一致）。
struct GWManagedStoragePaths: Sendable, Equatable {
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? GWPersistencePaths.defaultRoot
    }

    var mediaDirectory: URL { root.appendingPathComponent("Media", isDirectory: true) }
    var thumbnailsDirectory: URL { root.appendingPathComponent("Thumbnails", isDirectory: true) }
    var workshopDirectory: URL { root.appendingPathComponent("Workshop", isDirectory: true) }
    /// SteamCMD 运行时整棵树（含登录缓存与下载），永不清理。
    var workshopSteamCMDDirectory: URL { workshopDirectory.appendingPathComponent("SteamCMD", isDirectory: true) }
    var workshopDownloadsDirectory: URL { workshopSteamCMDDirectory.appendingPathComponent("downloads", isDirectory: true) }
    var workshopPreviewCacheDirectory: URL { workshopDirectory.appendingPathComponent("PreviewCache", isDirectory: true) }

    func directory(for category: GWCleanupCategory) -> URL {
        switch category {
        case .unreferencedMedia: return mediaDirectory
        case .thumbnailCache: return thumbnailsDirectory
        case .workshopPreviewCache: return workshopPreviewCacheDirectory
        }
    }
}

/// Expands a referenced library item into every app-owned path that must remain
/// intact while the item can still be played or edited.
struct GWStorageProtection: Sendable {
    static func urls(for item: WallpaperItem, storageRoot: URL) -> Set<URL> {
        var urls: Set<URL> = [item.fileURL]
        if let original = item.originalURL { urls.insert(original) }
        guard item.isProjectWallpaper else { return urls }
        urls.insert(item.fileURL.deletingLastPathComponent())
        urls.insert(storageRoot.appendingPathComponent("AuthorPropertyAssets", isDirectory: true)
            .appendingPathComponent(item.id.uuidString, isDirectory: true))
        urls.insert(storageRoot.appendingPathComponent("AuthorPropertyOverrides", isDirectory: true)
            .appendingPathComponent(item.id.uuidString + ".json"))
        return urls
    }
}

/// 清理项的展示样本（只保留文件名，不展示完整路径）。
struct GWCleanupSample: Sendable, Equatable, Hashable, Identifiable {
    var name: String
    var bytes: Int64
    var id: String { name }
}

/// 单个分类的清点结果。
struct GWStorageCategoryInventory: Identifiable, Sendable, Equatable {
    var category: GWCleanupCategory
    /// 目录是否存在（不存在时不可清理）。
    var isAvailable: Bool
    var fileCount: Int
    var totalBytes: Int64
    var samples: [GWCleanupSample]

    var id: String { category.rawValue }

    var sizeText: String { GWSettingsFormat.bytes(totalBytes) }
}

/// 信息行（受保护的目录与只统计项）。
struct GWStorageInfoLine: Sendable, Equatable, Identifiable {
    var title: String
    var detail: String
    var id: String { title }
}

/// 存储清点总览。
struct GWStorageInventory: Sendable, Equatable {
    var generatedAt: Date
    var rootExists: Bool
    var categories: [GWStorageCategoryInventory]
    var infoLines: [GWStorageInfoLine]
    var protectedNotes: [String]

    var totalCleanableCount: Int {
        categories.filter(\.isAvailable).reduce(0) { $0 + $1.fileCount }
    }

    var totalCleanableBytes: Int64 {
        categories.filter(\.isAvailable).reduce(Int64(0)) { $0 + $1.totalBytes }
    }

    func category(_ category: GWCleanupCategory) -> GWStorageCategoryInventory? {
        categories.first { $0.category == category }
    }
}

/// 可清理候选项（内部使用）。
struct GWCleanupCandidate: Sendable, Equatable, Hashable, Identifiable {
    var category: GWCleanupCategory
    var url: URL
    var bytes: Int64

    var id: String { "\(category.rawValue)|\(url.path)" }
}

/// 删除前的实时复核结果。
enum GWRecheckOutcome: Sendable, Equatable {
    case allowed(currentBytes: Int64)
    case skipped(reason: String)
}

/// 单个文件的清理失败。
struct GWCleanupFailure: Sendable, Equatable, Identifiable {
    var name: String
    var message: String
    var id: String { "\(name)|\(message)" }
}

/// 清理结果。
struct GWCleanupResult: Sendable, Equatable {
    var removedCount: Int
    var removedBytes: Int64
    var skippedReasons: [String]
    var failures: [GWCleanupFailure]
    var finishedAt: Date

    var summaryText: String {
        var parts: [String] = []
        if removedCount > 0 {
            parts.append("已将 \(removedCount) 个文件（\(GWSettingsFormat.bytes(removedBytes))）移到废纸篓，可从废纸篓恢复。")
        } else {
            parts.append("本次没有文件被清理。")
        }
        if !skippedReasons.isEmpty {
            parts.append("跳过 \(skippedReasons.count) 个受保护或已变化的项目。")
        }
        if !failures.isEmpty {
            parts.append("\(failures.count) 个文件清理失败。")
        }
        return parts.joined(separator: " ")
    }
}

/// 扫描结果。
struct GWStorageScanResult: Sendable, Equatable {
    var inventory: GWStorageInventory
    var candidates: [GWCleanupCandidate]
}

/// 纯文件系统扫描与复核（无 UI 依赖，可独立验证）。
struct GWStorageScanner: Sendable {
    static let sampleLimit = 60

    // MARK: - 扫描

    static func scan(paths: GWManagedStoragePaths, protectedURLs: Set<URL>) -> GWStorageScanResult {
        let manager = FileManager.default
        let rootExists = manager.fileExists(atPath: paths.root.path)
        let protectedPaths = normalizedProtected(protectedURLs)
        var seenPaths = Set<String>()
        var categories: [GWStorageCategoryInventory] = []
        var candidates: [GWCleanupCandidate] = []

        for category in GWCleanupCategory.allCases {
            let directory = paths.directory(for: category)
            let available = manager.fileExists(atPath: directory.path)
            var tally = DirectoryTally()
            if available {
                tally = scanDirectory(
                    directory,
                    category: category,
                    protectedPaths: protectedPaths,
                    seenPaths: &seenPaths,
                    candidates: &candidates
                )
            }
            categories.append(GWStorageCategoryInventory(
                category: category,
                isAvailable: available,
                fileCount: tally.count,
                totalBytes: tally.bytes,
                samples: tally.samples
            ))
        }

        let inventory = GWStorageInventory(
            generatedAt: Date(),
            rootExists: rootExists,
            categories: categories,
            infoLines: makeInfoLines(paths: paths, rootExists: rootExists),
            protectedNotes: protectedNotes
        )
        return GWStorageScanResult(inventory: inventory, candidates: candidates)
    }

    private struct DirectoryTally {
        var count = 0
        var bytes: Int64 = 0
        var samples: [GWCleanupSample] = []
    }

    private static func scanDirectory(
        _ directory: URL,
        category: GWCleanupCategory,
        protectedPaths: Set<String>,
        seenPaths: inout Set<String>,
        candidates: inout [GWCleanupCandidate]
    ) -> DirectoryTally {
        var tally = DirectoryTally()
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return tally
        }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey, .fileSizeKey
            ]) else { continue }
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  values.isAliasFile != true else { continue }
            guard isInside(url, root: directory) else { continue }
            let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard !isProtected(resolvedPath, by: protectedPaths) else { continue }
            guard !seenPaths.contains(resolvedPath) else { continue }
            seenPaths.insert(resolvedPath)

            let size = Int64(values.fileSize ?? 0)
            tally.count += 1
            tally.bytes += size
            if tally.samples.count < sampleLimit {
                tally.samples.append(GWCleanupSample(name: url.lastPathComponent, bytes: size))
            }
            candidates.append(GWCleanupCandidate(category: category, url: url, bytes: size))
        }
        return tally
    }

    // MARK: - 删除前复核（每次删除前调用）

    static func recheck(
        candidate: GWCleanupCandidate,
        allowedRoot: URL,
        protectedPaths: Set<String>
    ) -> GWRecheckOutcome {
        let manager = FileManager.default
        guard manager.fileExists(atPath: candidate.url.path) else {
            return .skipped(reason: "文件已不存在")
        }
        guard let values = try? candidate.url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey, .fileSizeKey
        ]) else {
            return .skipped(reason: "无法读取文件信息")
        }
        guard values.isRegularFile == true else {
            return .skipped(reason: "不是普通文件")
        }
        guard values.isSymbolicLink != true, values.isAliasFile != true else {
            return .skipped(reason: "符号链接或替身文件，已跳过")
        }
        guard isInside(candidate.url, root: allowedRoot) else {
            return .skipped(reason: "路径不在应用管理目录内")
        }
        let resolvedPath = candidate.url.resolvingSymlinksInPath().standardizedFileURL.path
        guard !isProtected(resolvedPath, by: protectedPaths) else {
            return .skipped(reason: "正在播放或已被素材库引用")
        }
        return .allowed(currentBytes: Int64(values.fileSize ?? 0))
    }

    // MARK: - 路径辅助

    /// 受保护路径集合的规范化（同时提供解析符号链接前后两种形式，稳妥匹配）。
    static func normalizedProtected(_ urls: Set<URL>) -> Set<String> {
        var paths = Set<String>()
        for url in urls {
            paths.insert(url.standardizedFileURL.path)
            paths.insert(url.resolvingSymlinksInPath().standardizedFileURL.path)
        }
        return paths
    }

    /// Exact files and descendants of protected project/resource directories are
    /// protected. Path-component comparison keeps sibling names such as `item-2`
    /// outside a protected `item` directory cleanable.
    static func isProtected(_ candidatePath: String, by protectedPaths: Set<String>) -> Bool {
        let candidate = URL(fileURLWithPath: candidatePath).standardizedFileURL.pathComponents
        for protectedPath in protectedPaths {
            let protected = URL(fileURLWithPath: protectedPath).standardizedFileURL.pathComponents
            if candidate == protected { return true }
            if candidate.count > protected.count,
               candidate.prefix(protected.count).elementsEqual(protected) { return true }
        }
        return false
    }

    /// 文件（解析符号链接后）是否位于允许目录内。使用路径组件比较，避免前缀字符串误判。
    static func isInside(_ file: URL, root: URL) -> Bool {
        let filePath = file.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard !rootPath.isEmpty, rootPath != "/" else { return false }
        let fileComponents = URL(fileURLWithPath: filePath).pathComponents
        let rootComponents = URL(fileURLWithPath: rootPath).pathComponents
        guard fileComponents.count > rootComponents.count else { return false }
        return fileComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }

    // MARK: - 只读信息

    private static let protectedNotes: [String] = [
        "原始导入文件保存在你选择的位置，不在应用管理目录内，清理不会访问它们。",
        "正在播放的素材和被素材库引用的文件会被实时保护，绝不会被清理。",
        "SteamCMD 运行时、登录缓存与创意工坊下载目录永不清理。"
    ]

    private static func makeInfoLines(paths: GWManagedStoragePaths, rootExists: Bool) -> [GWStorageInfoLine] {
        var lines: [GWStorageInfoLine] = []
        let manager = FileManager.default

        if !rootExists {
            lines.append(GWStorageInfoLine(
                title: "应用数据目录",
                detail: "尚未创建（导入或应用壁纸后会自动创建）。"
            ))
        }

        let installRecord = paths.workshopSteamCMDDirectory.appendingPathComponent("install-record.json")
        let executable = paths.workshopSteamCMDDirectory.appendingPathComponent("steamcmd")
        let steamCMDPresent = manager.fileExists(atPath: installRecord.path)
            || manager.fileExists(atPath: executable.path)
        lines.append(GWStorageInfoLine(
            title: "SteamCMD 运行时",
            detail: steamCMDPresent
                ? "已就绪。运行时、登录缓存与下载目录均受保护，清理永不触碰。"
                : "尚未安装。需要使用创意工坊下载时，应用会给出安装引导。"
        ))

        let downloads = tallyMetadata(at: paths.workshopDownloadsDirectory)
        if downloads.count > 0 {
            lines.append(GWStorageInfoLine(
                title: "创意工坊内容",
                detail: "\(GWSettingsFormat.fileCount(downloads.count))，共 \(GWSettingsFormat.bytes(downloads.bytes))。本版本只统计、不清理：无法安全区分进行中的下载与仍被引用的内容。"
            ))
        } else {
            lines.append(GWStorageInfoLine(
                title: "创意工坊内容",
                detail: "暂无下载内容。"
            ))
        }
        return lines
    }

    /// 只读统计文件数量与大小（不读取文件内容；不进入登录缓存目录）。
    private static func tallyMetadata(at directory: URL) -> (count: Int, bytes: Int64) {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }
        var count = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            count += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return (count, bytes)
    }
}

/// 清理控制器：异步清点 + 可取消的删除流程（删除使用废纸篓，可恢复）。
///
/// 注入：
/// - `protectedURLsProvider`：主控实时提供「素材库引用 + 正在播放/预览」的文件 URL 集合；
///   每次删除前都会重新调用。
/// - `trashMover`：默认移到系统废纸篓；测试可注入临时目录实现，避免真实清理。
@MainActor
@Observable
final class GWStorageCleanupController {
    private(set) var inventory: GWStorageInventory?
    private(set) var candidates: [GWCleanupCandidate] = []
    private(set) var isScanning = false
    private(set) var isCleaning = false
    private(set) var lastResult: GWCleanupResult?
    private(set) var lastError: String?

    let paths: GWManagedStoragePaths

    private let protectedURLsProvider: @MainActor @Sendable () -> Set<URL>
    private let trashMover: @Sendable (URL) async throws -> URL?

    init(
        paths: GWManagedStoragePaths = GWManagedStoragePaths(),
        protectedURLsProvider: @escaping @MainActor @Sendable () -> Set<URL>,
        trashMover: @escaping @Sendable (URL) async throws -> URL? = GWStorageCleanupController.systemTrashMover
    ) {
        self.paths = paths
        self.protectedURLsProvider = protectedURLsProvider
        self.trashMover = trashMover
    }

    /// 异步重新清点（在后台线程扫描，不阻塞界面）。
    func refreshInventory() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let paths = self.paths
        let protectedURLs = protectedURLsProvider()
        let result = await Task.detached(priority: .userInitiated) {
            GWStorageScanner.scan(paths: paths, protectedURLs: protectedURLs)
        }.value
        inventory = result.inventory
        candidates = result.candidates
        lastError = nil
    }

    /// 所选分类的预计清理数量与大小。
    func preview(for categories: Set<GWCleanupCategory>) -> (count: Int, bytes: Int64) {
        var count = 0
        var bytes: Int64 = 0
        for candidate in candidates where categories.contains(candidate.category) {
            count += 1
            bytes += candidate.bytes
        }
        return (count, bytes)
    }

    /// 执行清理：每个文件删除前实时复核（普通文件、目录边界、未被引用/播放）。
    @discardableResult
    func performCleanup(categories: Set<GWCleanupCategory>) async -> GWCleanupResult {
        guard !isCleaning else {
            return GWCleanupResult(removedCount: 0, removedBytes: 0, skippedReasons: [], failures: [], finishedAt: Date())
        }
        isCleaning = true
        defer { isCleaning = false }

        let selected = candidates.filter { categories.contains($0.category) }
        var removedCount = 0
        var removedBytes: Int64 = 0
        var skipped: [String] = []
        var failures: [GWCleanupFailure] = []

        for candidate in selected {
            let protectedPaths = GWStorageScanner.normalizedProtected(protectedURLsProvider())
            let allowedRoot = paths.directory(for: candidate.category)
            switch GWStorageScanner.recheck(
                candidate: candidate,
                allowedRoot: allowedRoot,
                protectedPaths: protectedPaths
            ) {
            case .skipped(let reason):
                skipped.append("\(candidate.url.lastPathComponent)：\(reason)")
            case .allowed(let currentBytes):
                do {
                    _ = try await trashMover(candidate.url)
                    removedCount += 1
                    removedBytes += currentBytes
                } catch {
                    failures.append(GWCleanupFailure(
                        name: candidate.url.lastPathComponent,
                        message: error.localizedDescription
                    ))
                }
            }
        }

        let result = GWCleanupResult(
            removedCount: removedCount,
            removedBytes: removedBytes,
            skippedReasons: skipped,
            failures: failures,
            finishedAt: Date()
        )
        lastResult = result
        await refreshInventory()
        return result
    }

    /// 默认删除方式：移到系统废纸篓（可恢复）。
    static func systemTrashMover(_ url: URL) async throws -> URL? {
        try await Task.detached(priority: .utility) {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return resulting as URL?
        }.value
    }
}
