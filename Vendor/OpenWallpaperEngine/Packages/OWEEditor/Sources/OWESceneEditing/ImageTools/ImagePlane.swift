import Foundation

/// One channel of an image as 32-bit floats, top row first: the working buffer of the image tools
/// (normal map generation, foreground separation, character sheets), which follow the OpenCV
/// operations WE's editor runs on its pictures (`wallpaperui.exe`, OpenCV 4.4).
public struct ImagePlane: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height, "ImagePlane needs width × height pixels")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, value: Float = 0) {
        self.init(width: width, height: height, pixels: [Float](repeating: value, count: max(width, 0) * max(height, 0)))
    }

    public subscript(x: Int, y: Int) -> Float {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// The smallest and largest pixel (`cv::minMaxLoc`); (0, 0) for an empty plane.
    public var minMax: (min: Float, max: Float) {
        guard var low = pixels.first else { return (0, 0) }
        var high = low
        for value in pixels {
            if value < low { low = value }
            if value > high { high = value }
        }
        return (low, high)
    }

    /// `cv::normalize(…, NORM_MINMAX)`: the plane's range mapped onto `lower…upper`. A flat plane
    /// becomes `lower` everywhere, as OpenCV's does.
    public func normalized(_ lower: Float = 0, _ upper: Float = 1) -> ImagePlane {
        let (low, high) = minMax
        let range = high - low
        let scale = range > 0 ? (upper - lower) / range : 0
        return map { (value: Float) -> Float in (value - low) * scale + lower }
    }

    public func map(_ transform: (Float) -> Float) -> ImagePlane {
        ImagePlane(width: width, height: height, pixels: pixels.map(transform))
    }

    /// The rectangle `x, y, width, height` of the plane (inside it).
    public func cropped(x: Int, y: Int, width cropWidth: Int, height cropHeight: Int) -> ImagePlane {
        var result = ImagePlane(width: cropWidth, height: cropHeight)
        for row in 0..<cropHeight {
            let from = (y + row) * width + x
            result.pixels.replaceSubrange(row * cropWidth..<(row + 1) * cropWidth, with: pixels[from..<from + cropWidth])
        }
        return result
    }

    /// `cv::copyMakeBorder`: `border` pixels added on every side.
    public func padded(by border: Int, mode: BorderMode) -> ImagePlane {
        let paddedWidth = width + 2 * border, paddedHeight = height + 2 * border
        var result = ImagePlane(width: paddedWidth, height: paddedHeight)
        let columns = (0..<paddedWidth).map { mode.index($0 - border, count: width) }
        for row in 0..<paddedHeight {
            guard let sourceRow = mode.index(row - border, count: height) else { continue }
            for column in 0..<paddedWidth {
                if let sourceColumn = columns[column] { result.pixels[row * paddedWidth + column] = pixels[sourceRow * width + sourceColumn] }
            }
        }
        return result
    }

    /// OpenCV's border modes for pixels outside the plane.
    public enum BorderMode: Sendable {
        /// `BORDER_CONSTANT` with 0.
        case zero
        /// `BORDER_REPLICATE`: the edge pixel repeated.
        case replicate
        /// `BORDER_REFLECT_101` (`BORDER_DEFAULT`): mirrored without repeating the edge.
        case reflect101

        /// The pixel index `index` reads, or nil for a constant border.
        func index(_ index: Int, count: Int) -> Int? {
            if index >= 0 && index < count { return index }
            switch self {
            case .zero: return nil
            case .replicate: return min(max(index, 0), count - 1)
            case .reflect101:
                guard count > 1 else { return 0 }
                let period = 2 * (count - 1)
                var folded = index % period
                if folded < 0 { folded += period }
                return folded < count ? folded : period - folded
            }
        }
    }
}

/// An 8-bit image with straight (not premultiplied) alpha, red first, top row first: what the
/// image tools read from a texture and write as a PNG.
public struct RGBAImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4, "RGBAImage needs width × height × 4 bytes")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: 0, count: width * height * 4))
    }

    /// Channel `channel` (0 red … 3 alpha) as floats 0…255.
    public func plane(_ channel: Int) -> ImagePlane {
        var plane = ImagePlane(width: width, height: height)
        for index in 0..<(width * height) { plane.pixels[index] = Float(pixels[index * 4 + channel]) }
        return plane
    }

    /// Whether any pixel is less than fully opaque.
    public var hasTransparency: Bool {
        stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 255 }
    }
}
