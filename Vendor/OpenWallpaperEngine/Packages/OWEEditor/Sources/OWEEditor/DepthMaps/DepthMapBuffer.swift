import CoreGraphics
import Foundation
import OWESceneEditing

/// One channel of floats, row-major from the top-left: a depth map, or a picture's luminance.
public struct DepthMapBuffer: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var values: [Float]

    public init(width: Int, height: Int, values: [Float]) {
        precondition(values.count == width * height, "a depth map needs width × height values")
        self.width = width
        self.height = height
        self.values = values
    }

    public init(width: Int, height: Int, repeating value: Float = 0) {
        self.init(width: width, height: height, values: Array(repeating: value, count: width * height))
    }

    public subscript(x: Int, y: Int) -> Float {
        get { values[y * width + x] }
        set { values[y * width + x] = newValue }
    }

    // MARK: Pictures

    /// The picture's luminance (Rec. 709, sRGB values), 0…1, at its own size. Transparent pixels
    /// count as black, as they show the layer's nothing.
    public static func luminance(of image: CGImage) -> DepthMapBuffer? {
        guard let pixels = rgba(of: image) else { return nil }
        let count = image.width * image.height
        var values = [Float](repeating: 0, count: count)
        pixels.withUnsafeBufferPointer { bytes in
            for index in 0..<count {
                let offset = index * 4
                let r = Float(bytes[offset]), g = Float(bytes[offset + 1]), b = Float(bytes[offset + 2])
                values[index] = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
            }
        }
        return DepthMapBuffer(width: image.width, height: image.height, values: values)
    }

    /// The picture as premultiplied RGBA8 in sRGB.
    public static func rgba(of image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// An 8-bit grey picture of the values (0…1, clamped).
    public func grayImage() -> CGImage? {
        let bytes = values.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        // Device grey, as a painted mask is: the loader reads the bytes as they are (r8).
        let space = CGColorSpaceCreateDeviceGray()
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The grey picture as PNG: the depth map's file (`format: r8`).
    public func pngData() -> Data? {
        grayImage().flatMap(EditorAssetStore.pngData)
    }

    /// A grey picture's values, 0…1 (the cache's files).
    public static func gray(of image: CGImage) -> DepthMapBuffer? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return DepthMapBuffer(width: width, height: height, values: bytes.map { Float($0) / 255 })
    }
}
