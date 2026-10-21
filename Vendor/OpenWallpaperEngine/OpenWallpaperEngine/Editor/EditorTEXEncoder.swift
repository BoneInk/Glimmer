import CoreGraphics
import Foundation
import OWESceneEditing

/// The Wallpaper Editor's `.tex` writer for its importer (`EditorAssetStore`), laid out as WE
/// 2.8's importer writes them (`TEXB0004`, raw texels, LZ4 where it helps; library textures such
/// as 3455121165's `0001.tex`, 3734636606's `checker.tex`):
///
/// - **RGBA 8888, R 8, RG 88**: the image's own size, its channels as stored (R 8 the red, RG 88
///   red and green).
/// - **DXT5, DXT1**: the texture padded to whole 32-pixel tiles (788 × 813 → 800 × 832, as WE's),
///   the edge pixels repeated, the header's image size the picture's.
/// - **Mipmaps** halve each side (rounding down) while the smaller side stays at 64 or more, as
///   WE's do for most library textures [I: WE stops one level earlier for some sizes]; No Mip Maps
///   writes the first only.
/// - **Flags**: Pixel Art is bit 0, Clamp UVs bit 1, a sprite sheet bit 2 (`TEXFlags`).
/// - **Sprite sheets** (a GIF, an image sequence): the frames in a grid, RGBA 8888 in one mipmap
///   in a `TEXB0003` container followed by the `TEXS0003` frame table (the frame size, then each
///   frame's time and pixel rectangle), as 3809943023's `background.tex`.
/// - **Videos**: the MP4 as the single, stored mipmap of a `TEXB0004` with no variants, flagged
///   Clamp UVs and video (`TEXFlags.video`), format 0, FreeImage format -1 and an uncompressed size
///   of 0, as library video textures (3802509485's `bg_2560x1600_nobars.tex`).
struct EditorTEXEncoder: EditorTextureEncoding {
    enum Failure: LocalizedError {
        case unreadable
        case tooLarge(Int, Int)
        case notAVideo

        var errorDescription: String? {
            switch self {
            case .unreadable: return String(localized: "The image’s pixels can’t be read.")
            case .tooLarge(let width, let height):
                return String(localized: "The frames don’t fit one texture (\(width) × \(height) pixels).")
            case .notAVideo: return String(localized: "The file isn’t an MP4 video with a picture.")
            }
        }
    }

    /// The GPU's largest texture side, which a sprite sheet must fit.
    static let maximumSide = 16384
    /// Mipmaps stop before the smaller side drops under this.
    static let smallestMipmapSide = 64

    // MARK: EditorTextureEncoding

    func texture(_ image: CGImage, options: TextureImportOptions) throws -> Data {
        let pixels = try Self.rgba(image)
        return Self.texture(pixels, width: image.width, height: image.height, format: options.format,
                            flags: options.texFlags(), mipmapped: !options.noMipmaps)
    }

    func normalMap(_ image: CGImage) throws -> Data {
        // WE's normal map import: {"clampuvs": true, "nonpoweroftwo": true, "format": "rg88n"}.
        Self.texture(try Self.rgba(image), width: image.width, height: image.height, format: .rg88,
                     flags: TEXFlags.clampUVs.rawValue, mipmapped: true)
    }

    func spriteSheet(_ frames: [TextureImportFrame], options: TextureImportOptions) throws -> (data: Data, size: SIMD2<Double>) {
        guard let first = frames.first else { throw Failure.unreadable }
        let layout = try Self.sheetLayout(count: frames.count, frameWidth: first.image.width, frameHeight: first.image.height)
        let width = layout.columns * layout.frameWidth, height = layout.rows * layout.frameHeight
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.unreadable }
        context.interpolationQuality = .high
        for (index, frame) in frames.enumerated() {
            let column = index % layout.columns, row = index / layout.columns
            // Core Graphics' origin is the bottom left; the sheet's rows run from the top.
            let rect = CGRect(x: column * layout.frameWidth, y: height - (row + 1) * layout.frameHeight,
                              width: layout.frameWidth, height: layout.frameHeight)
            context.draw(frame.image, in: rect)
        }
        guard let sheet = context.makeImage() else { throw Failure.unreadable }
        let pixels = try Self.rgba(sheet)
        var data = TEXWriter.data(TEXWriter.Texture(
            format: 0, flags: options.texFlags(spriteSheet: true), textureWidth: width, textureHeight: height,
            imageWidth: width, imageHeight: height, colorWord: 0xFF00_0000,
            mipmaps: [Self.mipmap(pixels, width: width, height: height)]), container: .b0003)
        data.append(Self.frameTable(frames, layout: layout))
        return (data, SIMD2(Double(width), Double(height)))
    }

    func video(_ url: URL) throws -> (data: Data, size: SIMD2<Double>) {
        let movie = try Data(contentsOf: url)
        guard movie.count > 12, movie[movie.startIndex + 4..<movie.startIndex + 8].elementsEqual("ftyp".utf8),
              let size = MP4TrackSize.pictureSize(of: movie) else { throw Failure.notAVideo }
        return (Self.videoTexture(movie, width: size.width, height: size.height), SIMD2(Double(size.width), Double(size.height)))
    }

    // MARK: Layout

    /// The frames' grid: about square (columns ⌈√(n·h/w)⌉), every frame at one size, scaled down
    /// to fit `maximumSide` when the frames are too many or too large.
    static func sheetLayout(count: Int, frameWidth: Int, frameHeight: Int) throws
        -> (columns: Int, rows: Int, frameWidth: Int, frameHeight: Int) {
        guard count > 0, frameWidth > 0, frameHeight > 0 else { throw Failure.unreadable }
        var columns = max(1, Int((Double(count) * Double(frameHeight) / Double(frameWidth)).squareRoot().rounded(.up)))
        columns = min(columns, count)
        let rows = (count + columns - 1) / columns
        let scale = min(1, Double(maximumSide) / Double(columns * frameWidth), Double(maximumSide) / Double(rows * frameHeight))
        let width = max(1, Int(Double(frameWidth) * scale)), height = max(1, Int(Double(frameHeight) * scale))
        guard columns * width <= maximumSide, rows * height <= maximumSide else {
            throw Failure.tooLarge(columns * frameWidth, rows * frameHeight)
        }
        return (columns, rows, width, height)
    }

    /// `TEXS0003`: count, the frame size, then per frame its image (0), time, x, y, width, 0, 0, height.
    static func frameTable(_ frames: [TextureImportFrame], layout: (columns: Int, rows: Int, frameWidth: Int, frameHeight: Int)) -> Data {
        var data = Data("TEXS0003".utf8)
        data.append(0)
        func word(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func float(_ value: Float) { word(value.bitPattern) }
        word(UInt32(frames.count))
        word(UInt32(layout.frameWidth))
        word(UInt32(layout.frameHeight))
        for (index, frame) in frames.enumerated() {
            word(0)
            float(Float(frame.duration))
            float(Float(index % layout.columns * layout.frameWidth))
            float(Float(index / layout.columns * layout.frameHeight))
            float(Float(layout.frameWidth))
            float(0)
            float(0)
            float(Float(layout.frameHeight))
        }
        return data
    }

    // MARK: Writing

    static func texture(_ pixels: [UInt8], width: Int, height: Int, format: TextureImportOptions.Format,
                        flags: UInt32, mipmapped: Bool) -> Data {
        let blocks = format == .dxt1 || format == .dxt5
        // DXT pads to whole 32-pixel tiles; the others keep the image's size.
        let textureWidth = blocks ? (width + 31) / 32 * 32 : width
        let textureHeight = blocks ? (height + 31) / 32 * 32 : height
        var level = blocks ? padded(pixels, width: width, height: height, to: textureWidth, textureHeight) : pixels
        var levelWidth = textureWidth, levelHeight = textureHeight
        var mipmaps: [TEXWriter.Mipmap] = []
        while true {
            mipmaps.append(mipmap(stored(level, width: levelWidth, height: levelHeight, format: format),
                                  width: levelWidth, height: levelHeight))
            let nextWidth = levelWidth / 2, nextHeight = levelHeight / 2
            guard mipmapped, min(nextWidth, nextHeight) >= smallestMipmapSide else { break }
            level = halved(level, width: levelWidth, height: levelHeight)
            levelWidth = nextWidth
            levelHeight = nextHeight
        }
        return TEXWriter.data(TEXWriter.Texture(format: format.texFormat, flags: flags, textureWidth: textureWidth,
                                                textureHeight: textureHeight, imageWidth: width, imageHeight: height,
                                                colorWord: 0xFF00_0000, mipmaps: mipmaps))
    }

    /// The level's bytes in the format: RGBA as it is, R 8 or RG 88 their channels, DXT its blocks.
    static func stored(_ pixels: [UInt8], width: Int, height: Int, format: TextureImportOptions.Format) -> [UInt8] {
        switch format {
        case .rgba8888: return pixels
        case .r8: return stride(from: 0, to: width * height * 4, by: 4).map { pixels[$0] }
        case .rg88: return stride(from: 0, to: width * height * 4, by: 4).flatMap { [pixels[$0], pixels[$0 + 1]] }
        case .dxt1: return BCBlockEncoder.encode(pixels, width: width, height: height, dxt5: false)
        case .dxt5: return BCBlockEncoder.encode(pixels, width: width, height: height, dxt5: true)
        }
    }

    /// LZ4 when it is smaller, else stored as is (WE stores its small mipmaps plain).
    static func mipmap(_ bytes: [UInt8], width: Int, height: Int) -> TEXWriter.Mipmap {
        let compressed = LZ4BlockEncoder.compress(bytes)
        if compressed.count < bytes.count {
            return TEXWriter.Mipmap(width: width, height: height, compression: 1, uncompressedSize: bytes.count, stored: Data(compressed))
        }
        return TEXWriter.Mipmap(width: width, height: height, compression: 0, uncompressedSize: bytes.count, stored: Data(bytes))
    }

    static func videoTexture(_ movie: Data, width: Int, height: Int) -> Data {
        // The movie is the one mipmap, stored as is with no uncompressed size.
        TEXWriter.data(TEXWriter.Texture(format: 0, flags: TEXFlags([.clampUVs, .video]).rawValue, textureWidth: width,
                                         textureHeight: height, imageWidth: width, imageHeight: height, colorWord: 0,
                                         mipmaps: [TEXWriter.Mipmap(width: width, height: height, compression: 0,
                                                                    uncompressedSize: 0, stored: movie)]))
    }

    // MARK: Pixels

    /// Straight RGBA, rows top to bottom.
    static func rgba(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw Failure.unreadable }
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in 0..<3 { pixels[index + channel] = UInt8(min(255, (Int(pixels[index + channel]) * 255 + alpha / 2) / alpha)) }
        }
        return pixels
    }

    static func padded(_ pixels: [UInt8], width: Int, height: Int, to newWidth: Int, _ newHeight: Int) -> [UInt8] {
        guard newWidth != width || newHeight != height else { return pixels }
        var result = [UInt8](repeating: 0, count: newWidth * newHeight * 4)
        for y in 0..<newHeight {
            for x in 0..<newWidth {
                let source = (min(y, height - 1) * width + min(x, width - 1)) * 4, target = (y * newWidth + x) * 4
                for channel in 0..<4 { result[target + channel] = pixels[source + channel] }
            }
        }
        return result
    }

    /// Each side halved (rounding down), every texel the mean of its 2 × 2 source.
    static func halved(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        let newWidth = max(width / 2, 1), newHeight = max(height / 2, 1)
        var result = [UInt8](repeating: 0, count: newWidth * newHeight * 4)
        for y in 0..<newHeight {
            for x in 0..<newWidth {
                for channel in 0..<4 {
                    var sum = 0
                    for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                        let sx = min(x * 2 + dx, width - 1), sy = min(y * 2 + dy, height - 1)
                        sum += Int(pixels[(sy * width + sx) * 4 + channel])
                    }
                    result[(y * newWidth + x) * 4 + channel] = UInt8((sum + 2) / 4)
                }
            }
        }
        return result
    }
}
