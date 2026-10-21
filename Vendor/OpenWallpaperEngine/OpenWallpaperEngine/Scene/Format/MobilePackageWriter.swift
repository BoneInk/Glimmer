import Foundation

/// Writes WE's mobile package (`.mpkg`, WE's "Export .mpkg" for its Android app): the scene.pkg
/// layout (`PKGParser`) with the magic `PKGM0014`, unencrypted.
///
/// ```
/// u32 length + "PKGM0014"
/// u32 entry count
/// per entry: u32 length + path (UTF-8), u32 offset, u32 size   (offset from the end of the table)
/// the entries' bytes, back to back, in the table's order
/// ```
///
/// The entries are written sorted by their paths' bytes, as WE's packages list them (its
/// sample has every entry in that order), so a package's bytes depend only on its files. Every
/// number is little-endian; offsets are 32-bit, so a package holds at most 4 GiB of files
/// (WE refuses wallpapers over 4 GB for mobile devices too).
enum MobilePackageWriter {
    static let magic = "PKGM0014"
    /// The largest package: offsets and sizes are 32-bit.
    static let maximumDataSize = UInt64(UInt32.max)

    struct Entry: Equatable {
        enum Source: Equatable {
            case data(Data)
            /// A file copied in as it is, read in chunks (a video can be hundreds of megabytes).
            case file(URL)
        }

        /// Its path in the package, with `/` separators (`materials/foo.tex`).
        var path: String
        var source: Source

        init(path: String, data: Data) {
            self.path = path
            source = .data(data)
        }

        init(path: String, file: URL) {
            self.path = path
            source = .file(file)
        }
    }

    enum Failure: LocalizedError, Equatable {
        case duplicatePath(String)
        case tooLarge(UInt64)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .duplicatePath(let path): return "The package lists \(path) twice."
            case .tooLarge: return String(localized: "Wallpapers larger than 4GB can currently not be transferred to mobile devices.")
            case .unreadable(let path): return "\(path) couldn't be read into the package."
            }
        }
    }

    /// `entries` in the package's order: by their paths' UTF-8 bytes.
    static func ordered(_ entries: [Entry]) -> [Entry] {
        entries.sorted { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
    }

    /// The header and entry table for `entries` (already `ordered`) of `sizes` bytes each.
    static func header(paths: [String], sizes: [UInt64]) throws -> Data {
        var header = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        append(UInt32(magic.utf8.count))
        header.append(contentsOf: Array(magic.utf8))
        append(UInt32(paths.count))
        var offset: UInt64 = 0
        for (path, size) in zip(paths, sizes) {
            append(UInt32(path.utf8.count))
            header.append(contentsOf: Array(path.utf8))
            append(UInt32(offset))
            append(UInt32(size))
            offset += size
        }
        return header
    }

    /// The whole package in memory (tests and small packages).
    static func data(_ entries: [Entry]) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appending(path: "mpkg-\(UUID().uuidString)", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: url) } // Optional: a temporary file.
        try write(entries, to: url)
        return try Data(contentsOf: url)
    }

    /// Writes the package to `url`, replacing it, through a partial file moved into place.
    static func write(_ entries: [Entry], to url: URL, progress: ((Double) -> Void)? = nil) throws {
        let entries = ordered(entries)
        var seen = Set<String>()
        for entry in entries where !seen.insert(entry.path).inserted { throw Failure.duplicatePath(entry.path) }
        let sizes = try entries.map(size)
        let total = sizes.reduce(0, +)
        guard total <= maximumDataSize else { throw Failure.tooLarge(total) }

        let partial = url.deletingLastPathComponent()
            .appending(path: ".partial-\(url.lastPathComponent)", directoryHint: .notDirectory)
        let manager = FileManager.default
        if manager.fileExists(atPath: partial.path(percentEncoded: false)) { try manager.removeItem(at: partial) }
        guard manager.createFile(atPath: partial.path(percentEncoded: false), contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path(percentEncoded: false)])
        }
        do {
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() } // Closing after a failed write only reports that failure again.
            try handle.write(contentsOf: header(paths: entries.map(\.path), sizes: sizes))
            var written: UInt64 = 0
            for (entry, size) in zip(entries, sizes) {
                try Task.checkCancellation()
                switch entry.source {
                case .data(let data):
                    try handle.write(contentsOf: data)
                case .file(let file):
                    try copy(file, size: size, into: handle, path: entry.path)
                }
                written += size
                progress?(total == 0 ? 1 : Double(written) / Double(total))
            }
            try handle.close()
            if manager.fileExists(atPath: url.path(percentEncoded: false)) { try manager.removeItem(at: url) }
            try manager.moveItem(at: partial, to: url)
        } catch {
            try? manager.removeItem(at: partial) // Optional: the partial file of a failed write.
            throw error
        }
    }

    private static func size(_ entry: Entry) throws -> UInt64 {
        switch entry.source {
        case .data(let data):
            return UInt64(data.count)
        case .file(let url):
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
            guard let size = attributes[.size] as? NSNumber else { throw Failure.unreadable(entry.path) }
            return size.uint64Value
        }
    }

    private static func copy(_ file: URL, size: UInt64, into handle: FileHandle, path: String) throws {
        let source = try FileHandle(forReadingFrom: file)
        defer { try? source.close() } // A read-only handle; closing it can't lose data.
        var remaining = size
        let chunk = 8 << 20
        while remaining > 0 {
            let data = try source.read(upToCount: Int(min(UInt64(chunk), remaining))) ?? Data()
            guard !data.isEmpty else { throw Failure.unreadable(path) }
            try handle.write(contentsOf: data)
            remaining -= UInt64(data.count)
        }
    }
}
