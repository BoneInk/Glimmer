import CoreGraphics
import Foundation
import ImageIO
import OWESceneEditing

/// Texture variants for the Wallpaper Editor (`TextureVariantDocument`): each option's file made
/// into a texture of the base's layout (its format, padding, mipmap sizes, picture or video), then
/// compiled into the base by `TEXVariantWriter`, as WE's resource compiler bakes a `.tex-json`'s
/// `variants` into its `.tex`.
extension EditorTEXEncoder {
    func texture(_ base: Data, withVariants options: [TextureVariantInput]) throws -> Data {
        let baseTexture = try Self.variantBaseTexture(base)
        var layout = try Self.layout(baseTexture)
        if layout.header.variantCount > 0 {
            // Variants already compiled in are replaced: the base without them.
            guard let plain = TEXVariantResolver.resolve(baseTexture, enabled: [:]) else { throw TextureVariantError.unsupportedTexture }
            layout = try Self.layout(plain)
        }
        let writerOptions = try options.map { option in
            TEXVariantWriter.Option(group: option.group, id: option.id, alphaBlend: option.alphaBlend, condition: option.condition,
                                    texture: try Self.variantTexture(option.file, like: layout, option: option.id))
        }
        do {
            return try TEXVariantWriter.write(base: baseTexture, options: writerOptions)
        } catch TEXVariantWriter.Failure.incompatible(let id) {
            throw TextureVariantError.incompatible(optionID: id)
        } catch TEXVariantWriter.Failure.alphaBlendUnsupported(let id) {
            throw TextureVariantError.alphaBlendUnsupported(optionID: id)
        } catch is TEXVariantWriter.Failure {
            throw TextureVariantError.unsupportedTexture
        }
    }

    func variantBase(_ data: Data) -> TextureVariantBase? {
        guard Self.isTEX(data) else {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return TextureVariantBase(width: image.width, height: image.height, isVideo: false, allowsAlphaBlend: true,
                                      hasCompiledVariants: false)
        }
        // The header alone, in the first bytes; the mipmaps aren't read.
        guard let header = TEXHeader([UInt8](data.prefix(256))) else { return nil }
        return TextureVariantBase(width: header.imageWidth, height: header.imageHeight, isVideo: header.isVideo,
                                  allowsAlphaBlend: !header.isVideo && header.format == 0, hasCompiledVariants: header.variantCount > 0)
    }

    // MARK: Pieces

    static func isTEX(_ data: Data) -> Bool { data.starts(with: Array("TEXV0005".utf8)) }

    private static func layout(_ data: Data) throws -> TEXVariantWriter.Layout {
        do {
            return try TEXVariantWriter.Layout(data)
        } catch {
            throw TextureVariantError.unsupportedTexture
        }
    }

    /// The base as a `.tex`: a picture (PNG, JPEG) becomes the texture WE's resource compiler
    /// makes of an imported picture with its defaults (capture 540's `variant_a.tex`: RGBA8888 in a
    /// PNG container, FreeImage format 13, the picture's own size, Clamp UVs, each mipmap a PNG,
    /// halved while the smaller side stays at 64 or more).
    static func variantBaseTexture(_ data: Data) throws -> Data {
        if isTEX(data) { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw TextureVariantError.unsupportedTexture }
        var pixels = try rgba(image)
        var width = image.width, height = image.height
        var mipmaps: [TEXWriter.Mipmap] = []
        while true {
            // Halved from the bled level, so the fill doesn't darken the edges of the smaller ones.
            pixels = bledTransparentColors(pixels, width: width, height: height)
            guard let png = TEXVariantWriter.pngData(pixels, width: width, height: height) else {
                throw TextureVariantError.unsupportedTexture
            }
            // A picture's mipmap has no uncompressed size (0), as WE writes it.
            mipmaps.append(TEXWriter.Mipmap(width: width, height: height, compression: 0, uncompressedSize: 0, stored: Data(png)))
            guard min(width / 2, height / 2) >= smallestMipmapSide else { break }
            pixels = halved(pixels, width: width, height: height)
            width /= 2
            height /= 2
        }
        // The container holds PNGs.
        return TEXWriter.data(TEXWriter.Texture(format: 0, flags: TextureImportOptions().texFlags(), textureWidth: image.width,
                                                textureHeight: image.height, imageWidth: image.width, imageHeight: image.height,
                                                colorWord: 0xFF00_0000, freeImageFormat: TEXVariantWriter.pngFreeImageFormat,
                                                mipmaps: mipmaps))
    }

    /// An option's file as a variant-free texture of `layout`; incompatible when it isn't of the
    /// base's size and kind (WE: "It must have the same resolution and needs to be the same type").
    static func variantTexture(_ file: Data, like layout: TEXVariantWriter.Layout, option: UInt32) throws -> Data {
        let incompatible = TextureVariantError.incompatible(optionID: option)
        let isMovie = file.count > 12 && file[file.startIndex + 4..<file.startIndex + 8].elementsEqual("ftyp".utf8)
        if layout.isVideo {
            guard isMovie, let size = MP4TrackSize.pictureSize(of: file), size.width == layout.imageWidth,
                  size.height == layout.imageHeight else { throw incompatible }
            let levels = layout.images.map { levels in
                levels.map { TEXVariantWriter.Level(width: $0.width, height: $0.height, compression: 0, uncompressedSize: 0,
                                                    stored: [UInt8](file)) }
            }
            return layout.data(with: levels)
        }
        guard !isMovie, let source = CGImageSourceCreateWithData(file as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == layout.imageWidth, image.height == layout.imageHeight else { throw incompatible }
        let format: TextureImportOptions.Format? = layout.isPicture ? .rgba8888 : importFormat(layout.header.format)
        guard let format else { throw TextureVariantError.unsupportedTexture }
        let pixels = try rgba(image)
        // The first mipmap is the texture's size (DXT pads the picture to it, edge pixels repeated).
        let firstWidth = max(layout.textureWidth, image.width), firstHeight = max(layout.textureHeight, image.height)
        var first = padded(pixels, width: image.width, height: image.height, to: firstWidth, firstHeight)
        if layout.isPicture { first = bledTransparentColors(first, width: firstWidth, height: firstHeight) }
        var levels: [[TEXVariantWriter.Level]] = []
        for baseLevels in layout.images {
            var result: [TEXVariantWriter.Level] = []
            var current = first, width = firstWidth, height = firstHeight
            for level in baseLevels {
                // Halved as the importer halves its mipmaps while that reaches the size, else resampled.
                while width / 2 >= level.width, height / 2 >= level.height, width > 1 || height > 1 {
                    current = halved(current, width: width, height: height)
                    width = max(width / 2, 1)
                    height = max(height / 2, 1)
                }
                let texels = width == level.width && height == level.height
                    ? current : resized(current, width: width, height: height, to: level.width, level.height)
                if layout.isPicture {
                    guard let png = TEXVariantWriter.pngData(bledTransparentColors(texels, width: level.width, height: level.height),
                                                             width: level.width, height: level.height) else {
                        throw TextureVariantError.unsupportedTexture
                    }
                    result.append(TEXVariantWriter.Level(width: level.width, height: level.height, compression: 0,
                                                         uncompressedSize: 0, stored: png))
                } else {
                    let stored = Self.stored(texels, width: level.width, height: level.height, format: format)
                    result.append(TEXVariantWriter.Level(width: level.width, height: level.height, compression: 0,
                                                         uncompressedSize: stored.count, stored: stored))
                }
            }
            levels.append(result)
        }
        return layout.data(with: levels, freeImageFormat: layout.isPicture ? TEXVariantWriter.pngFreeImageFormat : nil)
    }

    /// WE's `bleedtransparentcolors` (on in its imports): the colour of fully transparent pixels
    /// filled in from the visible ones around them, so filtering and an alpha-blended option over
    /// them don't draw black. WE's own fill is a smooth spread of the nearby colours (capture 540's
    /// `variant_a.tex`); this is a pull-push fill with bilinear upsampling, which comes close
    /// [I: WE's algorithm and its slight darkening are not known]. Visible pixels stay as they are.
    static func bledTransparentColors(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else { return pixels }
        var colours = [Float](repeating: 0, count: width * height * 3)
        var weights = [Float](repeating: 0, count: width * height)
        var transparent = false
        for index in 0..<(width * height) {
            if pixels[index * 4 + 3] == 0 { transparent = true; continue }
            weights[index] = 1
            for channel in 0..<3 { colours[index * 3 + channel] = Float(pixels[index * 4 + channel]) }
        }
        guard transparent, weights.contains(1) else { return pixels }
        let filled = pullPush(colours, weights, width: width, height: height)
        var result = pixels
        for index in 0..<(width * height) where pixels[index * 4 + 3] == 0 {
            for channel in 0..<3 { result[index * 4 + channel] = UInt8(min(max(filled[index * 3 + channel].rounded(), 0), 255)) }
        }
        return result
    }

    /// Colours where `weights` is 0 filled from a half-size level of the weighted means, recursively.
    private static func pullPush(_ colours: [Float], _ weights: [Float], width: Int, height: Int) -> [Float] {
        guard width > 1 || height > 1 else { return colours }
        let halfWidth = (width + 1) / 2, halfHeight = (height + 1) / 2
        var sums = [Float](repeating: 0, count: halfWidth * halfHeight * 3)
        var counts = [Float](repeating: 0, count: halfWidth * halfHeight)
        for y in 0..<height {
            for x in 0..<width where weights[y * width + x] > 0 {
                let target = (y / 2) * halfWidth + x / 2
                counts[target] += 1
                for channel in 0..<3 { sums[target * 3 + channel] += colours[(y * width + x) * 3 + channel] }
            }
        }
        var coarseWeights = [Float](repeating: 0, count: halfWidth * halfHeight)
        for index in 0..<(halfWidth * halfHeight) where counts[index] > 0 {
            coarseWeights[index] = 1
            for channel in 0..<3 { sums[index * 3 + channel] /= counts[index] }
        }
        let coarse = pullPush(sums, coarseWeights, width: halfWidth, height: halfHeight)
        var result = colours
        for y in 0..<height {
            let sy = min(max((Float(y) + 0.5) / 2 - 0.5, 0), Float(halfHeight - 1))
            let y0 = Int(sy), y1 = min(y0 + 1, halfHeight - 1), fy = sy - Float(y0)
            for x in 0..<width where weights[y * width + x] == 0 {
                let sx = min(max((Float(x) + 0.5) / 2 - 0.5, 0), Float(halfWidth - 1))
                let x0 = Int(sx), x1 = min(x0 + 1, halfWidth - 1), fx = sx - Float(x0)
                for channel in 0..<3 {
                    func at(_ cx: Int, _ cy: Int) -> Float { coarse[(cy * halfWidth + cx) * 3 + channel] }
                    let top: Float = at(x0, y0) * (1 - fx) + at(x1, y0) * fx
                    let bottom: Float = at(x0, y1) * (1 - fx) + at(x1, y1) * fx
                    result[(y * width + x) * 3 + channel] = top * (1 - fy) + bottom * fy
                }
            }
        }
        return result
    }

    /// The importer's format for a `.tex` format word; nil for one it doesn't write (DXT3, float…).
    static func importFormat(_ format: UInt32) -> TextureImportOptions.Format? {
        TextureImportOptions.Format.allCases.first { $0.texFormat == format }
    }

    /// Straight RGBA scaled to another size (high-quality interpolation).
    static func resized(_ pixels: [UInt8], width: Int, height: Int, to newWidth: Int, _ newHeight: Int) -> [UInt8] {
        guard newWidth != width || newHeight != height else { return pixels }
        guard newWidth > 0, newHeight > 0, let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let context = CGContext(data: nil, width: newWidth, height: newHeight, bitsPerComponent: 8, bytesPerRow: newWidth * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return [UInt8](repeating: 0, count: max(newWidth, 0) * max(newHeight, 0) * 4)
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        guard let scaled = context.makeImage(),
              let result = OWELog.attempt(.texture, "Texture variant: scaling to \(newWidth)x\(newHeight)", { try rgba(scaled) }) else {
            return [UInt8](repeating: 0, count: newWidth * newHeight * 4)
        }
        return result
    }
}
