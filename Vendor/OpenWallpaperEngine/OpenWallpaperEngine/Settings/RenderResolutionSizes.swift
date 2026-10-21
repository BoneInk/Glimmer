//
//  RenderResolutionSizes.swift
//  Open Wallpaper Engine
//

import AppKit
import Combine

/// The sizes the Render Resolution picker shows (`GSRenderResolution`): each display's backing
/// pixels (what Your Display draws at) and 4K at its shape (what 4K draws at), and the main
/// display's for the option's description.
struct RenderResolutionSizes: Equatable {
    struct Screen: Equatable {
        /// `NSScreen.frame.size`.
        var points: CGSize
        /// The screen's backing pixels.
        var pixels: CGSize
    }

    /// The displays, the main one (with the menu bar) first.
    var screens: [Screen]

    /// "2560×1440, 1920×1080": distinct sizes, largest first.
    static func list(_ sizes: [CGSize]) -> String {
        var seen = Set<[Int]>()
        let distinct = sizes
            .map { [Int($0.width.rounded()), Int($0.height.rounded())] }
            .filter { seen.insert($0).inserted }
            .sorted { ($0[0] * $0[1], $0[0]) > ($1[0] * $1[1], $1[0]) }
        return distinct.map { "\($0[0])×\($0[1])" }.joined(separator: ", ")
    }

    /// 4K at `pixels`' shape (`SceneRenderResolution.uhd4KSize`).
    static func uhd4K(_ pixels: CGSize) -> CGSize {
        let size = SceneRenderResolution.uhd4KSize(shapedLike: SIMD2(Float(pixels.width), Float(pixels.height)))
        return CGSize(width: CGFloat(size.x), height: CGFloat(size.y))
    }

    var yourDisplayList: String { Self.list(screens.map(\.pixels)) }
    var uhd4KList: String { Self.list(screens.map { Self.uhd4K($0.pixels) }) }
    /// The main display's backing pixels and 4K at its shape ("1920×1080", "3840×2160").
    var mainPixels: String { Self.list(screens.prefix(1).map(\.pixels)) }
    var mainUHD4K: String { Self.list(screens.prefix(1).map { Self.uhd4K($0.pixels) }) }

    func label(_ resolution: GSRenderResolution) -> String {
        switch resolution {
        case .yourDisplay:
            String(localized: "Your Display (\(yourDisplayList))",
                   comment: "Render resolution option: the displays' own pixels, e.g. 1920×1080")
        case .uhd4K:
            String(localized: "4K (\(uhd4KList))",
                   comment: "Render resolution option: 4K at the display's shape, e.g. 3840×2160")
        case .full:
            String(localized: "Full (wallpaper's size)", comment: "Render resolution: the wallpaper's authored size")
        }
    }

    /// What `resolution` does, for the main display.
    func summary(_ resolution: GSRenderResolution) -> String {
        switch resolution {
        case .yourDisplay:
            String(localized: "Draws at your display's own pixels (\(mainPixels)), whatever size the wallpaper was made at.",
                   comment: "Render resolution Your Display, described under the picker; the main display's pixels, e.g. 1920×1080")
        case .uhd4K:
            String(localized: "Draws at 4K (\(mainUHD4K)) and fits that to your display: text, particles and effects get sharper on a smaller display, for more GPU work. Images can't show more detail than they have.",
                   comment: "Render resolution 4K, described under the picker; 4K at the main display's shape, e.g. 3840×2160")
        case .full:
            String(localized: "Draws at the size the wallpaper was made at and places that on your display, as Wallpaper Engine does.",
                   comment: "Render resolution Full, described under the picker")
        }
    }

    static func screen(_ screen: NSScreen) -> Screen {
        let points = screen.frame.size
        var pixels = CGSize(width: points.width * screen.backingScaleFactor,
                            height: points.height * screen.backingScaleFactor)
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let mode = CGDisplayCopyDisplayMode(CGDirectDisplayID(number.uint32Value)),
           mode.pixelWidth > 0, mode.pixelHeight > 0 {
            pixels = CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        return Screen(points: points, pixels: pixels)
    }

    static func current() -> RenderResolutionSizes {
        RenderResolutionSizes(screens: NSScreen.screens.map(screen))
    }
}

/// Keeps `RenderResolutionSizes` current as displays are added, removed or changed.
final class RenderResolutionSizesModel: ObservableObject {
    @Published private(set) var sizes = RenderResolutionSizes.current()
    private var observer: AnyCancellable?

    init() {
        observer = NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                let sizes = RenderResolutionSizes.current()
                if self?.sizes != sizes { self?.sizes = sizes }
            }
    }
}
