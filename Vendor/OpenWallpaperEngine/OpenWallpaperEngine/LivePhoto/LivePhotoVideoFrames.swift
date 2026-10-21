import AVFoundation
import CoreImage

/// A video wallpaper's frames for its Live Photo, in place of the scene renderer
/// (`LivePhotoRenderer.render`): the video decoded in order (`AVAssetReader`), sampled on the
/// clip's frame grid (frame `i` shows the video at `i / frameRate` s, the latest frame at or
/// before that time), looping as the wallpaper loops, turned as the file says it plays and cut
/// to the crop at its output size. The crop is measured in the video's pixels as it plays
/// (`SceneEditorModes.videoSize`), so the Live Photo's settings, still, movie and pairing are
/// exactly a scene's. Runs in the render helper, like a scene's render.
final class LivePhotoVideoFrames {
    enum Failure: LocalizedError {
        case noVideoTrack, unreadable

        var errorDescription: String? {
            String(localized: "The video couldn't be read for the Live Photo.")
        }
    }

    let url: URL
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(url: URL) {
        self.url = url
    }

    /// Hands frames `leadIn ..< leadIn + frames` of the `frameRate` grid, cut to `crop`, to `frame`.
    func render(crop: LivePhotoCrop, leadIn: Int, frames: Int, frameRate: Int, progress: (Double) -> Void,
                frame: (Int, CGImage) throws -> Void) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideoTrack }
        let (transform, range) = try await track.load(.preferredTransform, .timeRange)
        let duration = CMTimeGetSeconds(range.end)
        guard duration.isFinite, duration > 0 else { throw Failure.unreadable }
        let orientation = Self.orientation(of: transform)
        var cursor: Cursor?
        for index in 0..<frames {
            try Task.checkCancellation()
            let time = (Double(leadIn + index) / Double(max(frameRate, 1))).truncatingRemainder(dividingBy: duration)
            // The first frame, or the loop's start again: read from there.
            if cursor.map({ time < $0.time }) ?? true {
                cursor = try Cursor(asset: asset, track: track, from: time)
            }
            guard let buffer = cursor?.buffer(at: time),
                  let image = cut(CIImage(cvPixelBuffer: buffer).oriented(orientation), to: crop) else {
                throw Failure.unreadable
            }
            try frame(index, image)
            progress(Double(index + 1) / Double(max(frames, 1)))
            await Task.yield()
        }
    }

    /// The crop's window of `image` (the whole video as it plays), at the crop's output pixels.
    private func cut(_ image: CIImage, to crop: LivePhotoCrop) -> CGImage? {
        let extent = image.extent
        let scale = extent.width / crop.sceneSize.x
        let window = crop.cropRect
        // Core Image's origin is the bottom-left; the crop's the top-left.
        let source = CGRect(x: extent.minX + window.minX * scale, y: extent.maxY - window.maxY * scale,
                            width: window.width * scale, height: window.height * scale).intersection(extent)
        guard source.width > 0, source.height > 0 else { return nil }
        let output = CGRect(x: 0, y: 0, width: crop.outputPixels.x, height: crop.outputPixels.y)
        let fitted = image.cropped(to: source)
            .transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY)
                .concatenating(CGAffineTransform(scaleX: output.width / source.width, y: output.height / source.height)))
        return context.createCGImage(fitted, from: output, format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// The turn a track's transform makes (the quarter turns cameras and editors write).
    static func orientation(of transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a.rounded(), transform.b.rounded(), transform.c.rounded(), transform.d.rounded()) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        default: return .up
        }
    }

    /// The video read in order from a time: each request takes the latest frame at or before it.
    private final class Cursor {
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput
        private var current: CMSampleBuffer?
        private var upcoming: CMSampleBuffer?
        /// The last time asked for.
        private(set) var time: Double

        init(asset: AVAsset, track: AVAssetTrack, from time: Double) throws {
            reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: time, preferredTimescale: 600), duration: .positiveInfinity)
            output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw Failure.unreadable }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? Failure.unreadable }
            self.time = time
        }

        deinit { reader.cancelReading() }

        func buffer(at time: Double) -> CVPixelBuffer? {
            self.time = time
            while true {
                if upcoming == nil { upcoming = output.copyNextSampleBuffer() }
                guard let next = upcoming else { break }
                guard CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(next)) <= time + 1e-6 else { break }
                current = next
                upcoming = nil
            }
            // A reader can start just after the time asked for: its first frame stands in.
            return (current ?? upcoming).flatMap(CMSampleBufferGetImageBuffer)
        }
    }
}
