import AVFoundation
import CoreGraphics
import VideoToolbox

/// A Live Photo's movie from the clip's frames, in the form the Lock Screen plays as a moving
/// wallpaper (`LivePhotoMetadata` has the metadata): 8-bit HEVC Main at the quality's bitrate,
/// at most `maximumMovieSide` pixels on its long side (`moviePixels`; the still keeps the device's
/// full resolution), tagged Rec. 709 (the frames are rendered and drawn as sRGB, standard-range
/// video's tags), carrying the content identifier the still carries, a `live-photo-info` sample
/// per frame and the still-image-time sample at the key frame, so iOS shows exactly the still's
/// frame when the motion isn't playing. The first and last frames blend from and into the still
/// over the screen saver's crossfade (`ScreenSaverSeamFinder.crossfadeWeight`, run from both
/// ends), so neither the start of the motion nor its settling back on the still jumps.
enum LivePhotoMovieEncoder {
    enum Failure: Error { case writer, frame, finish }

    /// The longest side of a movie the Lock Screen plays (the camera's Live Photo movies are
    /// 1920 × 1440); a device's own pixels (2868 on an iPhone 17 Pro Max) are more.
    static let maximumMovieSide = 1920

    /// The movie's pixels for a still of `still` pixels: the same aspect, the long side at most
    /// `maximumMovieSide`, even sides (4:2:0).
    static func moviePixels(for still: SIMD2<Int>) -> SIMD2<Int> {
        let longest = max(still.x, still.y, 1)
        guard longest > maximumMovieSide else { return still }
        let scale = Double(maximumMovieSide) / Double(longest)
        func side(_ value: Int) -> Int { max(2, Int((Double(value) * scale / 2).rounded()) * 2) }
        return SIMD2(min(side(still.x), maximumMovieSide), min(side(still.y), maximumMovieSide))
    }

    /// 8-bit HEVC Main (the Lock Screen takes no H.264; Photos flags 10-bit HDR), no reordered
    /// frames and a key frame each second, as Glitter Live writes the movies it plays.
    static func compression(frameRate: Int) -> [String: Any] {
        [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
         AVVideoAllowFrameReorderingKey: false,
         AVVideoMaxKeyFrameIntervalKey: max(frameRate, 1)]
    }

    static let colorProperties: [String: String] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    /// Frames each blend spans: the screen saver's crossfade, at most a quarter of the clip.
    static func fadeFrames(frameCount: Int, frameRate: Int) -> Int {
        max(0, min(Int((ScreenSaverSeamFinder.crossfadeSeconds * Double(frameRate)).rounded()), frameCount / 4))
    }

    /// The still's weight over frame `index`: just under 1 on the first frame, falling to 0 after
    /// `fade` frames, and rising again over the last `fade` frames.
    static func stillWeight(index: Int, frameCount: Int, fade: Int) -> Double {
        let end = ScreenSaverSeamFinder.crossfadeWeight(index: index, loopFrames: frameCount, fade: fade)
        let start = ScreenSaverSeamFinder.crossfadeWeight(index: frameCount - 1 - index, loopFrames: frameCount, fade: fade)
        return max(start, end)
    }

    /// Writes the movie of the `frameCount` frames `frame` gives in order (drawn at `pixelSize`),
    /// the still marked at `keyFrame`.
    static func write(to url: URL, pixelSize: SIMD2<Int>, frameRate: Int, frameCount: Int, keyFrame: Int, still: CGImage,
                      identifier: String, bitRate: Int, frame: (Int) throws -> CGImage?) throws {
        var tracks: LivePhotoMetadata.Tracks?
        guard let writer = HEVCWriter(url: url, pixelSize: pixelSize, frameRate: frameRate, bitRate: bitRate,
                                      colorProperties: colorProperties, compression: compression(frameRate: frameRate),
                                      prepare: { writer in
                                          writer.metadata = [LivePhotoMetadata.contentIdentifierItem(identifier)]
                                          tracks = try LivePhotoMetadata.addTracks(to: writer)
                                      }) else { throw Failure.writer }
        guard let tracks else {
            writer.cancel()
            throw Failure.writer
        }
        do {
            // The still's moment is known up front: written first, its track is done before the frames.
            let keyTime = LivePhotoMetadata.time(ofFrame: keyFrame, frameRate: frameRate)
            guard tracks.still.append(try LivePhotoMetadata.stillSample(format: tracks.stillFormat, at: keyTime)) else {
                throw Failure.writer
            }
            tracks.still.markAsFinished()
            let fade = fadeFrames(frameCount: frameCount, frameRate: frameRate)
            let frameDuration = LivePhotoMetadata.time(ofFrame: 1, frameRate: frameRate)
            for index in 0..<frameCount {
                guard let image = try frame(index) else { throw Failure.frame }
                let weight = stillWeight(index: index, frameCount: frameCount, fade: fade)
                guard writer.append(image, overlay: weight > 0 ? still : nil, weight: weight, frame: index) else {
                    throw Failure.frame
                }
                // Each frame's info right after it, so the writer can interleave the two.
                let info = try LivePhotoMetadata.infoSample(format: tracks.infoFormat,
                                                            at: LivePhotoMetadata.time(ofFrame: index, frameRate: frameRate),
                                                            duration: frameDuration)
                guard writer.waitUntilReady(tracks.info), tracks.info.append(info) else { throw Failure.frame }
            }
            tracks.info.markAsFinished()
        } catch {
            writer.cancel()
            throw error
        }
        guard writer.finish() else { throw Failure.finish }
    }
}
