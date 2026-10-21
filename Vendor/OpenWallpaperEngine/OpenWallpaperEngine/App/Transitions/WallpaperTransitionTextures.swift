import CoreGraphics
import Foundation
import ImageIO
import Metal

/// The two textures WE binds to its transition shader: g_Texture1Noise (`materials/util/noise.png`)
/// and g_Texture2Clouds (`materials/util/clouds_256.png`), which only Boilover (26) samples. They
/// come from the WE assets folder. Without one (CI, or before the user set up the assets) the
/// renderer makes textures of the same kind instead: uniform RGBA noise and a tiling fbm cloud
/// pattern, 256×256 and the same every time.
struct WallpaperTransitionTextures {
    enum Source: Equatable {
        case wallpaperEngine
        case generated
    }

    enum LoadError: Error, CustomStringConvertible {
        case unreadable(path: String)
        case texture(path: String)

        var description: String {
            switch self {
            case .unreadable(let path): return "\(path) can't be decoded as an image"
            case .texture(let path): return "no Metal texture could be made for \(path)"
            }
        }
    }

    static let noisePath = "materials/util/noise.png"
    static let cloudsPath = "materials/util/clouds_256.png"
    static let generatedSize = 256

    let noise: MTLTexture
    let clouds: MTLTexture
    let source: Source

    /// WE's files from `assetsDirectory` when both are there, else the generated pair. A file that
    /// is there but can't be read throws.
    static func load(device: MTLDevice, assetsDirectory: URL?) throws -> WallpaperTransitionTextures {
        let directories = assetsDirectory.map { [$0] } ?? []
        if let noiseURL = WallpaperEngineAssets.locate([noisePath], in: directories),
           let cloudsURL = WallpaperEngineAssets.locate([cloudsPath], in: directories) {
            return WallpaperTransitionTextures(noise: try texture(contentsOf: noiseURL, device: device),
                                               clouds: try texture(contentsOf: cloudsURL, device: device),
                                               source: .wallpaperEngine)
        }
        OWELog.info(.app, "Transition textures: \(noisePath) and \(cloudsPath) aren't in the WE assets; using generated noise and clouds")
        let size = generatedSize
        return WallpaperTransitionTextures(
            noise: try texture(rgba: generatedNoise(size: size), width: size, height: size, device: device, path: noisePath),
            clouds: try texture(rgba: generatedClouds(size: size), width: size, height: size, device: device, path: cloudsPath),
            source: .generated)
    }

    // MARK: - Files

    private static func texture(contentsOf url: URL, device: MTLDevice) throws -> MTLTexture {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw LoadError.unreadable(path: url.path)
        }
        let rgba = try storedRGBA(of: image) ?? drawnRGBA(of: image, path: url.path)
        return try texture(rgba: rgba, width: image.width, height: image.height, device: device, path: url.path)
    }

    /// The texels as stored, for 8-bit RGB(A) with straight alpha (WE's PNGs): no colour matching
    /// and no premultiplying, as WE uploads them. Nil for any other layout.
    private static func storedRGBA(of image: CGImage) -> [UInt8]? {
        let byteOrder = image.bitmapInfo.intersection(.byteOrderMask)
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 24 || image.bitsPerPixel == 32,
              byteOrder == [] || byteOrder == .byteOrder32Big,
              [.none, .noneSkipLast, .last].contains(image.alphaInfo),
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let channels = image.bitsPerPixel / 8
        var rgba = [UInt8](repeating: 255, count: image.width * image.height * 4)
        for y in 0..<image.height {
            let row = bytes + y * image.bytesPerRow
            for x in 0..<image.width {
                let source = row + x * channels
                let target = (y * image.width + x) * 4
                rgba[target] = source[0]
                rgba[target + 1] = source[1]
                rgba[target + 2] = source[2]
                if image.alphaInfo == .last { rgba[target + 3] = source[3] }
            }
        }
        return rgba
    }

    /// Any other layout, drawn into RGBA8 in the image's own RGB space (premultiplied, as Core
    /// Graphics draws).
    private static func drawnRGBA(of image: CGImage, path: String) throws -> [UInt8] {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let space, let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                                     bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw LoadError.unreadable(path: path) }
        return rgba
    }

    private static func texture(rgba: [UInt8], width: Int, height: Int, device: MTLDevice, path: String) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw LoadError.texture(path: path) }
        texture.label = path
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: rgba, bytesPerRow: width * 4)
        return texture
    }

    // MARK: - Generated

    /// Uniform noise in every channel, as noise.png holds.
    static func generatedNoise(size: Int) -> [UInt8] {
        (0..<(size * size * 4)).map { UInt8(truncatingIfNeeded: hash(UInt32($0) &+ 0x6E6F_6973) >> 24) }
    }

    /// Grey fbm clouds that tile, as clouds_256.png holds: five octaves of smoothed value noise on
    /// wrapping lattices, stretched to the full 0…255 range.
    static func generatedClouds(size: Int) -> [UInt8] {
        var values = [Float](repeating: 0, count: size * size)
        var amplitude: Float = 0.5
        var lattice = 4
        for octave in 0..<5 {
            for y in 0..<size {
                for x in 0..<size {
                    values[y * size + x] += amplitude * valueNoise(x: x, y: y, size: size, lattice: lattice, octave: octave)
                }
            }
            amplitude *= 0.5
            lattice *= 2
        }
        let low = values.min() ?? 0
        let range = max((values.max() ?? 1) - low, 1e-6)
        var rgba = [UInt8](repeating: 255, count: size * size * 4)
        for (index, value) in values.enumerated() {
            let level = UInt8(((value - low) / range * 255).rounded())
            rgba[index * 4] = level
            rgba[index * 4 + 1] = level
            rgba[index * 4 + 2] = level
        }
        return rgba
    }

    private static func valueNoise(x: Int, y: Int, size: Int, lattice: Int, octave: Int) -> Float {
        let cell = Float(size) / Float(lattice)
        let fx = Float(x) / cell, fy = Float(y) / cell
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let tx = smooth(fx - Float(x0)), ty = smooth(fy - Float(y0))
        func corner(_ cx: Int, _ cy: Int) -> Float {
            let key = UInt32((cy % lattice) * lattice + cx % lattice) &+ UInt32(octave) &* 0x9E37_79B9
            return Float(hash(key) >> 8) / Float(1 << 24)
        }
        let top = corner(x0, y0) + (corner(x0 + 1, y0) - corner(x0, y0)) * tx
        let bottom = corner(x0, y0 + 1) + (corner(x0 + 1, y0 + 1) - corner(x0, y0 + 1)) * tx
        return top + (bottom - top) * ty
    }

    private static func smooth(_ t: Float) -> Float { t * t * (3 - 2 * t) }

    /// A 32-bit integer hash (lowbias32).
    private static func hash(_ value: UInt32) -> UInt32 {
        var x = value
        x ^= x >> 16
        x = x &* 0x7FEB_352D
        x ^= x >> 15
        x = x &* 0x846C_A68B
        x ^= x >> 16
        return x
    }
}
