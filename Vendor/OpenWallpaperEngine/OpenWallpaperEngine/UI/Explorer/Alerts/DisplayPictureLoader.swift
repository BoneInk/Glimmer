import AVFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Loads Display Settings' miniature of a display (`DisplayWallpaperPicture`): chooses its source
/// (`DisplayPictureSource`) and decodes it with ImageIO at the size it is drawn, never the
/// picture's own. Decoded pictures stay in memory, keyed by file, file version and decode size.
///
/// A video wallpaper's frame is grabbed once, at most `videoFrameMaxPixelSize` on its longest
/// side, and kept in `<Caches>/Open Wallpaper Engine/DisplayPictures/r<revision>/` as
/// `<video key>-<content key>.jpg`; a changed video replaces its old frame.
///
/// Blocking file IO and decoding: call it off the main thread.
struct DisplayPictureLoader: Sendable {
    /// Bump when the stored video frames change meaning (time, size, encoding, names).
    static let revision = 1
    static let videoFrameMaxPixelSize = 1280

    // NSCache is thread-safe and evicts under memory pressure.
    private static let images = NSCache<NSString, CGImage>()

    let snapshots: SceneLoadingSnapshotStore
    /// This revision's folder of video frames.
    let videoFrames: URL

    static var current: DisplayPictureLoader {
        DisplayPictureLoader(cachesDirectory: AppStorageLocation.current.cachesDirectory)
    }

    init(cachesDirectory: URL) {
        snapshots = SceneLoadingSnapshotStore(cachesDirectory: cachesDirectory)
        videoFrames = cachesDirectory.appending(path: "Open Wallpaper Engine/DisplayPictures/r\(Self.revision)",
                                                directoryHint: .isDirectory)
    }

    struct Request: Hashable, Sendable {
        var wallpaperDirectory: URL
        var type: String
        var mediaURL: URL
        var preview: URL?
        /// The display's size in pixels: the snapshot to look for.
        var displayPixelSize: SIMD2<Int>
        /// The miniature's size in points, and the pixels per point it is drawn at.
        var frame: CGSize
        var scale: CGFloat
        var placement: WallpaperPlacement
    }

    struct Picture {
        var image: CGImage
        var placement: WallpaperPlacement
    }

    func load(_ request: Request) async -> Picture? {
        let source = await source(for: request)
        guard let url = source.url else { return nil }
        let placement = source.placement(request.placement)
        guard let image = Self.decode(url, frame: request.frame, placement: placement, scale: request.scale) else { return nil }
        return Picture(image: image, placement: placement)
    }

    func source(for request: Request) async -> DisplayPictureSource {
        ThreadGuards.assertBackground("display picture lookup")
        var exact: URL?
        var other: URL?
        if request.type.caseInsensitiveCompare("scene") == .orderedSame,
           let best = snapshots.bestSnapshot(forWallpaperAt: request.wallpaperDirectory, pixelSize: request.displayPixelSize) {
            if SceneLoadingSnapshotStore.entry(best)?.pixelSize == request.displayPixelSize { exact = best } else { other = best }
        }
        let media = request.mediaURL
        return await DisplayPictureSource.choose(type: request.type, exactSnapshot: exact, otherSnapshot: other,
                                                 videoFrame: { await videoFrame(of: media) }, preview: request.preview)
    }

    // MARK: Video frames

    func videoFrameURL(of video: URL) -> URL? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let values: URLResourceValues
        do { values = try video.resourceValues(forKeys: keys) } catch {
            OWELog.error(.ui, "Display picture: can't read \(video.lastPathComponent): \(error)")
            return nil
        }
        let modified = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let content = Self.hex("\(values.fileSize ?? 0)|\(modified)")
        return videoFrames.appending(path: "\(Self.videoKey(video))-\(content).jpg", directoryHint: .notDirectory)
    }

    static func videoKey(_ video: URL) -> String { hex(video.standardizedFileURL.path(percentEncoded: false)) }

    private static func hex(_ text: String) -> String {
        Digest.hex(SHA256.hash(data: Data(text.utf8)).prefix(8))
    }

    /// The video's stored frame, grabbed and stored first when there is none for its current file.
    func videoFrame(of video: URL) async -> URL? {
        guard let url = videoFrameURL(of: video) else { return nil }
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: Self.videoFrameMaxPixelSize, height: Self.videoFrameMaxPixelSize)
        // The first key frame: no decoding up to an exact time.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        let image: CGImage
        do { image = try await generator.image(at: .zero).image } catch {
            // AVFoundation can't decode every video (WebM plays through WebKit): use the preview.
            OWELog.info(.ui, "Display picture: no frame of \(video.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
        do {
            try write(image, to: url)
        } catch {
            OWELog.error(.ui, "Display picture: can't store the frame of \(video.lastPathComponent): \(error)")
            return nil
        }
        removeOtherFrames(of: video, keeping: url)
        return url
    }

    private func write(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: videoFrames, withIntermediateDirectories: true)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try (data as Data).write(to: url, options: .atomic)
    }

    /// Frames of the video's older contents, and older revisions' folders.
    private func removeOtherFrames(of video: URL, keeping kept: URL) {
        let fileManager = FileManager.default
        let prefix = Self.videoKey(video) + "-"
        let root = videoFrames.deletingLastPathComponent()
        var stale: [URL] = []
        // Optional: nothing to remove when a folder can't be listed.
        if let revisions = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            stale += revisions.filter { $0.lastPathComponent != videoFrames.lastPathComponent }
        }
        if let frames = try? fileManager.contentsOfDirectory(at: videoFrames, includingPropertiesForKeys: nil) {
            stale += frames.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent != kept.lastPathComponent }
        }
        for url in stale {
            do { try fileManager.removeItem(at: url) } catch CocoaError.fileNoSuchFile {
                // Removed meanwhile.
            } catch {
                OWELog.error(.ui, "Display picture: can't remove \(url.lastPathComponent): \(error)")
            }
        }
    }

    // MARK: Decoding

    /// The picture at `url`, decoded at the size it is drawn in `frame` with `placement`.
    static func decode(_ url: URL, frame: CGSize, placement: WallpaperPlacement, scale: CGFloat) -> CGImage? {
        ThreadGuards.assertBackground("display picture decode")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let size = pixelSize(of: source) else {
            OWELog.error(.ui, "Display picture: can't read \(url.lastPathComponent)")
            return nil
        }
        let maxPixelSize = DisplayPictureGeometry.decodePixelSize(image: size, in: frame, placement: placement, scale: scale)
        // A rewritten file is a new file: its creation date changes (writes are atomic).
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey]) // Optional: part of the key only.
        let version = "\(values?.creationDate?.timeIntervalSinceReferenceDate ?? 0)|\(values?.fileSize ?? 0)"
        let key = "\(url.path(percentEncoded: false))|\(version)|\(maxPixelSize)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            OWELog.error(.ui, "Display picture: can't decode \(url.lastPathComponent)")
            return nil
        }
        images.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    /// The first image's size as shown (EXIF orientation applied), read without decoding it.
    private static func pixelSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }
}
