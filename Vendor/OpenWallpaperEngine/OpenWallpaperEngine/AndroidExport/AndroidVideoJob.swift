import Foundation

/// One pre-rendered Android video, handed to the helper run (`HelperRunCommand`,
/// `--render-android-video <job.json>`, `AndroidVideoRenderer`) as a JSON file: the wallpaper,
/// the user-property snapshot it renders with, the crop (with its zoom), the pointer, the frame rate, the loop's length, the
/// bit rate and where the `.mp4` goes.
struct AndroidVideoJob: Codable, Equatable {
    var wallpaperDirectory: String
    var properties: [String: String]
    var sceneSize: [Double]
    var outputPixels: [Int]
    var center: [Double]
    var frameRate: Int
    var seconds: Int
    var bitRate: Int
    var outputPath: String
    /// Where the pointer rests, normalised, y up (`LivePhotoParallax`); nil is the centre.
    var pointer: [Double]?
    /// The crop's zoom (`LivePhotoCrop.zoom`); nil is 1, the whole cover window.
    var zoom: Double?

    init(wallpaperDirectory: URL, properties: [String: String], crop: LivePhotoCrop, frameRate: Int,
         seconds: Int = AndroidExportOptions.videoSeconds, bitRate: Int, output: URL,
         pointer: SIMD2<Double> = LivePhotoParallax.centre) {
        self.wallpaperDirectory = wallpaperDirectory.path(percentEncoded: false)
        self.properties = properties
        sceneSize = [crop.sceneSize.x, crop.sceneSize.y]
        outputPixels = [crop.outputPixels.x, crop.outputPixels.y]
        center = [crop.center.x, crop.center.y]
        self.frameRate = frameRate
        self.seconds = seconds
        self.bitRate = bitRate
        outputPath = output.path(percentEncoded: false)
        self.pointer = pointer == LivePhotoParallax.centre ? nil : [pointer.x, pointer.y]
        zoom = crop.zoom == 1 ? nil : crop.zoom
    }

    /// The pointer the video is rendered with.
    var pointerPosition: SIMD2<Double> {
        guard let pointer, pointer.count == 2 else { return LivePhotoParallax.centre }
        return LivePhotoParallax.clamped(SIMD2(pointer[0], pointer[1]))
    }

    var crop: LivePhotoCrop? {
        guard sceneSize.count == 2, outputPixels.count == 2, center.count == 2 else { return nil }
        return LivePhotoCrop(sceneSize: SIMD2(sceneSize[0], sceneSize[1]), outputPixels: SIMD2(outputPixels[0], outputPixels[1]),
                             zoom: zoom ?? 1, center: SIMD2(center[0], center[1]))
    }

    var output: URL { URL(filePath: outputPath, directoryHint: .notDirectory) }

    /// Frames in the loop.
    var frameCount: Int { max(1, frameRate * seconds) }
}
