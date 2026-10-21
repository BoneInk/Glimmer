import AppKit
import Metal

/// A decoded .tex mipmap kept as its own 8-bit channels (RGBA8888, RG88 or R8), so the renderer
/// uploads it in that format with one copy instead of expanding it to RGBA and going through
/// `CGImage` and `MTKTextureLoader`. Metal samples a missing channel as 0 and alpha as 1, which is
/// the (r, g, 0, 1) and (r, 0, 0, 1) the RGBA expansion held, so shaders read the same values.
///
/// The rows keep the .tex allocation's stride (`rowPixels`); only the visible `pixelsWide` ×
/// `pixelsHigh` rect is the image, as the cropped `CGImage` was. Code that wants a `CGImage` (the
/// inspector, particle fallbacks) gets the RGBA expansion through `cgImage`, made on demand.
final class TEXRawImageRep: NSImageRep, @unchecked Sendable {
    enum Channels: Int {
        case r = 1, rg = 2, rgba = 4

        var pixelFormat: MTLPixelFormat {
            switch self {
            case .r: return .r8Unorm
            case .rg: return .rg8Unorm
            case .rgba: return .rgba8Unorm
            }
        }
    }

    let channels: Channels
    /// The pixels per stored row: the .tex allocation's width.
    let rowPixels: Int
    let bytes: [UInt8]

    init?(bytes: [UInt8], channels: Channels, rowPixels: Int, width: Int, height: Int) {
        guard width > 0, height > 0, rowPixels >= width,
              bytes.count >= rowPixels * (height - 1) * channels.rawValue + width * channels.rawValue else { return nil }
        self.bytes = bytes
        self.channels = channels
        self.rowPixels = rowPixels
        super.init()
        pixelsWide = width
        pixelsHigh = height
        size = NSSize(width: width, height: height)
        hasAlpha = channels == .rgba
        bitsPerSample = 8
    }

    required init?(coder: NSCoder) { nil }

    /// An image of these pixels backed by this representation.
    static func image(bytes: [UInt8], channels: Channels, rowPixels: Int, width: Int, height: Int) -> NSImage? {
        guard let rep = TEXRawImageRep(bytes: bytes, channels: channels, rowPixels: rowPixels,
                                       width: width, height: height) else { return nil }
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// The raw representation of `image`, when it is one.
    static func of(_ image: NSImage) -> TEXRawImageRep? {
        image.representations.count == 1 ? image.representations.first as? TEXRawImageRep : nil
    }

    /// The visible pixels as straight RGBA8 (R8 → (r, 0, 0, 255), RG88 → (r, g, 0, 255)), cropped
    /// from the stored rows, exactly as the parser's RGBA expansion held them.
    var cgImage: CGImage? {
        let width = pixelsWide, height = pixelsHigh
        let rgba: [UInt8]
        let stride: Int
        switch channels {
        case .rgba:
            rgba = bytes
            stride = rowPixels * 4
        case .rg, .r:
            let count = channels.rawValue
            var expanded = [UInt8](repeating: 0, count: width * height * 4)
            for row in 0..<height {
                for column in 0..<width {
                    let source = (row * rowPixels + column) * count
                    let target = (row * width + column) * 4
                    expanded[target] = bytes[source]
                    if count == 2 { expanded[target + 1] = bytes[source + 1] }
                    expanded[target + 3] = 255
                }
            }
            rgba = expanded
            stride = width * 4
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder32Big),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    override func draw() -> Bool {
        guard let image = cgImage, let context = NSGraphicsContext.current?.cgContext else { return false }
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return true
    }

    override func cgImage(forProposedRect proposedDestRect: UnsafeMutablePointer<NSRect>?,
                          context: NSGraphicsContext?, hints: [NSImageRep.HintKey: Any]?) -> CGImage? {
        cgImage
    }

    /// The rows the stored mipmap holds: the .tex allocation's height (at least the image's).
    var allocationRows: Int { max(pixelsHigh, bytes.count / (rowPixels * channels.rawValue)) }

    /// Whether the .tex allocation is larger than the image (a padded, power-of-two texture).
    var isPadded: Bool { rowPixels > pixelsWide || allocationRows > pixelsHigh }

    /// The image's share of the allocation, in UV units: (1, 1) when it fills it.
    var contentUVExtent: SIMD2<Float> {
        SIMD2(Float(pixelsWide) / Float(rowPixels), Float(pixelsHigh) / Float(allocationRows))
    }

    /// A shader-read texture of the whole allocation, the image in its top-left texels, as WE
    /// uploads a .tex and as a block-compressed one is uploaded here: a material that samples this
    /// texture and others at the same coordinates finds each image where WE does.
    func makeAllocationTexture(device: MTLDevice) -> MTLTexture? {
        guard isPadded else { return makeTexture(device: device) }
        let rows = allocationRows
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: channels.pixelFormat, width: rowPixels,
                                                                  height: rows, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        bytes.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, rowPixels, rows), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: rowPixels * channels.rawValue)
        }
        return texture
    }

    /// A shader-read texture of the visible pixels in their own channels.
    func makeTexture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: channels.pixelFormat, width: pixelsWide,
                                                                  height: pixelsHigh, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        bytes.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, pixelsWide, pixelsHigh), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: rowPixels * channels.rawValue)
        }
        return texture
    }
}

extension NSImage {
    /// The image's bitmap: a raw .tex representation's RGBA expansion, else AppKit's `CGImage`.
    var oweCGImage: CGImage? {
        if let raw = TEXRawImageRep.of(self) { return raw.cgImage }
        return cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
