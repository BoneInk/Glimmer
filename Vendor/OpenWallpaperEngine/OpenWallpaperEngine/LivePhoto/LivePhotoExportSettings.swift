import Foundation

/// How hard the export's movie is compressed: HEVC at an average bitrate for the movie's
/// pixels (`bitRate(for:frameRate:)`, `LivePhotoMovieEncoder.moviePixels`).
enum LivePhotoQuality: String, CaseIterable, Identifiable, Codable {
    case best, high, smaller

    var id: String { rawValue }

    /// Bits per pixel per frame. At "High" an iPhone 17 Pro Max's movie (884 × 1920, its
    /// 1320 × 2868 scaled to the Lock Screen's size) at 30 fps is about 7.6 Mbit/s: generous, for
    /// rendered detail (particles, rain, glow) that compresses worse than camera footage.
    var bitsPerPixel: Double {
        switch self {
        case .best: return 0.25
        case .high: return 0.15
        case .smaller: return 0.08
        }
    }

    /// The movie's average bitrate in bits per second for `pixels` at `frameRate`.
    func bitRate(for pixels: SIMD2<Int>, frameRate: Int) -> Int {
        Int((Double(max(pixels.x, 1) * max(pixels.y, 1) * max(frameRate, 1)) * bitsPerPixel).rounded())
    }

    var title: String {
        switch self {
        case .best: return String(localized: "Best", comment: "Live Photo export quality: the largest file")
        case .high: return String(localized: "High", comment: "Live Photo export quality")
        case .smaller: return String(localized: "Smaller File", comment: "Live Photo export quality: more compression")
        }
    }
}

/// What the Export Settings panel sets for one Live Photo: the device it is made for, the
/// window of the scene it shows, the clip, the movie's quality and where the pointer rests. The
/// export renders exactly these, with the isolated store's values (`IsolatedSceneEditSession.values`).
struct LivePhotoExportSettings: Equatable {
    var device: DeviceModel
    var crop: LivePhotoCrop
    var clip: LivePhotoClip
    var quality: LivePhotoQuality
    /// The pointer the preview and the render hold (`LivePhotoParallax`).
    var parallaxPosition = LivePhotoParallax.centre
}

/// What the Export Settings sheet runs once confirmed.
enum LivePhotoExportAction: String, Identifiable {
    case airDrop, save

    var id: String { rawValue }
}
