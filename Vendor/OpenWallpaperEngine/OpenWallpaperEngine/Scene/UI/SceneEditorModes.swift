import AVFoundation
import Foundation

/// Which of Scene Edit / Export's modes a wallpaper shows, and why one it shows can't be
/// used. All exporting happens in the editor, so a video opens it too:
///
/// - **Scene:** every mode.
/// - **Video:** no Wallpaper mode (there are no layers to edit). Screen Saver plays the video
///   itself; iPhone & iPad Export makes a Live Photo from it; Android Export packs it as
///   Wallpaper Engine does. A file AVFoundation can't read (WebM, a remote video) leaves the
///   first two shown but unavailable, with why (a WebM video is set as the screen saver from the
///   library, drawn through Chromium); Android takes any local video, as WE does.
/// - **Web and the rest:** the Wallpaper mode, and Android Export unavailable with WE's own
///   message (WE doesn't export them for its mobile app). No Screen Saver mode: a web page has
///   no layers to choose, so it is set as the screen saver from the library as it is.
enum SceneEditorModes {
    enum Availability: Equatable {
        case available
        /// Shown, but it can't be used; the reason is shown in its place.
        case unavailable(String)

        var isAvailable: Bool { self == .available }
    }

    struct Entry: Equatable {
        let mode: SceneInspectorMode
        let availability: Availability
    }

    static func isVideo(_ wallpaper: WEWallpaper) -> Bool {
        SceneContentLoader.isVideoType(wallpaper.project.type)
    }

    /// The modes `wallpaper` shows, in the toolbar's order.
    static func entries(for wallpaper: WEWallpaper) -> [Entry] {
        if LivePhotoExportModel.isEligible(wallpaper) {
            return SceneInspectorMode.allCases.map { Entry(mode: $0, availability: .available) }
        }
        if isVideo(wallpaper) {
            // MP4, M4V and MOV files in the library: what AVFoundation reads.
            let readable = ScreenSaverVideoSource.isEligible(wallpaper)
            // A WebM video is drawn live through Chromium: it is set from the library, as it is.
            let screenSaverReason = ScreenSaverPlugin.isWebMVideo(wallpaper)
                ? String(localized: "A WebM video is drawn live through the Chromium engine. Set it with Set as Screen Saver in the library.",
                         comment: "Scene Edit / Export: why a WebM video's Screen Saver tab can't be used")
                : String(localized: "The screen saver can play only MP4, M4V or MOV video files in your library.")
            return [
                Entry(mode: .screenSaver, availability: readable ? .available : .unavailable(screenSaverReason)),
                Entry(mode: .deviceExport, availability: readable ? .available : .unavailable(
                    String(localized: "Live Photos can be made only from MP4, M4V or MOV video files in your library."))),
                Entry(mode: .androidExport, availability: AndroidPackageBuilder.kind(of: wallpaper) == .video ? .available
                      : .unavailable(String(localized: "Wallpaper type not supported on Android devices"))),
            ]
        }
        return [
            Entry(mode: .wallpaper, availability: .available),
            Entry(mode: .androidExport, availability: .unavailable(String(localized: "Wallpaper type not supported on Android devices"))),
        ]
    }

    static func availability(of mode: SceneInspectorMode, for wallpaper: WEWallpaper) -> Availability? {
        entries(for: wallpaper).first { $0.mode == mode }?.availability
    }

    /// The mode the editor opens in for `requested`: it when shown, else the first shown mode
    /// (a video's first export mode).
    static func initialMode(_ requested: SceneInspectorMode, for wallpaper: WEWallpaper) -> SceneInspectorMode {
        let modes = entries(for: wallpaper).map(\.mode)
        return modes.contains(requested) ? requested : modes.first ?? .wallpaper
    }

    /// A video file's picture size as it plays (its track's transform applied); nil when it has
    /// no readable video track.
    static func videoSize(of url: URL) async -> SIMD2<Double>? {
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            let rect = CGRect(origin: .zero, size: natural).applying(transform)
            guard abs(rect.width) > 0, abs(rect.height) > 0 else { return nil }
            return SIMD2(abs(rect.width).rounded(), abs(rect.height).rounded())
        } catch {
            OWELog.error(.app, "Scene Edit / Export: can't read the video size of \(url.lastPathComponent): \(error)")
            return nil
        }
    }
}
