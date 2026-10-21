//
//  TEXParser.swift
//  Open Wallpaper Engine
//
//  Parse Wallpaper Engine TEXV texture container files.
//  Structure: TEXV0005 > TEXI (metadata) > TEXB (image data).
//

import Cocoa
import Compression
import Foundation
import AVFoundation

struct TEXAnimatedImages {
    let images: [NSImage]
    let frames: [TEXAnimationFrame]
}

struct TEXAnimationFrame {
    let imageIndex: Int
    let duration: Float
    let x: Float
    let y: Float
    let width: Float
    let widthY: Float
    let heightX: Float
    let height: Float
}

struct TEXCompressedTexture {
    let format: UInt32
    /// Allocated (block/power-of-two padded) size of the stored mipmap.
    let width: Int
    let height: Int
    let data: [UInt8]
    /// The image's own size inside the allocation (the header's image width/height).
    var contentWidth: Int
    var contentHeight: Int
    /// The stored mipmaps after `data`'s, each half the one before (as Metal lays out a mipmapped
    /// texture), uploaded with it.
    var mipmaps: [Data] = []
    /// Every level, mapped from a prepared blob (`TexturePreparation`), in place of `data` and
    /// `mipmaps`.
    var storedLevels: [Data]? = nil
    /// The prepared blob's key, which identical textures share (one upload serves them all).
    var sourceKey: String? = nil
    /// The layer analysis's class and opacity, recorded when the texture was prepared.
    var contentClass: SceneLayerContentClass? = nil
    var opaque: Bool? = nil

    /// The `.tex` format number a prepared BC7 texture reports.
    static let bc7Format: UInt32 = 12

    /// Bytes per 4×4 block of a block-compressed `.tex` format (DXT1 8, the others 16).
    static func bytesPerBlock(format: UInt32) -> Int { format == 7 ? 8 : 16 }

    /// Every level to upload: `storedLevels`, else `data` followed by `mipmaps`.
    var levels: [Data] { storedLevels ?? ([Data(data)] + mipmaps) }
}

class TEXParser {
    private let data: Data

    /// Callers try several extract* methods on the same parser, so materialise the byte view once
    /// rather than copying the whole file per attempt.
    private lazy var bytes: [UInt8] = [UInt8](data)

    /// A texture with variants (`TEXVariants`) reads as its base: the variants a scene's user
    /// properties choose are composed in before (`UserPropertyBindingTable.resolvedData`).
    init(data: Data) {
        self.data = TEXVariants.declares(in: data) ? TEXVariantResolver.resolve(data, enabled: [:]) ?? data : data
    }

    /// The largest mipmap side read (Metal's texture limit).
    static let maxSide = 16_384
    /// The largest buffer an LZ4-compressed mipmap decodes into.
    static let maxDecompressedSize = 512 << 20

    static func isValidSize(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maxSide && height <= maxSide
    }

    /// `width × height × bytesPerPixel`, or nil when it overflows.
    static func byteCount(width: Int, height: Int, bytesPerPixel: Int) -> Int? {
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow else { return nil }
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: bytesPerPixel)
        return bytes.overflow ? nil : bytes.partialValue
    }

    /// The bytes of a block-compressed mipmap (4×4 blocks, rounded up), or nil when it overflows.
    static func blockByteCount(width: Int, height: Int, format: UInt32) -> Int? {
        guard width >= 0, height >= 0 else { return nil }
        return byteCount(width: (width + 3) / 4, height: (height + 3) / 4,
                         bytesPerPixel: TEXCompressedTexture.bytesPerBlock(format: format))
    }

    /// The most bytes a mipmap of `format` at `width × height` holds; nil when the format's size
    /// doesn't follow from its dimensions (format 0 also carries image and video files).
    static func expectedMipmapSize(format: UInt32, width: Int, height: Int) -> Int? {
        switch format {
        case 4, 6, 7, 12: return blockByteCount(width: width, height: height, format: format)
        case 9: return byteCount(width: width, height: height, bytesPerPixel: 1)
        case 2, 8, 11: return byteCount(width: width, height: height, bytesPerPixel: 2)
        case 1: return byteCount(width: width, height: height, bytesPerPixel: 3)
        case 10, 13: return byteCount(width: width, height: height, bytesPerPixel: 4)
        case 15: return byteCount(width: width, height: height, bytesPerPixel: 6)
        case 14: return byteCount(width: width, height: height, bytesPerPixel: 8)
        default: return nil
        }
    }

    /// The largest size an LZ4 mipmap may declare: its expected size, what `compressedSize` bytes
    /// can expand to (LZ4 at most 255×), and `maxDecompressedSize`.
    static func lz4OutputLimit(compressedSize: Int, format: UInt32, width: Int, height: Int) -> Int {
        let expansion = compressedSize.multipliedReportingOverflow(by: 255)
        var limit = min(maxDecompressedSize, expansion.overflow ? Int.max : expansion.partialValue)
        if let expected = expectedMipmapSize(format: format, width: width, height: height) {
            limit = min(limit, expected)
        }
        return limit
    }

    /// `reduction` is WE's texture reduction (`TextureReduction`): with 2, an image stored with more
    /// than one mipmap loads from its second, as WE's loader skips the first (`wallpaper64.exe`
    /// 0x14015d3fd); the frame rects, in the first mipmap's pixels, scale with it.
    func extractAnimatedImages(reduction: Int = 1) -> TEXAnimatedImages? {
        ThreadGuards.assertBackground("TEXParser.extractAnimatedImages")
        guard var reader = containerReader(), reader.header.imageCount > 0, reader.header.variantCount == 0 else { return nil }
        let format = reader.header.format, imageWidth = reader.header.imageWidth, imageHeight = reader.header.imageHeight
        let imageCount = reader.header.imageCount

        var imagePayloads: [(stored: [UInt8], compression: UInt32, uncompressedSize: Int, width: Int, height: Int)] = []
        // The loaded mipmap's size over the first's: frame rects are in the first's pixels.
        var frameScale = SIMD2<Float>(1, 1)
        for _ in 0..<imageCount {
            guard let mipmapCount = reader.word(), mipmapCount > 0 else { return nil }
            let loaded = TextureReduction.loadedMipmap(reduction: reduction, mipmapCount: Int(mipmapCount))
            var firstPayload: (stored: [UInt8], compression: UInt32, uncompressedSize: Int, width: Int, height: Int)?
            var fullSize = SIMD2<Float>(1, 1)
            for level in 0..<Int(mipmapCount) {
                guard let mipmap = reader.mipmap(accept: Self.isValidSize) else { return nil }
                let width = mipmap.width, height = mipmap.height
                if level == 0 { fullSize = SIMD2(Float(max(width, 1)), Float(max(height, 1))) }
                guard level == loaded else { continue }
                firstPayload = (Array(bytes[mipmap.stored]), mipmap.compression, mipmap.uncompressedSize, width, height)
                frameScale = SIMD2(Float(width), Float(height)) / fullSize
            }
            guard let firstPayload else { return nil }
            imagePayloads.append(firstPayload)
        }

        var cursor = reader.cursor
        guard let sheet = TEXSpriteFrames.parse(bytes, cursor: &cursor), !sheet.isEmpty else { return nil }
        let images = imagePayloads.compactMap { item -> NSImage? in
            let payload = item.compression == 0 ? item.stored
                : item.compression == 1 ? decompressLZ4(item.stored, uncompressedSize: item.uncompressedSize,
                                                        format: format, width: item.width, height: item.height) : []
            if format == 4 || format == 6 || format == 7 {
                return decodeDXT(payload, format: format, width: item.width, height: item.height,
                                 visibleWidth: min(Int(imageWidth), item.width), visibleHeight: min(Int(imageHeight), item.height))
            }
            if let image = rawChannelImage(payload, format: format, width: item.width, height: item.height,
                                           visibleWidth: item.width, visibleHeight: item.height) {
                return image
            }
            // Spritesheet atlases must keep their full padded dimensions; TEXS frame rects are defined in that space.
            return NSImage(data: Data(payload))
                ?? posterImage(fromVideoData: Data(payload))
                ?? rawRGBAImage(payload, width: item.width, height: item.height,
                                visibleWidth: item.width, visibleHeight: item.height)
        }
        guard images.count == imagePayloads.count else { return nil }
        // Every frame stays, 0 s ones included (WE shows those for one engine frame). A frame
        // that names a missing atlas or has no area can't be drawn; it is dropped, loudly.
        var frames: [TEXAnimationFrame] = []
        for frame in sheet {
            let imageIndex = images.count == 1 ? 0 : frame.imageIndex
            guard imageIndex >= 0, imageIndex < images.count, frame.duration.isFinite,
                  frame.width > 0, frame.height > 0 else { continue }
            frames.append(TEXAnimationFrame(imageIndex: imageIndex, duration: frame.duration,
                                            x: frame.x * frameScale.x, y: frame.y * frameScale.y,
                                            width: frame.width * frameScale.x, widthY: frame.widthY * frameScale.y,
                                            heightX: frame.heightX * frameScale.x, height: frame.height * frameScale.y))
        }
        if frames.count != sheet.count {
            OWELog.error(.texture, "Animated TEX: dropped \(sheet.count - frames.count) of \(sheet.count) TEXS frames "
                         + "(missing atlas, no area or a non-finite frame time)")
        }
        return frames.isEmpty ? nil : TEXAnimatedImages(images: images, frames: frames)
    }

    /// `reduction`: see `extractAnimatedImages(reduction:)`.
    func extractCompressedTexture(reduction: Int = 1) -> TEXCompressedTexture? {
        ThreadGuards.assertBackground("TEXParser.extractCompressedTexture")
        guard var reader = containerReader(), [UInt32(4), 6, 7, 12].contains(reader.header.format),
              reader.header.imageCount > 0, reader.header.variantCount == 0 else { return nil }
        let format = reader.header.format, imageWidth = reader.header.imageWidth, imageHeight = reader.header.imageHeight

        guard let mipmapCount = reader.word(), mipmapCount > 0 else {
            return nil
        }
        let loaded = TextureReduction.loadedMipmap(reduction: reduction, mipmapCount: Int(mipmapCount))
        guard let mipmap = readMipmap(at: loaded, reader: &reader) else { return nil }
        let width = mipmap.width, height = mipmap.height
        let compression = mipmap.compression, uncompressedSize = mipmap.uncompressedSize
        let storedData = mipmap.stored
        let mipmapData: [UInt8]
        if compression == 0 {
            mipmapData = storedData
        } else if compression == 1, uncompressedSize > 0 {
            mipmapData = decompressLZ4(storedData, uncompressedSize: uncompressedSize,
                                       format: format, width: width, height: height)
        } else {
            return nil
        }

        let textureWidth = Int(width)
        let textureHeight = Int(height)
        guard Self.isValidSize(width: textureWidth, height: textureHeight),
              let expectedSize = Self.blockByteCount(width: textureWidth, height: textureHeight, format: format),
              mipmapData.count >= expectedSize else { return nil }
        // A zero or oversized header size means "no crop": the whole allocation is content. A
        // later mipmap holds the image at its own scale (halved per level).
        let contentWidth = imageWidth > 0 ? min(TextureReduction.mipmapSide(Int(imageWidth), level: loaded), textureWidth) : textureWidth
        let contentHeight = imageHeight > 0 ? min(TextureReduction.mipmapSide(Int(imageHeight), level: loaded), textureHeight) : textureHeight
        var texture = TEXCompressedTexture(format: format, width: textureWidth, height: textureHeight, data: mipmapData,
                                           contentWidth: contentWidth, contentHeight: contentHeight)
        texture.mipmaps = followingMipmaps(count: Int(mipmapCount) - loaded - 1, format: format, width: textureWidth,
                                           height: textureHeight, reader: &reader)
        return texture
    }

    /// The block-compressed mipmaps stored after the loaded one, as WE uploads them all. Stops at
    /// the first one that isn't half the size of the one before or can't be read, since a mipmap
    /// chain can't skip a level.
    private func followingMipmaps(count: Int, format: UInt32, width: Int, height: Int,
                                  reader: inout TEXReader) -> [Data] {
        var levels: [Data] = []
        var expected = (width: width, height: height)
        for _ in 0..<max(0, count) {
            guard let mipmap = readMipmap(at: 0, reader: &reader) else { break }
            expected = (max(1, expected.width / 2), max(1, expected.height / 2))
            guard mipmap.width == expected.width, mipmap.height == expected.height else { break }
            let bytes: [UInt8]
            if mipmap.compression == 0 {
                bytes = mipmap.stored
            } else if mipmap.compression == 1, mipmap.uncompressedSize > 0 {
                bytes = decompressLZ4(mipmap.stored, uncompressedSize: mipmap.uncompressedSize,
                                      format: format, width: mipmap.width, height: mipmap.height)
            } else {
                break
            }
            guard let size = Self.blockByteCount(width: mipmap.width, height: mipmap.height, format: format),
                  bytes.count >= size else { break }
            levels.append(Data(bytes[0..<size]))
            if mipmap.width == 1, mipmap.height == 1 { break }
        }
        return levels
    }

    /// Whether the first image is stored raw (no FreeImage container) inside an allocation larger
    /// than the image: it is uploaded padded (`TEXRawImageRep.makeAllocationTexture`), so it isn't
    /// replaced by a cropped prepared texture (`TexturePreparation`).
    func isPaddedRawImage() -> Bool {
        guard let header = containerReader()?.header, ![UInt32(4), 6, 7].contains(header.format) else { return false }
        let padded = header.imageWidth > 0 && header.imageHeight > 0
            && (header.textureWidth > header.imageWidth || header.textureHeight > header.imageHeight)
        // From TEXB0003, FreeImage format -1: the mipmaps are raw texels, not an embedded PNG or JPEG.
        return padded && (header.containerVersion < 3 || header.freeImageFormat == -1)
    }

    /// How many mipmaps the first image stores; nil for a file that isn't a TEX container.
    func firstImageMipmapCount() -> Int? {
        guard var reader = containerReader() else { return nil }
        return reader.word().map(Int.init)
    }

    /// Extract the image from this TEX container. `reduction`: see `extractAnimatedImages(reduction:)`.
    func extractImage(reduction: Int = 1) -> NSImage? {
        if let image = extractContainerImage(reduction: reduction) {
            return image
        }
        OWELog.error(.texture, "Unsupported or malformed TEX container (\(data.count) bytes); refusing embedded thumbnail fallback")
        return nil
    }

    // MARK: - Private

    /// The MP4 file a video texture stores as its image (WE plays these as `IVideoTexture`), or nil
    /// when the container holds a picture.
    func extractVideoData() -> Data? {
        guard let payload = firstImagePayload(reduction: 1) else { return nil }
        let data = payload.data
        guard data.count > 12, data[4..<8].elementsEqual("ftyp".utf8) else { return nil }
        return Data(data)
    }

    private struct ImagePayload {
        let format: UInt32
        let data: [UInt8]
        let width: Int, height: Int
        let visibleWidth: Int, visibleHeight: Int
    }

    private func extractContainerImage(reduction: Int) -> NSImage? {
        ThreadGuards.assertBackground("TEXParser.extractContainerImage")
        guard let payload = firstImagePayload(reduction: reduction) else { return nil }
        let format = payload.format, mipmapData = payload.data
        let width = payload.width, height = payload.height
        let visibleWidth = payload.visibleWidth, visibleHeight = payload.visibleHeight
        switch format {
        case 4, 6, 7:
            return decodeDXT(mipmapData, format: format, width: width, height: height,
                             visibleWidth: visibleWidth, visibleHeight: visibleHeight)
        default:
            if let image = rawChannelImage(mipmapData, format: format, width: width, height: height,
                                           visibleWidth: visibleWidth, visibleHeight: visibleHeight) {
                return image
            }
            return NSImage(data: Data(mipmapData))
                ?? posterImage(fromVideoData: Data(mipmapData))
                ?? rawRGBAImage(mipmapData, width: width, height: height,
                                visibleWidth: visibleWidth, visibleHeight: visibleHeight)
        }
    }

    /// The first image's loaded mipmap, decompressed, with its sizes.
    private func firstImagePayload(reduction: Int) -> ImagePayload? {
        // TEXB0004's variants were composed in by `init` (a video's MP4 is its one mipmap,
        // `extractVideoData`).
        guard var reader = containerReader(), reader.header.imageCount > 0, reader.header.variantCount == 0 else { return nil }
        let format = reader.header.format, imageWidth = reader.header.imageWidth, imageHeight = reader.header.imageHeight

        guard let mipmapCount = reader.word(), mipmapCount > 0 else {
            return nil
        }
        let loaded = TextureReduction.loadedMipmap(reduction: reduction, mipmapCount: Int(mipmapCount))
        guard let mipmap = readMipmap(at: loaded, reader: &reader) else { return nil }
        let width = mipmap.width, height = mipmap.height
        guard Self.isValidSize(width: width, height: height) else { return nil }
        let compression = mipmap.compression, uncompressedSize = mipmap.uncompressedSize
        let storedData = mipmap.stored
        // The image's own size at the loaded mipmap's scale.
        let visibleImageWidth = TextureReduction.mipmapSide(Int(imageWidth), level: loaded)
        let visibleImageHeight = TextureReduction.mipmapSide(Int(imageHeight), level: loaded)
        let mipmapData: [UInt8]
        if compression == 0 {
            mipmapData = storedData
        } else if compression == 1, uncompressedSize > 0 {
            mipmapData = decompressLZ4(storedData, uncompressedSize: uncompressedSize,
                                       format: format, width: width, height: height)
        } else {
            return nil
        }

        return ImagePayload(format: format, data: mipmapData, width: width, height: height,
                            visibleWidth: min(visibleImageWidth, width), visibleHeight: min(visibleImageHeight, height))
    }

    /// Decodes RG88 (two-channel) and R8 (single-channel) raw mipmaps; nil for any other format.
    private func rawChannelImage(_ bytes: [UInt8], format: UInt32, width: Int, height: Int,
                                 visibleWidth: Int, visibleHeight: Int) -> NSImage? {
        guard Self.isValidSize(width: width, height: height), visibleWidth <= width, visibleHeight <= height,
              let pixelCount = Self.byteCount(width: width, height: height, bytesPerPixel: 1),
              let rgbaCount = Self.byteCount(width: width, height: height, bytesPerPixel: 4) else { return nil }
        /// Whether `bytes` holds every pixel at `bytesPerPixel`.
        func holds(_ bytesPerPixel: Int) -> Bool {
            Self.byteCount(width: width, height: height, bytesPerPixel: bytesPerPixel).map { bytes.count >= $0 } ?? false
        }
        switch format {
        case 1:
            guard holds(3) else { return nil }
            var rgba = [UInt8](repeating: 255, count: rgbaCount)
            for pixel in 0..<pixelCount {
                rgba[pixel * 4] = bytes[pixel * 3]
                rgba[pixel * 4 + 1] = bytes[pixel * 3 + 1]
                rgba[pixel * 4 + 2] = bytes[pixel * 3 + 2]
            }
            return rawRGBAImage(rgba, width: width, height: height,
                                visibleWidth: visibleWidth, visibleHeight: visibleHeight)
        case 2:
            guard holds(2) else { return nil }
            var rgba = [UInt8](repeating: 255, count: rgbaCount)
            for pixel in 0..<pixelCount {
                let offset = pixel * 2
                let packed = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                rgba[pixel * 4] = UInt8((packed >> 11) * 255 / 31)
                rgba[pixel * 4 + 1] = UInt8(((packed >> 5) & 63) * 255 / 63)
                rgba[pixel * 4 + 2] = UInt8((packed & 31) * 255 / 31)
            }
            return rawRGBAImage(rgba, width: width, height: height,
                                visibleWidth: visibleWidth, visibleHeight: visibleHeight)
        case 8:
            guard holds(2) else { return nil }
            // As a two-channel texture samples in WE: (r, g, 0, 1), which an `.rg8Unorm` texture
            // returns. Shaders that read RG88 as luminance and alpha convert it by `TEX<n>FORMAT`
            // (`ConvertTexture0Format`'s `.rrrg`); normal maps (`DecompressNormal`) and flow maps
            // read `.rg`.
            return TEXRawImageRep.image(bytes: bytes, channels: .rg, rowPixels: width,
                                        width: visibleWidth, height: visibleHeight)
        case 9:
            guard width > 0, height > 0, visibleWidth > 0, visibleHeight > 0,
                  holds(1) else { return nil }
            // As a one-channel texture samples in WE: (r, 0, 0, 1), which an `.r8Unorm` texture
            // returns. Opacity masks and depth maps read `.r`; particle shaders turn an R8 albedo
            // into (1, 1, 1, r) by `TEX<n>FORMAT` (`ConvertTexture0Format`).
            return TEXRawImageRep.image(bytes: bytes, channels: .r, rowPixels: width,
                                        width: visibleWidth, height: visibleHeight)
        case 10:
            guard holds(4) else { return nil }
            var rgba = [UInt8](repeating: 255, count: rgbaCount)
            for pixel in 0..<pixelCount {
                let offset = pixel * 4
                let red = Self.halfToFloat(UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
                let green = Self.halfToFloat(UInt16(bytes[offset + 2]) | UInt16(bytes[offset + 3]) << 8)
                rgba[pixel * 4] = Self.floatToByte(red)
                rgba[pixel * 4 + 1] = Self.floatToByte(green)
                rgba[pixel * 4 + 2] = 0
            }
            return rawRGBAImage(rgba, width: width, height: height,
                                visibleWidth: visibleWidth, visibleHeight: visibleHeight)
        case 11:
            guard holds(2) else { return nil }
            var rgba = [UInt8](repeating: 255, count: rgbaCount)
            for pixel in 0..<pixelCount {
                let offset = pixel * 2
                let value = Self.halfToFloat(UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
                let channel = Self.floatToByte(value)
                rgba[pixel * 4] = channel; rgba[pixel * 4 + 1] = channel; rgba[pixel * 4 + 2] = channel
            }
            return rawRGBAImage(rgba, width: width, height: height,
                                visibleWidth: visibleWidth, visibleHeight: visibleHeight)
        case 13:
            guard holds(4) else { return nil }
            var rgba = [UInt8](repeating: 255, count: rgbaCount)
            for pixel in 0..<pixelCount {
                let offset = pixel * 4
                let packed = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                    | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
                rgba[pixel * 4] = UInt8((packed & 1023) * 255 / 1023)
                rgba[pixel * 4 + 1] = UInt8(((packed >> 10) & 1023) * 255 / 1023)
                rgba[pixel * 4 + 2] = UInt8(((packed >> 20) & 1023) * 255 / 1023)
                rgba[pixel * 4 + 3] = UInt8(((packed >> 30) & 3) * 255 / 3)
            }
            return rawRGBAImage(rgba, width: width, height: height,
                                visibleWidth: visibleWidth, visibleHeight: visibleHeight)
        case 14:
            guard holds(8) else { return nil }
            return float16RGBAImage(bytes, width: width, height: height,
                                         visibleWidth: visibleWidth, visibleHeight: visibleHeight)
        case 15:
            guard holds(6) else { return nil }
            var rgba = [UInt8](repeating: 255, count: rgbaCount)
            for pixel in 0..<pixelCount {
                let offset = pixel * 6
                for component in 0..<3 {
                    let value = Self.halfToFloat(UInt16(bytes[offset + component * 2])
                        | UInt16(bytes[offset + component * 2 + 1]) << 8)
                    rgba[pixel * 4 + component] = Self.floatToByte(value)
                }
            }
            return rawRGBAImage(rgba, width: width, height: height,
                                visibleWidth: visibleWidth, visibleHeight: visibleHeight)
        default:
            return nil
        }
    }

    private static func floatToByte(_ value: Float) -> UInt8 {
        UInt8(Int(saturating: (value.isFinite ? value : 0) * 255, in: 0...255))
    }

    private func float16RGBAImage(_ bytes: [UInt8], width: Int, height: Int,
                                         visibleWidth: Int, visibleHeight: Int) -> NSImage? {
        guard let pixelCount = Self.byteCount(width: width, height: height, bytesPerPixel: 1),
              let rgbaCount = Self.byteCount(width: width, height: height, bytesPerPixel: 4),
              let needed = Self.byteCount(width: width, height: height, bytesPerPixel: 8),
              bytes.count >= needed else { return nil }
        var rgba = [UInt8](repeating: 255, count: rgbaCount)
        for pixel in 0..<pixelCount {
            let offset = pixel * 8
            for component in 0..<4 {
                let value = Self.halfToFloat(UInt16(bytes[offset + component * 2])
                    | UInt16(bytes[offset + component * 2 + 1]) << 8)
                    rgba[pixel * 4 + component] = Self.floatToByte(value)
            }
        }
        return rawRGBAImage(rgba, width: width, height: height,
                            visibleWidth: visibleWidth, visibleHeight: visibleHeight)
    }

    private static func halfToFloat(_ bits: UInt16) -> Float {
        let sign = (bits & 0x8000) == 0 ? Float(1) : -Float(1)
        let exponent = Int((bits >> 10) & 0x1f)
        let fraction = Float(bits & 0x03ff) / 1024
        if exponent == 0 { return sign * fraction * powf(2, -14) }
        if exponent == 31 { return fraction == 0 ? sign * Float.infinity : Float.nan }
        return sign * (1 + fraction) * powf(2, Float(exponent - 15))
    }

    /// Decodes an uncompressed RGBA8888 mipmap (TEXI format 0); these carry no image container header.
    private func rawRGBAImage(_ bytes: [UInt8], width: Int, height: Int,
                              visibleWidth: Int, visibleHeight: Int) -> NSImage? {
        guard Self.isValidSize(width: width, height: height), visibleWidth <= width, visibleHeight <= height,
              let needed = Self.byteCount(width: width, height: height, bytesPerPixel: 4),
              bytes.count >= needed else { return nil }
        return TEXRawImageRep.image(bytes: bytes, channels: .rgba, rowPixels: width,
                                    width: visibleWidth, height: visibleHeight)
    }

    /// Wallpaper Engine stores some TEX mipmaps as a raw MP4 file (video-backed materials).
    /// Decode a single poster frame so the layer still renders as a static image.
    /// The very first frame of these clips is frequently a noisy/black transition artifact,
    /// so sample a little into the clip instead of literal time zero.
    private func posterImage(fromVideoData data: Data) -> NSImage? {
        guard data.count > 12, data[4..<8].elementsEqual("ftyp".utf8) else { return nil }
        let folder = SceneBackendRuntimeContext.current?.temporaryDirectory ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporaryURL = folder
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("mp4")
        guard OWELog.attempt(.texture, "TEX video mipmap: can't write \(temporaryURL.lastPathComponent)", {
            try data.write(to: temporaryURL)
        }) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let asset = AVURLAsset(url: temporaryURL)
        let durationSemaphore = DispatchSemaphore(value: 0)
        var durationSeconds: Double = 0
        Task {
            // Optional: without a duration the poster frame is the first one.
            durationSeconds = (try? await asset.load(.duration))?.seconds ?? 0
            durationSemaphore.signal()
        }
        durationSemaphore.wait()
        let sampleSeconds = durationSeconds.isFinite && durationSeconds > 0
            ? min(max(durationSeconds * 0.1, 0.5), durationSeconds, 2)
            : 0

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let semaphore = DispatchSemaphore(value: 0)
        var decodedImage: CGImage?
        let sampleTime = CMTime(seconds: sampleSeconds, preferredTimescale: 600)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: sampleTime)]) { _, cgImage, _, _, _ in
            decodedImage = cgImage
            semaphore.signal()
        }
        semaphore.wait()
        guard let cgImage = decodedImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Wallpaper Engine stores raw LZ4 blocks, which the Compression framework decodes with a
    /// SIMD implementation. The hand-rolled decoder stays as a fallback for anything it rejects,
    /// decoding into the same buffer. A declared size over `lz4OutputLimit` is refused.
    private func decompressLZ4(_ input: [UInt8], uncompressedSize: Int, format: UInt32, width: Int, height: Int) -> [UInt8] {
        guard uncompressedSize > 0, !input.isEmpty else { return [] }
        let limit = Self.lz4OutputLimit(compressedSize: input.count, format: format, width: width, height: height)
        guard uncompressedSize <= limit else {
            OWELog.error(.texture, "TEX mipmap declares \(uncompressedSize) decompressed bytes, over its \(limit)-byte limit "
                         + "(\(width)x\(height), format \(format), \(input.count) compressed bytes)")
            return []
        }
        var output = [UInt8](repeating: 0, count: uncompressedSize)
        let written = input.withUnsafeBufferPointer { source -> Int in
            guard let sourceBase = source.baseAddress else { return 0 }
            return output.withUnsafeMutableBufferPointer { destination -> Int in
                guard let destinationBase = destination.baseAddress else { return 0 }
                return compression_decode_buffer(destinationBase, uncompressedSize,
                                                 sourceBase, input.count,
                                                 nil, COMPRESSION_LZ4_RAW)
            }
        }
        if written == uncompressedSize { return output }
        OWELog.debug(.texture, "TEX mipmap \(width)x\(height): Compression's LZ4 decoder wrote \(written) of \(uncompressedSize) bytes; retrying with the scalar decoder")
        return Self.decompressLZ4Scalar(input, into: &output) ? output : []
    }

    /// Decodes `input` into all of `output`; false when it doesn't fill it exactly.
    private static func decompressLZ4Scalar(_ input: [UInt8], into output: inout [UInt8]) -> Bool {
        guard !output.isEmpty else { return false }
        var source = 0
        var destination = 0

        func readLength(_ base: Int) -> Int? {
            var length = base
            guard base == 15 else { return length }
            while source < input.count {
                let value = Int(input[source])
                source += 1
                guard length <= Int.max - value else { return nil }
                length += value
                if value != 255 { return length }
            }
            return nil
        }

        while source < input.count {
            let token = input[source]
            source += 1

            guard let literalLength = readLength(Int(token >> 4)),
                  literalLength <= input.count - source,
                  literalLength <= output.count - destination else { return false }
            if literalLength > 0 {
                output.replaceSubrange(destination..<(destination + literalLength),
                                       with: input[source..<(source + literalLength)])
                source += literalLength
                destination += literalLength
            }

            if source == input.count { break }
            guard source + 2 <= input.count else { return false }
            let offset = Int(input[source]) | (Int(input[source + 1]) << 8)
            source += 2
            guard offset > 0, offset <= destination,
                  let matchLength = readLength(Int(token & 0x0F)).map({ $0 + 4 }),
                  matchLength <= output.count - destination else { return false }
            for _ in 0..<matchLength {
                output[destination] = output[destination - offset]
                destination += 1
            }
        }

        return destination == output.count
    }

    private func decodeDXT(_ input: [UInt8], format: UInt32, width: Int, height: Int,
                           visibleWidth: Int, visibleHeight: Int) -> NSImage? {
        guard Self.isValidSize(width: width, height: height), visibleWidth <= width, visibleHeight <= height,
              let needed = Self.blockByteCount(width: width, height: height, format: format),
              input.count >= needed,
              let pixelBytes = Self.byteCount(width: width, height: height, bytesPerPixel: 4) else { return nil }
        let bytesPerBlock = TEXCompressedTexture.bytesPerBlock(format: format)
        let blockColumns = (width + 3) / 4
        let blockRows = (height + 3) / 4

        var pixels = [UInt8](repeating: 0, count: pixelBytes)
        for blockY in 0..<blockRows {
            for blockX in 0..<blockColumns {
                let offset = (blockY * blockColumns + blockX) * bytesPerBlock
                let alpha: [UInt8]
                let colorOffset: Int
                switch format {
                case 4:
                    alpha = decodeDXT5Alpha(input, offset: offset)
                    colorOffset = offset + 8
                case 6:
                    alpha = decodeDXT3Alpha(input, offset: offset)
                    colorOffset = offset + 8
                default:
                    alpha = [UInt8](repeating: 255, count: 16)
                    colorOffset = offset
                }
                let colors = decodeDXTColors(input, offset: colorOffset, usesOneBitAlpha: format == 7)

                for pixelY in 0..<4 {
                    for pixelX in 0..<4 {
                        let sourceIndex = pixelY * 4 + pixelX
                        let destinationX = blockX * 4 + pixelX
                        let destinationY = blockY * 4 + pixelY
                        guard destinationX < width, destinationY < height else { continue }
                        let color = colors[sourceIndex]
                        let destinationIndex = (destinationY * width + destinationX) * 4
                        pixels[destinationIndex] = color.0
                        pixels[destinationIndex + 1] = color.1
                        pixels[destinationIndex + 2] = color.2
                        pixels[destinationIndex + 3] = format == 7 && color.3 == 0 ? 0 : alpha[sourceIndex]
                    }
                }
            }
        }

        guard visibleWidth > 0, visibleHeight > 0,
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: visibleWidth, height: visibleHeight, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
                                      .union(.byteOrder32Big), provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: visibleWidth, height: visibleHeight))
    }

    private func decodeDXTColors(_ bytes: [UInt8], offset: Int, usesOneBitAlpha: Bool) -> [(UInt8, UInt8, UInt8, UInt8)] {
        let color0 = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        let color1 = UInt16(bytes[offset + 2]) | (UInt16(bytes[offset + 3]) << 8)
        let first = color565(color0)
        let second = color565(color1)
        var palette = [(first.0, first.1, first.2, UInt8(255)), (second.0, second.1, second.2, UInt8(255))]
        if usesOneBitAlpha && color0 <= color1 {
            palette.append((UInt8((Int(first.0) + Int(second.0)) / 2),
                            UInt8((Int(first.1) + Int(second.1)) / 2),
                            UInt8((Int(first.2) + Int(second.2)) / 2), 255))
            palette.append((0, 0, 0, 0))
        } else {
            palette.append((UInt8((2 * Int(first.0) + Int(second.0)) / 3),
                            UInt8((2 * Int(first.1) + Int(second.1)) / 3),
                            UInt8((2 * Int(first.2) + Int(second.2)) / 3), 255))
            palette.append((UInt8((Int(first.0) + 2 * Int(second.0)) / 3),
                            UInt8((Int(first.1) + 2 * Int(second.1)) / 3),
                            UInt8((Int(first.2) + 2 * Int(second.2)) / 3), 255))
        }
        let indices = UInt32(bytes[offset + 4]) | (UInt32(bytes[offset + 5]) << 8)
            | (UInt32(bytes[offset + 6]) << 16) | (UInt32(bytes[offset + 7]) << 24)
        return (0..<16).map { palette[Int((indices >> ($0 * 2)) & 0x3)] }
    }

    private func decodeDXT3Alpha(_ bytes: [UInt8], offset: Int) -> [UInt8] {
        (0..<16).map { pixel in
            let nibble = (bytes[offset + pixel / 2] >> ((pixel % 2) * 4)) & 0xF
            return nibble * 17
        }
    }

    private func decodeDXT5Alpha(_ bytes: [UInt8], offset: Int) -> [UInt8] {
        let alpha0 = bytes[offset]
        let alpha1 = bytes[offset + 1]
        var palette = [alpha0, alpha1]
        if alpha0 > alpha1 {
            for index in 1...6 { palette.append(UInt8(((7 - index) * Int(alpha0) + index * Int(alpha1)) / 7)) }
        } else {
            for index in 1...4 { palette.append(UInt8(((5 - index) * Int(alpha0) + index * Int(alpha1)) / 5)) }
            palette.append(0)
            palette.append(255)
        }
        var indices: UInt64 = 0
        for index in 0..<6 { indices |= UInt64(bytes[offset + 2 + index]) << (index * 8) }
        return (0..<16).map { palette[Int((indices >> ($0 * 3)) & 0x7)] }
    }

    private func color565(_ color: UInt16) -> (UInt8, UInt8, UInt8) {
        (UInt8((color >> 11) * 255 / 31), UInt8(((color >> 5) & 0x3F) * 255 / 63), UInt8((color & 0x1F) * 255 / 31))
    }

    /// The reader past the header of a 2D texture in a `TEXB0001`…`TEXB0004` container (a volume
    /// is `TEXVolume`'s).
    private func containerReader() -> TEXReader? {
        guard let reader = TEXReader(bytes: bytes), !reader.header.isVolume else { return nil }
        return reader
    }

    /// Mipmap `level` of the first image, whose mipmap count the reader is past; the levels before
    /// it are skipped, and the reader is left past it.
    private func readMipmap(at level: Int,
                            reader: inout TEXReader) -> (width: Int, height: Int, compression: UInt32, uncompressedSize: Int, stored: [UInt8])? {
        for current in 0...level {
            guard let mipmap = reader.mipmap(accept: Self.isValidSize) else { return nil }
            if current == level {
                return (mipmap.width, mipmap.height, mipmap.compression, mipmap.uncompressedSize, Array(bytes[mipmap.stored]))
            }
        }
        return nil
    }
}
