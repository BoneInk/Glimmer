import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The picture the MCP Server plugin's snapshot returns, from what the app already keeps: a
/// scene's loading snapshot (its own frame, `SceneLoadingSnapshotStore`), a video's frame, else the
/// wallpaper's preview. Nothing is rendered for it. Blocking IO: call it off the main thread.
enum ControlSnapshotPicture {
    static let maxWidth = 960

    enum Source: String {
        case loadingSnapshot = "loading_snapshot"
        case videoFrame = "video_frame"
        case preview
    }

    /// The best picture of `wallpaper` for a display of `pixelSize`, as a PNG at most `maxWidth` wide.
    static func make(wallpaperDirectory: URL, type: String, mediaURL: URL?, previewURL: URL?,
                     pixelSize: SIMD2<Int>, store: SceneLoadingSnapshotStore = .current) -> (png: Data, width: Int, height: Int, source: Source)? {
        ThreadGuards.assertBackground("ControlSnapshotPicture.make")
        var candidates: [(Source, () -> CGImage?)] = []
        if type == "scene" {
            candidates.append((.loadingSnapshot, {
                store.bestSnapshot(forWallpaperAt: wallpaperDirectory, pixelSize: pixelSize).flatMap(image(at:))
            }))
        }
        if type == "video", let mediaURL, mediaURL.isFileURL {
            candidates.append((.videoFrame, { videoFrame(mediaURL) }))
        }
        if let previewURL {
            candidates.append((.preview, { image(at: previewURL) }))
        }
        for (source, load) in candidates {
            guard let picture = load(), let scaled = scaled(picture), let png = png(scaled) else { continue }
            return (png, scaled.width, scaled.height, source)
        }
        return nil
    }

    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func videoFrame(_ url: URL) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)
        do {
            return try generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
        } catch {
            OWELog.info(.app, "MCP snapshot: no frame of \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    /// `image` at most `maxWidth` wide, keeping its aspect.
    static func scaled(_ image: CGImage) -> CGImage? {
        guard image.width > maxWidth else { return image }
        let width = maxWidth
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
