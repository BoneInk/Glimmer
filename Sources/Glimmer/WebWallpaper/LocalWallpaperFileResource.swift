import Darwin
import Foundation

/// A validated open file, retained through the entire response. All components
/// are opened relative to the root descriptor, never following symbolic links.
final class LocalWallpaperFileResource {
    static let chunkBytes = 64 * 1024
    private let descriptor: Int32
    let size: Int64
    let fingerprint: String

    init(file: URL, root: URL) throws {
        guard WebWallpaperProjectLocation.contains(file, in: root) else { throw URLError(.noPermissionsToReadFile) }
        var fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw URLError(.noPermissionsToReadFile) }
        defer { if fd >= 0 { Darwin.close(fd) } }
        let components = file.path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw URLError(.noPermissionsToReadFile) }
        for (index, component) in components.enumerated() {
            guard component != ".", component != ".." else { throw URLError(.noPermissionsToReadFile) }
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (index < components.count - 1 ? O_DIRECTORY : O_NONBLOCK)
            let next = Darwin.openat(fd, component, flags)
            guard next >= 0 else { throw URLError(.noPermissionsToReadFile) }
            Darwin.close(fd); fd = next
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
            throw WebWallpaperFailure(message: "Blocked a special wallpaper resource.")
        }
        size = info.st_size; fingerprint = Self.fingerprint(info); descriptor = fd; fd = -1
    }

    deinit { Darwin.close(descriptor) }

    private static func fingerprint(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    func validateUnchanged() throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, Self.fingerprint(info) == fingerprint else {
            throw URLError(.resourceUnavailable)
        }
    }

    func read(offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, offset <= size, count >= 0, count <= Self.chunkBytes,
              Int64(count) <= size - offset else { throw URLError(.badServerResponse) }
        var result = Data(count: count)
        var received = 0
        try result.withUnsafeMutableBytes { buffer in
            while received < count {
                let amount = pread(descriptor, buffer.baseAddress!.advanced(by: received), count - received, off_t(offset + Int64(received)))
                if amount < 0 { if errno == EINTR { continue }; throw URLError(.cannotOpenFile) }
                guard amount > 0 else { throw URLError(.resourceUnavailable) }
                received += amount
            }
        }
        return result
    }

    /// HTML is transformed before serving and retains a bounded allocation.
    /// Binary assets are streamed, so their file size is not an allocation cap.
    func readDocument(maximumBytes: Int) throws -> Data {
        guard size <= maximumBytes else { throw WebWallpaperFailure(message: "Wallpaper HTML exceeds the document size limit.") }
        var bytes = Data()
        var offset: Int64 = 0
        while offset < size {
            let count = Int(min(Int64(Self.chunkBytes), size - offset))
            bytes.append(try read(offset: offset, count: count)); offset += Int64(count)
        }
        return bytes
    }
}

/// Single-range responses cover HTMLMediaElement's metadata/seek requests.
/// Unsupported/malformed/multiple ranges get an explicit 416 response.
struct LocalWallpaperResourceResponse {
    let status: Int
    let offset: Int64
    let length: Int64
    let contentRange: String?

    init(size: Int64, range: String?, method: String) {
        if method == "HEAD" || range == nil {
            status = 200; offset = 0; length = size; contentRange = nil; return
        }
        func unsatisfied() -> (Int, Int64, Int64, String?) { (416, 0, 0, "bytes */\(size)") }
        let value = range!.trimmingCharacters(in: .whitespaces)
        var parsed = unsatisfied()
        if value.lowercased().hasPrefix("bytes="), size > 0 {
            let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            func integer(_ text: Substring) -> Int64? {
                guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
                return Int64(text)
            }
            if parts.count == 2 {
                if parts[0].isEmpty, let suffix = integer(parts[1]), suffix > 0 {
                    let count = min(size, suffix), start = size - min(size, suffix)
                    parsed = (206, start, count, "bytes \(start)-\(size - 1)/\(size)")
                } else if let start = integer(parts[0]), start < size {
                    let requestedEnd = parts[1].isEmpty ? size - 1 : integer(parts[1])
                    if let requestedEnd, requestedEnd >= start {
                        let end = min(size - 1, requestedEnd)
                        parsed = (206, start, end - start + 1, "bytes \(start)-\(end)/\(size)")
                    }
                }
            }
        }
        (status, offset, length, contentRange) = parsed
    }

    func headers(mimeType: String) -> [String: String] {
        var headers = ["Content-Type": mimeType, "Content-Length": String(length),
                       "Accept-Ranges": "bytes", "Cache-Control": "no-store"]
        if let contentRange { headers["Content-Range"] = contentRange }
        return headers
    }
}
