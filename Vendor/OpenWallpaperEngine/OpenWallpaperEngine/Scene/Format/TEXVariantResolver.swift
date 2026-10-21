import Accelerate
import Compression
import CoreGraphics
import Foundation
import ImageIO

/// Bakes a `.tex`'s chosen texture variants (`TEXVariants`) into its mipmaps, as WE's loader
/// composes them while it reads the file (`wallpaper64.exe` 0x14015c8d0, 0x14015dd73 and the
/// patch writer 0x14015c480), so every reader after it sees an ordinary texture.
///
/// Per mipmap, the patches of the chosen options apply in stored order:
/// - `wholeMipmap`: the patch's bytes become the mipmap's (and the patches before it are dropped).
/// - `alphaBlend` (RGBA8888 only): each pixel `base + (patch − base) × patchAlpha / 256` per
///   channel, with alpha the larger of the two.
/// - otherwise the patch replaces its rectangle: rows of RGBA8888, RG88 or R8 pixels, or rows of
///   DXT1/3/5 blocks; other formats are left as they are, as WE leaves them.
///
/// A patch is stored as the mipmap is: LZ4 when the mipmap is, a FreeImage picture (decoded to
/// RGBA) when the container's format is one, else raw. A picture container whose patches apply
/// decodes to raw RGBA8888, as WE uploads it.
enum TEXVariantResolver {
    /// `data` in a `TEXB0004` container with no variants, the options in `enabled` (by option
    /// id, `TEXVariants.enabled`) composed in; nil when `data` declares none or can't be read.
    static func resolve(_ data: Data, enabled: [UInt32: TEXVariants.Blend]) -> Data? {
        guard var reader = TEXReader(data), reader.header.variantCount > 0,
              reader.options(count: reader.header.variantCount) != nil else { return nil }
        let header = reader.header
        var images: [[Mipmap]] = []
        for _ in 0..<header.imageCount {
            guard let count = reader.word(), count < 64 else { return malformed(data) }
            var mipmaps: [Mipmap] = []
            for _ in 0..<count {
                guard let mipmap = readMipmap(&reader, header: header) else { return malformed(data) }
                mipmaps.append(mipmap)
            }
            images.append(mipmaps)
        }
        let trailing = reader.cursor..<reader.bytes.count
        let bytes = reader.bytes
        // A picture container decodes to RGBA when a patch must be drawn into it.
        let decodesPictures = header.freeImageFormat >= 0 && images.joined().contains { mipmap in
            mipmap.patches.contains { enabled[$0.option].map { !$0.contains(.wholeMipmap) } ?? false }
        }
        var output: [[Mipmap]] = []
        for mipmaps in images {
            var resolved: [Mipmap] = []
            for mipmap in mipmaps {
                guard let composed = compose(mipmap, bytes: bytes, header: header, enabled: enabled,
                                             decodesPictures: decodesPictures) else { return malformed(data) }
                resolved.append(composed)
            }
            output.append(resolved)
        }
        return write(output, bytes: bytes, header: header, decodesPictures: decodesPictures, trailing: trailing)
    }

    // MARK: Reading

    struct Patch {
        let option: UInt32
        let x: Int, y: Int, width: Int, height: Int
        let stored: Range<Int>
    }

    struct Mipmap {
        var width: Int
        var height: Int
        /// The extra word of a volume slice (`TEXI` flag 0x40).
        var depth: UInt32?
        var compression: UInt32
        var uncompressedSize: Int
        var stored: Range<Int>
        var patches: [Patch]
        /// The composed bytes, once something changed them (else `stored`).
        var bytes: [UInt8]? = nil
    }

    private static func readMipmap(_ reader: inout TEXReader, header: TEXHeader) -> Mipmap? {
        guard let record = reader.mipmap(), let groups = reader.word(), groups <= 4096 else { return nil }
        var patches: [Patch] = []
        for _ in 0..<groups {
            guard let count = reader.word(), count <= 4096 else { return nil }
            for _ in 0..<count {
                guard reader.word() != nil, let option = reader.word(), let x = reader.word(), let y = reader.word(),
                      let patchWidth = reader.word(), let patchHeight = reader.word(), reader.word() != nil,
                      let patchSize = reader.word(), let patchBytes = reader.range(Int(patchSize)) else { return nil }
                patches.append(Patch(option: option, x: Int(x), y: Int(y), width: Int(patchWidth),
                                     height: Int(patchHeight), stored: patchBytes))
            }
        }
        return Mipmap(width: record.width, height: record.height, depth: record.depth, compression: record.compression,
                      uncompressedSize: record.uncompressedSize, stored: record.stored, patches: patches)
    }

    private static func malformed(_ data: Data) -> Data? {
        OWELog.error(.texture, "A .tex with texture variants (\(data.count) bytes) can't be read; its variants are ignored")
        return nil
    }

    // MARK: Composing

    private static func compose(_ mipmap: Mipmap, bytes: [UInt8], header: TEXHeader,
                                enabled: [UInt32: TEXVariants.Blend], decodesPictures: Bool) -> Mipmap? {
        var mipmap = mipmap
        var patches = mipmap.patches.filter { enabled[$0.option] != nil }
        // A whole-mipmap patch replaces what came before it.
        if let last = patches.lastIndex(where: { enabled[$0.option]!.contains(.wholeMipmap) }) {
            mipmap.stored = patches[last].stored
            patches.removeFirst(last + 1)
        }
        let isLZ4 = mipmap.compression == 1
        guard !patches.isEmpty || decodesPictures else { return mipmap }
        var base = Array(bytes[mipmap.stored])
        if isLZ4 {
            guard let expanded = lz4(base, size: mipmap.uncompressedSize) else { return nil }
            base = expanded
        }
        if decodesPictures {
            guard let picture = rgba(base, width: mipmap.width, height: mipmap.height) else {
                OWELog.error(.texture, "A variant texture's \(mipmap.width)×\(mipmap.height) picture can't be decoded")
                return nil
            }
            base = picture
        }
        for patch in patches {
            guard patch.width > 0, patch.height > 0, patch.x <= mipmap.width, patch.width <= mipmap.width - patch.x,
                  patch.y <= mipmap.height, patch.height <= mipmap.height - patch.y else {
                OWELog.error(.texture, "A texture variant's \(patch.width)×\(patch.height) patch at \(patch.x),\(patch.y) "
                             + "is outside its \(mipmap.width)×\(mipmap.height) mipmap; skipped")
                continue
            }
            let stored = Array(bytes[patch.stored])
            let pixels: [UInt8]?
            if isLZ4 {
                pixels = lz4(stored, size: patch.width * patch.height * 4, exact: false)
            } else if header.freeImageFormat >= 0 {
                pixels = rgba(stored, width: patch.width, height: patch.height)
            } else {
                pixels = stored
            }
            guard let pixels else {
                OWELog.error(.texture, "A texture variant's \(patch.width)×\(patch.height) patch can't be decoded; skipped")
                continue
            }
            let format = decodesPictures ? 0 : header.format
            if enabled[patch.option]!.contains(.alphaBlend) {
                if format == 0 { blend(pixels, into: &base, patch: patch, rowPixels: mipmap.width) }
            } else {
                copy(pixels, into: &base, patch: patch, rowPixels: mipmap.width, format: format)
            }
        }
        mipmap.bytes = base
        mipmap.compression = 0
        mipmap.uncompressedSize = base.count
        return mipmap
    }

    /// WE's alpha blend of an RGBA8888 patch, in its integer arithmetic.
    static func blend(_ patch: [UInt8], into base: inout [UInt8], patch rect: Patch, rowPixels: Int) {
        for row in 0..<rect.height {
            for column in 0..<rect.width {
                let source = (row * rect.width + column) * 4
                let target = ((rect.y + row) * rowPixels + rect.x + column) * 4
                guard source + 4 <= patch.count, target + 4 <= base.count else { return }
                let over = pixel(patch, source), under = pixel(base, target)
                let alpha = over >> 24
                func mix(_ mask: UInt32) -> UInt32 {
                    let difference = (over & mask) &- (under & mask)
                    return (((difference &* alpha) >> 8) &+ (under & mask)) & mask
                }
                let result = mix(0xff00ff) | mix(0xff00) | (max(alpha, under >> 24) << 24)
                for byte in 0..<4 { base[target + byte] = UInt8(truncatingIfNeeded: result >> (8 * UInt32(byte))) }
            }
        }
    }

    private static func pixel(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    /// WE's rectangle copy: whole rows, or rows of 4×4 blocks for DXT.
    static func copy(_ patch: [UInt8], into base: inout [UInt8], patch rect: Patch, rowPixels: Int, format: UInt32) {
        // (bytes per row copied, source offset of row r, target offset of row r, row step)
        let layout: (count: Int, source: (Int) -> Int, target: (Int) -> Int, step: Int)
        switch format {
        case 0:
            layout = (rect.width * 4, { $0 * rect.width * 4 }, { ((rect.y + $0) * rowPixels + rect.x) * 4 }, 1)
        case 4, 6:
            layout = (rect.width * 4, { $0 * rect.width }, { (rect.y + $0) * rowPixels + 4 * rect.x }, 4)
        case 7:
            layout = (rect.width * 2, { $0 * rect.width / 2 }, { ((rect.y + $0) * rowPixels + 4 * rect.x) / 2 }, 4)
        case 8:
            layout = (rect.width * 2, { $0 * rect.width * 2 }, { ((rect.y + $0) * rowPixels + rect.x) * 2 }, 1)
        case 9:
            layout = (rect.width, { $0 * rect.width }, { (rect.y + $0) * rowPixels + rect.x }, 1)
        default:
            return
        }
        for row in stride(from: 0, to: rect.height, by: layout.step) {
            let source = layout.source(row), target = layout.target(row)
            guard source + layout.count <= patch.count, target + layout.count <= base.count else { return }
            base.replaceSubrange(target..<(target + layout.count), with: patch[source..<(source + layout.count)])
        }
    }

    // MARK: Decoding

    private static func lz4(_ input: [UInt8], size: Int, exact: Bool = true) -> [UInt8]? {
        guard size > 0, size <= TEXParser.maxDecompressedSize, !input.isEmpty else { return nil }
        var output = [UInt8](repeating: 0, count: size)
        let written = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                compression_decode_buffer(target.baseAddress!, size, source.baseAddress!, input.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard written > 0, !exact || written == size else {
            OWELog.error(.texture, "A variant texture's LZ4 mipmap decoded \(written) of \(size) bytes")
            return nil
        }
        return output
    }

    /// A FreeImage picture (PNG, JPEG…) as `width` × `height` straight-alpha RGBA.
    private static func rgba(_ stored: [UInt8], width: Int, height: Int) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(Data(stored) as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == width, image.height == height,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: space,
                                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)) else { return nil }
        var buffer: vImage_Buffer
        do {
            buffer = try vImage_Buffer(cgImage: image, format: format)
        } catch {
            OWELog.error(.texture, "A variant texture's picture can't be converted to RGBA: \(error)")
            return nil
        }
        defer { buffer.free() }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let line = buffer.data.advanced(by: row * buffer.rowBytes).assumingMemoryBound(to: UInt8.self)
            pixels.withUnsafeMutableBufferPointer { target in
                (target.baseAddress! + row * width * 4).update(from: line, count: width * 4)
            }
        }
        return pixels
    }

    // MARK: Writing

    private static func write(_ images: [[Mipmap]], bytes: [UInt8], header: TEXHeader,
                              decodesPictures: Bool, trailing: Range<Int>) -> Data {
        var written = header
        // A decoded picture is raw RGBA8888 (`FORMAT_RGBA8888`).
        if decodesPictures {
            written.format = 0
            written.freeImageFormat = -1
        }
        written.containerVersion = 4
        written.variantCount = 0
        var writer = TEXContainerWriter(header: written)
        for mipmaps in images {
            writer.word(UInt32(mipmaps.count))
            for mipmap in mipmaps {
                if let composed = mipmap.bytes {
                    writer.mipmap(width: mipmap.width, height: mipmap.height, depth: mipmap.depth, compression: mipmap.compression,
                                  uncompressedSize: mipmap.uncompressedSize, stored: composed)
                } else {
                    writer.mipmap(width: mipmap.width, height: mipmap.height, depth: mipmap.depth, compression: mipmap.compression,
                                  uncompressedSize: mipmap.uncompressedSize, stored: bytes[mipmap.stored])
                }
            }
        }
        writer.append(bytes[trailing])
        return writer.data
    }
}
