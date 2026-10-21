import Foundation
import CryptoKit
import Darwin

/// Neutral import provenance: Support has no dependency on Import or Steam types.
struct WebWallpaperImportOrigin: Sendable {
    let workshopID: String
    let title: String
    let pageURLString: String?
    let authorSteamID: String?
    let managedDownloadRoot: URL?
    init(workshopID: String, title: String, pageURLString: String? = nil,
         authorSteamID: String? = nil, managedDownloadRoot: URL? = nil) {
        self.workshopID = workshopID; self.title = title; self.pageURLString = pageURLString
        self.authorSteamID = authorSteamID; self.managedDownloadRoot = managedDownloadRoot
    }
}

/// Copies a complete project before one atomic, correctly sourced library commit.
@MainActor
enum WebWallpaperProjectImporter {
    static func importProject(_ selectedURL: URL, store: VideoLibraryStore,
                              origin: WebWallpaperImportOrigin? = nil) async throws -> WallpaperItem {
        try Task.checkCancellation()
        let scoped = selectedURL.startAccessingSecurityScopedResource()
        defer { if scoped { selectedURL.stopAccessingSecurityScopedResource() } }
        var selectionInfo = stat()
        guard selectedURL.isFileURL, lstat(selectedURL.path, &selectionInfo) == 0,
              selectionInfo.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else {
            throw WebProjectError.invalid("请选择实际的 Web 项目文件夹，不能通过符号链接导入")
        }
        let source = selectionInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            ? selectedURL.appendingPathComponent("project.json") : selectedURL
        var sourceInfo = stat()
        guard lstat(source.path, &sourceInfo) == 0, sourceInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw WebProjectError.invalid("project.json 不是实际的常规文件")
        }
        let descriptor = try WebWallpaperProjectDescriptor(projectURL: source)
        if let origin {
            guard origin.workshopID.utf8.allSatisfy({ (48...57).contains($0) }),
                  let id = UInt64(origin.workshopID), id > 0 else { throw WebProjectError.invalid("工坊来源编号无效") }
        }
        let ownedRoot = try WebProjectPaths.canonical(store.storage.root).path
        let expected = ownedRoot + "/Media/WebProjects"
        guard descriptor.root.path != expected, !expected.hasPrefix(descriptor.root.path + "/") else { throw WebProjectError.invalid("源项目不能包含应用管理目录") }
        try store.storage.prepareDirectories()
        let media = store.storage.mediaDirectory
        guard try WebProjectPaths.canonical(media).path == ownedRoot + "/Media" else { throw WebProjectError.invalid("Web 项目管理目录不能是符号链接") }
        let projects = media.appendingPathComponent("WebProjects", isDirectory: true)
        if FileManager.default.fileExists(atPath: projects.path) {
            guard try WebProjectPaths.canonical(projects).path == expected,
                  (try projects.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw WebProjectError.invalid("Web 项目管理目录不能是符号链接") }
        } else { try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: false) }
        let target = URL(fileURLWithPath: expected, isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard !target.path.hasPrefix(descriptor.root.path + "/") else { throw WebProjectError.invalid("源项目不能包含应用管理目录") }
        let excludesAnnotation = origin?.managedDownloadRoot.flatMap { try? WebProjectPaths.canonical($0) } == descriptor.root
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: target) } }
        let copy = Task.detached(priority: .userInitiated) {
            try WebProjectTreeCopy.process(source: descriptor.root, target: target, excludesManagedAnnotation: excludesAnnotation)
        }
        let result = try await withTaskCancellationHandler { try await copy.value } onCancel: { copy.cancel() }
        try Task.checkCancellation()
        guard try WebProjectPaths.canonical(projects).path == expected else { throw WebProjectError.invalid("Web 项目管理目录发生变化") }
        _ = try WebWallpaperProjectDescriptor(projectURL: target.appendingPathComponent("project.json"))
        let workshopID = origin.flatMap { UInt64($0.workshopID).map(String.init) }
        let candidates = store.items.filter {
            $0.isWebWallpaper && $0.contentFingerprint == result.fingerprint &&
            (workshopID != nil ? $0.workshopID == workshopID : $0.workshopID == nil && $0.source == .local)
        }
        var repair: WallpaperItem?
        for candidate in candidates {
            try Task.checkCancellation()
            if !candidate.fileExists { repair = repair ?? candidate; continue }
            let existingRoot = candidate.fileURL.deletingLastPathComponent()
            guard let canonical = try? WebProjectPaths.canonical(existingRoot), canonical.path.hasPrefix(expected + "/") else { continue }
            let validation = Task.detached(priority: .userInitiated) {
                try? WebProjectTreeCopy.process(source: canonical, target: nil, excludesManagedAnnotation: false)
            }
            let existing = await withTaskCancellationHandler { await validation.value } onCancel: { validation.cancel() }
            try Task.checkCancellation()
            if existing?.fingerprint == result.fingerprint {
                var stamped = candidate
                stamp(&stamped, origin: origin, normalizedID: workshopID)
                if stamped != candidate { try store.replacePersistedItem(stamped) }
                try FileManager.default.removeItem(at: target)
                return stamped
            }
            if let existing, !Set(result.files).isSubset(of: Set(existing.files)) { repair = repair ?? candidate }
        }
        var item = repair ?? WallpaperItem(title: origin?.title.trimmingCharacters(in: .whitespacesAndNewlines).nonempty ?? descriptor.title,
            filePath: target.appendingPathComponent("project.json").path, contentKind: .web)
        item.filePath = target.appendingPathComponent("project.json").path
        item.originalPath = descriptor.projectURL.path
        item.fileSizeBytes = result.bytes
        item.contentFingerprint = result.fingerprint
        item.contentKind = .web
        stamp(&item, origin: origin, normalizedID: workshopID)
        try Task.checkCancellation()
        if repair != nil { try store.replacePersistedItem(item) } else { try store.addPersistedItem(item) }
        committed = true
        return item
    }

    private static func stamp(_ item: inout WallpaperItem, origin: WebWallpaperImportOrigin?, normalizedID: String?) {
        guard let origin, let normalizedID else { return }
        item.source = .steamWorkshop
        item.workshopID = normalizedID
        var parts = ["Steam 创意工坊作品 \(normalizedID)"]
        if let page = origin.pageURLString, !page.isEmpty { parts.append(page) }
        if let author = origin.authorSteamID, !author.isEmpty { parts.append("作者 ID \(author)") }
        if !(item.notes ?? "").contains(normalizedID) {
            item.notes = [item.notes?.nonempty, parts.joined(separator: " · ")].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

private extension String { var nonempty: String? { isEmpty ? nil : self } }

private enum WebProjectTreeCopy {
    struct Result: Sendable { let bytes: Int64; let fingerprint: String; let files: [String] }
    struct File: Sendable { let path: String; let inode: UInt64; let device: Int32; let size: Int64 }


    static func process(source: URL, target: URL?, excludesManagedAnnotation: Bool) throws -> Result {
        let fm = FileManager.default
        let rootFD = open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw WebProjectError.invalid("源项目目录不可读取") }
        defer { close(rootFD) }
        if let target { try fm.createDirectory(at: target, withIntermediateDirectories: false) }
        var files: [File] = []
        var entries = 0
        var expectedBytes: Int64 = 0
        func walk(_ fd: Int32, _ prefix: String) throws {
            guard prefix.utf8.count <= 4_096, prefix.split(separator: "/").count <= 64 else { throw WebProjectError.invalid("项目目录层级或路径过长") }
            let enumerationFD = dup(fd)
            guard enumerationFD >= 0, let directory = fdopendir(enumerationFD) else {
                if enumerationFD >= 0 { close(enumerationFD) }
                throw WebProjectError.invalid("无法读取项目目录")
            }
            defer { closedir(directory) }
            while true {
                try Task.checkCancellation()
                errno = 0
                guard let pointer = readdir(directory) else { if errno != 0 { throw WebProjectError.invalid("项目目录读取未完成") }; break }
                let name = withUnsafePointer(to: &pointer.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)+1) { String(cString: $0) } }
                if name == "." || name == ".." { continue }
                entries += 1
                guard entries <= 20_000 else { throw WebProjectError.invalid("项目目录项超过 20,000") }
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw WebProjectError.invalid("源项目发生变化") }
                let kind = info.st_mode & mode_t(S_IFMT)
                if kind == mode_t(S_IFDIR) {
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw WebProjectError.invalid("项目目录发生变化或包含符号链接") }
                    defer { close(child) }
                    if let target { try fm.createDirectory(at: target.appendingPathComponent(relative), withIntermediateDirectories: false) }
                    try walk(child, relative)
                } else if kind == mode_t(S_IFREG) {
                    if excludesManagedAnnotation,
                       GlimmerIdentity.downloadManifestNames.contains(relative) { continue }
                    expectedBytes += info.st_size
                    guard expectedBytes <= 2_147_483_648 else { throw WebProjectError.invalid("项目超过 2 GB") }
                    files.append(File(path: relative, inode: info.st_ino, device: info.st_dev, size: info.st_size))
                } else { throw WebProjectError.invalid("项目包含符号链接或特殊文件") }
            }
        }
        try walk(rootFD, "")
        var digest = SHA256(), copied: Int64 = 0
        for file in files.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
            try Task.checkCancellation()
            var fd = dup(rootFD)
            guard fd >= 0 else { throw WebProjectError.invalid("项目文件不可读取") }
            do {
                let components = file.path.split(separator: "/").map(String.init)
                for component in components.dropLast() {
                    let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard next >= 0 else { throw WebProjectError.invalid("复制期间项目目录已改变") }
                    close(fd); fd = next
                }
                let opened = openat(fd, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                close(fd); fd = -1
                guard opened >= 0 else { throw WebProjectError.invalid("复制期间源文件不可访问") }
                let input = FileHandle(fileDescriptor: opened, closeOnDealloc: true); defer { try? input.close() }
                var before = stat()
                guard fstat(opened, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_ino == file.inode, before.st_dev == file.device, before.st_size == file.size else { throw WebProjectError.invalid("复制期间源文件已替换") }
                let output: FileHandle?
                if let target {
                    let destination = target.appendingPathComponent(file.path)
                    guard fm.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw WebProjectError.invalid("无法创建项目副本") }
                    output = try FileHandle(forWritingTo: destination)
                } else { output = nil }
                defer { try? output?.close() }
                var hash = SHA256(), count: Int64 = 0
                while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                    try Task.checkCancellation(); count += Int64(data.count); copied += Int64(data.count)
                    guard copied <= 2_147_483_648 else { throw WebProjectError.invalid("复制期间项目超过 2 GB") }
                    hash.update(data: data); try output?.write(contentsOf: data)
                }
                var after = stat()
                guard fstat(opened, &after) == 0, count == before.st_size, before.st_size == after.st_size,
                      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw WebProjectError.invalid("复制期间源文件内容发生变化") }
                digest.update(data: Data(file.path.utf8)); digest.update(data: Data([0])); digest.update(data: Data(hash.finalize()))
            } catch { if fd >= 0 { close(fd) }; throw error }
        }
        let fingerprint = digest.finalize().map { String(format: "%02x", $0) }.joined()
        if target != nil {
            let current = try process(source: source, target: nil, excludesManagedAnnotation: excludesManagedAnnotation)
            guard current.fingerprint == fingerprint else { throw WebProjectError.invalid("复制期间源项目树发生变化，请重新导入") }
        }
        return Result(bytes: copied, fingerprint: fingerprint, files: files.map(\.path))
    }
}
