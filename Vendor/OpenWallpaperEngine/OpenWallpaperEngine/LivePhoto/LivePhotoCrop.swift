import CoreGraphics
import Foundation

/// The portrait window a Live Photo shows of a scene, and how large the scene is rendered for it.
///
/// Scene units are the scene's authored pixels, origin top-left. At zoom 1 the window is the
/// largest rectangle at the device's aspect the scene covers (cover-fit); zoom (up to
/// `maximumZoom`) shrinks it about its centre. The centre is kept so the window never leaves the
/// scene. The scene is rendered whole at `renderScale` of its authored size: at least 1 (the
/// authored size) and at least what makes the window cover the output's pixels, so the output is
/// never upscaled; the window is then cut out and drawn at the output's exact size.
struct LivePhotoCrop: Equatable {
    static let maximumZoom = 3.0
    /// The largest texture side the renderer allocates (`SceneRenderResolution.maximumTextureDimension`).
    static let maximumRenderDimension = Double(SceneRenderResolution.maximumTextureDimension)

    var sceneSize: SIMD2<Double>
    /// The output, in pixels (the device's portrait screen, or a smaller preview of it).
    var outputPixels: SIMD2<Int>
    private(set) var zoom = 1.0
    /// The window's centre, in scene units.
    private(set) var center: SIMD2<Double>
    /// The least the scene is rendered at: its authored size for an export; less for a render
    /// that only measures the scene (`LivePhotoMotion`).
    var minimumRenderScale = 1.0

    init(sceneSize: SIMD2<Double>, outputPixels: SIMD2<Int>, zoom: Double = 1, center: SIMD2<Double>? = nil) {
        self.sceneSize = SIMD2(max(sceneSize.x, 1), max(sceneSize.y, 1))
        self.outputPixels = SIMD2(max(outputPixels.x, 1), max(outputPixels.y, 1))
        self.center = center ?? self.sceneSize / 2
        setZoom(zoom)
    }

    /// Width over height of the output.
    var aspect: Double { Double(outputPixels.x) / Double(outputPixels.y) }

    /// The window at zoom 1: the largest rectangle at `aspect` inside the scene.
    var coverSize: SIMD2<Double> {
        if sceneSize.x / sceneSize.y > aspect {
            return SIMD2(sceneSize.y * aspect, sceneSize.y)
        }
        return SIMD2(sceneSize.x, sceneSize.x / aspect)
    }

    /// The window's size in scene units.
    var cropSize: SIMD2<Double> { coverSize / zoom }

    /// The window in scene units, origin top-left.
    var cropRect: CGRect {
        let size = cropSize
        let origin = center - size / 2
        return CGRect(x: origin.x, y: origin.y, width: size.x, height: size.y)
    }

    mutating func setZoom(_ value: Double) {
        zoom = value.isFinite ? min(max(value, 1), Self.maximumZoom) : 1
        setCenter(center)
    }

    /// Moves the window's centre to `value`, clamped so the window stays inside the scene.
    mutating func setCenter(_ value: SIMD2<Double>) {
        let half = cropSize / 2
        func clamp(_ v: Double, _ low: Double, _ high: Double) -> Double {
            guard v.isFinite else { return (low + high) / 2 }
            return low > high ? (low + high) / 2 : min(max(v, low), high)
        }
        center = SIMD2(clamp(value.x, half.x, sceneSize.x - half.x), clamp(value.y, half.y, sceneSize.y - half.y))
    }

    /// What an iPad shows of the window in landscape, in scene units: the lock screen turns and
    /// the same picture fills the wider screen, so its full width and a band of its middle show.
    var landscapeRect: CGRect {
        let rect = cropRect
        let height = rect.width * aspect
        return CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
    }

    /// Moves the window by `delta` scene units.
    mutating func pan(by delta: SIMD2<Double>) { setCenter(center + delta) }

    /// The scale the scene is rendered at: its authored size or more, as much as the window needs
    /// to cover the output's pixels, within what the GPU allocates.
    var renderScale: Double {
        let needed = max(Double(outputPixels.x) / cropSize.x, Double(outputPixels.y) / cropSize.y)
        let wanted = max(minimumRenderScale, needed)
        let fits = Self.maximumRenderDimension / max(sceneSize.x, sceneSize.y)
        return min(wanted, max(fits, 1))
    }

    /// The whole scene's render size, in pixels.
    var renderPixelSize: SIMD2<Int> {
        let size = (sceneSize * renderScale).rounded(.up)
        return SIMD2(Int(size.x), Int(size.y))
    }

    /// The window in the rendered frame's pixels, origin top-left, inside the frame.
    var renderCropRect: CGRect {
        let scale = renderScale
        let rect = CGRect(x: cropRect.minX * scale, y: cropRect.minY * scale,
                          width: cropRect.width * scale, height: cropRect.height * scale)
        let frame = CGRect(x: 0, y: 0, width: renderPixelSize.x, height: renderPixelSize.y)
        return rect.integral.intersection(frame)
    }

    /// The window cut out of `frame` (rendered at `renderPixelSize`) and drawn at exactly
    /// `outputPixels`.
    func outputImage(from frame: CGImage) -> CGImage? {
        let scaleX = Double(frame.width) / Double(renderPixelSize.x)
        let scaleY = Double(frame.height) / Double(renderPixelSize.y)
        let rect = renderCropRect
        let source = CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY, width: rect.width * scaleX,
                            height: rect.height * scaleY).integral
        guard let cut = frame.cropping(to: source),
              let context = CGContext(data: nil, width: outputPixels.x, height: outputPixels.y, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cut, in: CGRect(x: 0, y: 0, width: outputPixels.x, height: outputPixels.y))
        return context.makeImage()
    }
}

/// The ~3 s of the scene a Live Photo moves through: Live Photo motion is limited to about 3 s.
struct LivePhotoClip: Equatable {
    /// The longest clip, and the default.
    static let duration = 3.0
    static let frameRate = 30
    /// How far into the scene a clip can start, plus its length: the scrubber's range.
    static let timelineLength = 30.0

    /// The shortest clip the Export Settings offer.
    static let shortestChosen = 1.0

    /// Seconds of scene time from load to the clip's first frame.
    private(set) var start: Double = 0
    /// The clip's length in seconds: one frame up to `duration`.
    private(set) var length: Double = LivePhotoClip.duration

    init(start: Double = 0, length: Double = LivePhotoClip.duration) {
        setLength(length)
        setStart(start)
    }

    /// One frame up to `duration`; the start moves back when the clip would run past the timeline.
    mutating func setLength(_ value: Double) {
        let frame = 1 / Double(Self.frameRate)
        length = value.isFinite ? min(max(value, frame), Self.duration) : Self.duration
        setStart(start)
    }

    static var latestStart: Double { timelineLength - duration }

    mutating func setStart(_ value: Double) {
        start = value.isFinite ? min(max(value, 0), Self.timelineLength - length) : 0
    }

    var end: Double { start + length }
    /// Frames in the clip.
    var frameCount: Int { max(1, Int((length * Double(Self.frameRate)).rounded())) }
    /// Frames rendered (not kept) before the first, so particles and scripts have run to `start`.
    var leadInFrames: Int { Int((start * Double(Self.frameRate)).rounded()) }
    /// The still: the clip's middle frame, never before `LivePhotoKeyFrame.earliestSeconds`.
    var keyFrameIndex: Int { LivePhotoKeyFrame.middle(frameCount: frameCount) }
    /// The still's time in the movie.
    var keyFrameSeconds: Double { Double(keyFrameIndex) / Double(Self.frameRate) }
}
