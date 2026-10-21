import Foundation

/// The header of a 2D `.tex` file (`TEXHeader`, which has the layout) and where its first image's
/// mipmaps are: what a writer needs to copy or rewrite it (`TEXWriter`). `TEXParser` decodes the
/// pictures.
public struct TEXFileHeader: Equatable {
    public struct Mipmap: Equatable {
        public var width: Int
        public var height: Int
        /// 0 stored as is, 1 LZ4.
        public var compression: UInt32
        public var uncompressedSize: Int
        /// The stored bytes' range in the file.
        public var stored: Range<Int>

        public init(width: Int, height: Int, compression: UInt32, uncompressedSize: Int, stored: Range<Int>) {
            self.width = width
            self.height = height
            self.compression = compression
            self.uncompressedSize = uncompressedSize
            self.stored = stored
        }
    }

    public var format: UInt32
    public var flags: UInt32
    public var textureWidth: Int
    public var textureHeight: Int
    public var imageWidth: Int
    public var imageHeight: Int
    /// The `TEXI` header's last word, kept as it is (WE writes the texture's colour there).
    public var colorWord: UInt32
    /// 1…4, from `TEXB000n`.
    public var containerVersion: Int
    public var imageCount: Int
    /// The FreeImage format of an embedded picture (PNG, JPEG…); -1 for raw pixels.
    public var freeImageFormat: Int32
    public var isVideo: Bool
    /// The texture variants `TEXB0004` declares (`TEXVariants`); with any, the mipmaps aren't
    /// listed, as variant patches follow each one.
    public var variantCount: Int
    public var mipmaps: [Mipmap]
    /// Bytes after the first image's mipmaps (more images, a sprite sheet's frames).
    public var trailingByteCount: Int

    /// The header of `data`; nil when it isn't a `.tex` this reads (a volume is `TEXVolume`'s;
    /// video textures and multi-image files still give their header, without mipmaps past the
    /// first image).
    public init?(_ data: Data) {
        guard var reader = TEXReader(data), !reader.header.isVolume else { return nil }
        let header = reader.header
        format = header.format
        flags = header.flags
        textureWidth = header.textureWidth
        textureHeight = header.textureHeight
        imageWidth = header.imageWidth
        imageHeight = header.imageHeight
        colorWord = header.colorWord
        containerVersion = header.containerVersion
        imageCount = header.imageCount
        freeImageFormat = header.freeImageFormat
        isVideo = header.isVideo
        variantCount = header.variantCount
        mipmaps = []
        trailingByteCount = 0
        guard !isVideo, variantCount == 0, imageCount > 0, let count = reader.word(), count < 64 else { return }
        for _ in 0..<count {
            guard let mipmap = reader.mipmap() else { return nil }
            mipmaps.append(Mipmap(width: mipmap.width, height: mipmap.height, compression: mipmap.compression,
                                  uncompressedSize: mipmap.uncompressedSize, stored: mipmap.stored))
        }
        trailingByteCount = reader.bytes.count - reader.cursor
    }
}
