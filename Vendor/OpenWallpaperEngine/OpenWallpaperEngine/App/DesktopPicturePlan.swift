import CoreGraphics
import Foundation

/// What one display shows, as its desktop picture should show it (`DesktopPictureSync`): the
/// wallpaper of each of its windows (one, or a split display's regions), where each window sits,
/// where the wallpaper's frame lies in it (the window, or a stretch's canvas), the clone mirror and
/// the wallpaper's display options there. The windows are drawn the same way
/// (`WallpaperWindowContentView` mirrors, `WallpaperDisplayTransformView` applies the options,
/// a stretched view shows its rect of the canvas), so the picture matches the screen.
///
/// Rects are normalized to the display (0…1, origin bottom-left, as AppKit's desktop is).
struct DesktopPicturePlan: Equatable, Sendable {
    struct Layer: Equatable, Sendable {
        var wallpaperDirectory: URL
        var type: String
        var mediaURL: URL
        var preview: URL?
        /// The window's rect on the display.
        var rect: CGRect
        /// Where the wallpaper's frame lies on the display: the window's rect, or a stretch's canvas.
        var canvas: CGRect
        /// The frame's size in pixels: the snapshot to look for.
        var framePixelSize: SIMD2<Int>
        /// A flipped clone display: the window is mirrored left to right.
        var mirrored: Bool
        var options: WallpaperDisplayOptions

        static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// A connected display: its id, its rect in global points and its pixels per point.
    struct Display: Equatable, Sendable {
        var id: CGDirectDisplayID
        var frame: CGRect
        var scale: CGFloat

        var pixelSize: SIMD2<Int> {
            SIMD2(Int((frame.width * scale).rounded()), Int((frame.height * scale).rounded()))
        }
    }

    var display: CGDirectDisplayID
    var pixelSize: SIMD2<Int>
    var layers: [Layer]

    /// The display shows one frame as it was rendered at its size: the snapshot is the picture.
    var isPlain: Bool {
        guard layers.count == 1, let layer = layers.first else { return false }
        return layer.rect == Layer.unit && layer.canvas == Layer.unit && !layer.mirrored
            && !layer.options.transformsPicture
    }

    /// Each display's plan under `resolution`. `wallpaper` is the wallpaper a display or region id
    /// shows (nil for none), `options` its display options there.
    static func plans(displays: [Display], resolution: DisplayLayoutResolution,
                      wallpaper: (String) -> WEWallpaper?,
                      options: (String) -> WallpaperDisplayOptions) -> [DesktopPicturePlan] {
        displays.compactMap { display in
            let screenId = String(display.id)
            guard display.frame.width > 0, display.frame.height > 0 else { return nil }
            let windows = resolution.regions[screenId].map { $0.map { ($0.id, $0.rect) } } ?? [(screenId, display.frame)]
            let layers = windows.compactMap { id, rect -> Layer? in
                guard let shown = wallpaper(id) else { return nil }
                let canvas = resolution.canvases[screenId] ?? rect
                return Layer(wallpaperDirectory: shown.wallpaperDirectory, type: shown.project.type,
                             mediaURL: shown.mediaURL, preview: shown.previewURL,
                             rect: normalized(rect, in: display.frame), canvas: normalized(canvas, in: display.frame),
                             framePixelSize: SIMD2(Int((canvas.width * display.scale).rounded()),
                                                   Int((canvas.height * display.scale).rounded())),
                             mirrored: resolution.flipped.contains(screenId), options: options(id))
            }
            return DesktopPicturePlan(display: display.id, pixelSize: display.pixelSize, layers: layers)
        }
    }

    static func normalized(_ rect: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: (rect.minX - frame.minX) / frame.width, y: (rect.minY - frame.minY) / frame.height,
               width: rect.width / frame.width, height: rect.height / frame.height)
    }
}
