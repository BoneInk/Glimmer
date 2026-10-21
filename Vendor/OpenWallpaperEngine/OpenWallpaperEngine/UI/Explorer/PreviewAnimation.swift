import AppKit
import ImageIO
import QuartzCore

/// One animated preview's frames at one pixel size: decoded off the main thread, into the bitmap
/// format Core Animation shows as is (so a commit never decodes or converts), and no larger than
/// the tile shows them. A short GIF keeps its decoded frames, so after its first loop it costs
/// nothing; a long one (over `cachedBytesLimit`) decodes each frame as it comes up.
final class PreviewFrameSequence: @unchecked Sendable { // `lock` owns `frames` and `decoding`.
    /// A GIF whose frames take at most this many bytes at the shown size keeps them.
    static let cachedBytesLimit = 16 << 20
    /// Browsers (and WE's library, which is one) show a GIF delay under 11 ms as 100 ms.
    static let minimumDelay = 0.011
    static let substituteDelay = 0.1

    /// Every preview decodes on this one queue, in the background: a preview frame is never urgent.
    private static let decodeQueue = DispatchQueue(label: "OWE.PreviewFrames", qos: .utility)

    let frameCount: Int
    /// Each frame's display time, in seconds.
    let delays: [Double]
    let duration: Double
    /// The decoded frames' size, and the GIF's own.
    let pixelSize: CGSize
    let sourceSize: CGSize
    let keepsFrames: Bool

    private let source: CGImageSource
    private let lock = NSLock()
    private var frames: [Int: CGImage] = [:]
    private var decoding = false
    /// The frame decoded last, which a long GIF shows when the tick's own frame isn't ready.
    private var latest: (index: Int, image: CGImage)?

    /// `maxPixelSize` is the longest side the frames are shown at; frames are never enlarged.
    init?(url: URL, fitting maxPixelSize: CGSize, fills: Bool) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        self.source = source
        frameCount = count
        delays = (0..<count).map { index in
            let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? Self.substituteDelay
            return delay < Self.minimumDelay ? Self.substituteDelay : delay
        }
        duration = delays.reduce(0, +)
        sourceSize = CGSize(width: width, height: height)
        pixelSize = Self.decodedSize(of: sourceSize, shownIn: maxPixelSize, fills: fills)
        keepsFrames = count * Int(pixelSize.width) * Int(pixelSize.height) * 4 <= Self.cachedBytesLimit
    }

    /// The size to decode an image of `size` at for a tile of `tile` pixels: scaled down to what
    /// the tile shows (filling it, cropped, or fitting inside it), never up.
    static func decodedSize(of size: CGSize, shownIn tile: CGSize, fills: Bool) -> CGSize {
        guard size.width > 0, size.height > 0, tile.width > 0, tile.height > 0 else { return size }
        let widthScale = tile.width / size.width, heightScale = tile.height / size.height
        let scale = min(1, fills ? max(widthScale, heightScale) : min(widthScale, heightScale))
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }

    /// The frame showing `time` seconds into the animation, which loops.
    func frameIndex(at time: Double) -> Int {
        guard duration > 0 else { return 0 }
        var remaining = time.truncatingRemainder(dividingBy: duration)
        if remaining < 0 { remaining += duration }
        for (index, delay) in delays.enumerated() {
            if remaining < delay { return index }
            remaining -= delay
        }
        return frameCount - 1
    }

    /// Frame `index` if it is decoded; otherwise nil, and it is decoded in the background (one
    /// frame at a time per preview) to be ready on a later tick.
    func frame(_ index: Int) -> CGImage? {
        lock.lock()
        if let frame = frames[index] {
            lock.unlock()
            return frame
        }
        guard !decoding else {
            lock.unlock()
            return nil
        }
        decoding = true
        lock.unlock()
        Self.decodeQueue.async { [self] in
            let image = decode(index)
            lock.lock()
            decoding = false
            if let image {
                // A long GIF holds only the frame it shows next.
                if !keepsFrames { frames.removeAll(keepingCapacity: true) }
                frames[index] = image
                latest = (index, image)
            }
            lock.unlock()
        }
        return nil
    }

    /// The frame to show `time` seconds in: its own once decoded, else the one decoded last (the
    /// still stays until the first is ready). Asks for the frame the next tick shows, so in
    /// steady play each tick finds its frame decoded.
    func frameToShow(at time: Double, nextTick: Double) -> (index: Int, image: CGImage)? {
        let index = frameIndex(at: time)
        _ = frame(frameIndex(at: nextTick))
        lock.lock()
        defer { lock.unlock() }
        if let image = frames[index] { return (index, image) }
        return latest
    }

    /// Decodes frame `index` (ImageIO composes it with the frames before it) into a BGRA bitmap
    /// at `pixelSize`.
    func decode(_ index: Int) -> CGImage? {
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
        let width = Int(pixelSize.width), height = Int(pixelSize.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// Plays every animated preview from one timer on the main thread, at most `maximumRate` times a
/// second, and shows each tick's new frames in one Core Animation commit: the window server then
/// composites the window once per tick, not once per tile and GIF frame as one timer per tile
/// did. A preview takes part only while it plays (`PreviewImageView`); with none playing, the
/// timer stops.
@MainActor
final class PreviewAnimator {
    static let shared = PreviewAnimator()
    /// The tick rate's ceiling. Faster GIFs skip frames but keep their speed.
    static let maximumRate: Double = 30

    private var views: [ObjectIdentifier: PreviewImageView] = [:]
    private var timer: Timer?
    private let start = CACurrentMediaTime()

    var playingCount: Int { views.count }

    func add(_ view: PreviewImageView) {
        views[ObjectIdentifier(view)] = view
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1 / Self.maximumRate, repeats: true) { _ in
            MainActor.assumeIsolated { PreviewAnimator.shared.tick() }
        }
        timer.tolerance = 0.25 / Self.maximumRate
        // Common modes: previews keep playing while a menu is open or the window resizes.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func remove(_ view: PreviewImageView) {
        views[ObjectIdentifier(view)] = nil
        guard views.isEmpty else { return }
        timer?.invalidate()
        timer = nil
    }

    /// Shows each playing preview's current frame, all in one transaction.
    func tick() {
        let time = CACurrentMediaTime() - start
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for view in views.values { view.showFrame(at: time) }
        CATransaction.commit()
    }
}
