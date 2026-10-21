import CoreGraphics

/// Which loops the screen saver plays on which displays (WE's `wallpaperconfigscreensaver`):
/// "Same as wallpaper" follows the wallpapers' layout with its clone and stretch groups; its own
/// layout applies to every connected display.
///
/// - Per display: a loop per distinct wallpaper and properties shown, drawn at the largest of
///   its displays' sizes; displays showing the same one share it (a clone's members do).
/// - Clone: the clone source's (the wallpapers' clone source, else the main display's) loop on
///   every display.
/// - Stretch: one loop of the source's wallpaper drawn at the canvas size (`DisplayCanvas`),
///   each display playing its rect of it (`crops`).
struct ScreenSaverLayoutPlan: Equatable {
    /// What a display shows: a wallpaper (its folder's path) with the properties it runs with.
    struct Content: Hashable {
        var id: String
        var properties: [String: String] = [:]
    }

    /// A connected display: `frame` in global points (origin bottom-left), `scale` pixels per point.
    struct Display: Equatable {
        var screenId: String
        var identity: String
        var frame: CGRect
        var scale: CGFloat
    }

    /// A size a loop is shown at, in backing pixels and in points.
    struct Size: Equatable {
        var pixels: SIMD2<Int>
        var points: SIMD2<Int>
    }

    struct Loop: Equatable {
        var content: Content
        /// The sizes its displays (or its canvas) show it at; the live screen saver draws the
        /// largest (`ScreenSaverPlugin.liveLoops`).
        var sizes: [Size]
        /// The identities of the displays that play it, in display order.
        var displays: [String]
        /// A stretch's canvas in global points; nil when each display shows the whole loop.
        var canvas: CGRect?
        /// Each stretched display's rect of the canvas, as fractions from its top-left.
        var crops: [String: CGRect] = [:]
    }

    /// The largest side of a stretch's loop: the HEVC encoder's limit, the only cap.
    static let maximumDimension: CGFloat = 8192

    private(set) var loops: [Loop] = []
    /// The identities of the displays planned for, in display order.
    private(set) var displays: [String] = []

    /// The plan for `displays` (main display first): `shown` is each display's content by display
    /// id (a clone or stretch member its source's), `resolution` the wallpapers' layout on them.
    init(_ screenSaverLayout: ScreenSaverDisplayLayout, wallpaperLayout: DisplayLayoutMode,
         resolution: DisplayLayoutResolution, displays: [Display], shown: [String: Content]) {
        self.displays = displays.map(\.identity)
        let layout = screenSaverLayout.effectiveLayout(wallpaperLayout: wallpaperLayout)
        let sameAsWallpaper = screenSaverLayout.sameAsWallpaper
        let screenIds = displays.map(\.screenId)
        switch layout {
        case .clone:
            let source = sameAsWallpaper ? resolution.clones.first?.source : nil
            guard let content = Self.sourceContent(source ?? screenIds.first, screenIds: screenIds, shown: shown) else { return }
            loops = Self.perDisplay(displays, content: content)
        case .stretch:
            let source = sameAsWallpaper ? resolution.stretches.first?.source : nil
            guard let content = Self.sourceContent(source ?? screenIds.first, screenIds: screenIds, shown: shown) else { return }
            loops = Self.stretch(displays, content: content)
        case .perDisplay:
            // Same as wallpaper keeps its stretch groups; clone groups already show one content.
            let stretches = sameAsWallpaper ? resolution.stretches : []
            let stretched = Set(stretches.flatMap(\.screens))
            loops = Self.perDisplay(displays.filter { !stretched.contains($0.screenId) }, shown: shown)
            for group in stretches {
                guard let content = shown[group.source] else { continue }
                loops += Self.stretch(displays.filter { group.screens.contains($0.screenId) }, content: content)
            }
        }
    }

    /// What each display shows for the screen saver: its displayed content, a split display its
    /// first region's (WE's screen saver splits aren't supported: the whole display plays that).
    static func shown(_ displayed: [String: Content], screenIds: [String],
                      resolution: DisplayLayoutResolution) -> [String: Content] {
        var shown: [String: Content] = [:]
        for screen in screenIds {
            let id = resolution.regions[screen]?.first?.id ?? screen
            if let content = displayed[id] { shown[screen] = content }
        }
        return shown
    }

    /// `source`'s content, else the first display's that shows one.
    private static func sourceContent(_ source: String?, screenIds: [String], shown: [String: Content]) -> Content? {
        source.flatMap { shown[$0] } ?? screenIds.lazy.compactMap { shown[$0] }.first
    }

    private static func size(of display: Display) -> Size {
        Size(pixels: SIMD2(Int(display.frame.width * display.scale), Int(display.frame.height * display.scale)),
             points: SIMD2(Int(display.frame.width), Int(display.frame.height)))
    }

    /// A loop per distinct content, in the order displays first show it.
    private static func perDisplay(_ displays: [Display], shown: [String: Content]) -> [Loop] {
        var loops: [Loop] = []
        for display in displays {
            guard let content = shown[display.screenId] else { continue }
            if let index = loops.firstIndex(where: { $0.content == content }) {
                loops[index].sizes.append(size(of: display))
                loops[index].displays.append(display.identity)
            } else {
                loops.append(Loop(content: content, sizes: [size(of: display)], displays: [display.identity]))
            }
        }
        return loops
    }

    /// One loop of `content` on every display.
    private static func perDisplay(_ displays: [Display], content: Content) -> [Loop] {
        perDisplay(displays, shown: Dictionary(displays.map { ($0.screenId, content) }, uniquingKeysWith: { first, _ in first }))
    }

    /// One loop over the displays' canvas; a single display shows it whole.
    private static func stretch(_ displays: [Display], content: Content) -> [Loop] {
        guard displays.count >= 2 else { return perDisplay(displays, content: content) }
        let canvas = DisplayCanvas.bounds(of: displays.map(\.frame))
        let scale = displays.map(\.scale).max() ?? 1
        let size = Size(pixels: evenSize(canvas.size, scale: scale), points: evenSize(canvas.size, scale: 1))
        let crops = Dictionary(displays.map { ($0.identity, DisplayCanvas.unitRect(of: $0.frame, in: canvas)) },
                               uniquingKeysWith: { first, _ in first })
        return [Loop(content: content, sizes: [size], displays: displays.map(\.identity), canvas: canvas, crops: crops)]
    }

    /// The canvas at `scale`, fitted into `maximumDimension`, each side even (4:2:0 video).
    private static func evenSize(_ canvas: CGSize, scale: CGFloat) -> SIMD2<Int> {
        let size = DisplayCanvas.pixelSize(of: canvas, scale: scale, maximumDimension: maximumDimension)
        return SIMD2(max(Int(size.width) & ~1, 2), max(Int(size.height) & ~1, 2))
    }
}
