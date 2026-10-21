// PKG layout reference: MIT RePKG PackageReader.cs, commit 8005eb271f4cb5b9e375bafa912029a0d67b5eb8.
import Foundation
import Darwin

final class ScenePackageArchive: @unchecked Sendable {
    struct Entry: Equatable, Sendable { let path: String; let offset: UInt64; let length: Int }
    let magic: String
    let entries: [Entry]
    private let descriptor: Int32
    private let index: [String: Entry]
    private let dataStart: UInt64
    private let limits: SceneReadLimits

    static func normalizedPath(_ path: String) throws -> String {
        let path = path.replacingOccurrences(of: "\\", with: "/").precomposedStringWithCanonicalMapping
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 255, !path.contains(":"), !path.contains("\0"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw SceneWallpaperFailure(message: "Unsafe package-relative path: \(path.prefix(80))")
        }
        return path
    }

    convenience init(url: URL, limits: SceneReadLimits = SceneReadLimits()) throws {
        guard url.isFileURL else { throw SceneWallpaperFailure(message: "Scene PKG requires a local file.") }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SceneWallpaperFailure(message: "Cannot open Scene PKG without following links.") }
        defer { Darwin.close(descriptor) }
        try self.init(fileDescriptor: descriptor, limits: limits)
    }
    init(fileDescriptor: Int32, limits: SceneReadLimits = SceneReadLimits()) throws {
        let fd = dup(fileDescriptor)
        guard fd >= 0 else { throw SceneWallpaperFailure(message: "Cannot retain Scene PKG descriptor.") }
        var retained = false
        defer { if !retained { Darwin.close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 12,
              UInt64(info.st_size) <= limits.maximumArchiveBytes, limits.maximumEntries > 0, limits.maximumIndexBytes >= 12 else {
            throw SceneWallpaperFailure(message: "Scene PKG is not a bounded regular archive.")
        }
        let indexBytes = try Self.read(fd, offset: 0, count: min(Int(info.st_size), limits.maximumIndexBytes))
        var cursor = SceneByteCursor(data: indexBytes)
        let magicLength = try cursor.u32()
        guard (8...32).contains(magicLength), let marker = String(data: try cursor.bytes(Int(magicLength)), encoding: .utf8),
              marker.count == 8, marker.hasPrefix("PKGV"), marker.utf8.count == 8, marker.suffix(4).utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw SceneWallpaperFailure(message: "Unsupported PKG signature.")
        }
        let count = try cursor.u32()
        guard count > 0, count <= limits.maximumEntries else { throw SceneWallpaperFailure(message: "Unsafe PKG entry count.") }
        var parsed: [Entry] = [], dictionary: [String: Entry] = [:]
        for _ in 0..<count {
            let pathLength = try cursor.u32()
            guard pathLength > 0, pathLength <= 255,
                  let path = String(data: try cursor.bytes(Int(pathLength)), encoding: .utf8) else { throw SceneWallpaperFailure(message: "Invalid PKG entry path.") }
            let normalized = try Self.normalizedPath(path), offset = try cursor.u32(), length = try cursor.u32()
            guard offset <= Int32.max, length <= Int32.max else { throw SceneWallpaperFailure(message: "Negative/overflowing PKG entry range.") }
            let entry = Entry(path: normalized, offset: UInt64(offset), length: Int(length)), key = normalized.lowercased()
            guard dictionary[key] == nil else { throw SceneWallpaperFailure(message: "Ambiguous duplicate PKG path.") }
            dictionary[key] = entry; parsed.append(entry)
        }
        let start = UInt64(cursor.offset), total = UInt64(info.st_size)
        var end: UInt64 = 0
        for entry in parsed.sorted(by: { $0.offset < $1.offset }) {
            guard start <= total, entry.offset <= total - start, UInt64(entry.length) <= total - start - entry.offset,
                  entry.length == 0 || entry.offset >= end else { throw SceneWallpaperFailure(message: "Truncated or overlapping PKG payload ranges.") }
            if entry.length > 0 { end = entry.offset + UInt64(entry.length) }
        }
        magic = marker; entries = parsed; index = dictionary; dataStart = start; descriptor = fd; self.limits = limits
        retained = true
    }
    deinit { Darwin.close(descriptor) }
    func contains(_ path: String) -> Bool { (try? Self.normalizedPath(path)).map { index[$0.lowercased()] != nil } ?? false }
    func read(_ path: String, maximumBytes: Int? = nil) throws -> Data {
        let normalized = try Self.normalizedPath(path)
        guard let entry = index[normalized.lowercased()] else { throw SceneWallpaperFailure(message: "Missing archive resource: \(normalized)") }
        guard entry.length <= min(maximumBytes ?? limits.maximumEntryBytes, limits.maximumEntryBytes) else { throw SceneWallpaperFailure(message: "Archive entry exceeds configured read limit: \(normalized)") }
        return try Self.read(descriptor, offset: dataStart + entry.offset, count: entry.length)
    }
    private static func read(_ descriptor: Int32, offset: UInt64, count: Int) throws -> Data {
        var result = Data(count: count), readCount = 0
        try result.withUnsafeMutableBytes { buffer in
            while readCount < count {
                let amount = pread(descriptor, buffer.baseAddress!.advanced(by: readCount), count - readCount, off_t(offset + UInt64(readCount)))
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw SceneWallpaperFailure(message: "PKG changed or was truncated during bounded read.") }
                readCount += amount
            }
        }
        return result
    }
}
