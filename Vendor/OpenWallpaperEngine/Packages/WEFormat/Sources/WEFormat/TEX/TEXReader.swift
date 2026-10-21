import Foundation

/// Reads a `.tex` on from its header (`TEXHeader` has the layout): the words, strings and mipmap
/// records after it. It only walks the bytes; decoding a mipmap is the caller's (the app's
/// `TEXParser`).
public struct TEXReader {
    /// One mipmap's record: its sizes and where its stored bytes are.
    public struct Mipmap: Equatable {
        public var width: Int
        public var height: Int
        /// A volume's slice count (`TEXHeader.volumeFlag`).
        public var depth: UInt32?
        /// 0 stored as is, 1 LZ4; 0 before `TEXB0002`.
        public var compression: UInt32
        /// 0 before `TEXB0002`.
        public var uncompressedSize: Int
        /// The stored bytes' range in `bytes`.
        public var stored: Range<Int>
    }

    public let bytes: [UInt8]
    public let header: TEXHeader
    /// Where the next read starts; `header.end` at first.
    public var cursor: Int

    /// nil when `data` doesn't start with a `.tex` header.
    public init?(_ data: Data) {
        self.init(bytes: [UInt8](data))
    }

    public init?(bytes: [UInt8]) {
        guard let header = TEXHeader(bytes) else { return nil }
        self.bytes = bytes
        self.header = header
        cursor = header.end
    }

    /// The next little-endian u32.
    public mutating func word() -> UInt32? {
        guard cursor >= 0, cursor + 4 <= bytes.count else { return nil }
        defer { cursor += 4 }
        return UInt32(bytes[cursor]) | UInt32(bytes[cursor + 1]) << 8 | UInt32(bytes[cursor + 2]) << 16
            | UInt32(bytes[cursor + 3]) << 24
    }

    /// The next NUL-terminated string.
    public mutating func string() -> String? {
        guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
        defer { cursor = end + 1 }
        return String(decoding: bytes[cursor..<end], as: UTF8.self)
    }

    /// `count` bytes from the cursor, which moves past them.
    public mutating func range(_ count: Int) -> Range<Int>? {
        guard count >= 0, count <= bytes.count - cursor else { return nil }
        defer { cursor += count }
        return cursor..<(cursor + count)
    }

    /// The next mipmap record (width, height, a volume's depth, from `TEXB0002` the compression and
    /// uncompressed size, the stored size), the cursor past its stored bytes; nil when the record or
    /// its bytes run past the end. `accept` sees the width and height first, and a size it refuses
    /// ends the read there.
    public mutating func mipmap(accept: (Int, Int) -> Bool = { _, _ in true }) -> Mipmap? {
        guard let width = word(), let height = word(), accept(Int(width), Int(height)) else { return nil }
        var depth: UInt32?
        if header.isVolume {
            guard let value = word() else { return nil }
            depth = value
        }
        var compression: UInt32 = 0, uncompressed = 0
        if header.mipmapsHaveCompression {
            guard let value = word(), let size = word() else { return nil }
            compression = value
            uncompressed = Int(size)
        }
        guard let size = word(), let stored = range(Int(size)) else { return nil }
        return Mipmap(width: Int(width), height: Int(height), depth: depth, compression: compression,
                      uncompressedSize: uncompressed, stored: stored)
    }
}

/// Writes a `.tex`: a header (`TEXHeader.data`), then each image's mipmap count and mipmap
/// records, with whatever a caller adds between them (texture variants' patches).
public struct TEXContainerWriter {
    public private(set) var data: Data

    public init(header: TEXHeader) {
        data = header.data
    }

    public mutating func word(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// `text` and its NUL.
    public mutating func string(_ text: String) {
        data.append(contentsOf: Array(text.utf8) + [0])
    }

    public mutating func append<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        data.append(contentsOf: bytes)
    }

    /// One mipmap record and its stored bytes: width, height, a volume's `depth`, the compression
    /// and uncompressed size (written from `TEXB0002` on, as every writer here writes), the stored
    /// size.
    public mutating func mipmap<Bytes: Collection>(width: Int, height: Int, depth: UInt32? = nil, compression: UInt32,
                                                   uncompressedSize: Int, stored: Bytes) where Bytes.Element == UInt8 {
        word(UInt32(width))
        word(UInt32(height))
        if let depth { word(depth) }
        word(compression)
        word(UInt32(uncompressedSize))
        word(UInt32(stored.count))
        data.append(contentsOf: stored)
    }
}
