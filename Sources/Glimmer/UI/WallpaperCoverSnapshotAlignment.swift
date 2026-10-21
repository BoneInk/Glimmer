import AppKit

/// A poster is often a center crop of the authored wallpaper. Validate that
/// relationship against the actual rendered frame rather than assuming its
/// aspect ratio describes the live canvas. Unrelated artwork uses a blend.
enum WallpaperCoverSnapshotAlignment {
    struct Match {
        let sourceFrame: CGRect
        let meanError: Double
    }
    static func match(source: NSImage, target: NSImage, in container: CGRect) -> Match? {
        guard let a = pixels(source), let b = pixels(target) else { return nil }
        let candidates: [WallpaperCoverContentMode] = [.fit, .fill]
        let matches = candidates.compactMap { mode -> Match? in
            let rect = WallpaperCoverTransitionGeometry.imageFrame(imageSize: source.size, container: container, mode: mode)
            var error = 0.0, count = 0
            // Bound the work independently of source/snapshot resolution.
            for row in 1..<32 {
                for column in 1..<32 {
                    let u = CGFloat(column) / 32, v = CGFloat(row) / 32
                    let x = rect.minX + rect.width * u, y = rect.minY + rect.height * v
                    guard container.contains(CGPoint(x: x, y: y)) else { continue }
                    let ap = a.color(u, v), bp = b.color((x - container.minX) / container.width, (y - container.minY) / container.height)
                    error += Double(abs(Int(ap.0) - Int(bp.0)) + abs(Int(ap.1) - Int(bp.1)) + abs(Int(ap.2) - Int(bp.2))) / 3
                    count += 1
                }
            }
            guard count > 240 else { return nil }
            return Match(sourceFrame: rect, meanError: error / Double(count))
        }
        guard let best = matches.min(by: { $0.meanError < $1.meanError }), best.meanError < 18 else { return nil }
        return best
    }
    private struct Pixels {
        let width: Int, height: Int, bytes: [UInt8]
        func color(_ u: CGFloat, _ v: CGFloat) -> (UInt8, UInt8, UInt8) {
            let x = min(width - 1, max(0, Int(u * CGFloat(width))))
            let y = min(height - 1, max(0, Int(v * CGFloat(height))))
            let index = (y * width + x) * 4
            return (bytes[index], bytes[index + 1], bytes[index + 2])
        }
    }
    private static func pixels(_ image: NSImage) -> Pixels? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ratio = min(1, 320 / CGFloat(max(cg.width, cg.height)))
        let width = max(1, Int(CGFloat(cg.width) * ratio)), height = max(1, Int(CGFloat(cg.height) * ratio))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? Pixels(width: width, height: height, bytes: bytes) : nil
    }
}
