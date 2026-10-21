import Foundation

/// How a video wallpaper's music sync maps an audio level onto its picture and pace. The AVKit
/// and WebKit video paths share it, so the same level zooms, tilts, saturates and paces a video
/// the same way whichever decodes it. An amount is 0 while its switch is off.
struct VideoMusicSyncEffect: Equatable {
    var zoomAmount: Double = 0
    var tiltAmount: Double = 0
    var saturationAmount: Double = 0
    var paceAmount: Double = 0

    /// The amounts set for `wallpaper`, with the controls' defaults.
    init(_ wallpaper: WEWallpaper) {
        func amount(_ name: String, _ defaultValue: Double) -> Double {
            VideoMusicSyncSettings.bool(wallpaper, "\(name)Enabled")
                ? VideoMusicSyncSettings.double(wallpaper, "\(name)Amount", default: defaultValue)
                : 0
        }
        zoomAmount = amount("zoom", 0.08)
        tiltAmount = amount("tilt", 3)
        saturationAmount = amount("saturation", 0.6)
        paceAmount = amount("pace", 0.25)
    }

    init(zoomAmount: Double = 0, tiltAmount: Double = 0, saturationAmount: Double = 0, paceAmount: Double = 0) {
        self.zoomAmount = zoomAmount
        self.tiltAmount = tiltAmount
        self.saturationAmount = saturationAmount
        self.paceAmount = paceAmount
    }

    /// Whether any effect moves the video, so it needs the audio level.
    var isActive: Bool { zoomAmount != 0 || tiltAmount != 0 || saturationAmount != 0 || paceAmount != 0 }

    /// The picture's scale at `level`.
    func zoom(at level: Double) -> Double { max(0.1, 1 + level * zoomAmount) }

    /// The picture's rotation at `level`, in degrees.
    func tilt(at level: Double) -> Double { level * tiltAmount }

    /// The picture's saturation at `level` (1 leaves it unchanged).
    func saturation(at level: Double) -> Double { max(0, 1 + level * saturationAmount) }

    /// The playback rate at the smoothed `level` for a video playing at `base`; a paused video
    /// (`base` 0) stays paused.
    func rate(base: Float, level: Double) -> Float {
        base > 0 ? max(0, base + Float(level * paceAmount)) : 0
    }

    /// How far each audio sample moves the smoothed level pace follows: the raw level is noisy,
    /// and pacing straight off it reads as stutter rather than a pulse.
    static let paceSmoothing = 0.25
}
