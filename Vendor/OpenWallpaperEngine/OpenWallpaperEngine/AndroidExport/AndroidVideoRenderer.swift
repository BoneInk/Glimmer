import AVFoundation
import CoreGraphics
import VideoToolbox

/// Renders a scene's pre-rendered Android video (WE's "Pre-Rendered / High Performance"), in the
/// app's helper run (`--render-android-video`), never on the app's main or render thread:
///
/// - the real loader and renderer, offscreen, on a fixed frame step (`LivePhotoRenderer.render`,
///   as the Live Photo export draws: the job's user properties, silent, the job's pointer, the
///   whole scene at its authored size or more), cut to the job's crop at the video's pixels;
/// - WE's format: H.264 Constrained Baseline (CAVLC, no B-frames), yuv420p, BT.709, at the
///   job's size, frame rate and average bit rate, a 30.0 s loop in an `.mp4`;
/// - seamless: `ScreenSaverSeamFinder.crossfadeSeconds` more are rendered, and the loop's last
///   frames are crossfaded into the scene's first ones as the screen saver's loop does it
///   (`ScreenSaverSeamFinder.crossfadeWeight`), the video starting just after them so the motion
///   runs on through the seam;
/// - clocks and dates draw as recorded (WE: "dynamic elements like clocks… will not work").
@MainActor
enum AndroidVideoRenderer {
    enum Failure: LocalizedError {
        case writer, frame

        var errorDescription: String? { String(localized: "Failed converting the wallpaper to a video.") }
    }

    /// H.264 Constrained Baseline, as WE's pre-rendered `wallpaper.mp4` is.
    static let compression: [String: Any] = [
        AVVideoProfileLevelKey: kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel as String,
        AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCAVLC,
        AVVideoAllowFrameReorderingKey: false,
    ]

    static let colorProperties = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    /// Frames of the seam's crossfade at `frameRate`.
    static func fadeFrames(frameRate: Int, loopFrames: Int) -> Int {
        min(max(Int((ScreenSaverSeamFinder.crossfadeSeconds * Double(frameRate)).rounded()), 1), loopFrames / 2)
    }

    /// The helper's work: renders `job`, writing progress lines to standard output; 0 when done.
    static func run(_ job: AndroidVideoJob) -> Int32 {
        guard let crop = job.crop,
              let wallpaper = InstalledLibrary.wallpaper(at: URL(filePath: job.wallpaperDirectory, directoryHint: .isDirectory), hiding: []),
              AndroidPackageBuilder.kind(of: wallpaper) == .scene else {
            OWELog.error(.app, "Android export: bad video job for \(job.wallpaperDirectory)")
            return 2
        }
        var status: Int32?
        Task { @MainActor in
            do {
                try await render(job, wallpaper: wallpaper, crop: crop) { fraction in
                    FileHandle.standardOutput.write(Data(LivePhotoJob.progressLine(fraction).utf8))
                }
                status = 0
            } catch {
                OWELog.error(.app, "Android export: \(wallpaper.wallpaperDirectory.lastPathComponent)'s video failed: \(error)")
                status = 1
            }
        }
        while status == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return status ?? 1
    }

    static func render(_ job: AndroidVideoJob, wallpaper: WEWallpaper, crop: LivePhotoCrop,
                       progress: @escaping (Double) -> Void) async throws {
        let renderer = LivePhotoRenderer(wallpaper: wallpaper)
        renderer.useProperties(job.properties)
        let frames = job.frameCount
        let fade = fadeFrames(frameRate: job.frameRate, loopFrames: frames)
        let partial = job.output.deletingLastPathComponent()
            .appending(path: ".partial-\(job.output.lastPathComponent)", directoryHint: .notDirectory)
        try? FileManager.default.removeItem(at: partial) // Optional: a partial file a cancelled render left.
        guard let writer = HEVCWriter(url: partial, pixelSize: crop.outputPixels, frameRate: job.frameRate, bitRate: job.bitRate,
                                      colorProperties: colorProperties, codec: .h264, fileType: .mp4,
                                      compression: compression.merging([AVVideoMaxKeyFrameIntervalKey: job.frameRate]) { $1 }) else {
            throw Failure.writer
        }
        var head: [CGImage] = []
        do {
            try await renderer.render(crop: crop, pointer: job.pointerPosition, leadIn: 0, frames: frames + fade,
                                      frameRate: job.frameRate, hidesClockLayers: false, progress: progress) { rendered, image in
                if rendered < fade {
                    head.append(image)
                    return
                }
                let index = rendered - fade
                let weight = ScreenSaverSeamFinder.crossfadeWeight(index: index, loopFrames: frames, fade: fade)
                let overlay = weight > 0 ? head[index - (frames - fade)] : nil
                guard writer.append(image, overlay: overlay, weight: weight, frame: index) else { throw Failure.frame }
            }
        } catch {
            writer.cancel()
            try? FileManager.default.removeItem(at: partial) // Optional: the failed render's partial file.
            throw error
        }
        guard writer.finish() else { throw Failure.writer }
        if FileManager.default.fileExists(atPath: job.output.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: job.output)
        }
        try FileManager.default.moveItem(at: partial, to: job.output)
    }
}
