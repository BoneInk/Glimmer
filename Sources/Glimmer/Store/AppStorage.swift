import Darwin
import Foundation

/// 应用数据目录（Application Support）管理。
///
/// 目录结构：
/// ```
/// ~/Library/Application Support/Glimmer/
///   library.json      素材库与设置（带 schemaVersion）
///   Media/           导入源视频的应用管理副本（原文件不动）
///   Thumbnails/      缩略图缓存（可安全删除，会自动重建）
///   Workshop/        Steam 创意工坊下载目录（B02 批次）
///   Desktop/         桌面替换前的图片备份（退出时恢复用）
/// ```
struct AppStorage: Sendable {
    let root: URL
    /// A launch-time failure that must be shown before an empty library can be
    /// mistaken for a fresh installation.
    let startupError: String?

    init(root: URL? = nil) {
        #if GW_UI_REVIEW
        // Compiled only into the isolated review app, including shared thumbnail/preview caches.
        if let reviewRoot = ProcessInfo.processInfo.environment["GW_UI_REVIEW_ROOT"] {
            self.root = URL(fileURLWithPath: reviewRoot, isDirectory: true)
            self.startupError = nil
            return
        }
        preconditionFailure("UI review requires a temporary GW_UI_REVIEW_ROOT")
        #else
        // Default construction deliberately performs no migration. The real
        // composition root runs GlimmerStorageMigration on a background task and
        // only constructs stores/controllers after it succeeds. This prevents an
        // accidental empty library from being created while the old tree is still
        // pending, conflicted, or unreadable.
        if let root {
            self.root = root
        } else {
            self.root = GlimmerStorageMigration.defaultLocations().target
        }
        self.startupError = nil
        #endif
    }

    var libraryFile: URL { root.appendingPathComponent(AppConstants.libraryFileName, isDirectory: false) }
    var mediaDirectory: URL { root.appendingPathComponent("Media", isDirectory: true) }
    var thumbnailsDirectory: URL { root.appendingPathComponent("Thumbnails", isDirectory: true) }
    var workshopDirectory: URL { root.appendingPathComponent("Workshop", isDirectory: true) }
    var desktopBackupDirectory: URL { root.appendingPathComponent("Desktop", isDirectory: true) }

    /// 创建所需目录，失败时抛出带原因的 AppFileError。
    func prepareDirectories() throws {
        if let startupError {
            throw AppFileError.storageUnavailable(startupError)
        }
        let manager = FileManager.default
        var rootInfo = stat()
        if lstat(root.path, &rootInfo) == 0,
           rootInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
            throw AppFileError.storageUnavailable("数据目录不能是符号链接")
        }
        for directory in [root, mediaDirectory, thumbnailsDirectory, workshopDirectory, desktopBackupDirectory] {
            do {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw AppFileError.storageUnavailable("\(PathRedaction.short(directory)): \(error.localizedDescription)")
            }
        }
        do {
            try GlimmerStorageMigration.ensureInitializedProfile(at: root)
        } catch {
            throw AppFileError.storageUnavailable(error.localizedDescription)
        }
    }

    /// 计算应用管理目录占用（用于设置页展示，不包含原始导入文件）。
    func managedDiskUsageBytes() -> Int64 {
        let manager = FileManager.default
        var total: Int64 = 0
        for directory in [mediaDirectory, thumbnailsDirectory, workshopDirectory] {
            guard let enumerator = manager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true {
                    total += Int64(values?.fileSize ?? 0)
                }
            }
        }
        return total
    }

    /// 在媒体目录中生成不与现有文件冲突的目标 URL。
    func uniqueMediaURL(for fileName: String) -> URL {
        let manager = FileManager.default
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = mediaDirectory.appendingPathComponent(fileName, isDirectory: false)
        var index = 2
        while manager.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = mediaDirectory.appendingPathComponent(name, isDirectory: false)
            index += 1
            if index > 9999 { break }
        }
        return candidate
    }

    func thumbnailURL(for id: UUID) -> URL {
        thumbnailsDirectory.appendingPathComponent("\(id.uuidString).jpg", isDirectory: false)
    }
}

/// One-way, non-destructive migration from the previous application-support
/// directory. The old tree is only read. A complete clone is renamed into place
/// with RENAME_EXCL, so an empty, partial, or concurrent target is never silently
/// accepted as the migrated library.
enum GlimmerStorageMigration {
    static let profileMarkerFileName = ".glimmer-profile.json"
    private static let profileMarkerSchemaVersion = 1
    private static let maximumProfileMarkerBytes = 4_096
    private static let maximumEntries = 200_000

    struct Progress: Sendable, Equatable {
        let completedFiles: Int
        let totalFiles: Int
        let fraction: Double?
        let message: String
    }

    typealias ProgressHandler = @Sendable (Progress) -> Void

    private struct TestHooks: Sendable {
        var interruptAfterRegularFiles: Int?
    }

    private struct Snapshot: Equatable {
        let path: String
        let isDirectory: Bool
        let isSymbolicLink: Bool
        let linkDestination: String?
        let size: Int64
        let mode: UInt16
        let device: Int32
        let inode: UInt64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
    }

    struct TestHooksUnavailable: Error {}

    /// Current default locations. Kept together so the startup gate and routine
    /// storage access can never disagree about the source/target pair.
    static func defaultLocations() -> (source: URL, target: URL) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return (
            base.appendingPathComponent(GlimmerIdentity.legacyApplicationSupportFolderName, isDirectory: true),
            base.appendingPathComponent(AppConstants.applicationSupportFolderName, isDirectory: true)
        )
    }

    /// Read-only launch gate. Only an existing legacy directory plus an absent
    /// target can produce a migration. An initialized target is ready, and an
    /// existing unmarked target is a conflict for the migrator rather than a
    /// reason to ask about the old process. The retained legacy backup therefore
    /// never blocks later launches.
    static func requiresMigration(source sourceURL: URL, target targetURL: URL) -> Bool {
        var targetInfo = stat()
        guard lstat(targetURL.path, &targetInfo) != 0, errno == ENOENT else { return false }
        var sourceInfo = stat()
        guard lstat(sourceURL.path, &sourceInfo) == 0,
              sourceInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return false }
        return true
    }

    /// Returns true only when this invocation published a new target.
    @discardableResult
    static func migrateIfNeeded(source sourceURL: URL, target targetURL: URL,
                                progress: ProgressHandler? = nil) throws -> Bool {
        try migrate(source: sourceURL, target: targetURL, progress: progress, hooks: .init())
    }

    /// Same migration path with a deterministic interruption point for tests.
    @discardableResult
    static func migrateIfNeededForTesting(source sourceURL: URL, target targetURL: URL,
                                         interruptAfterRegularFiles: Int,
                                         progress: ProgressHandler? = nil) throws -> Bool {
        try migrate(source: sourceURL, target: targetURL, progress: progress,
                    hooks: .init(interruptAfterRegularFiles: interruptAfterRegularFiles))
    }

    private static func migrate(source sourceURL: URL, target targetURL: URL,
                                progress: ProgressHandler?,
                                hooks: TestHooks) throws -> Bool {
        let fileManager = FileManager.default
        guard sourceURL.isFileURL, targetURL.isFileURL else {
            throw MigrationError.unsafePath("迁移路径必须是绝对文件路径")
        }
        guard !hasRelativeComponent(sourceURL.path), !hasRelativeComponent(targetURL.path) else {
            throw MigrationError.unsafePath("迁移路径不能包含相对节点")
        }
        // Do not use `standardizedFileURL` here: Foundation may resolve an
        // existing ancestor such as `/private/tmp` through `/tmp`, which would
        // bypass the literal no-follow target checks. Relative `.`/`..` nodes
        // have already been rejected above.
        let source = sourceURL
        let target = targetURL
        guard source.path.hasPrefix("/"), target.path.hasPrefix("/") else {
            throw MigrationError.unsafePath("迁移路径必须是绝对文件路径")
        }
        guard source.path != target.path,
              !source.path.hasPrefix(target.path + "/"),
              !target.path.hasPrefix(source.path + "/") else {
            throw MigrationError.unsafePath("源目录与目标目录不能相同或互相包含")
        }

        // Validate the literal target (and every existing ancestor) first. Never
        // resolve a target symlink: resolving it would publish into a different
        // directory than the one requested by the application.
        try rejectSymlinkComponents(target, allowMissing: true)

        var targetInfo = stat()
        let targetExists = lstat(target.path, &targetInfo) == 0
        if targetExists {
            guard targetInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw MigrationError.conflict("新数据路径已存在且不是目录，未覆盖")
            }
            // A target is trustworthy only when it carries the completed-profile
            // marker. Check this even when the source is absent: an empty or
            // partially-created target must be surfaced as a conflict rather than
            // being mistaken for a fresh installation.
            guard isInitializedProfile(at: target) else {
                throw MigrationError.conflict(
                    "新数据目录已存在但不是完整初始化的 Glimmer 配置；为保护旧库未合并、覆盖或删除任一目录"
                )
            }
        } else if errno != ENOENT {
            throw MigrationError.conflict("无法确认新数据路径状态，未写入")
        }

        try rejectSymlinkComponents(source, allowMissing: true)
        var sourceInfo = stat()
        guard lstat(source.path, &sourceInfo) == 0 else {
            if errno == ENOENT { return false }
            throw MigrationError.unreadable("无法读取旧数据目录")
        }
        guard sourceInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw MigrationError.unsafeSource("旧数据路径不是普通目录")
        }

        if targetExists { return false }

        report(progress, completed: 0, total: 0, message: "正在检查旧数据…")
        let sourceBefore = try scan(source)
        let fileCount = sourceBefore.filter { !$0.isDirectory }.count
        let byteCount = sourceBefore.reduce(Int64(0)) { $0 + ($1.isDirectory ? 0 : $1.size) }

        let parent = target.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        } catch {
            throw MigrationError.unreadable("无法创建新数据父目录")
        }
        try rejectSymlinkComponents(parent, allowMissing: false)

        // Re-check after creating the parent: another launch may have initialized
        // the target while the source was being scanned.
        if lstat(target.path, &targetInfo) == 0 {
            guard targetInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  isInitializedProfile(at: target) else {
                throw MigrationError.conflict(
                    "迁移期间出现新的目标目录，但其不是完整初始化的 Glimmer 配置；两个目录均已保留"
                )
            }
            return false
        }
        guard errno == ENOENT else { throw MigrationError.conflict("无法确认目标目录状态，未覆盖") }

        let stageName = ".Glimmer-migration-\(UUID().uuidString)"
        let stage = parent.appendingPathComponent(stageName, isDirectory: true)
        var promoted = false
        defer {
            if !promoted { try? fileManager.removeItem(at: stage) }
        }

        do {
            try copyTree(from: source, to: stage, totalFiles: fileCount,
                         progress: progress, hooks: hooks)
            guard try scan(source) == sourceBefore else {
                throw MigrationError.sourceChanged("旧数据在迁移期间发生变化，未推进新目录")
            }
            let copied = try scan(stage)
            guard snapshotsMatchForCopy(sourceBefore, copied) else {
                throw MigrationError.verificationFailed("迁移副本与旧数据不一致，未推进新目录")
            }
            try relocateManagedReferences(in: stage, legacyRoot: source, newRoot: target)
            try writeProfileMarker(to: stage, source: "legacy-migration",
                                   fileCount: fileCount, byteCount: byteCount)
            report(progress, completed: fileCount, total: fileCount, message: "正在提交迁移结果…")

            let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parentFD >= 0 else { throw MigrationError.verificationFailed("无法锁定新数据父目录") }
            defer { close(parentFD) }
            var existing = stat()
            if fstatat(parentFD, target.lastPathComponent, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                guard existing.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                      isInitializedProfile(at: target) else {
                    throw MigrationError.conflict(
                        "并发创建的目标目录不完整；两个目录均已保留，请先处理目标目录后重试"
                    )
                }
                return false
            }
            guard errno == ENOENT else { throw MigrationError.conflict("无法确认目标目录状态，未覆盖") }
            guard renameatx_np(parentFD, stageName, parentFD, target.lastPathComponent,
                               UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST {
                    guard isInitializedProfile(at: target) else {
                        throw MigrationError.conflict("目标目录在提交时出现且不完整；两个目录均已保留")
                    }
                    return false
                }
                throw MigrationError.verificationFailed("无法原子发布迁移目录")
            }
            _ = fsync(parentFD)
            promoted = true
            return true
        } catch let error as MigrationError {
            throw error
        } catch {
            throw MigrationError.verificationFailed(error.localizedDescription)
        }
    }

    enum MigrationError: LocalizedError, Equatable {
        case unsafePath(String)
        case unsafeSource(String)
        case unreadable(String)
        case conflict(String)
        case sourceChanged(String)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsafePath(let text), .unsafeSource(let text), .unreadable(let text),
                 .conflict(let text), .sourceChanged(let text), .verificationFailed(let text):
                return text
            }
        }
    }

    /// Creates the marker for a brand-new profile. An existing valid marker is
    /// preserved; an existing malformed marker is a conflict rather than a
    /// reason to treat the directory as an empty library.
    static func ensureInitializedProfile(at root: URL) throws {
        var info = stat()
        if lstat(root.appendingPathComponent(profileMarkerFileName).path, &info) == 0 {
            guard isInitializedProfile(at: root) else {
                throw MigrationError.conflict("数据目录存在但缺少有效的 Glimmer 初始化标记")
            }
            return
        }
        guard errno == ENOENT else {
            throw MigrationError.conflict("无法确认 Glimmer 初始化标记状态")
        }
        try writeProfileMarker(to: root, source: "new-profile", fileCount: 0, byteCount: 0)
    }

    static func isInitializedProfile(at root: URL) -> Bool {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { return false }
        defer { close(rootFD) }
        let fd = openat(rootFD, profileMarkerFileName,
                        O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size > 0, info.st_size <= maximumProfileMarkerBytes else { return false }
        var data = Data(count: Int(info.st_size))
        var offset = 0
        let complete = data.withUnsafeMutableBytes { buffer -> Bool in
            while offset < buffer.count {
                let count = read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard complete,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              dictionary["schemaVersion"] as? Int == profileMarkerSchemaVersion,
              dictionary["application"] as? String == GlimmerIdentity.displayName,
              dictionary["source"] is String else { return false }
        return true
    }

    private static func writeProfileMarker(to root: URL, source: String,
                                           fileCount: Int, byteCount: Int64) throws {
        let object: [String: Any] = [
            "application": GlimmerIdentity.displayName,
            "schemaVersion": profileMarkerSchemaVersion,
            "source": source,
            "sourceFileCount": fileCount,
            "sourceByteCount": byteCount,
            "createdAt": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard data.count <= maximumProfileMarkerBytes else {
            throw MigrationError.verificationFailed("Glimmer 初始化标记异常过大")
        }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw MigrationError.verificationFailed("无法打开数据目录") }
        defer { close(rootFD) }
        var info = stat()
        if fstatat(rootFD, profileMarkerFileName, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard unlinkat(rootFD, profileMarkerFileName, 0) == 0 else {
                throw MigrationError.verificationFailed("无法替换 Glimmer 初始化标记")
            }
        } else if errno != ENOENT {
            throw MigrationError.conflict("无法确认 Glimmer 初始化标记状态")
        }
        let fd = openat(rootFD, profileMarkerFileName,
                        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MigrationError.verificationFailed("无法创建 Glimmer 初始化标记") }
        defer { close(fd) }
        var offset = 0
        let written = data.withUnsafeBytes { buffer -> Bool in
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard written, fchmod(fd, 0o600) == 0, fsync(fd) == 0, fsync(rootFD) == 0 else {
            throw MigrationError.verificationFailed("Glimmer 初始化标记未能持久化")
        }
    }

    private static func hasRelativeComponent(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0 == "." || $0 == ".." }
    }

    private static func rejectSymlinkComponents(_ url: URL, allowMissing: Bool) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        let parts = url.path.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            current.appendPathComponent(part)
            var info = stat()
            let status = lstat(current.path, &info)
            if status != 0 {
                if allowMissing && errno == ENOENT { return }
                throw MigrationError.unsafePath("迁移路径包含不可访问节点")
            }
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                throw MigrationError.unsafePath(
                    "迁移路径包含符号链接：\(PathRedaction.short(current))")
            }
            if index < parts.count - 1, info.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR) {
                throw MigrationError.unsafePath(
                    "迁移路径包含非目录节点：\(PathRedaction.short(current))")
            }
        }
    }

    private static func scan(_ root: URL) throws -> [Snapshot] {
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw MigrationError.unreadable("无法读取目录") }
        defer { close(descriptor) }
        guard let rootRealPath = realPath(root.path) else {
            throw MigrationError.unsafePath("无法解析迁移源目录")
        }
        var result: [Snapshot] = []
        var visited = 0
        func walk(_ fd: Int32, prefix: String) throws {
            let duplicate = dup(fd)
            guard duplicate >= 0, let stream = fdopendir(duplicate) else {
                if duplicate >= 0 { close(duplicate) }
                throw MigrationError.unreadable("无法枚举迁移目录")
            }
            defer { closedir(stream) }
            rewinddir(stream)
            while true {
                errno = 0
                guard let item = readdir(stream) else {
                    if errno != 0 { throw MigrationError.unreadable("迁移目录枚举未完成") }
                    break
                }
                let name = directoryEntryName(item)
                if name == "." || name == ".." { continue }
                visited += 1
                guard visited <= maximumEntries else { throw MigrationError.unsafeSource("迁移目录项目过多") }
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw MigrationError.sourceChanged("迁移目录在检查期间发生变化")
                }
                let type = info.st_mode & mode_t(S_IFMT)
                if type == mode_t(S_IFDIR) {
                    result.append(snapshot(relative, info, directory: true, linkDestination: nil))
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw MigrationError.unsafeSource("迁移目录包含符号链接或特殊节点") }
                    defer { close(child) }
                    try walk(child, prefix: relative)
                } else if type == mode_t(S_IFREG) {
                    result.append(snapshot(relative, info, directory: false, linkDestination: nil))
                } else if type == mode_t(S_IFLNK) {
                    let destination = try readSymbolicLink(fd: fd, name: name)
                    try validateSymbolicLink(destination, linkRelativePath: relative,
                                             rootPath: root.path, rootRealPath: rootRealPath)
                    result.append(snapshot(relative, info, directory: false,
                                           linkDestination: destination))
                } else {
                    throw MigrationError.unsafeSource("迁移源包含特殊文件")
                }
            }
        }
        try walk(descriptor, prefix: "")
        return result.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    private static func snapshot(_ path: String, _ info: stat, directory: Bool,
                                 linkDestination: String?) -> Snapshot {
        Snapshot(path: path, isDirectory: directory, isSymbolicLink: linkDestination != nil,
                 linkDestination: linkDestination, size: directory ? 0 : Int64(info.st_size),
                 mode: UInt16(info.st_mode & 0o777), device: info.st_dev, inode: info.st_ino,
                 modifiedSeconds: info.st_mtimespec.tv_sec,
                 modifiedNanoseconds: info.st_mtimespec.tv_nsec)
    }

    private static func snapshotsMatchForCopy(_ source: [Snapshot], _ copy: [Snapshot]) -> Bool {
        guard source.count == copy.count else { return false }
        for (left, right) in zip(source, copy) {
            guard left.path == right.path,
                  left.isDirectory == right.isDirectory,
                  left.isSymbolicLink == right.isSymbolicLink,
                  left.linkDestination == right.linkDestination,
                  left.size == right.size,
                  left.mode == right.mode else { return false }
        }
        return true
    }

    private static func copyTree(from source: URL, to target: URL, totalFiles: Int,
                                 progress: ProgressHandler?, hooks: TestHooks) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: target, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        let sourceFD = open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw MigrationError.unreadable("无法打开旧数据目录") }
        defer { close(sourceFD) }
        let targetFD = open(target.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard targetFD >= 0 else { throw MigrationError.verificationFailed("无法打开迁移暂存目录") }
        defer { close(targetFD) }
        guard let rootRealPath = realPath(source.path) else {
            throw MigrationError.unsafePath("无法解析迁移源目录")
        }
        var copiedEntries = 0
        var copiedRegularFiles = 0

        func copyDirectory(_ sourceFD: Int32, _ targetFD: Int32, prefix: String) throws {
            let duplicate = dup(sourceFD)
            guard duplicate >= 0, let stream = fdopendir(duplicate) else {
                if duplicate >= 0 { close(duplicate) }
                throw MigrationError.unreadable("无法枚举待迁移目录")
            }
            defer { closedir(stream) }
            rewinddir(stream)
            while true {
                errno = 0
                guard let item = readdir(stream) else {
                    if errno != 0 { throw MigrationError.unreadable("待迁移目录枚举未完成") }
                    break
                }
                let name = directoryEntryName(item)
                if name == "." || name == ".." { continue }
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                var info = stat()
                guard fstatat(sourceFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw MigrationError.sourceChanged("待迁移目录在复制期间发生变化")
                }
                let type = info.st_mode & mode_t(S_IFMT)
                if type == mode_t(S_IFDIR) {
                    let sourceChild = openat(sourceFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard sourceChild >= 0 else { throw MigrationError.unsafeSource("待迁移目录包含符号链接") }
                    defer { close(sourceChild) }
                    guard mkdirat(targetFD, name, 0o700) == 0 else {
                        throw MigrationError.verificationFailed("无法创建迁移子目录")
                    }
                    let targetChild = openat(targetFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard targetChild >= 0 else { throw MigrationError.verificationFailed("无法打开迁移子目录") }
                    defer { close(targetChild) }
                    try copyDirectory(sourceChild, targetChild, prefix: relative)
                    _ = fchmod(targetChild, info.st_mode & 0o777)
                } else if type == mode_t(S_IFREG) {
                    try copyRegularFile(name: name, sourceFD: sourceFD, targetFD: targetFD,
                                        metadata: info)
                    copiedRegularFiles += 1
                    copiedEntries += 1
                    report(progress, completed: copiedEntries, total: totalFiles,
                           message: "正在复制旧数据…")
                    if let limit = hooks.interruptAfterRegularFiles,
                       copiedRegularFiles >= limit {
                        throw MigrationError.verificationFailed("测试注入：复制中断")
                    }
                } else if type == mode_t(S_IFLNK) {
                    let destination = try readSymbolicLink(fd: sourceFD, name: name)
                    try validateSymbolicLink(destination, linkRelativePath: relative,
                                             rootPath: source.path, rootRealPath: rootRealPath)
                    let created = name.withCString { namePointer in
                        destination.withCString {
                            symlinkat($0, targetFD, namePointer)
                        }
                    }
                    guard created == 0 else {
                        throw MigrationError.verificationFailed("无法复制旧数据中的安全符号链接")
                    }
                    let copiedDestination = try readSymbolicLink(fd: targetFD, name: name)
                    guard copiedDestination == destination else {
                        throw MigrationError.verificationFailed("迁移符号链接目标不一致")
                    }
                    copiedEntries += 1
                    report(progress, completed: copiedEntries, total: totalFiles,
                           message: "正在复制旧数据…")
                } else {
                    throw MigrationError.unsafeSource("待迁移目录包含特殊文件")
                }
            }
        }

        try copyDirectory(sourceFD, targetFD, prefix: "")
        var rootInfo = stat()
        guard fstat(sourceFD, &rootInfo) == 0 else {
            throw MigrationError.unreadable("无法读取旧数据目录属性")
        }
        _ = fchmod(targetFD, rootInfo.st_mode & 0o777)
        report(progress, completed: copiedEntries, total: totalFiles, message: "正在校验迁移副本…")
    }

    private static func copyRegularFile(name: String, sourceFD: Int32, targetFD: Int32,
                                        metadata: stat) throws {
        let input = openat(sourceFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw MigrationError.unreadable("无法打开待迁移文件") }
        defer { close(input) }
        var before = stat()
        guard fstat(input, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_ino == metadata.st_ino, before.st_dev == metadata.st_dev,
              before.st_size == metadata.st_size else {
            throw MigrationError.sourceChanged("待迁移文件在打开期间发生变化")
        }

        // APFS clone first: no user-byte loop on the main/startup path and still
        // verified by descriptor identity and size below. Unsupported clone
        // filesystems fall back to the bounded read/write path.
        let cloned = name.withCString { fclonefileat(input, targetFD, $0, 0) } == 0
        if cloned {
            let output = openat(targetFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard output >= 0 else { throw MigrationError.verificationFailed("无法打开克隆文件") }
            defer { close(output) }
            var outputInfo = stat()
            guard fstat(output, &outputInfo) == 0,
                  outputInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  outputInfo.st_size == before.st_size,
                  fchmod(output, before.st_mode & 0o777) == 0,
                  fsync(output) == 0 else {
                throw MigrationError.verificationFailed("克隆文件校验失败")
            }
            try verifySourceUnchanged(input, before: before)
            return
        }

        // A failed clone may have left a destination entry on some filesystems.
        _ = unlinkat(targetFD, name, 0)
        let output = openat(targetFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                            before.st_mode & 0o777)
        guard output >= 0 else { throw MigrationError.verificationFailed("无法创建迁移文件") }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        var copied: Int64 = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw MigrationError.unreadable("读取待迁移文件失败") }
            if count == 0 { break }
            copied += Int64(count)
            guard copied <= Int64(before.st_size) else {
                throw MigrationError.sourceChanged("待迁移文件在复制期间增长")
            }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes {
                    write(output, $0.baseAddress!.advanced(by: offset), count - offset)
                }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw MigrationError.verificationFailed("写入迁移文件失败") }
                offset += written
            }
        }
        var after = stat()
        guard copied == Int64(before.st_size), fstat(input, &after) == 0,
              after.st_size == before.st_size, after.st_ino == before.st_ino,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              fchmod(output, before.st_mode & 0o777) == 0, fsync(output) == 0 else {
            throw MigrationError.sourceChanged("待迁移文件在复制期间发生变化")
        }
    }

    private static func verifySourceUnchanged(_ input: Int32, before: stat) throws {
        var after = stat()
        guard fstat(input, &after) == 0,
              after.st_size == before.st_size,
              after.st_ino == before.st_ino,
              after.st_dev == before.st_dev,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
            throw MigrationError.sourceChanged("待迁移文件在克隆期间发生变化")
        }
    }

    private static func directoryEntryName(_ item: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &item.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
        }
    }

    private static func readSymbolicLink(fd: Int32, name: String) throws -> String {
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) else {
            throw MigrationError.sourceChanged("待迁移链接在读取期间发生变化")
        }
        let capacity = max(Int(info.st_size) + 1, 1_024)
        var buffer = [CChar](repeating: 0, count: capacity)
        let count = name.withCString { path in
            readlinkat(fd, path, &buffer, capacity)
        }
        guard count >= 0 else {
            throw MigrationError.unreadable("无法读取迁移符号链接")
        }
        guard count < capacity else {
            throw MigrationError.unsafeSource("迁移符号链接目标过长")
        }
        let bytes = buffer.prefix(count).map { UInt8(bitPattern: $0) }
        guard !bytes.contains(0), let destination = String(bytes: bytes, encoding: .utf8) else {
            throw MigrationError.unsafeSource("迁移符号链接目标无效")
        }
        return destination
    }

    /// A symlink is copied verbatim, never followed. Its target must be relative,
    /// must stay inside the lexical tree, and any resolvable target chain must
    /// also stay inside the real root. Dangling contained links are allowed.
    private static func validateSymbolicLink(_ destination: String, linkRelativePath: String,
                                             rootPath: String, rootRealPath: String) throws {
        guard !destination.isEmpty,
              !destination.hasPrefix("/"),
              !destination.contains("\0") else {
            throw MigrationError.unsafeSource("迁移源包含绝对或无效符号链接")
        }
        let parentComponents = linkRelativePath.split(separator: "/").dropLast()
        var resolved: [String] = []
        for component in parentComponents {
            if component == ".." {
                guard !resolved.isEmpty else { throw MigrationError.unsafeSource("符号链接词法越界") }
                resolved.removeLast()
            } else if component != "." {
                resolved.append(String(component))
            }
        }
        let targetComponents = destination.split(separator: "/", omittingEmptySubsequences: false)
        for component in targetComponents {
            if component.isEmpty || component == "." { continue }
            if component == ".." {
                guard !resolved.isEmpty else {
                    throw MigrationError.unsafeSource("符号链接目标越出旧数据目录")
                }
                resolved.removeLast()
            } else {
                resolved.append(String(component))
            }
        }
        let candidate = resolved.isEmpty ? rootPath : rootPath + "/" + resolved.joined(separator: "/")
        if let tracked = realPath(candidate) {
            guard isInside(tracked, root: rootRealPath) else {
                throw MigrationError.unsafeSource("符号链接跟踪目标越出旧数据目录")
            }
            return
        }
        if errno == ELOOP {
            throw MigrationError.unsafeSource("迁移源包含危险循环符号链接")
        }
        guard errno == ENOENT || errno == ENOTDIR else {
            throw MigrationError.unsafeSource("无法安全验证符号链接目标")
        }

        // The final path is dangling. Verify the deepest existing ancestor does
        // not itself escape (or loop) through symlinks.
        var ancestor = (candidate as NSString).deletingLastPathComponent
        while !ancestor.isEmpty, ancestor != "/" {
            if let tracked = realPath(ancestor) {
                guard isInside(tracked, root: rootRealPath) else {
                    throw MigrationError.unsafeSource("符号链接现有祖先越出旧数据目录")
                }
                return
            }
            if errno == ELOOP {
                throw MigrationError.unsafeSource("迁移源包含危险循环符号链接")
            }
            guard errno == ENOENT || errno == ENOTDIR else {
                throw MigrationError.unsafeSource("无法安全验证符号链接祖先")
            }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
    }

    private static func realPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = path.withCString { realpath($0, &buffer) }
        guard result != nil else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Only known app-owned reference fields are relocated, and only when the
    /// corresponding copied file exists. Both absolute paths and Foundation
    /// `file://` URL strings are rebased. External paths and opaque
    /// security-scoped bookmark bytes are copied byte-for-byte.
    private static func relocateManagedReferences(in stage: URL, legacyRoot: URL, newRoot: URL) throws {
        let referenceKeys: Set<String> = ["filePath", "originalPath", "videoURL", "posterURL"]
        let documents = ["library.json", "ExperimentalLockScreen/state.json"]
        for relative in documents {
            let url = stage.appendingPathComponent(relative)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw MigrationError.unsafeSource("迁移配置不是普通文件")
            }
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { continue }
            let object: Any
            do {
                object = try JSONSerialization.jsonObject(with: data)
            } catch {
                throw MigrationError.verificationFailed("旧配置无法解析，未推进新目录")
            }
            var changed = false
            func relocate(_ value: Any, key: String?) throws -> Any {
                if let dictionary = value as? [String: Any] {
                    var result: [String: Any] = [:]
                    for (childKey, child) in dictionary {
                        result[childKey] = try relocate(child, key: childKey)
                    }
                    return result
                }
                if let array = value as? [Any] {
                    return try array.map { try relocate($0, key: key) }
                }
                guard let key, referenceKeys.contains(key), let string = value as? String,
                      let mapped = try mappedManagedPath(string, stage: stage,
                                                        legacyRoot: legacyRoot, newRoot: newRoot) else {
                    return value
                }
                changed = true
                return mapped
            }
            let relocated = try relocate(object, key: nil)
            if changed {
                guard JSONSerialization.isValidJSONObject(relocated) else {
                    throw MigrationError.verificationFailed("迁移后的配置无效")
                }
                let encoded = try JSONSerialization.data(withJSONObject: relocated,
                                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                try encoded.write(to: url, options: .atomic)
            }
        }
    }

    private enum ReferenceStyle {
        case path
        case fileURL
    }

    private static func mappedManagedPath(_ raw: String, stage: URL,
                                          legacyRoot: URL, newRoot: URL) throws -> String? {
        let style: ReferenceStyle
        let path: String
        if raw.hasPrefix("/") {
            style = .path
            path = raw
        } else {
            guard raw.lowercased().hasPrefix("file:"),
                  let url = URL(string: raw), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost",
                  url.path.hasPrefix("/") else { return nil }
            style = .fileURL
            path = url.path
        }
        let legacyPath = legacyRoot.path
        guard path.hasPrefix(legacyPath + "/") else { return nil }
        let suffix = String(path.dropFirst(legacyPath.count + 1))
        guard !suffix.isEmpty, !hasRelativeComponent(suffix) else {
            throw MigrationError.unsafePath("旧配置包含越界素材路径")
        }
        let stageCandidate = stage.appendingPathComponent(suffix)
        var info = stat()
        guard lstat(stageCandidate.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
                || info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return nil }
        let mappedPath = newRoot.path + "/" + suffix
        switch style {
        case .path:
            return mappedPath
        case .fileURL:
            let isDirectory = info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            return URL(fileURLWithPath: mappedPath, isDirectory: isDirectory).absoluteString
        }
    }

    private static func report(_ handler: ProgressHandler?, completed: Int, total: Int,
                               message: String) {
        let fraction = total > 0 ? min(max(Double(completed) / Double(total), 0), 1) : nil
        handler?(Progress(completedFiles: completed, totalFiles: total,
                          fraction: fraction, message: message))
    }
}
