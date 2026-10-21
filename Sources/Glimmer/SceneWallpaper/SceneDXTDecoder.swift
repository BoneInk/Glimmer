// Original CPU decoder from Microsoft's BC1/BC2/BC3 public format descriptions.
// DXT1/3/5 map to BC1/2/3; returns straight-alpha, row-major RGBA8888.
import Foundation

struct SceneDXTDecoder {
    enum Format { case dxt1, dxt3, dxt5 }
    static func byteCount(width: Int, height: Int, format: Format) throws -> Int {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384 else { throw failure() }
        return ((width + 3) / 4) * ((height + 3) / 4) * (format == .dxt1 ? 8 : 16)
    }
    static func decode(_ data: Data, width: Int, height: Int, format: Format, maximumBytes: Int) throws -> Data {
        let expected = try byteCount(width: width, height: height, format: format)
        guard data.count == expected, width * height <= maximumBytes / 4 else { throw failure() }
        let source = [UInt8](data)
        var output = [UInt8](repeating: 0, count: width * height * 4)
        let columns = (width + 3) / 4, rows = (height + 3) / 4, stride = format == .dxt1 ? 8 : 16
        func little(_ position: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(UInt64(0)) { $0 | (UInt64(source[position + $1]) << (8 * $1)) }
        }
        func rgb(_ endpoint: Int) -> [Int] {
            let r = (endpoint >> 11) & 31, g = (endpoint >> 5) & 63, b = endpoint & 31
            return [(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2), 255]
        }
        for row in 0..<rows {
            try Task.checkCancellation()
            for column in 0..<columns {
                let start = (row * columns + column) * stride, colorStart = start + (format == .dxt1 ? 0 : 8)
                let c0 = Int(little(colorStart, 2)), c1 = Int(little(colorStart + 2, 2))
                let a = rgb(c0), b = rgb(c1)
                var palette = [a, b, [0,0,0,255], [0,0,0,255]]
                for channel in 0..<3 {
                    if c0 > c1 || format != .dxt1 {
                        palette[2][channel] = (2 * a[channel] + b[channel]) / 3
                        palette[3][channel] = (a[channel] + 2 * b[channel]) / 3
                    } else { palette[2][channel] = (a[channel] + b[channel]) / 2 }
                }
                if c0 <= c1 && format == .dxt1 { palette[3] = [0,0,0,0] }
                let colors = little(colorStart + 4, 4)
                var alphaPalette = [Int](repeating: 0, count: 8)
                var alphaBits: UInt64 = 0
                if format == .dxt5 {
                    alphaPalette[0] = Int(source[start]); alphaPalette[1] = Int(source[start + 1])
                    let x = alphaPalette[0], y = alphaPalette[1]
                    if x > y {
                        for i in 2..<8 { alphaPalette[i] = ((8-i)*x + (i-1)*y) / 7 }
                    } else {
                        for i in 2..<6 { alphaPalette[i] = ((6-i)*x + (i-1)*y) / 5 }
                        alphaPalette[6] = 0; alphaPalette[7] = 255
                    }
                    alphaBits = little(start + 2, 6)
                } else if format == .dxt3 { alphaBits = little(start, 8) }
                for index in 0..<16 {
                    let x = column * 4 + index % 4, y = row * 4 + index / 4
                    guard x < width, y < height else { continue }
                    var color = palette[Int((colors >> (2*index)) & 3)]
                    if format == .dxt3 { color[3] = Int((alphaBits >> (4*index)) & 15) * 17 }
                    if format == .dxt5 { color[3] = alphaPalette[Int((alphaBits >> (3*index)) & 7)] }
                    let destination = (y * width + x) * 4
                    for channel in 0..<4 { output[destination + channel] = UInt8(color[channel]) }
                }
            }
        }
        return Data(output)
    }
    private static func failure() -> SceneWallpaperFailure {
        SceneWallpaperFailure(message: "Invalid or over-budget DXT TEX payload/dimensions.")
    }
}
