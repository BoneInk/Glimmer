import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes what the editor's renderer drew into a WE thumbnail: the scene's centre square as
/// `preview.jpg`, or frames of it as `preview.gif`, each kept under Steam's 1 MB limit.
public enum ThumbnailEncoder {
    public enum Failure: Error, Equatable {
        case noFrames
        case encodingFailed
    }

    /// The JPEG quality a snapshot starts at; it steps down only for a still over Steam's limit.
    static let jpegQuality = 0.9

    /// Take Snapshot: the centre square of `image` at `side` pixels, as `preview.jpg`.
    public static func snapshot(_ image: CGImage, side: Int) throws -> WallpaperThumbnail {
        guard let square = centreSquare(image, side: side) else { throw Failure.encodingFailed }
        var quality = jpegQuality
        while true {
            let data = try jpeg(square, quality: quality)
            if data.count <= WallpaperThumbnail.steamSizeLimit || quality <= 0.31 {
                return WallpaperThumbnail(kind: .image, data: data, side: side)
            }
            quality -= 0.1
        }
    }

    /// Record GIF: `frames` (the scene drawn at `format`'s rate) as `preview.gif`. As WE's encoder
    /// does, a GIF over Steam's limit is made again 32 pixels smaller with 128 colours until it
    /// fits (WE's 256-pixel GIFs come out at 224, 192 or 160 that way).
    public static func gif(_ frames: [CGImage], format: GIFRecordingFormat) throws -> WallpaperThumbnail {
        guard !frames.isEmpty else { throw Failure.noFrames }
        var side = format.side
        var colors = 256
        while true {
            let pixels = try frames.map { image -> GIFEncoder.Frame in
                guard let square = centreSquare(image, side: side), let frame = rgba(square) else { throw Failure.encodingFailed }
                return frame
            }
            let data = GIFEncoder.encode(pixels, colors: colors, delay: format.delayCentiseconds, dithered: format.dithered)
            if data.count <= WallpaperThumbnail.steamSizeLimit || side - 32 < 64 {
                return WallpaperThumbnail(kind: .gif, data: data, side: side)
            }
            side -= 32
            colors = 128
        }
    }

    /// The largest centred square of `image`, scaled to `side` pixels, in sRGB.
    static func centreSquare(_ image: CGImage, side: Int) -> CGImage? {
        let short = min(image.width, image.height)
        guard short > 0, side > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let scale = Double(side) / Double(short)
        let width = Double(image.width) * scale, height = Double(image.height) * scale
        context.draw(image, in: CGRect(x: (Double(side) - width) / 2, y: (Double(side) - height) / 2, width: width, height: height))
        return context.makeImage()
    }

    private static func rgba(_ image: CGImage) -> GIFEncoder.Frame? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? GIFEncoder.Frame(width: width, height: height, rgba: pixels) : nil
    }

    private static func jpeg(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
        return data as Data
    }
}
