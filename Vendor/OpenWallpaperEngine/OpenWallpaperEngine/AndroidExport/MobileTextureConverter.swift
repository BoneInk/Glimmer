import Accelerate
import AppKit
import Foundation

/// Converts a scene's `.tex` files as WE's mobile export does (its Dynamic / Balanced sample of a
/// Workshop scene, byte for byte apart from the compressed blocks):
///
/// - **R8 and RG88** (masks, normal maps) are copied unchanged, at full size.
/// - **Pictures** (an embedded PNG or JPEG, FreeImage format ≥ 0) and **DXT** are decoded,
///   reduced to `1/reduction` of their image size (rounded down), padded to whole 4×4 blocks
///   (edge pixels repeated) and stored as one ETC2 RGBA8 mipmap (`ETC2Encoder`, format 5), LZ4
///   compressed, in a `TEXB0004` container. The header's texture size is then the mipmap's
///   times the reduction, plus the image's remainder (WE's: 1931×1772 → mipmap 968×888, texture
///   1937×1776), so image ÷ texture is still the share of the mipmap the picture covers.
/// - **Raw RGBA8888** (no picture) keeps its pixels and mipmaps as they are, rewritten into a
///   `TEXB0004` container.
/// - Every texture it rewrites that the scene samples only as a second or later texture of a
///   pass (masks, flow phases) gets flag `0x8` (`secondaryFlag`), as WE's sample has it; what
///   the flag means to the app isn't documented.
/// - **Pixel art optimization** keeps every texture at full size and uncompressed (RGBA8888, LZ4),
///   with nearest filtering (`TEXFlags.noInterpolation`), so no pixel is blurred or blocked.
/// - Sprite sheets, several images and video textures are copied unchanged.
enum MobileTextureConverter {
    static let secondaryFlag: UInt32 = 0x8

    enum Failure: LocalizedError {
        case undecodable(String)

        var errorDescription: String? {
            switch self {
            case .undecodable(let path): return String(localized: "Failed converting a texture.") + " (\(path))"
            }
        }
    }

    /// The `.tex` file's contents for the package.
    static func convert(_ data: Data, path: String, reduction: Int, pixelArt: Bool, secondary: Bool) throws -> Data {
        ThreadGuards.assertBackground("MobileTextureConverter.convert")
        guard let header = TEXFileHeader(data) else {
            OWELog.error(.texture, "Android export: \(path) isn't a .tex this can read; copied as it is")
            return data
        }
        let isChannelReduced = TEXImageFormat(rawValue: header.format).isChannelReduced
        guard !isChannelReduced, !header.isVideo, header.imageCount == 1, header.trailingByteCount == 0,
              header.flags & TEXFlags.sprite.rawValue == 0, !header.mipmaps.isEmpty else { return data }
        let flags = header.flags | (secondary ? secondaryFlag : 0)
        let isPicture = header.freeImageFormat >= 0
        let isBlockCompressed = TEXImageFormat(rawValue: header.format).isBlockCompressed
        if !isPicture, !isBlockCompressed, !pixelArt, header.format == 0 {
            return recontainered(data, header: header, flags: flags)
        }
        guard let pixels = decode(data, header: header) else { throw Failure.undecodable(path) }
        if pixelArt {
            return rawTexture(pixels, header: header, flags: flags | TEXFlags.noInterpolation.rawValue)
        }
        return etc2Texture(pixels, header: header, reduction: max(reduction, 1), flags: flags)
    }

    // MARK: Layout

    /// The mipmap side for an image side reduced by `reduction`: rounded down, then up to whole blocks.
    static func reducedSide(_ image: Int, reduction: Int) -> (content: Int, mipmap: Int) {
        let content = max(image / reduction, 1)
        return (content, (content + 3) / 4 * 4)
    }

    /// The header's texture side for that mipmap: WE's `mipmap × reduction + image mod reduction`.
    static func textureSide(image: Int, mipmap: Int, reduction: Int) -> Int {
        mipmap * reduction + image % reduction
    }

    // MARK: Writing

    private static func recontainered(_ data: Data, header: TEXFileHeader, flags: UInt32) -> Data {
        TEXWriter.data(TEXWriter.Texture(
            format: header.format, flags: flags, textureWidth: header.textureWidth, textureHeight: header.textureHeight,
            imageWidth: header.imageWidth, imageHeight: header.imageHeight, colorWord: header.colorWord,
            mipmaps: header.mipmaps.map {
                TEXWriter.Mipmap(width: $0.width, height: $0.height, compression: $0.compression,
                                 uncompressedSize: $0.uncompressedSize, stored: data.subdata(in: $0.stored.offset(by: data.startIndex)))
            }))
    }

    private static func etc2Texture(_ pixels: Pixels, header: TEXFileHeader, reduction: Int, flags: UInt32) -> Data {
        let width = reducedSide(pixels.width, reduction: reduction), height = reducedSide(pixels.height, reduction: reduction)
        let scaled = pixels.scaled(width: width.content, height: height.content)
        let padded = scaled.padded(width: width.mipmap, height: height.mipmap)
        let blocks = ETC2Encoder.encode(padded.bytes, width: width.mipmap, height: height.mipmap)
        return TEXWriter.data(TEXWriter.Texture(
            format: ETC2Encoder.texFormat, flags: flags,
            textureWidth: textureSide(image: header.imageWidth, mipmap: width.mipmap, reduction: reduction),
            textureHeight: textureSide(image: header.imageHeight, mipmap: height.mipmap, reduction: reduction),
            imageWidth: header.imageWidth, imageHeight: header.imageHeight, colorWord: header.colorWord,
            mipmaps: [TEXWriter.Mipmap(width: width.mipmap, height: height.mipmap, compression: 1,
                                       uncompressedSize: blocks.count, stored: Data(LZ4BlockEncoder.compress(blocks)))]))
    }

    private static func rawTexture(_ pixels: Pixels, header: TEXFileHeader, flags: UInt32) -> Data {
        TEXWriter.data(TEXWriter.Texture(
            format: 0, flags: flags, textureWidth: pixels.width, textureHeight: pixels.height,
            imageWidth: header.imageWidth, imageHeight: header.imageHeight, colorWord: header.colorWord,
            mipmaps: [TEXWriter.Mipmap(width: pixels.width, height: pixels.height, compression: 1,
                                       uncompressedSize: pixels.bytes.count, stored: Data(LZ4BlockEncoder.compress(pixels.bytes)))]))
    }

    // MARK: Pixels

    /// Straight-alpha RGBA8 pixels, rows top to bottom.
    struct Pixels {
        var width: Int
        var height: Int
        var bytes: [UInt8]

        /// Resampled to `width`×`height` (vImage's Lanczos), or itself when it is that size.
        func scaled(width newWidth: Int, height newHeight: Int) -> Pixels {
            guard newWidth != width || newHeight != height else { return self }
            var output = [UInt8](repeating: 0, count: newWidth * newHeight * 4)
            var source = bytes
            source.withUnsafeMutableBytes { sourceBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    var input = vImage_Buffer(data: sourceBytes.baseAddress, height: vImagePixelCount(height),
                                              width: vImagePixelCount(width), rowBytes: width * 4)
                    var result = vImage_Buffer(data: outputBytes.baseAddress, height: vImagePixelCount(newHeight),
                                               width: vImagePixelCount(newWidth), rowBytes: newWidth * 4)
                    let status = vImageScale_ARGB8888(&input, &result, nil, vImage_Flags(kvImageHighQualityResampling))
                    if status != kvImageNoError { OWELog.error(.texture, "Android export: scaling a texture failed (\(status))") }
                }
            }
            return Pixels(width: newWidth, height: newHeight, bytes: output)
        }

        /// Padded to `width`×`height`, repeating the last column and row.
        func padded(width newWidth: Int, height newHeight: Int) -> Pixels {
            guard newWidth != width || newHeight != height else { return self }
            var output = [UInt8](repeating: 0, count: newWidth * newHeight * 4)
            for y in 0..<newHeight {
                let sourceRow = min(y, height - 1) * width * 4
                for x in 0..<newWidth {
                    let source = sourceRow + min(x, width - 1) * 4, target = (y * newWidth + x) * 4
                    output[target..<target + 4] = bytes[source..<source + 4]
                }
            }
            return Pixels(width: newWidth, height: newHeight, bytes: output)
        }
    }

    /// The first image's picture at the image's size, straight alpha (`TEXParser` decodes it).
    static func decode(_ data: Data, header: TEXFileHeader) -> Pixels? {
        guard let cgImage = picture(data, header: header) else { return nil }
        let space = cgImage.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: space,
                                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)) else { return nil }
        var buffer: vImage_Buffer
        do {
            buffer = try vImage_Buffer(cgImage: cgImage, format: format)
        } catch {
            OWELog.error(.texture, "Android export: a texture's picture couldn't be converted to RGBA: \(error)")
            return nil
        }
        defer { buffer.free() }
        let width = Int(buffer.width), height = Int(buffer.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let source = buffer.data.advanced(by: row * buffer.rowBytes).assumingMemoryBound(to: UInt8.self)
            for column in 0..<(width * 4) { bytes[row * width * 4 + column] = source[column] }
        }
        let pixels = Pixels(width: width, height: height, bytes: bytes)
        // A padded raw texture decodes at its allocation; the picture is its image's part.
        guard width > header.imageWidth || height > header.imageHeight, header.imageWidth > 0, header.imageHeight > 0 else {
            return pixels
        }
        var cropped = [UInt8](repeating: 0, count: header.imageWidth * header.imageHeight * 4)
        for row in 0..<min(header.imageHeight, height) {
            let source = row * width * 4, target = row * header.imageWidth * 4
            let count = min(header.imageWidth, width) * 4
            cropped[target..<target + count] = bytes[source..<source + count]
        }
        return Pixels(width: header.imageWidth, height: header.imageHeight, bytes: cropped)
    }
}

extension MobileTextureConverter {
    /// The first image as a picture: an embedded PNG or JPEG read as it is (at its own pixels),
    /// else what `TEXParser` decodes (DXT, raw pixels).
    static func picture(_ data: Data, header: TEXFileHeader) -> CGImage? {
        if header.freeImageFormat >= 0, let first = header.mipmaps.first, first.compression == 0,
           let source = CGImageSourceCreateWithData(data.subdata(in: first.stored.offset(by: data.startIndex)) as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return image
        }
        return TEXParser(data: data).extractImage()?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

private extension Range where Bound == Int {
    func offset(by start: Int) -> Range<Int> { (lowerBound + start)..<(upperBound + start) }
}
