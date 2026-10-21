import AppKit

/// Texture 0 as the renderer's built-in particle draw samples it. WE's particle shaders convert
/// their albedo by `TEX0FORMAT` (`ConvertTexture0Format`), which the built-in draw doesn't. An
/// RG88 albedo, loaded as (r, g, 0, 1) like the GPU samples it, is expanded here to the
/// luminance and alpha (`.rrrg`) the shaders would read; an R8 one, loaded as (r, 0, 0, 1), to
/// white with coverage `r` (`(1, 1, 1, r)`).
enum ParticleFallbackTexture {
    /// The built-in draw's copy of `source` when its format needs converting; nil when the
    /// source draws as it is (or can't be read, which the caller's own upload reports).
    static func converted(_ source: SceneMetalTextureSource, format: TEXImageFormat?) -> SceneMetalTextureSource? {
        guard let format, format.isChannelReduced else { return nil }
        let convert = { (image: NSImage) in luminanceAlpha(image, format: format) }
        switch source {
        case let .image(image):
            return convert(image).map(SceneMetalTextureSource.image)
        case let .animated(animation):
            let images = animation.images.compactMap(convert)
            guard images.count == animation.images.count else { return nil }
            return .animated(TEXAnimatedImages(images: images, frames: animation.frames))
        case .dxt, .video, .uploaded:
            return nil
        }
    }

    /// `image` as `ConvertTexture0Format` reads it: red as luminance (rgb) and green as alpha for
    /// RG88, white with red as alpha for R8.
    static func luminanceAlpha(_ image: NSImage, format: TEXImageFormat) -> NSImage? {
        guard let cgImage = image.oweCGImage else { return nil }
        let bytes: [UInt8]
        do {
            bytes = try SceneTextureUpload.straightRGBA(cgImage)
        } catch {
            OWELog.error(.scene, "Format \(format.rawValue) particle texture can't be expanded for the built-in draw: \(error)")
            return nil
        }
        var expanded = bytes
        let isR8 = format == .r8
        for pixel in 0..<(bytes.count / 4) {
            let red = bytes[pixel * 4]
            let luminance: UInt8 = isR8 ? 255 : red
            expanded[pixel * 4] = luminance
            expanded[pixel * 4 + 1] = luminance
            expanded[pixel * 4 + 2] = luminance
            expanded[pixel * 4 + 3] = isR8 ? red : bytes[pixel * 4 + 1]
        }
        let width = cgImage.width, height = cgImage.height
        guard let provider = CGDataProvider(data: Data(expanded) as CFData),
              let converted = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
                                          .union(.byteOrder32Big),
                                      provider: provider, decode: nil, shouldInterpolate: true,
                                      intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: converted, size: image.size)
    }
}
