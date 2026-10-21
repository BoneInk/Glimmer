import CryptoKit
import Darwin
import Foundation

/// Explicit native selections only. Project strings never confer file access.
/// Callers persist grant.value as the override, then install manifest before
/// delivering it. Retained versions permit rollback and still-running hosts;
/// prune only after every host has acknowledged the new manifest or closed.
actor AuthorPropertyAssetStore {
    struct Limits: Sendable {
        var maximumFileBytes: Int64 = 32 * 1024 * 1024
        var maximumTotalBytes: Int64 = 256 * 1024 * 1024
        var maximumFiles: Int = 1024
        var maximumEntries: Int = 4096
    }
    private struct Document: Codable {
        var schemaVersion = 1
        let itemID: UUID
        var records: [String: AuthorPropertyAssetRecord]
    }
    private var itemRemovals: [UUID: UUID] = [:]
    private var removedItems: Set<UUID> = []
    private let directory: URL
    private let limits: Limits
    private let fm = FileManager.default
    init(directory: URL, limits: Limits = Limits()) {
        let path = directory.standardizedFileURL.path
        self.directory = directory.isFileURL ? URL(fileURLWithPath: path.hasPrefix("/var/") || path.hasPrefix("/tmp/") ? "/private" + path : path, isDirectory: true) : directory
        self.limits = limits
    }

    /// Queued behind any current copy; prevents delayed native selections,
    /// refreshes and manifest creation from rebuilding a deleted item's vault.
    func beginItemRemoval(itemID: UUID, token: UUID) throws {
        try requireAvailable(itemID)
        itemRemovals[itemID] = token
    }

    func finishItemRemoval(itemID: UUID, token: UUID, committed: Bool) {
        guard itemRemovals[itemID] == token else { return }
        itemRemovals[itemID] = nil
        if committed { removedItems.insert(itemID) }
    }

    private func requireAvailable(_ itemID: UUID) throws {
        guard itemRemovals[itemID] == nil, !removedItems.contains(itemID) else {
            throw failure("此壁纸正在删除或已删除，未重新创建资源授权")
        }
    }

    func selectFile(_ selectedURL: URL, itemID: UUID, propertyKey: String, project: AuthorPropertyProject) throws -> AuthorPropertyAssetGrant {
        try select(selectedURL, kind: .file, itemID: itemID, key: propertyKey, project: project)
    }

    func selectDirectory(_ selectedURL: URL, itemID: UUID, propertyKey: String, project: AuthorPropertyProject) throws -> AuthorPropertyAssetGrant {
        try select(selectedURL, kind: .directory, itemID: itemID, key: propertyKey, project: project)
    }

    func refresh(itemID: UUID, propertyKey: String, project: AuthorPropertyProject) throws -> AuthorPropertyAssetGrant {
        let document = try load(itemID)
        guard let record = document.records[propertyKey] else { throw failure("此属性尚未获得用户资源授权") }
        var stale = false
        let source = try URL(resolvingBookmarkData: record.bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
        return try select(source, kind: record.grant.kind, itemID: itemID, key: propertyKey, project: project)
    }

    func grants(itemID: UUID) throws -> [AuthorPropertyAssetGrant] {
        try load(itemID).records.values.map(\.grant).sorted { $0.propertyKey < $1.propertyKey }
    }

    /// Native monitoring only. Never pass these URLs to a Web page. A monitor
    /// retaining security-scoped access must balance start/stop itself.
    func sourceURLs(itemID: UUID) throws -> [URL] {
        try load(itemID).records.values.map { record in
            var stale = false
            return try URL(resolvingBookmarkData: record.bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
        }
    }

    func manifest(itemID: UUID) throws -> WebWallpaperResourceManifest {
        let all = try grants(itemID: itemID)
        let root = try itemRoot(itemID, create: true)
        for grant in all { for asset in grant.assets { try validateAsset(asset, root: root) } }
        return WebWallpaperResourceManifest(itemID: itemID, rootURL: root, assets: all.flatMap(\.assets), directories: all.compactMap { grant in
            guard let mode = grant.directoryMode, let value = grant.value.stringValue else { return nil }
            return WebWallpaperGrantedDirectory(propertyKey: grant.propertyKey, mode: mode, assets: grant.assets, revision: grant.revision, virtualPath: value)
        })
    }

    func checkpoint(itemID: UUID, propertyKey: String) throws -> AuthorPropertyAssetCheckpoint {
        AuthorPropertyAssetCheckpoint(itemID: itemID, propertyKey: propertyKey, record: try load(itemID).records[propertyKey])
    }

    /// A revision mismatch protects a newer successful choice from stale rollback.
    func restore(_ checkpoint: AuthorPropertyAssetCheckpoint, replacingRevision: String?) throws {
        var document = try load(checkpoint.itemID)
        guard document.records[checkpoint.propertyKey]?.grant.revision == replacingRevision else {
            throw failure("资源授权已发生变化，未覆盖较新的选择")
        }
        document.records[checkpoint.propertyKey] = checkpoint.record
        try save(document)
    }

    func revoke(itemID: UUID, propertyKey: String) throws {
        var document = try load(itemID)
        document.records.removeValue(forKey: propertyKey)
        try save(document)
    }

    func revokeAll(itemID: UUID) throws {
        var document = try load(itemID)
        document.records = [:]
        try save(document)
    }

    func pruneUnreferencedAssets(itemID: UUID) throws {
        let document = try load(itemID)
        let root = try itemRoot(itemID, create: false)
        let live = Set(document.records.values.map { $0.grant.id.uuidString })
        for url in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: url.lastPathComponent) != nil, !live.contains(url.lastPathComponent) else { continue }
            try ownedDirectory(url, create: false)
            try fm.removeItem(at: url)
        }
    }

    private func select(_ selected: URL, kind: AuthorPropertyAssetKind, itemID: UUID, key: String, project: AuthorPropertyProject) throws -> AuthorPropertyAssetGrant {
        try requireAvailable(itemID)
        try Task.checkCancellation()
        guard let definition = project.definition(for: key),
              (kind == .file && definition.kind == .file) || (kind == .directory && definition.kind == .directory) else {
            throw failure("所选资源与作者属性类型不匹配")
        }
        let mode: WebWallpaperDirectoryMode?
        if kind == .directory {
            guard let parsed = WebWallpaperDirectoryMode(rawValue: definition.raw["mode"]?.stringValue ?? "ondemand") else { throw failure("不支持此目录属性模式") }
            mode = parsed
        } else { mode = nil }
        guard selected.isFileURL else { throw failure("必须选择本地文件或目录") }
        let scoped = selected.startAccessingSecurityScopedResource()
        defer { if scoped { selected.stopAccessingSecurityScopedResource() } }
        var selectedStat = stat()
        guard lstat(selected.path, &selectedStat) == 0,
              selectedStat.st_mode & mode_t(S_IFMT) == mode_t(kind == .file ? S_IFREG : S_IFDIR) else {
            throw failure("所选资源不是实际文件或目录，符号链接不被授权")
        }
        let source = try canonical(selected)
        let sourceRoot = kind == .directory ? source : source.deletingLastPathComponent()
        let itemRoot = try itemRoot(itemID, create: true)
        let vaultRoot = itemRoot.deletingLastPathComponent()
        guard !source.path.hasPrefix(vaultRoot.path + "/"), source.path != vaultRoot.path,
              kind != .directory || !vaultRoot.path.hasPrefix(source.path + "/") else { throw failure("所选资源不能位于资源库内，也不能包含资源库") }
        let grantID = UUID()
        let stage = itemRoot.appendingPathComponent(grantID.uuidString, isDirectory: true)
        try ownedDirectory(stage, create: true)
        var committed = false
        defer { if !committed { try? fm.removeItem(at: stage) } }
        var document = try load(itemID)
        let sourceIdentity = SHA256.hash(data: Data("\(selectedStat.st_dev):\(selectedStat.st_ino)".utf8)).map { String(format: "%02x", $0) }.joined()
        let previous = document.records[key]
        let sameSource = previous?.sourceIdentity == sourceIdentity && previous?.grant.kind == kind
        let files = try selectedFiles(source, kind: kind, fileType: definition.raw["fileType"]?.stringValue)
        // A file-picker grant covers that file, not its parent directory. Opening
        // the parent can block on an unrelated macOS privacy request. Only a
        // directory selection needs a traversal descriptor; the selected file
        // is verified against its original device/inode after a direct open.
        let rootFD = kind == .directory ? open(sourceRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) : -1
        guard kind != .directory || rootFD >= 0 else { throw failure("无法打开所选资源目录") }
        defer { if rootFD >= 0 { close(rootFD) } }
        if kind == .directory {
            var openedRoot = stat()
            guard fstat(rootFD, &openedRoot) == 0, openedRoot.st_dev == selectedStat.st_dev,
                  openedRoot.st_ino == selectedStat.st_ino else { throw failure("复制期间所选目录被替换") }
        }
        var assets: [WebWallpaperGrantedAsset] = []
        var relativeTokens: [String: String] = [:]
        var usedTokens: Set<String> = []
        var total: Int64 = 0
        var revision = SHA256()
        revision.update(data: Data((kind.rawValue + ":" + (mode?.rawValue ?? "")).utf8))
        revision.update(data: Data(sourceIdentity.utf8)); revision.update(data: Data([0]))
        for relative in files.sorted() {
            try Task.checkCancellation()
            let priorToken = sameSource ? previous?.relativeTokens?[relative] : nil
            let token: String
            if let priorToken, UUID(uuidString: priorToken) != nil, !usedTokens.contains(priorToken) { token = priorToken }
            else { token = UUID().uuidString }
            usedTokens.insert(token)
            relativeTokens[relative] = token
            // The page needs a usable media extension, not a private source
            // basename or characters with URL fragment/query semantics.
            let name = "resource." + URL(fileURLWithPath: relative).pathExtension.lowercased()
            let output = stage.appendingPathComponent(token)
            let inputFD: Int32
            if kind == .file {
                inputFD = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard inputFD >= 0 else { throw failure("无法打开所选文件") }
            } else { inputFD = try openRelative(relative, rootFD: rootFD) }
            let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
            var before = stat()
            guard fstat(inputFD, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_size <= limits.maximumFileBytes else {
                try? input.close(); throw failure("所选资源不是常规文件或超过单文件限制")
            }
            if kind == .file, before.st_dev != selectedStat.st_dev || before.st_ino != selectedStat.st_ino {
                try? input.close(); throw failure("复制期间所选文件被替换")
            }
            guard fm.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { try? input.close(); throw failure("无法创建资源副本") }
            let destination = try FileHandle(forWritingTo: output)
            var hash = SHA256()
            var fileBytes: Int64 = 0
            do {
                while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                    try Task.checkCancellation()
                    fileBytes += Int64(data.count); total += Int64(data.count)
                    guard fileBytes <= limits.maximumFileBytes, total <= limits.maximumTotalBytes else { throw failure("所选资源超过容量限制") }
                    hash.update(data: data)
                    try destination.write(contentsOf: data)
                }
                var after = stat()
                guard fstat(inputFD, &after) == 0, before.st_size == after.st_size,
                      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, fileBytes == Int64(after.st_size) else {
                    throw failure("复制期间源文件发生变化，请重试")
                }
                try destination.close(); try input.close()
            } catch { try? destination.close(); try? input.close(); throw error }
            let identity = hash.finalize().map { String(format: "%02x", $0) }.joined()
            revision.update(data: Data(relative.utf8)); revision.update(data: Data([0])); revision.update(data: Data(identity.utf8))
            assets.append(WebWallpaperGrantedAsset(token: token, url: output, name: name, contentIdentity: identity))
        }
        let contentRevision = revision.finalize().map { String(format: "%02x", $0) }.joined()
        let bookmark = try selected.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        if let old = document.records[key], sameSource, old.contentRevision == contentRevision,
           old.grant.assets.allSatisfy({ (try? validateAsset($0, root: itemRoot)) != nil }) {
            // No content changes: keep stable URLs and refresh the source bookmark.
            document.records[key] = AuthorPropertyAssetRecord(grant: old.grant, bookmark: bookmark, contentRevision: contentRevision, sourceIdentity: sourceIdentity, relativeTokens: relativeTokens)
            try Task.checkCancellation(); try save(document)
            return old.grant
        }
        let value = kind == .file ? assets.first?.virtualPath ?? "" : (sameSource ? previous?.grant.value.stringValue : nil) ?? "__gw_assets__/\(grantID.uuidString)"
        let grant = AuthorPropertyAssetGrant(id: grantID, itemID: itemID, propertyKey: key, kind: kind, value: .string(value), revision: UUID().uuidString, assets: assets, directoryMode: mode)
        document.records[key] = AuthorPropertyAssetRecord(grant: grant, bookmark: bookmark, contentRevision: contentRevision, sourceIdentity: sourceIdentity, relativeTokens: relativeTokens)
        try Task.checkCancellation()
        try save(document)
        committed = true
        return grant
    }

    private func selectedFiles(_ source: URL, kind: AuthorPropertyAssetKind, fileType: String?) throws -> [String] {
        let images: Set<String> = ["jpeg", "jpg", "png", "pnga", "bmp", "gif", "svg", "webp", "avif", "heic"]
        let videos: Set<String> = ["webm", "ogg", "ogv", "mp4", "mov", "m4v"]
        let extensions: Set<String>
        switch fileType?.lowercased() {
        case "image": extensions = images
        case "video": extensions = videos
        case nil, "": extensions = images.union(videos)
        default: throw failure("不支持此资源文件类型筛选")
        }
        if kind == .file {
            guard extensions.contains(source.pathExtension.lowercased()) else { throw failure("所选文件不符合作者要求的图像或视频类型") }
            return [source.lastPathComponent]
        }
        var enumerationError: Error?
        guard let iterator = fm.enumerator(at: source, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in enumerationError = error; return false }) else { throw failure("无法读取所选目录") }
        var files: [String] = []
        var count = 0
        for case let url as URL in iterator {
            try Task.checkCancellation()
            count += 1
            guard count <= limits.maximumEntries else { throw failure("目录项目过多") }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw failure("目录资源不可访问") }
            let type = info.st_mode & mode_t(S_IFMT)
            guard type == mode_t(S_IFDIR) || type == mode_t(S_IFREG) else { throw failure("目录包含符号链接或特殊文件") }
            let resolved = try canonical(url)
            guard resolved.path.hasPrefix(source.path + "/") else { throw failure("资源超出所选目录") }
            if type == mode_t(S_IFREG), extensions.contains(resolved.pathExtension.lowercased()) {
                files.append(String(resolved.path.dropFirst(source.path.count + 1)))
                guard files.count <= limits.maximumFiles else { throw failure("目录媒体文件过多") }
            }
        }
        if let enumerationError { throw enumerationError }
        return files
    }

    private func openRelative(_ path: String, rootFD: Int32) throws -> Int32 {
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else { throw failure("资源路径无效") }
        var current = dup(rootFD)
        guard current >= 0 else { throw failure("无法打开资源目录") }
        for (index, component) in components.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (index == components.count - 1 ? 0 : O_DIRECTORY)
            let next = openat(current, component, flags)
            close(current)
            guard next >= 0 else { throw failure("资源不可访问或复制时被替换") }
            current = next
        }
        return current
    }

    private func load(_ itemID: UUID) throws -> Document {
        try requireAvailable(itemID)
        guard fm.fileExists(atPath: directory.path) else { return Document(itemID: itemID, records: [:]) }
        try ownedDirectory(directory, create: false)
        let root = directory.appendingPathComponent(itemID.uuidString, isDirectory: true)
        guard fm.fileExists(atPath: root.path) else { return Document(itemID: itemID, records: [:]) }
        try ownedDirectory(root, create: false)
        let file = root.appendingPathComponent("grants.json")
        guard fm.fileExists(atPath: file.path) else { return Document(itemID: itemID, records: [:]) }
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid(), info.st_size <= 8 * 1024 * 1024 else { throw failure("资源授权文件无效") }
        let handleFD = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard handleFD >= 0 else { throw failure("资源授权文件不可访问") }
        let handle = FileHandle(fileDescriptor: handleFD, closeOnDealloc: true)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
        guard bytes.count <= 8 * 1024 * 1024 else { throw failure("资源授权文件过大") }
        let document = try JSONDecoder().decode(Document.self, from: bytes)
        guard document.schemaVersion == 1, document.itemID == itemID,
              document.records.allSatisfy({ $0.key == $0.value.grant.propertyKey && $0.value.grant.itemID == itemID }) else { throw failure("资源授权文件版本或作品标识无效") }
        for record in document.records.values {
            let grant = record.grant
            if let tokens = record.relativeTokens {
                guard let identity = record.sourceIdentity, identity.count == 64,
                      tokens.count == grant.assets.count, Set(tokens.values).count == tokens.count,
                      tokens.values.allSatisfy({ UUID(uuidString: $0) != nil }),
                      Set(tokens.values) == Set(grant.assets.map(\.token)) else { throw failure("资源授权路径标识无效") }
            }
            let expectedValue: String
            if grant.kind == .file {
                guard grant.assets.count == 1, grant.directoryMode == nil else { throw failure("文件授权结构无效") }
                expectedValue = grant.assets[0].virtualPath
            } else {
                guard grant.directoryMode != nil else { throw failure("目录授权模式无效") }
                guard let value = grant.value.stringValue, value.hasPrefix("__gw_assets__/"),
                      UUID(uuidString: String(value.dropFirst("__gw_assets__/".count))) != nil else { throw failure("目录虚拟命名空间无效") }
                expectedValue = value
            }
            guard grant.value == .string(expectedValue), grant.assets.count <= limits.maximumFiles else { throw failure("资源授权虚拟值无效") }
            for asset in grant.assets {
                guard asset.url.path == root.appendingPathComponent(grant.id.uuidString).appendingPathComponent(asset.token).path else { throw failure("资源授权副本路径无效") }
            }
        }
        return document
    }

    private func save(_ document: Document) throws {
        guard document.records.values.reduce(0, { $0 + $1.grant.assets.count }) <= 2048,
              document.records.values.filter({ $0.grant.kind == .directory }).count <= 128 else {
            throw failure("该作品的授权资源总数超过运行时限制")
        }
        let root = try itemRoot(document.itemID, create: true)
        let destination = root.appendingPathComponent("grants.json")
        var info = stat()
        if lstat(destination.path, &info) == 0 {
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid() else { throw failure("资源授权目标不是本用户常规文件") }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= 8 * 1024 * 1024 else { throw failure("资源授权记录过大") }
        // Set private permissions before the atomic commit; no throwing work
        // after rename can make the caller mistake a committed grant for failure.
        let temporary = root.appendingPathComponent(".grants-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw failure("无法准备资源授权记录") }
        defer { try? fm.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard rename(temporary.path, destination.path) == 0 else { throw failure("无法原子保存资源授权记录") }
    }

    private func itemRoot(_ itemID: UUID, create: Bool) throws -> URL {
        try ownedDirectory(directory, create: create)
        let root = directory.appendingPathComponent(itemID.uuidString, isDirectory: true)
        try ownedDirectory(root, create: create)
        return try canonical(root)
    }

    private func ownedDirectory(_ url: URL, create: Bool) throws {
        guard url.isFileURL else { throw failure("资源库必须为本地目录") }
        // Reject symlink ancestors too; /tmp and /var aliases are normalized once
        // by the caller's choice of vault root, not accepted as managed links.
        var ancestors: [URL] = []
        var cursor = url
        while cursor.path != "/" { ancestors.append(cursor); cursor.deleteLastPathComponent() }
        for component in ancestors.reversed() {
            var info = stat()
            if lstat(component.path, &info) != 0 {
                guard create else { throw failure("资源库目录不存在") }
                try fm.createDirectory(at: component, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                guard lstat(component.path, &info) == 0 else { throw failure("无法验证资源库目录") }
            }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw failure("资源库路径包含符号链接或不是目录") }
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid() else { throw failure("资源库目录不属于当前用户") }
        if create { try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
    }

    private func validateAsset(_ asset: WebWallpaperGrantedAsset, root: URL) throws {
        guard UUID(uuidString: asset.token) != nil, !asset.name.isEmpty, !asset.name.contains("/"), !asset.name.contains("\\"), !asset.name.contains("\0"),
              asset.url.path.hasPrefix(root.path + "/") else { throw failure("资源映射无效") }
        let resolved = try canonical(asset.url)
        guard resolved.path == asset.url.path, resolved.path.hasPrefix(root.path + "/") else { throw failure("资源副本超出所属作品目录") }
        var info = stat()
        guard lstat(asset.url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid(), info.st_size <= limits.maximumFileBytes else { throw failure("资源副本不可访问或被替换") }
    }

    private func canonical(_ url: URL) throws -> URL {
        guard url.isFileURL, let pointer = realpath(url.path, nil) else { throw failure("资源路径不可访问") }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer))
    }
    private func failure(_ text: String) -> AuthorPropertyAssetError { AuthorPropertyAssetError(message: text) }
}
