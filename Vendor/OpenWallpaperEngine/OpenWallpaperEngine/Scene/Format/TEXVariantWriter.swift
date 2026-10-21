import Compression
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes a `.tex` with texture variants (`TEXVariants` has the layout WE's loader reads,
/// `wallpaper64.exe` 0x14015c8d0): the base texture with the option records after its
/// `TEXB0004` header and each option's patches after every mipmap, so `TEXVariantResolver`
/// composes the chosen ones back into the option's own texture.
///
/// As WE 2.8's resource compiler writes them (capture 540: `variant_a.tex`, a 512 × 256 RGBA8888
/// picture in a PNG container with three mipmaps, one group of a Replace and an Alpha blended
/// option): groups and option ids count from 1, and every option has one patch per mipmap, the
/// whole mipmap's rectangle, stored as the mipmap is (a PNG with FreeImage format 13 there; raw
/// texels, LZ4 when the mipmap is, in a raw texture). Replace is blend 0 (the rectangle copied in),
/// Alpha blended blend 1 (drawn over the base by its alpha; RGBA8888 only, WE's
/// `variantallowcomplexblend`). A video's option replaces the whole mipmap (blend 2), as does one
/// of a format the loader copies no rectangles of.
///
/// Each option comes as a texture of the base's layout (its format, mipmap sizes and container;
/// `EditorTEXEncoder.variantTexture`).
enum TEXVariantWriter {
    struct Option {
        var group: UInt32
        var id: UInt32
        var alphaBlend: Bool
        /// The record's JSON: `{"condition":"<bool>"}` or `{"condition":{"condition":"<value>","name":"<combo>"}}`.
        var condition: String
        /// The option's texture, of the base's layout and without variants.
        var texture: Data
    }

    enum Failure: Error, Equatable {
        /// The base isn't a `.tex` this writes variants into (a volume texture, unreadable).
        case unsupportedBase
        /// An option's texture isn't of the base's size and kind (WE's "Incompatible Variant Option").
        case incompatible(option: UInt32)
        /// Alpha blending in a texture that isn't RGBA8888 (or is a video).
        case alphaBlendUnsupported(option: UInt32)
    }

    /// FreeImage's PNG, which a picture container's blended patches are stored as.
    static let pngFreeImageFormat: Int32 = 13
    /// Formats whose patches are rectangles (`TEXVariantResolver.copy`).
    static let regionFormats: Set<UInt32> = [0, 4, 6, 7, 8, 9]

    /// The blend word an option gets in a base of this layout.
    static func blend(alphaBlend: Bool, layout: Layout) -> TEXVariants.Blend {
        if alphaBlend { return .alphaBlend }
        return layout.patchesRegions ? [] : .wholeMipmap
    }

    static func write(base: Data, options: [Option]) throws -> Data {
        var layout = try Layout(base)
        if layout.header.variantCount > 0 {
            // Variants already there are replaced: the base without them.
            guard let plain = TEXVariantResolver.resolve(base, enabled: [:]) else { throw Failure.unsupportedBase }
            layout = try Layout(plain)
        }
        var optionLayouts: [Layout] = []
        for option in options {
            guard let other = try? Layout(option.texture), other.header.variantCount == 0, layout.isCompatible(with: other) else {
                throw Failure.incompatible(option: option.id)
            }
            if option.alphaBlend && !layout.allowsAlphaBlend { throw Failure.alphaBlendUnsupported(option: option.id) }
            optionLayouts.append(other)
        }

        var header = layout.header
        header.containerVersion = 4
        header.variantCount = options.count
        var writer = TEXContainerWriter(header: header)
        func word(_ value: UInt32) { writer.word(value) }
        for option in options {
            word(option.group)
            word(option.id)
            word(blend(alphaBlend: option.alphaBlend, layout: layout).rawValue)
            writer.string(option.condition)
        }
        // Groups in the order their first option comes.
        var groups: [UInt32] = []
        for option in options where !groups.contains(option.group) { groups.append(option.group) }
        for (imageIndex, levels) in layout.images.enumerated() {
            word(UInt32(levels.count))
            for (levelIndex, level) in levels.enumerated() {
                writer.mipmap(width: level.width, height: level.height, compression: level.compression,
                              uncompressedSize: level.uncompressedSize, stored: level.stored)
                guard !options.isEmpty else { continue }
                var patchesByGroup: [UInt32: [Patch]] = [:]
                for (index, option) in options.enumerated() {
                    let variant = optionLayouts[index].images[imageIndex][levelIndex]
                    if let patch = try patch(option, base: level, variant: variant, layout: layout,
                                             variantFreeImageFormat: optionLayouts[index].header.freeImageFormat) {
                        patchesByGroup[option.group, default: []].append(patch)
                    }
                }
                word(UInt32(groups.count))
                for group in groups {
                    let patches = patchesByGroup[group] ?? []
                    word(UInt32(patches.count))
                    for patch in patches {
                        for value in [group, patch.option, UInt32(patch.x), UInt32(patch.y), UInt32(patch.width),
                                      UInt32(patch.height), UInt32(bitPattern: patch.freeImageFormat), UInt32(patch.bytes.count)] {
                            word(value)
                        }
                        writer.append(patch.bytes)
                    }
                }
            }
        }
        writer.append(layout.trailing)
        return writer.data
    }

    // MARK: Patches

    struct Patch {
        var option: UInt32
        var x: Int, y: Int, width: Int, height: Int
        var freeImageFormat: Int32
        var bytes: [UInt8]
    }

    private static func patch(_ option: Option, base: Level, variant: Level, layout: Layout,
                              variantFreeImageFormat: Int32) throws -> Patch? {
        if layout.isPicture {
            // The option's picture at the mipmap's size, as the mipmap is stored.
            return Patch(option: option.id, x: 0, y: 0, width: base.width, height: base.height,
                         freeImageFormat: variantFreeImageFormat, bytes: variant.stored)
        }
        guard let texels = texels(variant) else { throw Failure.incompatible(option: option.id) }
        if layout.patchesRegions {
            // A DXT mipmap smaller than whole blocks can't take a rectangle (the loader copies rows of blocks).
            let side = block(format: layout.header.format).side
            guard base.width % side == 0, base.height % side == 0 else { return nil }
        }
        return Patch(option: option.id, x: 0, y: 0, width: base.width, height: base.height, freeImageFormat: -1,
                     bytes: base.compression == 1 ? LZ4BlockEncoder.compress(texels) : texels)
    }

    /// A format's addressable unit: a pixel, or a 4 × 4 block of DXT.
    static func block(format: UInt32) -> (side: Int, bytes: Int) {
        switch format {
        case 4, 6: return (4, 16)
        case 7: return (4, 8)
        case 8: return (1, 2)
        case 9: return (1, 1)
        default: return (1, 4)
        }
    }

    // MARK: Layout

    struct Level {
        var width: Int
        var height: Int
        var compression: UInt32
        var uncompressedSize: Int
        var stored: [UInt8]
    }

    /// A variant-free `.tex` read into its parts.
    struct Layout {
        let header: TEXHeader
        var textureWidth: Int { header.textureWidth }
        var textureHeight: Int { header.textureHeight }
        var imageWidth: Int { header.imageWidth }
        var imageHeight: Int { header.imageHeight }
        var images: [[Level]]
        let trailing: [UInt8]

        var isVideo: Bool { header.flags & TEXFlags.video.rawValue != 0 }
        var isPicture: Bool { header.freeImageFormat >= 0 && !isVideo }
        /// Replace patches are rectangles the loader copies in (else whole mipmaps): a picture (which
        /// it decodes to RGBA) or a raw format it copies rows of.
        var patchesRegions: Bool { !isVideo && (isPicture || TEXVariantWriter.regionFormats.contains(header.format)) }
        /// WE's `variantallowcomplexblend`: an RGBA8888 picture.
        var allowsAlphaBlend: Bool { !isVideo && header.format == 0 }

        init(_ data: Data) throws {
            guard var reader = TEXReader(data), !reader.header.isVolume else { throw Failure.unsupportedBase }
            let header = reader.header
            self.header = header
            if header.variantCount > 0 {
                // Read no further: the writer strips them first.
                images = []
                trailing = []
                return
            }
            var images: [[Level]] = []
            for _ in 0..<header.imageCount {
                guard let count = reader.word(), count < 64 else { throw Failure.unsupportedBase }
                var levels: [Level] = []
                for _ in 0..<count {
                    guard let mipmap = reader.mipmap() else { throw Failure.unsupportedBase }
                    // Before `TEXB0002` a mipmap is stored as is: its uncompressed size is its size.
                    let uncompressed = header.mipmapsHaveCompression ? mipmap.uncompressedSize : mipmap.stored.count
                    levels.append(Level(width: mipmap.width, height: mipmap.height, compression: mipmap.compression,
                                        uncompressedSize: uncompressed, stored: Array(reader.bytes[mipmap.stored])))
                }
                images.append(levels)
            }
            self.images = images
            trailing = Array(reader.bytes[reader.cursor...])
        }

        /// A variant-free `TEXB0004` `.tex` of this layout with `images`' bytes in place of its own
        /// (an option's texture); `freeImageFormat` for a picture's.
        func data(with images: [[Level]], freeImageFormat: Int32? = nil) -> Data {
            var written = header
            written.containerVersion = 4
            written.imageCount = images.count
            written.freeImageFormat = freeImageFormat ?? header.freeImageFormat
            written.variantCount = 0
            var writer = TEXContainerWriter(header: written)
            for levels in images {
                writer.word(UInt32(levels.count))
                for level in levels {
                    writer.mipmap(width: level.width, height: level.height, compression: level.compression,
                                  uncompressedSize: level.uncompressedSize, stored: level.stored)
                }
            }
            writer.append(trailing)
            return writer.data
        }

        /// Same kind (raw format, picture or video), size and mipmaps.
        func isCompatible(with other: Layout) -> Bool {
            guard isVideo == other.isVideo, isPicture == other.isPicture, imageWidth == other.imageWidth,
                  imageHeight == other.imageHeight, images.count == other.images.count else { return false }
            if !isPicture && !isVideo && (header.format != other.header.format || textureWidth != other.textureWidth
                                          || textureHeight != other.textureHeight) { return false }
            for (mine, theirs) in zip(images, other.images) {
                guard mine.count == theirs.count else { return false }
                for (a, b) in zip(mine, theirs) where a.width != b.width || a.height != b.height { return false }
            }
            return true
        }
    }

    // MARK: Decoding and encoding

    /// A raw mipmap's texels (LZ4 expanded).
    static func texels(_ level: Level) -> [UInt8]? {
        guard level.compression == 1 else { return level.stored }
        let size = level.uncompressedSize
        guard size > 0, size <= TEXParser.maxDecompressedSize, !level.stored.isEmpty else { return nil }
        var output = [UInt8](repeating: 0, count: size)
        let written = level.stored.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                compression_decode_buffer(target.baseAddress!, size, source.baseAddress!, source.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        return written == size ? output : nil
    }

    /// Straight RGBA as a PNG.
    static func pngData(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8]? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return [UInt8](output as Data)
    }
}
