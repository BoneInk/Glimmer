import Foundation

/// One Live Photo render, handed to the helper run (`HelperRunCommand`, `--render-live-photo
/// <job.json>`) as a JSON file: the wallpaper, the isolated store's values (its user properties and
/// layer edits, `IsolatedSceneEditSession.values`), the crop, the device's pixels, the clip, the
/// movie's quality, where the pointer rests and where the files go. With `analysisPath` it renders no movie: it measures the
/// scene's motion over its first `analysisSeconds` (`LivePhotoMotion`) and writes that there.
struct LivePhotoJob: Codable, Equatable {
    var wallpaperDirectory: String
    /// The user-property snapshot the render uses, whatever the helper's defaults hold.
    var properties: [String: String]
    var sceneSize: [Double]
    var outputPixels: [Int]
    var zoom: Double
    var center: [Double]
    var clipStart: Double
    var clipLength: Double
    /// `LivePhotoQuality`'s raw value.
    var quality: String
    /// The fixed pointer (`LivePhotoParallax`), normalised over the scene with y up.
    var parallaxPosition: [Double]
    /// The HEIC; nil renders the movie only (the clip's preview).
    var stillPath: String?
    var moviePath: String
    var identifier: String
    /// Where a motion analysis goes (`LivePhotoMotion.Analysis`); nil renders the clip.
    var analysisPath: String?
    var analysisSeconds: Double = 0

    init(wallpaperDirectory: URL, properties: [String: String], crop: LivePhotoCrop, clip: LivePhotoClip,
         quality: LivePhotoQuality = .best, parallaxPosition: SIMD2<Double> = LivePhotoParallax.centre, still: URL?,
         movie: URL, identifier: String) {
        self.wallpaperDirectory = wallpaperDirectory.path(percentEncoded: false)
        self.properties = properties
        sceneSize = [crop.sceneSize.x, crop.sceneSize.y]
        outputPixels = [crop.outputPixels.x, crop.outputPixels.y]
        zoom = crop.zoom
        center = [crop.center.x, crop.center.y]
        clipStart = clip.start
        clipLength = clip.length
        self.quality = quality.rawValue
        self.parallaxPosition = [parallaxPosition.x, parallaxPosition.y]
        stillPath = still?.path(percentEncoded: false)
        moviePath = movie.path(percentEncoded: false)
        self.identifier = identifier
    }

    var crop: LivePhotoCrop? {
        guard sceneSize.count == 2, outputPixels.count == 2, center.count == 2 else { return nil }
        return LivePhotoCrop(sceneSize: SIMD2(sceneSize[0], sceneSize[1]), outputPixels: SIMD2(outputPixels[0], outputPixels[1]),
                             zoom: zoom, center: SIMD2(center[0], center[1]))
    }

    var clip: LivePhotoClip { LivePhotoClip(start: clipStart, length: clipLength) }
    var qualityLevel: LivePhotoQuality { LivePhotoQuality(rawValue: quality) ?? .best }
    var pointer: SIMD2<Double> {
        guard parallaxPosition.count == 2 else { return LivePhotoParallax.centre }
        return LivePhotoParallax.clamped(SIMD2(parallaxPosition[0], parallaxPosition[1]))
    }
    var analysis: URL? { analysisPath.map { URL(filePath: $0, directoryHint: .notDirectory) } }
    var still: URL? { stillPath.map { URL(filePath: $0, directoryHint: .notDirectory) } }
    var movie: URL { URL(filePath: moviePath, directoryHint: .notDirectory) }

    // MARK: Progress over the pipe

    static let progressPrefix = "progress "

    /// The line the helper writes to standard output for `fraction` done.
    static func progressLine(_ fraction: Double) -> String {
        progressPrefix + String(format: "%.4f", min(max(fraction, 0), 1)) + "\n"
    }

    /// The fraction a line reports, nil for any other line.
    static func progress(fromLine line: Substring) -> Double? {
        guard line.hasPrefix(progressPrefix) else { return nil }
        return Double(line.dropFirst(progressPrefix.count).trimmingCharacters(in: .whitespaces))
    }
}
