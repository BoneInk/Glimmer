import Foundation
import Darwin

/// Explicitly requested deletion of a Workshop download and its imported copies.
/// Source files outside the app's managed roots are never moved or removed.
@MainActor
final class ManagedWallpaperDeletionService {
    private struct Candidate {
        let url: URL
        let root: URL
        let validatesOwnedTree: Bool
    }

    private let store: VideoLibraryStore
    private let playback: DesktopPlaybackController
    private let storage: AppStorage
    private let workshopLayout: SteamCMDLayout
    private let trashOperation: (URL) throws -> URL
    private let restoreOperation: (URL, URL) throws -> Void
    private var isDeleting = false
    private(set) var lastCleanupDiagnostic: String?

    init(store: VideoLibraryStore, playback: DesktopPlaybackController, storage: AppStorage,
         workshopLayout: SteamCMDLayout,
         trashOperation: ((URL) throws -> URL)? = nil,
         restoreOperation: ((URL, URL) throws -> Void)? = nil) {
        self.store = store
        self.playback = playback
        self.storage = storage
        self.workshopLayout = workshopLayout
        self.trashOperation = trashOperation ?? { url in
            var destination: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
            guard let destination else { throw DeletionError.failed("无法确认废纸篓中的文件位置") }
            return destination as URL
        }
        self.restoreOperation = restoreOperation ?? { source, destination in
            // Never overwrite a file created while an operation was in progress.
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    func delete(workshopID: String, itemID: UUID? = nil) async -> String? {
        lastCleanupDiagnostic = nil
        guard !Task.isCancelled else { return "已取消删除" }
        guard !isDeleting else { return "正在删除另一张壁纸，请稍候" }
        guard let id = WorkshopItemID(workshopID) else { return "作品 ID 无效" }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try validateManagedRoots()
            let matches = store.items.filter { $0.source == .steamWorkshop && $0.workshopID == id.value }
            if let itemID, !matches.contains(where: { $0.id == itemID }) {
                throw DeletionError.failed("素材与工坊作品不匹配，未删除任何文件")
            }
            let matchedIDs = Set(matches.map(\.id))
            try await AuthorPropertyServices.shared.withItemRemoval(itemIDs: matchedIDs, storage: storage) {
                let others = store.items.filter { !matchedIDs.contains($0.id) }
                let download = workshopLayout.downloadDirectory(for: id)
                // The layout itself must remain inside this app's Workshop directory.
                try Self.validate(workshopLayout.downloadsURL, within: storage.workshopDirectory)
                try Self.validate(download, within: workshopLayout.downloadsURL)
                var candidates: [Candidate] = []
                if FileManager.default.fileExists(atPath: download.path) {
                    if others.contains(where: { Self.contains(download, $0.fileURL) }) {
                        throw DeletionError.failed("其他素材仍在引用这个下载目录，未删除任何文件")
                    }
                    candidates.append(Candidate(url: download, root: workshopLayout.downloadsURL,
                                                validatesOwnedTree: false))
                }
                for item in matches {
                    let file = item.fileURL
                    // Relinked external files are preserved; only their library records are removed.
                    if Self.contains(storage.mediaDirectory, file) {
                        try Self.validate(file, within: storage.mediaDirectory)
                        let candidate: URL
                        if item.isProjectWallpaper {
                            // A Web wallpaper is an entire immutable owned project,
                            // not just project.json. Never widen this to an arbitrary parent.
                            let folder = file.deletingLastPathComponent()
                            let projects = storage.mediaDirectory.appendingPathComponent(item.isSceneWallpaper ? "SceneProjects" : "WebProjects", isDirectory: true)
                            guard file.lastPathComponent == "project.json",
                                  Self.canonical(folder.deletingLastPathComponent()) == Self.canonical(projects),
                                  UUID(uuidString: folder.lastPathComponent) != nil else {
                                throw DeletionError.failed("Web 项目管理路径无效，未删除任何文件")
                            }
                            candidate = folder
                        } else { candidate = file }
                        if !others.contains(where: { Self.canonical($0.fileURL) == Self.canonical(candidate) || Self.contains(candidate, $0.fileURL) }),
                           FileManager.default.fileExists(atPath: candidate.path) {
                            candidates.append(Candidate(url: candidate, root: storage.mediaDirectory,
                                                        validatesOwnedTree: false))
                        }
                    } else if Self.contains(download, file) {
                        try Self.validate(file, within: download)
                    }
                    // Only UUID-managed author data, never bookmark source URLs.
                    let resourceRoot = storage.root.appendingPathComponent("AuthorPropertyAssets", isDirectory: true)
                    let overrideRoot = storage.root.appendingPathComponent("AuthorPropertyOverrides", isDirectory: true)
                    for (path, root, expectedType) in [
                        (resourceRoot.appendingPathComponent(item.id.uuidString, isDirectory: true), resourceRoot, mode_t(S_IFDIR)),
                        (overrideRoot.appendingPathComponent(item.id.uuidString + ".json"), overrideRoot, mode_t(S_IFREG))
                    ] {
                        try Self.validate(path, within: root)
                        var metadata = stat()
                        if lstat(path.path, &metadata) == 0 {
                            guard metadata.st_mode & mode_t(S_IFMT) == expectedType, metadata.st_uid == getuid() else {
                                throw DeletionError.failed("作者设置路径不是当前用户的受管文件，未删除任何文件")
                            }
                            candidates.append(Candidate(url: path, root: root, validatesOwnedTree: false))
                        } else if errno != ENOENT { throw DeletionError.failed("无法检查作者设置路径，未删除任何文件") }
                    }
                    let thumbnail = storage.thumbnailURL(for: item.id)
                    try Self.validate(thumbnail, within: storage.thumbnailsDirectory)
                    if FileManager.default.fileExists(atPath: thumbnail.path) {
                        candidates.append(Candidate(url: thumbnail, root: storage.thumbnailsDirectory,
                                                    validatesOwnedTree: false))
                    }
                }
                let native = try nativeDownloadCandidates(for: id)
                candidates.append(contentsOf: native.candidates)
                if native.skippedCount > 0 {
                    let diagnostic = "已保留 \(native.skippedCount) 个身份无法确认的原生下载历史或暂存目录，可稍后手动检查"
                    lastCleanupDiagnostic = diagnostic
                    WorkshopLog.notice(diagnostic)
                }
                // A queued item may be explicitly deleted before its first byte is written.
                // The coordinator proves that queue record exists; at this filesystem boundary,
                // an otherwise valid item-scoped delete is intentionally idempotent.
                if matches.isEmpty && candidates.isEmpty { return }
                var seen: Set<String> = []
                candidates = candidates.filter { seen.insert(Self.canonical($0.url).path).inserted }
                var moved: [(original: URL, trashed: URL)] = []
                do {
                    for candidate in candidates {
                        guard !Task.isCancelled else { throw DeletionError.failed("已取消删除") }
                        try validateManagedRoots()
                        // Recheck after planning, immediately before each move.
                        try Self.validate(candidate.url, within: candidate.root)
                        if candidate.validatesOwnedTree { try Self.validateOwnedTree(candidate.url) }
                        moved.append((candidate.url, try trashOperation(candidate.url)))
                    }
                    // A failed atomic library write is handled by the same file rollback.
                    try store.removePersistedItems(ids: matchedIDs)
                } catch {
                    var rollbackFailed = false
                    for pair in moved.reversed() {
                        do { try restoreOperation(pair.trashed, pair.original) }
                        catch { rollbackFailed = true }
                    }
                    if candidates.contains(where: { !FileManager.default.fileExists(atPath: $0.url.path) }) {
                        rollbackFailed = true
                    }
                    if rollbackFailed {
                        throw DeletionError.failed("删除未完成，素材记录已保留；部分文件已在废纸篓中，请在访达中放回原处")
                    }
                    throw DeletionError.failed("删除未完成，文件与素材记录已保留：\(error.localizedDescription)")
                }
            }
            // Nothing changes in the library or live players until every move succeeds.
            playback.discardDeletedWallpaperSessions(itemIDs: matchedIDs)
            return nil
        } catch { return error.localizedDescription }
    }

    /// Deletes one local library item and only the app-owned copies attached to it.
    /// `originalPath` and every path outside the managed roots are always preserved.
    func deleteLocal(itemID: UUID) async -> String? {
        guard !Task.isCancelled else { return "已取消删除" }
        guard !isDeleting else { return "正在删除另一张壁纸，请稍候" }
        guard let item = store.item(withID: itemID) else { return "素材记录已不存在" }
        guard item.source == .local else { return "工坊壁纸必须从下载事务删除" }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try validateManagedRoots()
            try await AuthorPropertyServices.shared.withItemRemoval(itemIDs: [itemID], storage: storage) {
                let others = store.items.filter { $0.id != itemID }
                var candidates: [URL] = []
                let file = item.fileURL
                if Self.contains(storage.mediaDirectory, file) {
                    try Self.validate(file, within: storage.mediaDirectory)
                    let candidate: URL
                    if item.isProjectWallpaper {
                        let folder = file.deletingLastPathComponent()
                        let projects = storage.mediaDirectory.appendingPathComponent(
                            item.isSceneWallpaper ? "SceneProjects" : "WebProjects", isDirectory: true)
                        guard file.lastPathComponent == "project.json",
                              Self.canonical(folder.deletingLastPathComponent()) == Self.canonical(projects),
                              UUID(uuidString: folder.lastPathComponent) != nil else {
                            throw DeletionError.failed("项目管理路径无效，未删除任何文件")
                        }
                        candidate = folder
                    } else { candidate = file }
                    let containsOriginal = item.originalURL.map {
                        Self.canonical($0) == Self.canonical(candidate) || Self.contains(candidate, $0)
                    } ?? false
                    if !containsOriginal,
                       !others.contains(where: { Self.canonical($0.fileURL) == Self.canonical(candidate)
                        || Self.contains(candidate, $0.fileURL) }),
                       FileManager.default.fileExists(atPath: candidate.path) { candidates.append(candidate) }
                }
                let resourceRoot = storage.root.appendingPathComponent("AuthorPropertyAssets", isDirectory: true)
                let overrideRoot = storage.root.appendingPathComponent("AuthorPropertyOverrides", isDirectory: true)
                for (path, root, expectedType) in [
                    (resourceRoot.appendingPathComponent(item.id.uuidString, isDirectory: true), resourceRoot, mode_t(S_IFDIR)),
                    (overrideRoot.appendingPathComponent(item.id.uuidString + ".json"), overrideRoot, mode_t(S_IFREG))
                ] {
                    try Self.validate(path, within: root)
                    var metadata = stat()
                    if lstat(path.path, &metadata) == 0 {
                        guard metadata.st_mode & mode_t(S_IFMT) == expectedType, metadata.st_uid == getuid() else {
                            throw DeletionError.failed("作者设置路径不是当前用户的受管文件，未删除任何文件")
                        }
                        candidates.append(path)
                    } else if errno != ENOENT { throw DeletionError.failed("无法检查作者设置路径，未删除任何文件") }
                }
                let thumbnail = storage.thumbnailURL(for: item.id)
                try Self.validate(thumbnail, within: storage.thumbnailsDirectory)
                if FileManager.default.fileExists(atPath: thumbnail.path) { candidates.append(thumbnail) }
                var seen: Set<String> = []
                candidates = candidates.filter { seen.insert(Self.canonical($0).path).inserted }
                var moved: [(original: URL, trashed: URL)] = []
                do {
                    for candidate in candidates {
                        guard !Task.isCancelled else { throw DeletionError.failed("已取消删除") }
                        try validateManagedRoots()
                        let assetRoot = storage.root.appendingPathComponent("AuthorPropertyAssets", isDirectory: true)
                        let overrideRoot = storage.root.appendingPathComponent("AuthorPropertyOverrides", isDirectory: true)
                        let root = Self.contains(storage.mediaDirectory, candidate) ? storage.mediaDirectory
                            : Self.contains(assetRoot, candidate) ? assetRoot
                            : Self.contains(overrideRoot, candidate) ? overrideRoot : storage.thumbnailsDirectory
                        try Self.validate(candidate, within: root)
                        moved.append((candidate, try trashOperation(candidate)))
                    }
                    try store.removePersistedItems(ids: [itemID])
                } catch {
                    var rollbackFailed = false
                    for pair in moved.reversed() {
                        do { try restoreOperation(pair.trashed, pair.original) }
                        catch { rollbackFailed = true }
                    }
                    if candidates.contains(where: { !FileManager.default.fileExists(atPath: $0.path) }) { rollbackFailed = true }
                    if rollbackFailed {
                        throw DeletionError.failed("删除未完成，素材记录已保留；部分文件已在废纸篓中，请在访达中放回原处")
                    }
                    throw DeletionError.failed("删除未完成，文件与素材记录已保留：\(error.localizedDescription)")
                }
            }
            playback.discardDeletedWallpaperSessions(itemIDs: [itemID])
            return nil
        } catch { return error.localizedDescription }
    }

    private func validateManagedRoots() throws {
        let authorRoots = ["AuthorPropertyAssets", "AuthorPropertyOverrides"].map { storage.root.appendingPathComponent($0, isDirectory: true) }
        for directory in [storage.mediaDirectory, storage.thumbnailsDirectory, storage.workshopDirectory] + authorRoots {
            try Self.validate(directory, within: storage.root)
            var metadata = stat()
            if lstat(directory.path, &metadata) == 0 {
                guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), metadata.st_uid == getuid() else {
                    throw DeletionError.failed("管理目录不是当前用户的实际目录，未删除任何文件")
                }
            } else if errno != ENOENT { throw DeletionError.failed("无法检查管理目录，未删除任何文件") }
        }
    }

    /// Plans only item-scoped native artifacts. Account/session data under SteamCMD/home,
    /// the workspace root itself, the delivery lock and every other item are excluded.
    private func nativeDownloadCandidates(for id: WorkshopItemID) throws -> (candidates: [Candidate], skippedCount: Int) {
        let manager = FileManager.default
        let workspace = workshopLayout.root.deletingLastPathComponent()
            .appendingPathComponent("SteamContent", isDirectory: true)
        var result: [Candidate] = []
        var skipped = 0

        if manager.fileExists(atPath: workspace.path) {
            try Self.validate(workspace, within: storage.workshopDirectory)
            try Self.validateOwnedDirectory(workspace, privatePermissions: true)
            let items = workspace.appendingPathComponent("items", isDirectory: true)
            if manager.fileExists(atPath: items.path) {
                try Self.validate(items, within: workspace)
                try Self.validateOwnedDirectory(items)
                let item = items.appendingPathComponent(id.value, isDirectory: true)
                if manager.fileExists(atPath: item.path) {
                    try Self.validate(item, within: items)
                    try Self.validateOwnedTree(item)
                    result.append(Candidate(url: item, root: items, validatesOwnedTree: true))
                }
            }
        }

        let previous = workshopLayout.root.appendingPathComponent(".steam-content-previous", isDirectory: true)
        let stageParent = workshopLayout.downloadsURL
            .appendingPathComponent(String(WorkshopInputValidator.wallpaperEngineAppID), isDirectory: true)
        let archivePlans = [
            (root: previous, prefix: id.value + "-"),
            (root: stageParent, prefix: ".steam-content-stage-" + id.value + "-")
        ]
        for plan in archivePlans where manager.fileExists(atPath: plan.root.path) {
            do {
                let allowedRoot = plan.root == previous ? workshopLayout.root : workshopLayout.downloadsURL
                try Self.validate(plan.root, within: allowedRoot)
                try Self.validateOwnedDirectory(plan.root)
                let children = try manager.contentsOfDirectory(at: plan.root,
                    includingPropertiesForKeys: nil, options: [])
                for child in children where child.lastPathComponent.hasPrefix(plan.prefix) {
                    let suffix = String(child.lastPathComponent.dropFirst(plan.prefix.count))
                    guard let uuid = UUID(uuidString: suffix),
                          uuid.uuidString.caseInsensitiveCompare(suffix) == .orderedSame else {
                        skipped += 1
                        continue
                    }
                    do {
                        try Self.validate(child, within: plan.root)
                        try Self.validateOwnedTree(child)
                        guard try Self.hasTrustedDownloadManifest(child, itemID: id.value) else {
                            skipped += 1
                            continue
                        }
                        result.append(Candidate(url: child, root: plan.root, validatesOwnedTree: true))
                    } catch {
                        skipped += 1
                    }
                }
            } catch {
                // Delivery intentionally preserves anomalous history/stages after races.
                // An untrusted archive root is diagnostic-only and never blocks deletion
                // of the current, independently validated item artifacts.
                skipped += 1
            }
        }
        return (result, skipped)
    }

    private static func hasTrustedDownloadManifest(_ directory: URL, itemID: String) throws -> Bool {
        for name in GlimmerIdentity.downloadManifestNames {
            let manifestURL = directory.appendingPathComponent(name, isDirectory: false)
            try validate(manifestURL, within: directory)
            var metadata = stat()
            guard lstat(manifestURL.path, &metadata) == 0,
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  metadata.st_uid == getuid(), metadata.st_nlink == 1 else { continue }
            let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let manifest = try? decoder.decode(WorkshopDownloadManifest.self, from: data) else { continue }
            if manifest.appID == WorkshopInputValidator.wallpaperEngineAppID,
               manifest.publishedFileID == itemID { return true }
        }
        return false
    }

    private static func validateOwnedDirectory(_ url: URL, privatePermissions: Bool = false) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              metadata.st_uid == getuid(),
              !privatePermissions || metadata.st_mode & 0o077 == 0 else {
            throw DeletionError.failed("原生下载管理目录不安全，未删除任何文件")
        }
    }

    /// Native helper trees are private regular files/directories only. Rejecting links
    /// before Trash preserves the helper's no-follow/single-link trust boundary.
    private static func validateOwnedTree(_ root: URL) throws {
        try validateOwnedDirectory(root)
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: nil, options: []) else {
            throw DeletionError.failed("无法检查原生下载目录，未删除任何文件")
        }
        var count = 0
        for case let entry as URL in enumerator {
            count += 1
            guard count <= 100_000 else {
                throw DeletionError.failed("原生下载目录项目过多，未删除任何文件")
            }
            try validate(entry, within: root)
            var metadata = stat()
            guard lstat(entry.path, &metadata) == 0, metadata.st_uid == getuid() else {
                throw DeletionError.failed("原生下载目录包含不属于当前用户的节点，未删除任何文件")
            }
            let type = metadata.st_mode & mode_t(S_IFMT)
            guard type == mode_t(S_IFDIR)
                    || type == mode_t(S_IFREG) && metadata.st_nlink == 1 else {
                throw DeletionError.failed("原生下载目录包含符号链接、硬链接或特殊文件，未删除任何文件")
            }
        }
    }

    private static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    private static func contains(_ root: URL, _ candidate: URL) -> Bool {
        canonical(candidate).path.hasPrefix(canonical(root).path + "/")
    }
    private static func validate(_ candidate: URL, within root: URL) throws {
        let resolvedRoot = canonical(root)
        let lexicalRoot = root.standardizedFileURL
        let lexicalCandidate = candidate.standardizedFileURL
        guard candidate.isFileURL, root.isFileURL,
              lexicalCandidate.path.hasPrefix(lexicalRoot.path + "/") else {
            throw DeletionError.failed("文件不在此应用的管理目录内，未删除任何文件")
        }
        let relative = String(lexicalCandidate.path.dropFirst(lexicalRoot.path.count + 1))
        let expected = resolvedRoot.appendingPathComponent(relative).standardizedFileURL
        // URL equality also compares the directory hint. A missing managed
        // directory (for example an item's AuthorPropertyAssets UUID folder)
        // can therefore compare unequal to the same canonical filesystem path:
        // the candidate was built with `isDirectory: true`, while `expected`
        // was appended without that hint. Compare canonical paths instead;
        // symlink traversal still changes the resolved path and is rejected.
        guard canonical(candidate).path == expected.path else {
            throw DeletionError.failed("管理文件路径包含符号链接，未删除任何文件")
        }
        var metadata = stat()
        if lstat(lexicalCandidate.path, &metadata) == 0 {
            let type = metadata.st_mode & mode_t(S_IFMT)
            guard type != mode_t(S_IFREG) || metadata.st_nlink == 1 else {
                throw DeletionError.failed("管理文件与其他路径共享硬链接，未删除任何文件")
            }
        } else if errno != ENOENT {
            throw DeletionError.failed("无法检查管理文件路径，未删除任何文件")
        }
    }
    private enum DeletionError: LocalizedError {
        case failed(String)
        var errorDescription: String? { switch self { case .failed(let message): return message } }
    }
}
