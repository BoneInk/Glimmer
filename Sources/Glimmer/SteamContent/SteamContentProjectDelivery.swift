import CryptoKit
import Darwin
import Foundation

/// Converts a verified helper cache into the existing managed Workshop download layout.
/// The helper's manifest-exact source tree is never annotated, modified or deleted here.
actor SteamContentProjectDelivery {
    private let layout: SteamCMDLayout
    private var delivering = false
    init(layout: SteamCMDLayout = SteamCMDLayout()) { self.layout = layout }

    func deliver(contentURL: URL, item: WorkshopDownloadItem,
                 progress: @escaping @Sendable (WorkshopDownloadState) -> Void) async throws -> WorkshopResolvedProject {
        guard !delivering else { throw Self.invalid("另一份原生下载正在交付，请稍后重试") }
        delivering = true
        defer { delivering = false }
        guard let id = WorkshopItemID(item.publishedFileID), contentURL.isFileURL else { throw Self.invalid("作品 ID 或下载目录不合法") }
        try Task.checkCancellation()
        let sourceURL = Self.systemAliases(contentURL)
        let layoutURL = Self.systemAliases(layout.root)
        guard !Self.contains(sourceURL, layoutURL), !Self.contains(layoutURL, sourceURL) else {
            throw Self.invalid("原生下载缓存与目标管理目录不能互相包含")
        }
        let source = try Self.openAbsolute(sourceURL, create: false, ownedLeaf: true)
        defer { close(source) }
        let layoutFD = try Self.openAbsolute(layoutURL, create: true, ownedLeaf: true)
        defer { close(layoutFD) }
        let downloads = try Self.directory("downloads", parent: layoutFD, create: true)
        defer { close(downloads) }
        let parent = try Self.directory(String(WorkshopInputValidator.wallpaperEngineAppID), parent: downloads, create: true)
        defer { close(parent) }
        let lockFD = openat(parent, ".steam-content-delivery.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw Self.invalid("无法锁定下载交付目录") }
        defer { close(lockFD) }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0, Self.regularOwned(lockInfo), flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw Self.invalid("下载目录正在被另一项交付操作使用")
        }
        defer { _ = flock(lockFD, LOCK_UN) }
        let targetName = id.value
        let targetURL = layoutURL.appendingPathComponent("downloads/\(WorkshopInputValidator.wallpaperEngineAppID)/\(targetName)")
        let old = try Self.existingSnapshot(name: targetName, parent: parent)
        progress(.validating("检查原生下载文件"))
        let original = try Self.snapshot(source)
        let reservedManifestNames = Set(GlimmerIdentity.downloadManifestNames)
        guard !original.entries.contains(where: { !$0.directory && reservedManifestNames.contains($0.path) }) else {
            throw Self.invalid("作品根目录包含保留的下载清单文件，无法安全交付")
        }
        try Self.ensurePath(sourceURL, matches: source)
        let sourceProject = try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: sourceURL, declaredTags: item.declaredTags)
        try Task.checkCancellation()
        try Self.ensurePath(sourceURL, matches: source)
        guard try Self.snapshot(source) == original else { throw Self.invalid("原生下载内容在校验期间发生变化") }
        let stageName = ".steam-content-stage-\(targetName)-\(UUID().uuidString)"
        let stageURL = targetURL.deletingLastPathComponent().appendingPathComponent(stageName)
        guard mkdirat(parent, stageName, 0o700) == 0 else { throw Self.invalid("无法创建私有交付暂存目录") }
        let stage = try Self.directory(stageName, parent: parent, create: false)
        defer { close(stage) }
        let stageIdentity = try Self.identity(stage)
        var prepared: Snapshot?
        var promoted = false
        var committed = false
        var retainStage = false
        defer {
            // Old downloads are intentionally retained after successful exchange for parent-managed
            // cleanup. Unknown/concurrently changed directories are never recursively removed.
            if !committed && !retainStage, Self.namedIdentity(stageName, parent: parent) == stageIdentity {
                try? Self.removeOwnedTree(stageName, parent: parent, expected: stageIdentity)
            }
        }
        do {
            progress(.validating("正在复制本地项目文件"))
            try Self.copy(original, from: source, to: stage, progress: progress)
            guard try Self.snapshot(source) == original else { throw Self.invalid("原生下载源在复制期间发生变化") }
            let copied = try Self.snapshot(stage)
            guard copied.contentSignature == original.contentSignature else { throw Self.invalid("交付副本与原生下载内容不一致") }
            try Self.ensurePath(stageURL, matches: stage)
            let stagedProject = try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: stageURL, declaredTags: item.declaredTags)
            try Self.ensurePath(stageURL, matches: stage)
            try Self.sameProject(sourceProject, stagedProject)
            try Task.checkCancellation()
            let manifest = try Self.manifest(project: stagedProject, item: item)
            try Self.write(manifest, name: Self.manifestName, parent: stage)
            let staged = try Self.snapshot(stage, allowingHostManifest: true)
            prepared = staged
            try Task.checkCancellation()
            guard try Self.existingSnapshot(name: targetName, parent: parent) == old,
                  try Self.snapshot(source) == original,
                  Self.namedIdentity(stageName, parent: parent) == stageIdentity else {
                throw Self.invalid("下载目录在交付期间发生变化，已保留原有内容")
            }
            try Self.ensurePath(layoutURL, matches: layoutFD)
            progress(.validating("正在原子交付已校验项目"))
            try Task.checkCancellation()
            let operation = old == nil ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)
            guard renameatx_np(parent, stageName, parent, targetName, operation) == 0 else { throw Self.invalid("无法原子交付下载，原有目录保持不变") }
            promoted = true
            guard fsync(parent) == 0 else { throw Self.invalid("交付目录落盘失败") }
            progress(.validating("复验已交付项目"))
            try Task.checkCancellation()
            try Self.ensurePath(targetURL, matches: stage)
            let final = try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: targetURL, declaredTags: item.declaredTags)
            try Self.ensurePath(targetURL, matches: stage)
            try Self.sameProject(sourceProject, final)
            try Task.checkCancellation()
            guard Self.namedIdentity(targetName, parent: parent) == stageIdentity,
                  try Self.existingSnapshot(name: targetName, parent: parent) == staged else {
                throw Self.invalid("交付目录在最终校验期间发生变化")
            }
            try Task.checkCancellation()
            committed = true
            // Keep old downloads outside the live downloads tree so recursive restoration cannot
            // mistake a retained old manifest for the newly delivered item. Never delete old data.
            if old != nil, let previous = try? Self.directory(".steam-content-previous", parent: layoutFD, create: true) {
                defer { close(previous) }
                let name = "\(targetName)-\(UUID().uuidString)"
                if renameatx_np(parent, stageName, previous, name, UInt32(RENAME_EXCL)) == 0 {
                    _ = fsync(previous); _ = fsync(parent)
                }
                // Failure merely leaves the old directory at stageName; delivery stays committed.
            }
            return final
        } catch {
            if promoted {
                if Self.namedIdentity(targetName, parent: parent) == stageIdentity {
                    if let old {
                        // The retained old directory is also a compare-and-swap input. Never
                        // install a concurrent replacement or a modified backup as the old item.
                        guard let retained = try? Self.existingSnapshot(name: stageName, parent: parent, checkingCancellation: false),
                              retained == old else {
                            retainStage = true
                            throw Self.invalid("旧下载副本在还原前发生变化；已保留当前目录与暂存内容，未覆盖任何目录")
                        }
                    }
                    let rolledBack = renameatx_np(parent, targetName, parent, stageName,
                                                  old == nil ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)) == 0
                    guard rolledBack else {
                        retainStage = true
                        throw Self.invalid("下载交付失败，旧目录已保留在私有暂存位置，无法自动还原")
                    }
                    _ = fsync(parent)
                    // If somebody modified our promoted tree, preserve that tree after rollback too.
                    if let expected = prepared,
                       let now = try? Self.existingSnapshot(name: stageName, parent: parent, checkingCancellation: false),
                       now.contentSignature != expected.contentSignature { retainStage = true }
                } else {
                    retainStage = true
                    throw Self.invalid("下载目录被并发替换；已保留旧副本，未覆盖新的目录")
                }
            }
            throw error
        }
    }

    private static let manifestName = GlimmerIdentity.downloadManifestName
    private struct Identity: Equatable { let device: Int32; let inode: UInt64 }
    private struct Entry: Equatable {
        let path: String; let directory: Bool; let size: Int64; let digest: String
        let identity: Identity; let modified: Int; let modifiedNS: Int; let changed: Int; let changedNS: Int
    }
    private struct Snapshot: Equatable {
        let root: Identity; let entries: [Entry]
        var contentSignature: [String] { entries.map { "\($0.directory ? "d" : "f"):\($0.path):\($0.size):\($0.digest)" } }
    }
    private static func invalid(_ message: String) -> WorkshopDownloadError { .validationFailed(reason: message) }
    private static func contains(_ parent: URL, _ child: URL) -> Bool { parent.path == child.path || child.path.hasPrefix(parent.path + "/") }
    private static func systemAliases(_ url: URL) -> URL {
        let path = "/" + url.path.split(separator: "/").joined(separator: "/")
        for alias in ["/tmp", "/var", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: alias),
               (link.hasPrefix("/") ? link : "/" + link) == "/private" + alias {
                // Foundation standardizedFileURL may turn /private/tmp back into /tmp. Do not
                // standardize the resulting physical spelling again before the no-follow walker.
                return URL(fileURLWithPath: "/private" + path, isDirectory: true)
            }
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    private static func identity(_ fd: Int32) throws -> Identity {
        var info = stat(); guard fstat(fd, &info) == 0 else { throw invalid("无法读取管理目录标识") }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }
    private static func namedIdentity(_ name: String, parent: Int32) -> Identity? {
        var info = stat(); guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
            info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == geteuid() else { return nil }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }
    private static func directory(_ name: String, parent: Int32, create: Bool) throws -> Int32 {
        if create {
            let created = mkdirat(parent, name, 0o700)
            if created != 0, errno != EEXIST { throw invalid("无法创建管理子目录") }
            if created == 0, fsync(parent) != 0 { throw invalid("管理子目录落盘失败") }
        }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw invalid("管理目录不可访问或包含符号链接") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == geteuid() else {
            close(fd); throw invalid("管理子目录不属于当前用户")
        }
        return fd
    }
    private static func openAbsolute(_ url: URL, create: Bool, ownedLeaf: Bool) throws -> Int32 {
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw invalid("无法定位管理目录") }
        do {
            for part in url.path.split(separator: "/").map(String.init) {
                guard part != ".", part != ".." else { throw invalid("管理路径包含不允许的相对节点") }
                if create, mkdirat(current, part, 0o700) != 0, errno != EEXIST { throw invalid("无法创建交付管理目录") }
                let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard next >= 0 else { throw invalid("目录路径包含不可访问或符号链接节点") }
                close(current); current = next
            }
            var info = stat()
            guard fstat(current, &info) == 0, !ownedLeaf || info.st_uid == geteuid() else { throw invalid("目录不属于当前用户") }
            return current
        } catch { close(current); throw error }
    }
    private static func ensurePath(_ url: URL, matches fd: Int32) throws {
        let current = try openAbsolute(url, create: false, ownedLeaf: true)
        defer { close(current) }
        guard try identity(current) == identity(fd) else { throw invalid("管理路径在交付期间被替换") }
    }
    private static func removeOwnedTree(_ name: String, parent: Int32, expected: Identity) throws {
        guard namedIdentity(name, parent: parent) == expected else { throw invalid("暂存目录身份已改变，保留待检查") }
        let child = try directory(name, parent: parent, create: false)
        defer { close(child) }
        guard try identity(child) == expected else { throw invalid("暂存目录被替换") }
        let duplicate = dup(child)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else { if duplicate >= 0 { close(duplicate) }; throw invalid("无法清理自有暂存目录") }
        defer { closedir(stream) }; rewinddir(stream)
        while let item = readdir(stream) {
            var tuple = item.pointee.d_name
            guard let leaf = withUnsafePointer(to: &tuple, { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) } }) else { throw invalid("暂存文件名无效") }
            if leaf == "." || leaf == ".." { continue }
            var info = stat()
            guard fstatat(child, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_uid == geteuid() else { throw invalid("暂存节点已改变，保留待检查") }
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                try removeOwnedTree(leaf, parent: child, expected: Identity(device: info.st_dev, inode: info.st_ino))
            } else {
                guard regularOwned(info), unlinkat(child, leaf, 0) == 0 else { throw invalid("暂存节点不安全，保留待检查") }
            }
        }
        guard namedIdentity(name, parent: parent) == expected, unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw invalid("暂存目录发生变化，保留待检查") }
    }
    private static func existingSnapshot(name: String, parent: Int32, checkingCancellation: Bool = true) throws -> Snapshot? {
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw invalid("无法检查已有下载") }; return nil
        }
        let fd = try directory(name, parent: parent, create: false)
        defer { close(fd) }
        return try snapshot(fd, checkingCancellation: checkingCancellation, allowingHostManifest: true)
    }
    private static func stamp(_ path: String, _ info: stat, directory: Bool, digest: String = "") -> Entry {
        Entry(path: path, directory: directory, size: directory ? 0 : info.st_size, digest: digest,
              identity: Identity(device: info.st_dev, inode: info.st_ino), modified: info.st_mtimespec.tv_sec,
              modifiedNS: info.st_mtimespec.tv_nsec, changed: info.st_ctimespec.tv_sec, changedNS: info.st_ctimespec.tv_nsec)
    }
    private static func regularOwned(_ info: stat) -> Bool {
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && info.st_uid == geteuid() && info.st_nlink == 1
    }
    private static func snapshot(_ root: Int32, checkingCancellation: Bool = true, allowingHostManifest: Bool = false) throws -> Snapshot {
        var entries: [Entry] = []; var total: Int64 = 0
        func walk(_ fd: Int32, prefix: String, depth: Int) throws {
            guard depth <= 32 else { throw invalid("项目目录层级过深") }
            let duplicate = dup(fd)
            guard duplicate >= 0, let stream = fdopendir(duplicate) else { if duplicate >= 0 { close(duplicate) }; throw invalid("无法枚举项目目录") }
            defer { closedir(stream) }; rewinddir(stream)
            while true {
                if checkingCancellation { try Task.checkCancellation() }
                errno = 0
                guard let item = readdir(stream) else { if errno != 0 { throw invalid("项目目录枚举失败") }; break }
                var tuple = item.pointee.d_name
                let name = withUnsafePointer(to: &tuple) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) } }
                guard let name else { throw invalid("项目文件名不是有效 UTF-8") }
                if name == "." || name == ".." { continue }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                guard entries.count < (allowingHostManifest ? 40_002 : 40_000), path.utf8.count <= 1024, path.split(separator: "/").count <= 32, !name.contains(":"), !name.contains("\\"), !name.contains(where: \.isNewline),
                      !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw invalid("项目路径不安全或文件过多") }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_uid == geteuid() else { throw invalid("项目节点在枚举期间发生变化") }
                if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                    let child = try directory(name, parent: fd, create: false)
                    defer { close(child) }
                    guard try identity(child) == Identity(device: info.st_dev, inode: info.st_ino) else { throw invalid("项目目录在读取期间被替换") }
                    entries.append(stamp(path, info, directory: true))
                    try walk(child, prefix: path, depth: depth + 1)
                } else {
                    let hostManifest = allowingHostManifest && GlimmerIdentity.downloadManifestNames.contains(path)
                    guard regularOwned(info), info.st_size >= 0, info.st_size <= (hostManifest ? 2_097_152 : 2_147_483_648),
                          hostManifest || total <= 2_147_483_648 - info.st_size else { throw invalid("项目包含链接、特殊节点或超过 2 GiB") }
                    if !hostManifest { total += info.st_size }
                    let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard file >= 0 else { throw invalid("项目文件不可访问") }; defer { close(file) }
                    var before = stat(); guard fstat(file, &before) == 0, stamp(path, before, directory: false) == stamp(path, info, directory: false) else { throw invalid("项目文件在打开期间被替换") }
                    let digest = try hash(file, expected: info.st_size, checkingCancellation: checkingCancellation)
                    var after = stat(); guard fstat(file, &after) == 0, stamp(path, before, directory: false) == stamp(path, after, directory: false) else { throw invalid("项目文件在读取期间被修改") }
                    entries.append(stamp(path, after, directory: false, digest: digest))
                }
            }
        }
        try walk(root, prefix: "", depth: 0)
        return Snapshot(root: try identity(root), entries: entries.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) })
    }
    private static func hash(_ fd: Int32, expected: Int64, checkingCancellation: Bool = true) throws -> String {
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw invalid("无法读取项目文件") }
        var hash = SHA256(); var count: Int64 = 0; var bytes = [UInt8](repeating: 0, count: 262_144)
        while true {
            if checkingCancellation { try Task.checkCancellation() }
            let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n >= 0 else { throw invalid("项目文件读取失败") }; if n == 0 { break }
            count += Int64(n); guard count <= expected else { throw invalid("项目文件在读取期间增长") }
            hash.update(data: Data(bytes.prefix(n)))
        }
        guard count == expected else { throw invalid("项目文件长度发生变化") }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func relativeDirectory(_ path: String, root: Int32, create: Bool) throws -> Int32 {
        var current = dup(root); guard current >= 0 else { throw invalid("无法定位暂存目录") }
        do { for part in path.split(separator: "/").map(String.init) { let next = try directory(part, parent: current, create: create); close(current); current = next }; return current }
        catch { close(current); throw error }
    }
    private static func copy(_ snapshot: Snapshot, from source: Int32, to target: Int32,
                             progress: @Sendable (WorkshopDownloadState) -> Void) throws {
        var copied: Int64 = 0
        for entry in snapshot.entries {
            try Task.checkCancellation()
            if entry.directory { let fd = try relativeDirectory(entry.path, root: target, create: true); close(fd); continue }
            let components = entry.path.split(separator: "/").map(String.init)
            let parentPath = components.dropLast().joined(separator: "/")
            let sourceParent = try relativeDirectory(parentPath, root: source, create: false); defer { close(sourceParent) }
            let targetParent = try relativeDirectory(parentPath, root: target, create: true); defer { close(targetParent) }
            let input = openat(sourceParent, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard input >= 0 else { throw invalid("无法读取原生缓存文件") }; defer { close(input) }
            var info = stat(); guard fstat(input, &info) == 0, stamp(entry.path, info, directory: false) == Entry(path: entry.path, directory: false, size: entry.size, digest: "", identity: entry.identity, modified: entry.modified, modifiedNS: entry.modifiedNS, changed: entry.changed, changedNS: entry.changedNS) else { throw invalid("原生缓存文件在复制前发生变化") }
            let output = openat(targetParent, components.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw invalid("无法写入私有项目副本") }; defer { close(output) }
            var bytes = [UInt8](repeating: 0, count: 262_144); var count: Int64 = 0; var digest = SHA256()
            while true {
                try Task.checkCancellation()
                let n = bytes.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
                if n < 0, errno == EINTR { continue }
                guard n >= 0 else { throw invalid("原生下载读取失败") }; if n == 0 { break }
                count += Int64(n); guard count <= entry.size else { throw invalid("源文件在复制期间增长") }
                digest.update(data: Data(bytes.prefix(n)))
                try bytes.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < n { let written = Darwin.write(output, buffer.baseAddress!.advanced(by: offset), n - offset); if written < 0, errno == EINTR { continue }; guard written > 0 else { throw invalid("项目副本写入失败") }; offset += written }
                }
                copied += Int64(n)
                if copied % 8_388_608 < Int64(n) { progress(.validating("正在复制本地项目 · \(ByteCountFormatter.string(fromByteCount: copied, countStyle: .file))")) }
            }
            guard count == entry.size, digest.finalize().map({ String(format: "%02x", $0) }).joined() == entry.digest, fsync(output) == 0, fsync(targetParent) == 0 else { throw invalid("项目副本校验或落盘失败") }
        }
    }
    private static func sameProject(_ expected: WorkshopResolvedProject, _ actual: WorkshopResolvedProject) throws {
        guard expected.kind == actual.kind, expected.projectJSONPath == actual.projectJSONPath,
              expected.contentFingerprint == actual.contentFingerprint, expected.totalByteSize == actual.totalByteSize else { throw invalid("项目在交付前后解析结果不一致") }
    }
    private static func manifest(project: WorkshopResolvedProject, item: WorkshopDownloadItem) throws -> Data {
        let digest = try project.videoProject.map { try SteamCMDInstaller.sha256(of: $0.videoURL) }
        let manifest = WorkshopDownloadManifest(schemaVersion: 2, appID: WorkshopInputValidator.wallpaperEngineAppID,
            publishedFileID: item.publishedFileID, title: project.projectTitle ?? item.title, projectType: project.projectType,
            projectJSONRelativePath: project.projectJSONPath, videoRelativePath: project.videoProject?.videoRelativePath,
            videoByteSize: project.videoProject?.videoByteSize, videoSHA256: digest, validatedAt: Date(), declaredTags: item.declaredTags,
            appVersion: AppConstants.version, entryRelativePath: project.entryRelativePath, projectByteSize: project.totalByteSize,
            projectFingerprint: project.contentFingerprint, resourceCount: project.resourceCount)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        var fields = try JSONSerialization.jsonObject(with: encoder.encode(manifest)) as! [String: Any]
        fields["downloadBackend"] = "steamkit2"
        fields["previewImageURLString"] = item.previewImageURLString
        fields["fileSizeBytes"] = item.fileSizeBytes
        return try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
    }
    private static func write(_ data: Data, name: String, parent: Int32) throws {
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw invalid("无法写入本地下载清单") }; defer { close(fd) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count { try Task.checkCancellation(); let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset); if n < 0, errno == EINTR { continue }; guard n > 0 else { throw invalid("本地下载清单写入失败") }; offset += n }
        }
        guard fsync(fd) == 0, fsync(parent) == 0 else { throw invalid("本地下载清单落盘失败") }
    }
}
