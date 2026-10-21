import Darwin
import Foundation

/// Read-only, explicit-root inventory. Does not parse external VDF library paths,
/// log in, execute media, copy assets or write a library. Importers must revalidate
/// the source at import time; a scan result is not a persistent filesystem grant.
actor SteamLibraryScanner {
    private let limits: SteamLibraryScanLimits
    init(limits: SteamLibraryScanLimits = .default) {
        var bounded = limits
        bounded.maximumItems = min(max(0, limits.maximumItems), 2_000)
        bounded.maximumDirectoryEntries = min(max(0, limits.maximumDirectoryEntries), 10_000)
        bounded.maximumProjectBytes = min(max(0, limits.maximumProjectBytes), 2 * 1024 * 1024)
        bounded.maximumTitleCharacters = min(max(1, limits.maximumTitleCharacters), 1_024)
        self.limits = bounded
    }

    func scan(selectedRoot: URL) async throws -> SteamLibraryScanReport {
        try Task.checkCancellation()
        let scoped = selectedRoot.startAccessingSecurityScopedResource()
        defer { if scoped { selectedRoot.stopAccessingSecurityScopedResource() } }
        var diagnostics: [SteamLibraryScanDiagnostic] = []
        var roots: [URL] = []
        var items: [SteamLibraryScannedItem] = []
        var truncated = false
        let original = selectedRoot.standardizedFileURL
        func report(_ root: URL) -> SteamLibraryScanReport {
            .init(selectedRoot: root, contentRoots: roots, items: items.sorted {
                if $0.workshopID.count != $1.workshopID.count { return $0.workshopID.count < $1.workshopID.count }
                return $0.workshopID == $1.workshopID ? $0.itemRoot.path < $1.itemRoot.path : $0.workshopID < $1.workshopID
            }, diagnostics: diagnostics, wasTruncated: truncated)
        }
        guard selectedRoot.isFileURL, Self.hasSafeAncestors(original) else {
            diagnostics.append(.init(code: .rejectedSymlink, severity: .error, path: original.path, message: "所选目录包含符号链接或不是本地目录，未扫描。"))
            return report(original)
        }
        let root = original.resolvingSymlinksInPath()
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else {
            diagnostics.append(.init(code: .invalidSelectedRoot, severity: .error, path: root.path, message: "所选目录不存在、不可读取或不是文件夹。"))
            return report(root)
        }
        defer { close(rootFD) }
        let candidates = root.lastPathComponent == "431960" ? [[]] : [["steamapps", "workshop", "content", "431960"], ["workshop", "content", "431960"]]
        var entriesRead = 0
        scanRoots: for components in candidates {
            try Task.checkCancellation()
            let contentURL = components.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
            let contentFD: Int32
            do { contentFD = try Self.openDirectory(rootFD, components: components) }
            catch let failure as ScanFailure {
                if failure.code == .rejectedSymlink || failure.code == .unreadable {
                    diagnostics.append(.init(code: failure.code, severity: .warning, path: contentURL.path, message: failure.message))
                }
                continue
            }
            defer { close(contentFD) }
            roots.append(contentURL)
            let enumerationFD = dup(contentFD)
            guard enumerationFD >= 0, let directory = fdopendir(enumerationFD) else {
                if enumerationFD >= 0 { close(enumerationFD) }
                diagnostics.append(.init(code: .unreadable, severity: .error, path: contentURL.path, message: "无法读取作品目录。")); continue
            }
            defer { closedir(directory) }
            var ignored = 0
            while true {
                try Task.checkCancellation()
                errno = 0
                guard let pointer = readdir(directory) else {
                    if errno != 0 { diagnostics.append(.init(code: .unreadable, severity: .error, path: contentURL.path, message: "作品目录读取未完成，请重新扫描。")) }
                    break
                }
                let name = withUnsafePointer(to: &pointer.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                entriesRead += 1
                if entriesRead > max(0, limits.maximumDirectoryEntries) || items.count >= max(0, limits.maximumItems) {
                    truncated = true
                    diagnostics.append(.init(code: .limitExceeded, severity: .warning, path: contentURL.path, message: "扫描达到目录或作品数量上限；结果仅包含已检查部分。"))
                    break scanRoots
                }
                guard name.utf8.allSatisfy({ (48...57).contains($0) }), let number = UInt64(name), number > 0 else { ignored += 1; continue }
                items.append(try inspect(name: name, normalizedID: String(number), contentFD: contentFD, contentURL: contentURL))
            }
            if ignored > 0 {
                diagnostics.append(.init(code: .ignoredEntries, severity: .information, path: contentURL.path, message: "已忽略 \(ignored) 个非有效数字作品编号的目录项。"))
            }
        }
        if roots.isEmpty { diagnostics.append(.init(code: .contentNotFound, severity: .information, path: root.path, message: "所选目录中没有找到受支持的 431960 工坊内容路径。")) }
        return report(root)
    }

    private func inspect(name: String, normalizedID: String, contentFD: Int32, contentURL: URL) throws -> SteamLibraryScannedItem {
        let itemRoot = contentURL.appendingPathComponent(name, isDirectory: true)
        let projectURL = itemRoot.appendingPathComponent("project.json")
        var title = "作品 \(normalizedID)"
        var kind: SteamLibraryWallpaperKind = .unknown
        var entryURL: URL?
        var availability: SteamLibraryItemAvailability = .invalidProject
        var diagnostics: [SteamLibraryScanDiagnostic] = []
        func item() -> SteamLibraryScannedItem {
            .init(workshopID: normalizedID, itemRoot: itemRoot, projectURL: projectURL, title: title, kind: kind, entryURL: entryURL, availability: availability, diagnostics: diagnostics)
        }
        do {
            let itemFD = try Self.openDirectory(contentFD, components: [name]); defer { close(itemFD) }
            var metadata = stat()
            guard fstatat(itemFD, "project.json", &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw ScanFailure(.missingProject, "缺少可读取的 project.json。") }
            guard metadata.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else { throw ScanFailure(.rejectedSymlink, "project.json 是符号链接，未读取。") }
            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ScanFailure(.invalidProject, "project.json 不是常规文件。") }
            guard metadata.st_size >= 0, metadata.st_size <= max(0, limits.maximumProjectBytes) else { throw ScanFailure(.limitExceeded, "project.json 超过读取大小上限。") }
            let fd = openat(itemFD, "project.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw ScanFailure(.unreadable, "无法安全读取 project.json。") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), opened.st_ino == metadata.st_ino, opened.st_dev == metadata.st_dev else { throw ScanFailure(.sourceChanged, "扫描期间项目文件已改变，请重新扫描。") }
            var bytes = Data()
            while bytes.count <= limits.maximumProjectBytes {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: min(65_536, limits.maximumProjectBytes + 1 - bytes.count)) ?? Data()
                if chunk.isEmpty { break }
                bytes.append(chunk)
            }
            guard bytes.count <= limits.maximumProjectBytes else { throw ScanFailure(.limitExceeded, "project.json 读取达到大小上限。") }
            var after = stat()
            guard fstat(fd, &after) == 0, opened.st_size == after.st_size, opened.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, opened.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw ScanFailure(.sourceChanged, "读取期间项目文件已改变，请重新扫描。") }
            let object: [String: Any]
            do { guard let parsed = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw ScanFailure(.invalidProject, "项目 JSON 顶层必须是对象。") }; object = parsed }
            catch let failure as ScanFailure { throw failure }
            catch { throw ScanFailure(.invalidProject, "project.json 内容损坏或格式无效。") }
            if let provided = object["title"] as? String, !provided.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                title = String(provided.prefix(max(1, limits.maximumTitleCharacters)))
                if provided.count > max(1, limits.maximumTitleCharacters) { diagnostics.append(.init(code: .limitExceeded, severity: .warning, path: projectURL.path, message: "作者标题过长，已截短显示。")) }
            }
            guard let type = object["type"] as? String, type.utf8.count <= 64 else { throw ScanFailure(.invalidProject, "项目缺少有效的作品类型。") }
            kind = SteamLibraryWallpaperKind(rawValue: type.lowercased()) ?? .unknown
            guard let entry = object["file"] as? String, !entry.isEmpty else { throw ScanFailure(.missingEntry, "项目没有声明本地入口文件。") }
            var components = try Self.relativeComponents(entry)
            if kind == .scene {
                // A common Scene declaration names scene.json stored inside
                // scene.pkg. Discovery does not extract or claim renderability.
                var loose = stat(), archive = stat()
                if fstatat(itemFD, components.joined(separator: "/"), &loose, AT_SYMLINK_NOFOLLOW) != 0,
                   fstatat(itemFD, "scene.pkg", &archive, AT_SYMLINK_NOFOLLOW) == 0,
                   archive.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) { components = ["scene.pkg"] }
            }
            let parentFD: Int32
            do { parentFD = try Self.openDirectory(itemFD, components: Array(components.dropLast())) }
            catch let failure as ScanFailure where failure.code == .contentNotFound {
                throw ScanFailure(.missingEntry, "项目入口所在的本地子目录不存在。")
            }
            defer { close(parentFD) }
            var info = stat()
            guard fstatat(parentFD, components.last!, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw ScanFailure(.missingEntry, "项目声明的本地入口文件不存在。") }
            guard info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else { throw ScanFailure(.rejectedSymlink, "入口文件是符号链接，未作为导入候选。") }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ScanFailure(.invalidEntry, "入口不是常规文件。") }
            entryURL = components.reduce(itemRoot) { $0.appendingPathComponent($1) }
            availability = kind == .video || kind == .web || kind == .scene ? .readyForValidation : .unsupportedType
            if kind == .scene { diagnostics.append(.init(code: .validationRequired, severity: .information, path: projectURL.path, message: "已发现本地 Scene 项目；导入前仍须验证当前支持的二维图层与受限 SceneScript 能力，自定义 shader 等未支持功能会给出诊断。")) }
            if availability == .unsupportedType { diagnostics.append(.init(code: .unsupportedType, severity: .information, path: projectURL.path, message: "已识别本地类型，但当前导入链路不支持：\(kind.rawValue)。")) }
        } catch let failure as ScanFailure {
            switch failure.code {
            case .rejectedSymlink: availability = .rejectedSymlink
            case .limitExceeded: availability = .limitExceeded
            case .missingEntry: availability = .missingEntry
            default: availability = .invalidProject
            }
            diagnostics.append(.init(code: failure.code, severity: .error, path: projectURL.path, message: failure.message))
        } catch is CancellationError { throw CancellationError() }
        catch { diagnostics.append(.init(code: .unreadable, severity: .error, path: projectURL.path, message: "项目读取失败，未写入任何文件。")) }
        return item()
    }

    private struct ScanFailure: Error {
        let code: SteamLibraryScanDiagnostic.Code
        let message: String
        init(_ code: SteamLibraryScanDiagnostic.Code, _ message: String) { self.code = code; self.message = message }
    }
    private static func openDirectory(_ rootFD: Int32, components: [String]) throws -> Int32 {
        var fd = dup(rootFD)
        guard fd >= 0 else { throw ScanFailure(.unreadable, "无法打开所选目录。") }
        do {
            for name in components {
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw ScanFailure(.contentNotFound, "候选目录不存在。") }
                guard info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else { throw ScanFailure(.rejectedSymlink, "候选目录包含符号链接，未遍历。") }
                guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw ScanFailure(.unreadable, "候选目录不是实际文件夹。") }
                let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ScanFailure(.unreadable, "无法安全读取候选目录。") }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    private static func relativeComponents(_ path: String) throws -> [String] {
        guard path.utf8.count <= 4096, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"), !path.contains("\0") else { throw ScanFailure(.invalidEntry, "入口必须是作品目录内的相对路径。") }
        let parts = path.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(where: { $0.contains(":") }) else { throw ScanFailure(.invalidEntry, "入口路径越界或格式无效。") }
        return parts
    }
    private static func hasSafeAncestors(_ url: URL) -> Bool {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            guard lstat(current.path, &info) == 0 else { return true } // root open reports missing paths
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                // macOS system aliases are not user-selected library expansion.
                guard current.path == "/tmp" || current.path == "/var" else { return false }
                current = current.resolvingSymlinksInPath()
            }
        }
        return true
    }
}
