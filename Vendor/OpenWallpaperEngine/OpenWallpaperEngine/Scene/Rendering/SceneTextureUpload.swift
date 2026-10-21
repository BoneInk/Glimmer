import Accelerate
import MetalKit

/// Uploads decoded images the way WE's textures hold them: straight (not premultiplied) alpha,
/// with the stored colour values as they are (no colour management).
///
/// `MTKTextureLoader` copies a `CGImage`'s bytes unchanged. That is right for straight-alpha
/// images, but CoreText output and some decoded files are premultiplied, and WE's shaders and
/// blend modes (`SrcAlpha, InvSrcAlpha`) would apply their alpha a second time, darkening
/// semi-transparent edges. Those are unpremultiplied here first, in their own colour space.
enum SceneTextureUpload {
    static func texture(from image: CGImage, loader: MTKTextureLoader, device: MTLDevice) throws -> MTLTexture {
        guard isPremultiplied(image) else {
            return try loader.newTexture(cgImage: image, options: [MTKTextureLoader.Option.SRGB: false])
        }
        let bytes = try straightRGBA(image)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: image.width,
                                                                  height: image.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw UploadError.allocation(image.width, image.height)
        }
        bytes.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: image.width * 4)
        }
        return texture
    }

    static func isPremultiplied(_ image: CGImage) -> Bool {
        image.alphaInfo == .premultipliedLast || image.alphaInfo == .premultipliedFirst
    }

    /// The image as tightly packed RGBA8 rows with straight alpha, in its own RGB colour space.
    static func straightRGBA(_ image: CGImage) throws -> [UInt8] {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        guard let format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: space,
                                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
                                                    .union(.byteOrder32Big)) else {
            throw UploadError.unsupported(image.bitsPerPixel)
        }
        var buffer = try vImage_Buffer(cgImage: image, format: format)
        defer { buffer.free() }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rowBytes = image.width * 4
        let source = buffer.data.assumingMemoryBound(to: UInt8.self)
        bytes.withUnsafeMutableBytes { destination in
            for row in 0..<image.height {
                (destination.baseAddress! + row * rowBytes).copyMemory(from: source + row * buffer.rowBytes,
                                                                        byteCount: rowBytes)
            }
        }
        return bytes
    }

    /// White text as WE's `font` shader samples its glyph atlas: one channel of coverage
    /// (`ConvertSampleR8`), from the raster's alpha. nil when the raster holds colour (colour
    /// glyphs such as emoji), which a coverage mask would lose.
    static func coverageTexture(from image: CGImage, device: MTLDevice) throws -> MTLTexture? {
        guard let coverage = try whiteCoverage(image) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: image.width,
                                                                  height: image.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw UploadError.allocation(image.width, image.height)
        }
        coverage.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: image.width)
        }
        return texture
    }

    /// The alpha of a premultiplied white raster, row by row; nil when any texel isn't grey at its
    /// own coverage (premultiplied white is r = g = b = a).
    static func whiteCoverage(_ image: CGImage) throws -> [UInt8]? {
        let width = image.width, height = image.height
        var texels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = texels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw UploadError.unsupported(image.bitsPerPixel) }
        // Runs on the render thread whenever a text layer's string changes (a score, a clock), so it
        // walks raw buffers: the indexed, generic loop took ~100 ms for a 5K-sized label.
        let count = width * height
        var coverage = [UInt8](repeating: 0, count: count)
        let grey = texels.withUnsafeBufferPointer { source -> Bool in
            coverage.withUnsafeMutableBufferPointer { target -> Bool in
                var texel = 0
                for index in 0..<count {
                    let alpha = Int16(source[texel + 3])
                    if abs(Int16(source[texel]) &- alpha) > 2 || abs(Int16(source[texel + 1]) &- alpha) > 2
                        || abs(Int16(source[texel + 2]) &- alpha) > 2 { return false }
                    target[index] = UInt8(truncatingIfNeeded: alpha)
                    texel &+= 4
                }
                return true
            }
        }
        return grey ? coverage : nil
    }

    // MARK: Block-compressed textures

    /// The Metal format and block size of a block-compressed `.tex` format; nil for others.
    static func blockFormat(for format: UInt32) -> (pixelFormat: MTLPixelFormat, bytesPerBlock: Int)? {
        switch format {
        case 4: return (.bc3_rgba, 16)   // DXT5
        case 6: return (.bc2_rgba, 16)   // DXT3
        case 7: return (.bc1_rgba, 8)    // DXT1
        case TEXCompressedTexture.bc7Format: return (.bc7_rgbaUnorm, 16)
        default: return nil
        }
    }

    /// Uploads textures that share a prepared blob once: identical images in several layers,
    /// materials or wallpapers get the same texture while any of them holds it.
    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static let shared = NSMapTable<NSString, MTLTexture>.strongToWeakObjects()

    /// `source` as a block-compressed texture with every mipmap it carries (`levels`), or nil when
    /// the device can't sample its format or its data is short. The level count stops at the
    /// first level whose data is short, so a partial chain still uploads what it has.
    static func blockCompressedTexture(_ source: TEXCompressedTexture, device: MTLDevice) -> MTLTexture? {
        guard device.supportsBCTextureCompression, let format = blockFormat(for: source.format),
              source.width > 0, source.height > 0 else { return nil }
        let sharedKey = source.sourceKey.map { "\($0)|\(device.registryID)" as NSString }
        if let sharedKey {
            sharedLock.lock()
            let existing = shared.object(forKey: sharedKey)
            sharedLock.unlock()
            if let existing { return existing }
        }
        var levels: [(data: Data, width: Int, height: Int, rowBytes: Int)] = []
        for (index, data) in source.levels.enumerated() {
            let width = max(1, source.width >> index), height = max(1, source.height >> index)
            let rowBytes = ((width + 3) / 4) * format.bytesPerBlock
            // A truncated payload would read out of bounds inside replace(region:).
            guard data.count >= rowBytes * ((height + 3) / 4) else { break }
            levels.append((data, width, height, rowBytes))
        }
        guard !levels.isEmpty else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format.pixelFormat, width: source.width,
                                                                  height: source.height, mipmapped: levels.count > 1)
        descriptor.mipmapLevelCount = levels.count
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        for (index, level) in levels.enumerated() {
            level.data.withUnsafeBytes { raw in
                texture.replace(region: MTLRegionMake2D(0, 0, level.width, level.height), mipmapLevel: index,
                                withBytes: raw.baseAddress!, bytesPerRow: level.rowBytes)
            }
        }
        if let sharedKey {
            sharedLock.lock()
            defer { sharedLock.unlock() }
            if let raced = shared.object(forKey: sharedKey) { return raced }
            shared.setObject(texture, forKey: sharedKey)
        }
        return texture
    }

    enum UploadError: Error, CustomStringConvertible {
        case allocation(Int, Int)
        case unsupported(Int)

        var description: String {
            switch self {
            case let .allocation(width, height): return "could not allocate a \(width)×\(height) texture"
            case let .unsupported(bits): return "no RGBA conversion for a \(bits)-bit image"
            }
        }
    }
}
