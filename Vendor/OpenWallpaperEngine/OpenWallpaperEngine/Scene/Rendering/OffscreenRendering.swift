import AVFoundation
import CoreGraphics
import CoreVideo
import Metal

/// What the offscreen scene renders share (the Live Photo and Android exports, the depth map
/// capture, the Wallpaper Editor's previews): the app's settings read from its defaults, no
/// now-playing session, a frame handed over from the Metal thread, and the HEVC writer.
enum OffscreenRendering {
    static func globalSettings(from defaults: UserDefaults) -> GlobalSettings {
        guard let data = defaults.data(forKey: "GlobalSettings") else { return GlobalSettings() }
        do {
            return try JSONDecoder().decode(GlobalSettings.self, from: data)
        } catch {
            OWELog.error(.app, "Screen saver: can't read the settings, using the defaults: \(error)")
            return GlobalSettings()
        }
    }
}

/// No now-playing session: a saver plays without media integration.
final class SilentMediaSession: MediaSessionSource {
    func subscribe(_ update: @escaping (MediaSessionState) -> Void) -> Int {
        update(MediaSessionState())
        return 0
    }

    func unsubscribe(_ id: Int) {}
}

/// One capture's result, handed over from the Metal thread that completes it: `done` orders the
/// write of `image` before the waiting thread reads it.
final class FrameCapture: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private(set) var image: CGImage?

    func finish(_ image: CGImage?) {
        self.image = image
        done.signal()
    }
}

/// An HEVC `.mov` written frame by frame from `CGImage`s (the screen saver's loop, a Live Photo's
/// movie), or another codec and container when a caller names them (the Android export's H.264
/// `.mp4`, `AndroidVideoRenderer`).
final class HEVCWriter {
    /// HEVC encoder quality (0…1) for the loop video.
    static let quality: Double = 0.95
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let pixelSize: SIMD2<Int>
    private let frameRate: Int

    /// `prepare` adds what else the movie holds (metadata, more inputs) before writing starts.
    /// `bitRate` (bits per second) replaces the constant quality with an average bitrate;
    /// `colorProperties` tags the track's colour (`AVVideoColorPropertiesKey`).
    /// `codec`, `fileType` and `compression` (more compression properties, e.g. a profile) choose
    /// another format than HEVC in a `.mov`.
    init?(url: URL, pixelSize: SIMD2<Int>, frameRate: Int, quality: Double = HEVCWriter.quality, bitRate: Int? = nil,
          colorProperties: [String: String]? = nil, codec: AVVideoCodecType = .hevc, fileType: AVFileType = .mov,
          compression extraCompression: [String: Any] = [:], prepare: (AVAssetWriter) throws -> Void = { _ in }) {
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        } catch {
            OWELog.error(.app, "Screen saver: can't create the video writer: \(error)")
            return nil
        }
        // Constant quality, not a bitrate: rain, particles and glow need several times the bits
        // of a calm scene (a fixed 0.07 bit per pixel smeared them), and a still scene stays small.
        // A caller with a size budget (a Live Photo) passes its bitrate instead.
        var compression: [String: Any] = [AVVideoExpectedSourceFrameRateKey: frameRate]
        compression.merge(extraCompression) { _, extra in extra }
        if let bitRate {
            compression[AVVideoAverageBitRateKey] = bitRate
        } else {
            compression[AVVideoQualityKey] = quality
        }
        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: pixelSize.x,
            AVVideoHeightKey: pixelSize.y,
            AVVideoCompressionPropertiesKey: compression,
        ]
        if let colorProperties { settings[AVVideoColorPropertiesKey] = colorProperties }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: pixelSize.x,
            kCVPixelBufferHeightKey as String: pixelSize.y,
        ])
        self.pixelSize = pixelSize
        self.frameRate = frameRate
        guard writer.canAdd(input) else {
            OWELog.error(.app, "The video writer takes no \(codec.rawValue) input")
            return nil
        }
        writer.add(input)
        do {
            try prepare(writer)
        } catch {
            OWELog.error(.app, "Can't prepare the video writer: \(error)")
            return nil
        }
        guard writer.startWriting() else {
            OWELog.error(.app, "Screen saver: the video writer didn't start: \(String(describing: writer.error))")
            return nil
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// Appends `image`, with `overlay` blended over it at `weight` (the seam's crossfade).
    func append(_ image: CGImage, overlay: CGImage?, weight: Double, frame: Int) -> Bool {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard writer.status == .writing, let pool = adaptor.pixelBufferPool else {
            OWELog.error(.app, "Screen saver: the video writer stopped: \(String(describing: writer.error))")
            return false
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return false }
        CVPixelBufferLockBaseAddress(buffer, [])
        let drawn: Bool = {
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: pixelSize.x, height: pixelSize.y,
                                          bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            let rect = CGRect(x: 0, y: 0, width: pixelSize.x, height: pixelSize.y)
            context.draw(image, in: rect)
            if let overlay, weight > 0 {
                context.setAlpha(weight)
                context.draw(overlay, in: rect)
            }
            return true
        }()
        guard drawn else { return false }
        return adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(frameRate)))
    }

    /// Waits until `other` (an input `prepare` added) takes more data; false once the writer stops.
    func waitUntilReady(_ other: AVAssetWriterInput) -> Bool {
        while !other.isReadyForMoreMediaData {
            guard writer.status == .writing else { return false }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return writer.status == .writing
    }

    func finish() -> Bool {
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            OWELog.error(.app, "Screen saver: the video didn't finish: \(String(describing: writer.error))")
            return false
        }
        return true
    }

    func cancel() { writer.cancelWriting() }
}

/// Reads an intermediate video's frames back in order as `CGImage`s (a recorded page's, a Live
/// Photo's first pass).
final class IntermediateReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

    init?(url: URL) {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else {
            OWELog.error(.app, "Screen saver: can't read the recorded frames back")
            return nil
        }
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        self.reader = reader
    }

    func next() -> CGImage? {
        guard let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        // A copy: the buffer goes back to the decoder's pool.
        let data = Data(bytes: base, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                    | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func cancel() { reader.cancelReading() }
}
