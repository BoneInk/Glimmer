import CryptoKit
import Darwin
import Foundation

/// Runs on its owning scheme handler's serial reader queue. Content-addressed
/// private caches are independent of author projects and immutable lock bundles.
/// No decoder, video encoder, frame readback or authored-script rewrite is used.
final class WebWallpaperMediaResolver {
    private enum Prepared { case original, mp4(URL, Int64) }
    private var prepared: [String: Prepared] = [:]
    private let cacheRoot: URL
    private static let diskBudget: Int64 = 2 * 1024 * 1024 * 1024

    init(cacheRoot: URL? = nil) {
        self.cacheRoot = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath()
            .appendingPathComponent("GlimmerWebMedia/vp9-isobmff-v1", isDirectory: true)
    }

    func resolve(_ source: LocalWallpaperFileResource, extension fileExtension: String,
                 cancelled: @escaping () -> Bool) throws -> (file: LocalWallpaperFileResource, mime: String)? {
        guard fileExtension.lowercased() == "webm" else { return nil }
        guard !cancelled() else { throw CancellationError() }
        try source.validateUnchanged()
        if let result = prepared[source.fingerprint] {
            switch result {
            case .original: return nil
            case .mp4(let url, let size):
                if let file = try? openCached(url, expectedSize: size) { return (file, "video/mp4") }
                prepared.removeValue(forKey: source.fingerprint)
            }
        }
        let movie: WebMVP9Container.Movie
        do { movie = try WebMVP9Container.inspect(source, cancelled: cancelled) }
        catch WebMVP9Container.Failure.unsupported { remember(.original, for: source); return nil }
        // Invalid input is rejected, rather than forwarding a malformed container.
        guard source.size <= Self.diskBudget else { remember(.original, for: source); return nil }
        let header = try WebMVP9Container.header(movie)
        let outputSize = movie.samples.reduce(Int64(header.count)) { $0 + Int64($1.size) }
        guard outputSize <= Self.diskBudget else { remember(.original, for: source); return nil }
        var hash = SHA256(), position: Int64 = 0
        while position < source.size {
            if cancelled() { throw CancellationError() }
            let count = Int(min(Int64(LocalWallpaperFileResource.chunkBytes), source.size-position))
            hash.update(data: try source.read(offset: position, count: count)); position += Int64(count)
        }
        try source.validateUnchanged()
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        try makePrivateCache()
        let output = cacheRoot.appendingPathComponent(digest + ".mp4")
        if let file = try? openCached(output, expectedSize: outputSize) { remember(.mp4(output, outputSize), for: source); return (file, "video/mp4") }
        let temporary = cacheRoot.appendingPathComponent("pending-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw URLError(.cannotCreateFile) }
        var committed = false
        defer { Darwin.close(fd); if !committed { try? FileManager.default.removeItem(at: temporary) } }
        func write(_ bytes: Data) throws {
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), bytes.count-offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw URLError(.cannotWriteToFile) }
                    offset += count
                }
            }
        }
        try write(header)
        for sample in movie.samples {
            var offset = sample.offset, remaining = sample.size
            while remaining > 0 {
                if cancelled() { throw CancellationError() }
                let count = min(LocalWallpaperFileResource.chunkBytes, remaining)
                try write(source.read(offset: offset, count: count)); offset += Int64(count); remaining -= count
            }
        }
        try source.validateUnchanged()
        guard !cancelled() else { throw CancellationError() }
        guard fsync(fd) == 0, rename(temporary.path, output.path) == 0 else { throw URLError(.cannotWriteToFile) }
        committed = true
        let file = try openCached(output, expectedSize: outputSize)
        remember(.mp4(output, outputSize), for: source)
        prune(excluding: output)
        return (file, "video/mp4")
    }

    private func remember(_ value: Prepared, for source: LocalWallpaperFileResource) {
        if prepared.count >= 128 { prepared.removeAll(keepingCapacity: true) }
        prepared[source.fingerprint] = value
    }

    private func makePrivateCache() throws {
        // Foundation chooses the process's own sandbox cache, where applicable.
        // Verify each owned subdirectory; never follow a cache-root symlink.
        let parent = cacheRoot.deletingLastPathComponent()
        let base = parent.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: base.path) {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        for url in [parent, cacheRoot] {
            if !FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700])
                } catch {
                    // Another renderer can create this same private cache first.
                    // The ownership/type checks below still apply in that case.
                    if !FileManager.default.fileExists(atPath: url.path) { throw error }
                }
            }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0,
                  url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path else {
                throw URLError(.noPermissionsToReadFile)
            }
        }
    }

    private func openCached(_ url: URL, expectedSize: Int64) throws -> LocalWallpaperFileResource {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw URLError(.noPermissionsToReadFile) }
        let file = try LocalWallpaperFileResource(file: url, root: cacheRoot)
        // Detect interrupted/truncated cache writes before serving a range.
        let header = try file.read(offset: 0, count: Int(min(file.size, 12)))
        guard file.size == expectedSize, header.count == 12,
              header.subdata(in: 4..<8) == Data("ftyp".utf8) else { throw URLError(.cannotDecodeContentData) }
        return file
    }

    private func prune(excluding current: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheRoot,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        var owned: [(URL, Int64, Date)] = []
        for file in files where file.pathExtension == "mp4" {
            let key = file.deletingPathExtension().lastPathComponent
            guard key.count == 64, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { continue }
            owned.append((file, info.st_size, Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))))
        }
        var total = owned.reduce(Int64(0)) { $0 + $1.1 }
        for (url, size, _) in owned.sorted(by: { $0.2 < $1.2 }) where url != current && total > Self.diskBudget {
            if (try? FileManager.default.removeItem(at: url)) != nil { total -= size }
        }
    }
}
