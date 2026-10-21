import Foundation
import CryptoKit
import Darwin

struct LiveWallpaperFile: Codable, Equatable, Sendable {
    let path: String
    let size: UInt64
    let sha256: String
}

/// Relative paths only. Shared by the application and its sandboxed extension.
struct LiveWallpaperRecipe: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case scene, web }
    let assetID: UUID
    let kind: Kind
    let width: Int
    let height: Int
    let fps: Int
    let entryFile: String?
    let propertiesJSON: Data
    let sceneProperties: [String: String]
    let projectDigest: String
    let assetsManifestDigest: String
    let allowHTTPS: Bool
    var files: [LiveWallpaperFile] = []

    func validate() throws {
        guard (2...8192).contains(width), (2...8192).contains(height),
              width * height <= 16_777_216, (1...240).contains(fps),
              propertiesJSON.count <= 1_048_576, sceneProperties.count <= 256,
              sceneProperties.allSatisfy({ $0.key.utf8.count <= 256 && $0.value.utf8.count <= 16_384 }),
              Self.digest(projectDigest), Self.digest(assetsManifestDigest),
              !files.isEmpty, files.count <= LiveWallpaperBundle.maximumFiles,
              files.contains(where: { $0.path == "project/project.json" && $0.sha256 == projectDigest }),
              files.allSatisfy({ Self.relative($0.path) && Self.digest($0.sha256) && $0.size <= LiveWallpaperBundle.maximumBytes }),
              Set(files.map(\.path)).count == files.count,
              kind != .web || (entryFile.map(Self.relative) == true
                && ["html", "htm"].contains((entryFile! as NSString).pathExtension.lowercased())
                && files.contains(where: { $0.path == "project/" + entryFile! }))
        else { throw LiveWallpaperFailure(message: "实时锁屏项目配置无效。") }
        var total: UInt64 = 0
        for file in files {
            guard file.size <= LiveWallpaperBundle.maximumBytes - total else { throw LiveWallpaperFailure(message: "实时锁屏项目超出大小限制。") }
            total += file.size
        }
    }
    static func relative(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 1024 && !path.contains("\\")
            && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func digest(_ text: String) -> Bool { text.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

struct LiveWallpaperFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Copies/hashes regular owned files via directory descriptors. Symlinks, hard
/// links and special files never grant access outside the selected project.
enum LiveWallpaperBundle {
    static let maximumFiles = 50_000
    static let maximumBytes: UInt64 = 2 * 1024 * 1024 * 1024

    static func inspect(_ root: URL, copyTo destination: URL? = nil, requirePrivate: Bool = false) throws -> [LiveWallpaperFile] {
        let source = try openRoot(root)
        defer { close(source) }
        let output: Int32?
        if let destination {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            output = try openRoot(destination)
        } else { output = nil }
        defer { if let output { close(output) } }
        var records = [LiveWallpaperFile](), total: UInt64 = 0, nodes = 0
        try walk(source, output: output, prefix: "", depth: 0, requirePrivate: requirePrivate,
            records: &records, total: &total, nodes: &nodes)
        return records.sorted { $0.path < $1.path }
    }

    static func load(_ root: URL) throws -> LiveWallpaperRecipe {
        let directory = try openRoot(root)
        defer { close(directory) }
        var rootInfo = stat()
        guard fstat(directory, &rootInfo) == 0, rootInfo.st_mode & 0o077 == 0 else { throw failure() }
        let descriptor = openat(directory, "recipe.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw failure() }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 16 * 1024 * 1024 else { throw failure() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        while let next = try handle.read(upToCount: 65_536), !next.isEmpty {
            guard data.count + next.count <= 16 * 1024 * 1024 else { throw failure() }
            data.append(next)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { throw failure() }
        let recipe = try JSONDecoder().decode(LiveWallpaperRecipe.self, from: data)
        try recipe.validate()
        guard try inspect(root, requirePrivate: true) == recipe.files.sorted(by: { $0.path < $1.path }) else { throw failure() }
        return recipe
    }

    static func writeRecipe(_ recipe: LiveWallpaperRecipe, root: URL) throws {
        try recipe.validate()
        let data = try JSONEncoder().encode(recipe)
        let file = root.appendingPathComponent("recipe.json")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func openRoot(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), let resolved = realpath(url.path, nil) else { throw failure() }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        let expected = (url.path.hasPrefix("/tmp/") || url.path.hasPrefix("/var/")) ? "/private" + url.path : url.path
        guard canonical == expected else { throw failure() }
        // An extension may read its granted subtree without permission to list
        // / or /Users. Open that root directly, then verify the actual descriptor
        // path to detect an ancestor changed between realpath and open.
        let descriptor = open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure() }
        var actual = [CChar](repeating: 0, count: Int(MAXPATHLEN)), info = stat()
        let pathResult = actual.withUnsafeMutableBufferPointer { fcntl(descriptor, F_GETPATH, $0.baseAddress!) }
        let actualPath = String(decoding: actual.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard pathResult == 0, actualPath == canonical,
              fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            close(descriptor); throw failure()
        }
        return descriptor
    }

    private static func walk(_ parent: Int32, output: Int32?, prefix: String, depth: Int, requirePrivate: Bool,
                             records: inout [LiveWallpaperFile], total: inout UInt64, nodes: inout Int) throws {
        guard depth <= 32, let stream = fdopendir(dup(parent)) else { throw failure() }
        defer { closedir(stream) }
        errno = 0
        while let entry = readdir(stream) {
            try Task.checkCancellation()
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." || name == ".DS_Store" || (prefix.isEmpty && name == "recipe.json") { errno = 0; continue }
            nodes += 1
            let path = prefix.isEmpty ? name : prefix + "/" + name
            guard nodes <= maximumFiles, LiveWallpaperRecipe.relative(path) else { throw failure() }
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_uid == getuid(), info.st_mode & (requirePrivate ? 0o077 : 0o022) == 0 else { throw failure() }
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw failure() }
                defer { close(child) }
                var opened = stat()
                guard fstat(child, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino,
                      opened.st_uid == getuid(), opened.st_mode & (requirePrivate ? 0o077 : 0o022) == 0 else { throw failure() }
                let target: Int32?
                if let output {
                    guard mkdirat(output, name, 0o700) == 0 else { throw failure() }
                    let value = openat(output, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard value >= 0 else { throw failure() }
                    target = value
                } else { target = nil }
                defer { if let target { close(target) } }
                try walk(child, output: target, prefix: path, depth: depth + 1, requirePrivate: requirePrivate,
                    records: &records, total: &total, nodes: &nodes)
            } else {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size >= 0,
                      records.count < maximumFiles, UInt64(info.st_size) <= maximumBytes - total else { throw failure() }
                let input = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard input >= 0 else { throw failure() }
                defer { close(input) }
                var before = stat()
                guard fstat(input, &before) == 0, before.st_dev == info.st_dev, before.st_ino == info.st_ino,
                      before.st_nlink == 1, before.st_size == info.st_size else { throw failure() }
                let target = output.map { openat($0, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
                if let target, target < 0 { throw failure() }
                defer { if let target { close(target) } }
                var digest = SHA256(), bytes: UInt64 = 0, buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    try Task.checkCancellation()
                    let length = Darwin.read(input, &buffer, buffer.count)
                    if length < 0, errno == EINTR { continue }
                    guard length >= 0, UInt64(length) <= UInt64(before.st_size) - bytes else { throw failure() }
                    if length == 0 { break }
                    let data = Data(buffer.prefix(length)); digest.update(data: data); bytes += UInt64(length)
                    if let target {
                        try data.withUnsafeBytes { raw in
                            var offset = 0
                            while offset < length {
                                let written = Darwin.write(target, raw.baseAddress!.advanced(by: offset), length - offset)
                                if written < 0, errno == EINTR { continue }
                                guard written > 0 else { throw failure() }
                                offset += written
                            }
                        }
                    }
                }
                var after = stat()
                guard fstat(input, &after) == 0, bytes == UInt64(before.st_size),
                      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw failure() }
                records.append(.init(path: path, size: bytes, sha256: digest.finalize().map { String(format: "%02x", $0) }.joined()))
                total += bytes
            }
            errno = 0
        }
        guard errno == 0 else { throw failure() }
    }
    private static func failure() -> LiveWallpaperFailure {
        .init(message: "实时锁屏资源校验失败：项目包含不安全、已改变或超出限制的文件。")
    }
}
