import AVFoundation
import CoreGraphics
import Metal

/// Renders a scene wallpaper's clip (or a video wallpaper's, its frames read from the video by
/// `LivePhotoVideoFrames` in place of the scene renderer) as a Live Photo (a HEIC still and an HEVC movie paired by one
/// content identifier), or as the clip's movie alone for its preview, in the app's helper run
/// (`HelperRunCommand`, `--render-live-photo`): in its own process, never on the app's main
/// or render thread. The app shows the progress the helper reports and shares the files
/// (`LivePhotoHelper`).
///
/// The scene is loaded by the real loader and drawn offscreen by its own real renderer: the job's
/// user properties, no sound, a
/// silent spectrum, the clock, day and date layers hidden (iOS draws its own,
/// `SceneClockLayers`), on a fixed frame step from load, so frame `i` shows scene time
/// `i / frameRate`. The whole scene is drawn at `LivePhotoCrop.renderScale` (never below its
/// authored size nor below the device's pixels), whatever the user's playback settings, and the
/// crop is cut out at the device's exact pixel size: the still's; the movie is drawn from it at
/// most the Lock Screen's size (`LivePhotoMovieEncoder.moviePixels`).
///
/// A Live Photo is written in two passes: the clip's frames go into a near-lossless intermediate
/// movie while the still is chosen among them (`LivePhotoKeyFrame`, at full resolution), then the
/// final movie is encoded from it with the still marked and blended in at both ends
/// (`LivePhotoMovieEncoder`). A motion analysis job renders the scene's first seconds small and
/// writes each frame's motion (`LivePhotoMotion`).
@MainActor
final class LivePhotoRenderer {
    enum Failure: LocalizedError {
        case noScene, loadTimedOut, readBack, movie

        var errorDescription: String? {
            switch self {
            case .noScene: return String(localized: "The scene couldn't be loaded for the Live Photo.")
            case .loadTimedOut: return String(localized: "The scene took too long to load for the Live Photo.")
            case .readBack: return String(localized: "A frame of the Live Photo couldn't be rendered.")
            case .movie: return String(localized: "The Live Photo's movie couldn't be written.")
            }
        }
    }

    /// What every Live Photo render does: a recorded picture shows no clock, and is silent.
    enum Policy {
        static let hidesClockLayers = true
        static let muted = true
    }

    let wallpaper: WEWallpaper
    let defaults: UserDefaults
    var timeoutSeconds: TimeInterval = 120

    /// `defaults`: the helper's read-only view of the app's (`UserDefaults.app`); the job's
    /// properties are written to its scratch suite, never to the app's.
    init(wallpaper: WEWallpaper, defaults: UserDefaults = .app) {
        self.wallpaper = wallpaper
        self.defaults = defaults
    }

    /// The export's quality: the user's settings with WE's full effect detail, no upscaling and
    /// full-size textures, whatever Render Resolution draws the displays at. The scene target is
    /// sized for the export's drawable, never below the scene's authored size
    /// (`floorsAtAuthoredSize`); `LivePhotoCrop` sizes the drawable to the authored size or more,
    /// raised to the device's pixels when they need more.
    nonisolated static func renderSettings(from settings: GlobalSettings) -> SceneRenderSettings {
        var render = SceneRenderSettings(settings)
        render.renderResolution = .yourDisplay
        render.floorsAtAuthoredSize = true
        render.sceneDetail = .full
        render.upscaling = .off
        render.textureReduction = 1
        return render
    }

    /// How the export draws its scene, and its preview too (`IsolatedSceneView`), so the preview
    /// shows what is exported: the whole scene filling a drawable of its own aspect, from which
    /// `LivePhotoCrop` cuts the window; the pointer held at `pointer` (Export Settings' Parallax
    /// Position, `LivePhotoParallax`; the scene's centre by default), so the camera and depth
    /// parallax and the cursor uniforms don't follow the mouse; no clock layers.
    /// `hidesClockLayers` false draws them (the Android export's pre-rendered video, which WE records as it plays).
    static func presentation(pointer: SIMD2<Double> = LivePhotoParallax.centre,
                             hidesClockLayers: Bool = Policy.hidesClockLayers) -> SceneWallpaperInstance.Presentation {
        SceneWallpaperInstance.Presentation(placement: .fill, pointer: SIMD2<Float>(LivePhotoParallax.clamped(pointer)),
                                            hidesClockLayers: hidesClockLayers)
    }

    /// The scene's drawable for `crop`: the whole scene at `LivePhotoCrop.renderScale`, one pixel a
    /// point, without a cursor (`presentation` fixes the pointer).
    static func viewport(for crop: LivePhotoCrop, frameRate: Int = LivePhotoClip.frameRate) -> SceneViewport {
        let pixelSize = crop.renderPixelSize
        let drawable = SIMD2(Float(pixelSize.x), Float(pixelSize.y))
        return SceneViewport(drawableSize: drawable, pointSize: drawable, cursor: nil, frameRateLimit: frameRate)
    }

    /// The renderer's configuration for a Live Photo with the pointer at `pointer`.
    static func configure(_ renderer: SceneMetalRenderer, pointer: SIMD2<Double> = LivePhotoParallax.centre,
                          hidesClockLayers: Bool = Policy.hidesClockLayers) {
        renderer.rendersScreenSaver = true
        presentation(pointer: pointer, hidesClockLayers: hidesClockLayers).apply(to: renderer)
        if Policy.muted { renderer.sounds.setTargetGain(0) }
        renderer.audioSpectrumFrame = { _ in .silent }
    }

    // MARK: Helper run

    /// The helper's work: renders `job`, writing progress lines to standard output; 0 when done.
    static func run(_ job: LivePhotoJob) -> Int32 {
        guard let crop = job.crop,
              let wallpaper = InstalledLibrary.wallpaper(at: URL(filePath: job.wallpaperDirectory, directoryHint: .isDirectory), hiding: []),
              LivePhotoExportModel.isEligible(wallpaper) || ScreenSaverVideoSource.isEligible(wallpaper) else {
            OWELog.error(.app, "Live Photo: bad job for \(job.wallpaperDirectory)")
            return 2
        }
        let renderer = LivePhotoRenderer(wallpaper: wallpaper)
        renderer.useProperties(job.properties)
        var status: Int32?
        Task { @MainActor in
            do {
                let progress: (Double) -> Void = { fraction in
                    FileHandle.standardOutput.write(Data(LivePhotoJob.progressLine(fraction).utf8))
                }
                if let analysis = job.analysis {
                    try await renderer.analyse(crop: crop, pointer: job.pointer, seconds: job.analysisSeconds, into: analysis,
                                               progress: progress)
                } else {
                    try await renderer.write(job, crop: crop, progress: progress)
                }
                status = 0
            } catch {
                OWELog.error(.app, "Live Photo: \(wallpaper.wallpaperDirectory.lastPathComponent) failed: \(error)")
                status = 1
            }
        }
        while status == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return status ?? 1
    }

    /// The scene loads with `values` as its stored user properties (the shared store).
    func useProperties(_ values: [String: String]) {
        let identity = WallpaperSettingsIdentity.resolve(wallpaper, defaults: defaults)
        defaults.set(values, forKey: identity.key(.userProperties, scope: .shared))
        defaults.set(true, forKey: identity.key(.explicitUserProperties, scope: .shared))
    }

    /// Writes the job's movie, and its still when it has one: the clip's preview in one pass, a
    /// Live Photo in two (see the type's notes).
    func write(_ job: LivePhotoJob, crop: LivePhotoCrop, progress: @escaping (Double) -> Void) async throws {
        let clip = job.clip
        // The movie at most the Lock Screen's size; the still at the crop's full pixels.
        let moviePixels = LivePhotoMovieEncoder.moviePixels(for: crop.outputPixels)
        let bitRate = job.qualityLevel.bitRate(for: moviePixels, frameRate: LivePhotoClip.frameRate)
        guard let still = job.still else {
            guard let writer = HEVCWriter(url: job.movie, pixelSize: moviePixels, frameRate: LivePhotoClip.frameRate,
                                          bitRate: bitRate, colorProperties: LivePhotoMovieEncoder.colorProperties) else {
                throw Failure.movie
            }
            do {
                try await render(crop: crop, pointer: job.pointer, leadIn: clip.leadInFrames, frames: clip.frameCount,
                                 progress: progress) { index, image in
                    guard writer.append(image, overlay: nil, weight: 0, frame: index) else { throw Failure.movie }
                }
            } catch {
                writer.cancel()
                throw error
            }
            guard writer.finish() else { throw Failure.movie }
            return
        }

        // Pass 1: the frames, near-lossless at the movie's size, and the still among them at full size.
        let pass = job.movie.deletingLastPathComponent().appending(path: ".pass-\(job.identifier).mov", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: pass) } // Optional: a temporary file.
        guard let intermediate = HEVCWriter(url: pass, pixelSize: moviePixels, frameRate: LivePhotoClip.frameRate,
                                            quality: 1) else { throw Failure.movie }
        let candidates = LivePhotoKeyFrame.candidates(frameCount: clip.frameCount)
        var sharpness: [Int: Double] = [:]
        var keyImage: (index: Int, score: Double, image: CGImage)?
        do {
            try await render(crop: crop, pointer: job.pointer, leadIn: clip.leadInFrames, frames: clip.frameCount,
                             progress: { progress($0 * 0.85) }) { index, image in
                guard intermediate.append(image, overlay: nil, weight: 0, frame: index) else { throw Failure.movie }
                guard candidates.contains(index) else { return }
                let value = LivePhotoKeyFrame.sharpness(of: image)
                sharpness[index] = value
                let score = value * LivePhotoKeyFrame.weight(index: index, frameCount: clip.frameCount)
                if keyImage.map({ score > $0.score }) ?? true { keyImage = (index, score, image) }
            }
        } catch {
            intermediate.cancel()
            throw error
        }
        guard intermediate.finish() else { throw Failure.movie }
        let keyFrame = LivePhotoKeyFrame.choose(sharpness: sharpness, frameCount: clip.frameCount)
        guard let keyImage, keyImage.index == keyFrame else { throw Failure.readBack }
        try LivePhotoMetadata.writeStill(keyImage.image, to: still, identifier: job.identifier)

        // Pass 2: the movie, the still marked and blended in at both ends.
        guard let reader = IntermediateReader(url: pass) else { throw Failure.movie }
        defer { reader.cancel() }
        do {
            try LivePhotoMovieEncoder.write(to: job.movie, pixelSize: moviePixels, frameRate: LivePhotoClip.frameRate,
                                            frameCount: clip.frameCount, keyFrame: keyFrame, still: keyImage.image,
                                            identifier: job.identifier, bitRate: bitRate) { index in
                try Task.checkCancellation()
                progress(0.85 + 0.15 * Double(index + 1) / Double(clip.frameCount))
                return reader.next()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            OWELog.error(.app, "Live Photo: \(wallpaper.wallpaperDirectory.lastPathComponent)'s movie failed: \(error)")
            throw Failure.movie
        }
    }

    /// Renders the scene's first `seconds` small (the crop at about `LivePhotoMotion.analysisPixels`)
    /// and writes each frame's motion to `url` (`LivePhotoMotion.Analysis`).
    func analyse(crop: LivePhotoCrop, pointer: SIMD2<Double> = LivePhotoParallax.centre, seconds: Double, into url: URL,
                 progress: @escaping (Double) -> Void) async throws {
        let scale = Double(LivePhotoMotion.analysisPixels) / Double(max(crop.outputPixels.x, crop.outputPixels.y, 1))
        let small = SIMD2(max(16, Int(Double(crop.outputPixels.x) * min(scale, 1))),
                          max(16, Int(Double(crop.outputPixels.y) * min(scale, 1))))
        var analysisCrop = LivePhotoCrop(sceneSize: crop.sceneSize, outputPixels: small, zoom: crop.zoom, center: crop.center)
        analysisCrop.minimumRenderScale = 0
        let frames = max(2, Int((min(max(seconds, 1), LivePhotoClip.timelineLength) * Double(LivePhotoClip.frameRate)).rounded()))
        var signatures: [ScreenSaverFrameSignature] = []
        signatures.reserveCapacity(frames)
        try await render(crop: analysisCrop, pointer: pointer, leadIn: 0, frames: frames, progress: progress) { _, image in
            guard let signature = ScreenSaverFrameSignature(image) else { throw Failure.readBack }
            signatures.append(signature)
        }
        let analysis = LivePhotoMotion.Analysis(frameRate: LivePhotoClip.frameRate,
                                                differences: LivePhotoMotion.differences(signatures))
        try JSONEncoder().encode(analysis).write(to: url)
    }

    // MARK: Rendering

    /// Loads the scene with the pointer at `pointer`, runs it `leadIn` frames (to the clip's start)
    /// and hands each of the next `frames` frames, cut to `crop`, to `frame`, one every
    /// `1 / frameRate` s of scene time. Checks for cancellation between frames. The Android
    /// export's pre-rendered video renders through it too (`AndroidVideoRenderer`).
    func render(crop: LivePhotoCrop, pointer: SIMD2<Double>, leadIn: Int, frames: Int,
                frameRate: Int = LivePhotoClip.frameRate, hidesClockLayers: Bool = Policy.hidesClockLayers,
                progress: @escaping (Double) -> Void,
                frame: (Int, CGImage) throws -> Void) async throws {
        // A video wallpaper's frames are its video's, read in place of a scene render.
        if ScreenSaverVideoSource.isEligible(wallpaper) {
            try await LivePhotoVideoFrames(url: wallpaper.mediaURL).render(crop: crop, leadIn: leadIn, frames: frames,
                                                                            frameRate: frameRate, progress: progress, frame: frame)
            return
        }
        let name = wallpaper.wallpaperDirectory.lastPathComponent
        let scratch = FileManager.default.temporaryDirectory.appending(path: "owe-livephoto-\(UUID().uuidString)",
                                                                       directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(),
                                           storage: SceneScriptStorage(directory: scratch),
                                           media: SilentMediaSession(), spectrum: { .silent })
        let model = SceneContentLoader(wallpaper: wallpaper)
        let settings = Self.renderSettings(from: OffscreenRendering.globalSettings(from: defaults))
        model.setRenderSettings(settings)
        guard let content = model.metalContent(),
              let renderer = SceneMetalRenderer(pixelFormat: .bgra8Unorm, scriptServices: services,
                                                screenID: "livephoto-\(name)") else { throw Failure.noScene }
        defer { renderer.releaseContent() }
        let pixelSize = crop.renderPixelSize
        let startTime: CFTimeInterval = 1000
        Self.configure(renderer, pointer: pointer, hidesClockLayers: hidesClockLayers)
        renderer.renderSettings = settings
        renderer.wallTime = { startTime }
        renderer.holdsClock = true
        renderer.setContent(content)
        let viewport = Self.viewport(for: crop, frameRate: frameRate)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !renderer.hasContent, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        var settled = 0
        while renderer.hasContent, settled < 3, Date() < deadline {
            try Task.checkCancellation()
            renderer.renderShared([viewport])
            renderer.lastCommandBuffer?.waitUntilCompleted()
            try await Task.sleep(for: .milliseconds(5))
            settled = renderer.hasPendingEffectPipelines ? 0 : settled + 1
        }
        guard renderer.hasContent, settled >= 3 else { throw Failure.loadTimedOut }
        renderer.holdsClock = false

        let total = Double(leadIn + frames)
        for index in 0..<(leadIn + frames) {
            try Task.checkCancellation()
            let time = startTime + Double(index) / Double(frameRate)
            renderer.wallTime = { time }
            renderer.renderShared([viewport])
            if index < leadIn {
                renderer.lastCommandBuffer?.waitUntilCompleted()
            } else {
                guard let image = await capture(renderer, pixelSize: pixelSize),
                      let output = crop.outputImage(from: image) else { throw Failure.readBack }
                try frame(index - leadIn, output)
            }
            progress(Double(index + 1) / total)
            await Task.yield()
        }
    }

    private func capture(_ renderer: SceneMetalRenderer, pixelSize: SIMD2<Int>) async -> CGImage? {
        let capture = FrameCapture()
        guard renderer.captureSharedFrame(pixelSize: pixelSize, pixelsPerPoint: 1, completion: { capture.finish($0) }) else {
            return nil
        }
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: capture.done.wait(timeout: .now() + 10) == .success)
            }
        }
        return finished ? capture.image : nil
    }

    /// A file name from the wallpaper's title: no path separators, never empty.
    nonisolated static func fileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Live Photo" : String(cleaned.prefix(80))
    }
}
