import Foundation

/// The header of a `.tex` file, through its container's words: the one place it is read and
/// written (`TEXReader` reads on from it, `TEXContainerWriter` writes a file from it).
///
/// ```
/// "TEXV0005\0" "TEXI0001\0"
/// u32 format, flags, texture width, texture height, image width, image height, [depth,] colour
/// "TEXB000n\0"  u32 image count
/// TEXB0003: i32 FreeImage format   TEXB0004: i32 FreeImage format, u32 variant count (`TEXVariants`)
/// per image: u32 mipmap count, per mipmap: u32 width, height, [depth,] [u32 compression, uncompressed size,] stored size, bytes
/// ```
///
/// A volume (TEXI flag 0x40, `TEXVolume`) has a depth word after the image height, and so does
/// each of its mipmaps.
public struct TEXHeader: Equatable {
    /// The TEXI flag of a volume texture, whose header and mipmaps carry a depth word.
    public static let volumeFlag: UInt32 = 0x40

    public var format: UInt32
    public var flags: UInt32
    public var textureWidth: Int
    public var textureHeight: Int
    public var imageWidth: Int
    public var imageHeight: Int
    /// A volume's depth (`volumeFlag`); nil for a 2D texture.
    public var depth: UInt32?
    /// The `TEXI` header's last word, kept as it is (WE writes the texture's colour there).
    public var colorWord: UInt32
    /// 1…4, from `TEXB000n`.
    public var containerVersion: Int
    public var imageCount: Int
    /// The FreeImage format of an embedded picture (PNG, JPEG…); -1 for raw pixels, and before
    /// `TEXB0003`.
    public var freeImageFormat: Int32
    /// The texture variants `TEXB0004` declares (`TEXVariants`); 0 before it.
    public var variantCount: Int

    public init(format: UInt32, flags: UInt32, textureWidth: Int, textureHeight: Int, imageWidth: Int, imageHeight: Int,
                depth: UInt32? = nil, colorWord: UInt32, containerVersion: Int = 4, imageCount: Int = 1,
                freeImageFormat: Int32 = -1, variantCount: Int = 0) {
        self.format = format
        self.flags = flags
        self.textureWidth = textureWidth
        self.textureHeight = textureHeight
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.depth = depth
        self.colorWord = colorWord
        self.containerVersion = containerVersion
        self.imageCount = imageCount
        self.freeImageFormat = freeImageFormat
        self.variantCount = variantCount
    }

    /// Whether the TEXI flags mark a volume.
    public var isVolume: Bool { flags & Self.volumeFlag != 0 }
    /// WE marks a video texture with the TEXI flag, not the FreeImage format (-1 in library video
    /// textures, `TEXFlags.video`).
    public var isVideo: Bool { flags & TEXFlags.video.rawValue != 0 }
    /// A mipmap stores its compression and uncompressed size from `TEXB0002` on.
    public var mipmapsHaveCompression: Bool { containerVersion >= 2 }

    /// The `TEXV`/`TEXI` part's length: where `TEXB000n` starts.
    public var containerOffset: Int { 18 + (depth == nil ? 7 : 8) * 4 }
    /// The header's length: where the first image's mipmap count (or, with variants, the first
    /// option record) starts.
    public var end: Int { containerOffset + 9 + 4 + (containerVersion >= 3 ? 4 : 0) + (containerVersion >= 4 ? 4 : 0) }

    /// The header of `bytes`; nil when they don't start with a `.tex` header (tags, words and a
    /// `TEXB0001`…`TEXB0004` container).
    public init?<Bytes: RandomAccessCollection>(_ bytes: Bytes) where Bytes.Element == UInt8, Bytes.Index == Int {
        var reader = TEXByteCursor(bytes: bytes)
        guard reader.string() == "TEXV0005", reader.string() == "TEXI0001",
              let format = reader.word(), let flags = reader.word(), let textureWidth = reader.word(),
              let textureHeight = reader.word(), let imageWidth = reader.word(), let imageHeight = reader.word() else { return nil }
        var depth: UInt32?
        if flags & Self.volumeFlag != 0 {
            guard let value = reader.word() else { return nil }
            depth = value
        }
        guard let colorWord = reader.word(), let container = reader.string(), container.hasPrefix("TEXB"),
              let version = Int(container.dropFirst(4)), (1...4).contains(version), let imageCount = reader.word() else { return nil }
        var freeImageFormat: Int32 = -1
        if version >= 3 {
            guard let value = reader.word() else { return nil }
            freeImageFormat = Int32(bitPattern: value)
        }
        var variantCount = 0
        if version >= 4 {
            guard let value = reader.word() else { return nil }
            variantCount = Int(value)
        }
        self.init(format: format, flags: flags, textureWidth: Int(textureWidth), textureHeight: Int(textureHeight),
                  imageWidth: Int(imageWidth), imageHeight: Int(imageHeight), depth: depth, colorWord: colorWord,
                  containerVersion: version, imageCount: Int(imageCount), freeImageFormat: freeImageFormat,
                  variantCount: variantCount)
        guard reader.offset == end else { return nil }
    }

    /// The header's bytes, through the container's words.
    public var data: Data {
        var data = Data()
        func word(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("TEXV0005".utf8) + [0])
        data.append(contentsOf: Array("TEXI0001".utf8) + [0])
        for value in [format, flags, UInt32(textureWidth), UInt32(textureHeight), UInt32(imageWidth), UInt32(imageHeight)] {
            word(value)
        }
        if let depth { word(depth) }
        word(colorWord)
        data.append(contentsOf: Array("TEXB000\(containerVersion)".utf8) + [0])
        word(UInt32(imageCount))
        if containerVersion >= 3 { word(UInt32(bitPattern: freeImageFormat)) }
        if containerVersion >= 4 { word(UInt32(variantCount)) }
        return data
    }

    /// The `index`th 32-bit word after the `TEXI0001` tag of a `.tex` file (`TEXV0005\0TEXI0001\0`,
    /// format, flags…), from the file's first 64 bytes, whatever follows; nil when there is no
    /// `TEXI` tag with the word after it.
    public static func texiWord(_ index: Int, in data: Data) -> UInt32? {
        let bytes = [UInt8](data.prefix(64))
        guard let texi = (0..<max(bytes.count - 4, 0)).first(where: { bytes[$0..<$0 + 4] == [0x54, 0x45, 0x58, 0x49] }),
              let end = bytes[texi...].firstIndex(of: 0) else { return nil }
        let offset = end + 1 + 4 * index
        guard offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

/// Little-endian words and NUL-terminated strings from the start of some bytes.
struct TEXByteCursor<Bytes: RandomAccessCollection> where Bytes.Element == UInt8, Bytes.Index == Int {
    let bytes: Bytes
    var offset = 0

    mutating func word() -> UInt32? {
        let at = bytes.startIndex + offset
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        defer { offset += 4 }
        return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    mutating func string() -> String? {
        let start = bytes.startIndex + offset
        guard offset < bytes.count, let end = bytes[start...].firstIndex(of: 0) else { return nil }
        defer { offset = end - bytes.startIndex + 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }
}
