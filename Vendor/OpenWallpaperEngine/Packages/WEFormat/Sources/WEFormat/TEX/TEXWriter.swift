import Foundation

/// Writes a single-image `.tex` (`TEXHeader` has the layout), raw texels unless `freeImageFormat` says the mipmaps are pictures: in
/// WE's newest container, `TEXB0004` with no video, as WE's mobile export writes the textures it
/// converts, or in `TEXB0003`, as WE's editor writes a painted effect mask (`effectMask`).
public enum TEXWriter {
    /// The `TEXB` container: `TEXB0004` has a video word after the FreeImage format.
    public enum Container: Equatable {
        case b0003, b0004
    }

    public struct Mipmap: Equatable {
        public var width: Int
        public var height: Int
        /// 0 stored as is, 1 LZ4.
        public var compression: UInt32
        public var uncompressedSize: Int
        public var stored: Data

        public init(width: Int, height: Int, compression: UInt32, uncompressedSize: Int, stored: Data) {
            self.width = width
            self.height = height
            self.compression = compression
            self.uncompressedSize = uncompressedSize
            self.stored = stored
        }
    }

    public struct Texture: Equatable {
        public var format: UInt32
        public var flags: UInt32
        public var textureWidth: Int
        public var textureHeight: Int
        public var imageWidth: Int
        public var imageHeight: Int
        public var colorWord: UInt32
        /// -1 for raw texels, else the FreeImage format of the pictures the mipmaps are (13, PNG).
        public var freeImageFormat: Int32
        public var mipmaps: [Mipmap]

        public init(format: UInt32, flags: UInt32, textureWidth: Int, textureHeight: Int, imageWidth: Int, imageHeight: Int, colorWord: UInt32, freeImageFormat: Int32 = -1, mipmaps: [Mipmap]) {
            self.format = format
            self.flags = flags
            self.textureWidth = textureWidth
            self.textureHeight = textureHeight
            self.imageWidth = imageWidth
            self.imageHeight = imageHeight
            self.colorWord = colorWord
            self.freeImageFormat = freeImageFormat
            self.mipmaps = mipmaps
        }
    }

    public static func data(_ texture: Texture, container: Container = .b0004) -> Data {
        var writer = TEXContainerWriter(header: TEXHeader(
            format: texture.format, flags: texture.flags, textureWidth: texture.textureWidth,
            textureHeight: texture.textureHeight, imageWidth: texture.imageWidth, imageHeight: texture.imageHeight,
            colorWord: texture.colorWord, containerVersion: container == .b0004 ? 4 : 3,
            freeImageFormat: texture.freeImageFormat))
        writer.word(UInt32(texture.mipmaps.count))
        for mipmap in texture.mipmaps {
            writer.mipmap(width: mipmap.width, height: mipmap.height, compression: mipmap.compression,
                          uncompressedSize: mipmap.uncompressedSize, stored: mipmap.stored)
        }
        return writer.data
    }

    /// An effect mask as WE's editor writes one (`materials/masks/<effect>_mask_<hash>.tex` in
    /// Workshop scenes): one 8-bit channel (`FORMAT_R8`, format 9), clamped UVs, the texture the
    /// image's own size (no power-of-two padding), one LZ4 mipmap in a `TEXB0003` container.
    /// `pixels`: `width` × `height` grey values, rows top to bottom.
    public static func effectMask(_ pixels: [UInt8], width: Int, height: Int) -> Data {
        precondition(pixels.count == width * height, "a mask has one byte per pixel")
        return data(Texture(format: UInt32(TEXImageFormat.r8.rawValue), flags: TEXFlags.clampUVs.rawValue,
                            textureWidth: width, textureHeight: height, imageWidth: width, imageHeight: height,
                            colorWord: 0xFF00_0000,
                            mipmaps: [Mipmap(width: width, height: height, compression: 1, uncompressedSize: pixels.count,
                                             stored: Data(LZ4BlockEncoder.compress(pixels)))]),
                    container: .b0003)
    }
}
