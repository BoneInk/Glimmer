import Darwin
import Foundation

@main enum LocalWallpaperFileResourceTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, name); checks += 1; print("PASS \(name)")
        }
        func rejects(_ name: String, _ action: () throws -> Void) {
            do { try action(); preconditionFailure(name) } catch { check(true, name) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Glimmer-resource-tests-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("movie.webm")
        let bytes = Data((0..<100_000).map { UInt8($0 % 251) })
        try bytes.write(to: file)
        let resource = try LocalWallpaperFileResource(file: file, root: root)
        let firstChunk = try resource.read(offset: 0, count: 65536)
        check(resource.size == Int64(bytes.count) && firstChunk == bytes.prefix(65536), "bounded reads preserve source bytes")
        check((try resource.read(offset: 99900, count: 100)) == bytes.suffix(100), "random access preserves the exact requested suffix")
        rejects("oversized chunk requests cannot allocate the entire media") { _ = try resource.read(offset: 0, count: 65537) }
        rejects("out-of-file requests fail") { _ = try resource.read(offset: 99999, count: 2) }
        let large = root.appendingPathComponent("300MiB.webm")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 300 * 1024 * 1024)
        try handle.seek(toOffset: 300 * 1024 * 1024 - 4); try handle.write(contentsOf: Data([1, 2, 3, 4])); try handle.close()
        let largeResource = try LocalWallpaperFileResource(file: large, root: root)
        let largeTail = try largeResource.read(offset: largeResource.size - 4, count: 4)
        check(largeResource.size == 300 * 1024 * 1024 && largeTail == Data([1, 2, 3, 4]), "a 300 MiB binary file is accessible without reading it into memory")
        rejects("the buffered document limit remains separate from binary streaming") { _ = try largeResource.readDocument(maximumBytes: 32 * 1024 * 1024) }
        let full = LocalWallpaperResourceResponse(size: 100, range: nil, method: "GET")
        check(full.status == 200 && full.offset == 0 && full.length == 100, "ordinary GET describes the complete resource")
        for (header, start, length) in [("bytes=0-0", 0, 1), ("bytes=0-19", 0, 20), ("bytes=90-", 90, 10), ("bytes=-20", 80, 20), ("bytes=-999", 0, 100), ("bytes=90-999", 90, 10)] {
            let response = LocalWallpaperResourceResponse(size: 100, range: header, method: "GET")
            check(response.status == 206 && response.offset == start && response.length == length && response.contentRange != nil, "range honored: \(header)")
        }
        for header in ["bytes=100-", "bytes=5-4", "bytes=-0", "bytes=", "bytes=1-2,4-5", "items=0-1", "bytes=+1-2", "bytes=0-999999999999999999999999999"] {
            let response = LocalWallpaperResourceResponse(size: 100, range: header, method: "GET")
            check(response.status == 416 && response.length == 0 && response.contentRange == "bytes */100", "invalid/unsatisfiable range rejected: \(header)")
        }
        let head = LocalWallpaperResourceResponse(size: largeResource.size, range: "bytes=0-3", method: "HEAD")
        check(head.status == 200 && head.headers(mimeType: "video/webm")["Content-Length"] == String(largeResource.size), "HEAD describes the large resource without serving a body")
        let empty = LocalWallpaperResourceResponse(size: 0, range: "bytes=0-", method: "GET")
        check(empty.status == 416 && empty.contentRange == "bytes */0", "empty resource range stays well-defined")
        let symlink = root.appendingPathComponent("link.webm")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
        rejects("symbolic link resources remain denied") { _ = try LocalWallpaperFileResource(file: symlink, root: root) }
        let fifo = root.appendingPathComponent("pipe.webm")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw URLError(.cannotCreateFile) }
        rejects("special files are rejected without blocking the reader") { _ = try LocalWallpaperFileResource(file: fifo, root: root) }
        rejects("a sibling project is outside the resource boundary") { _ = try LocalWallpaperFileResource(file: root.deletingLastPathComponent().appendingPathComponent("secret.webm"), root: root) }
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("original.webm"))
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: large)
        check((try resource.read(offset: 0, count: 12)) == bytes.prefix(12), "the open response remains bound to its original inode after path replacement")
        let truncate = try FileHandle(forWritingTo: root.appendingPathComponent("original.webm"))
        try truncate.truncate(atOffset: 0); try truncate.close()
        rejects("truncation during a response fails instead of claiming successful delivery") { _ = try resource.read(offset: 0, count: 12) }
        print("RESULT \(checks) streaming-file and byte-range checks passed")
    }
}
