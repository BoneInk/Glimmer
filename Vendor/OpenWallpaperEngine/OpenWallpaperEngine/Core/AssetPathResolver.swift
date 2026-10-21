import Darwin
import Foundation

/// The one place a wallpaper's asset paths (scene, material, model, shader include, font, sound…)
/// become files. A path is relative, uses `/` or `\`, and never climbs out with `..`; the file it
/// names, with every symbolic link resolved, must lie inside the folder it is looked up in (the
/// wallpaper's folder, the WE assets folder, or one Workshop dependency's folder), be a regular
/// file, and be no larger than `maxFileSize`.
enum AssetPathResolver {
    /// The largest asset read. WE's biggest assets (textures, models) are far below it.
    static let maxFileSize: UInt64 = 1 << 30

    enum ReadError: Error, CustomStringConvertible {
        case tooLarge(path: String, size: UInt64)
        case notRegularFile(path: String)
        case io(path: String, errno: Int32)

        var description: String {
            switch self {
            case .tooLarge(let path, let size): return "\(path) is \(size) bytes, over the \(AssetPathResolver.maxFileSize)-byte limit"
            case .notRegularFile(let path): return "\(path) is not a regular file"
            case .io(let path, let code): return "\(path): \(String(cString: strerror(code)))"
            }
        }
    }

    /// `path` as a clean relative path (`a/b/c.ext`): backslashes become `/`, empty and `.`
    /// components drop out. Nil for an empty path, an absolute one (`/…`, `C:…`, `\\server…`), one
    /// with a `..` component, or one with a NUL.
    static func sanitize(_ path: String) -> String? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.hasPrefix("/"), !normalized.contains("\0") else { return nil }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        guard let first = components.first, !components.contains("..") else { return nil }
        // A drive letter (`C:\…`, `C:…`) makes a Windows path absolute or drive-relative.
        if first.count >= 2, first.first?.isLetter == true, first.dropFirst().first == ":" { return nil }
        return components.joined(separator: "/")
    }

    /// The canonical URL of the regular file `path` names inside `root`; nil when the path isn't a
    /// clean relative one, the file doesn't exist, isn't regular, is too large, or lies outside
    /// `root` once links are resolved.
    static func fileURL(_ path: String, in root: URL) -> URL? {
        guard let relative = sanitize(path),
              let rootPath = ContainedPath.canonical(root),
              let filePath = ContainedPath.canonical(root.appending(path: relative)),
              filePath != rootPath else { return nil }
        guard ContainedPath.isInside(filePath, root: rootPath) else {
            OWELog.debug(.scene, "Asset \(path) resolves outside \(root.path(percentEncoded: false)); not used")
            return nil
        }
        var info = stat()
        guard stat(filePath, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              UInt64(max(info.st_size, 0)) <= maxFileSize else { return nil }
        return URL(fileURLWithPath: filePath)
    }

    /// The bytes of `path` inside `root`; nil when `fileURL(_:in:)` finds no usable file there.
    /// Throws only when a usable file can't be read.
    static func data(_ path: String, in root: URL) throws -> Data? {
        guard let url = fileURL(path, in: root) else { return nil }
        return try readRegularFile(at: url)
    }

    /// Reads the regular file at `url` (a canonical path from `fileURL(_:in:)`), refusing a link in
    /// its place, anything that isn't a regular file, and anything over `maxFileSize`.
    static func readRegularFile(at url: URL) throws -> Data {
        let path = url.path(percentEncoded: false)
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ReadError.io(path: path, errno: errno) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ReadError.io(path: path, errno: errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw ReadError.notRegularFile(path: path) }
        let size = UInt64(max(info.st_size, 0))
        guard size <= maxFileSize else { throw ReadError.tooLarge(path: path, size: size) }
        // Read at most one byte past the limit, so a file that grows meanwhile is still refused.
        let data = try handle.read(upToCount: Int(maxFileSize) + 1) ?? Data()
        guard UInt64(data.count) <= maxFileSize else { throw ReadError.tooLarge(path: path, size: UInt64(data.count)) }
        return data
    }
}
