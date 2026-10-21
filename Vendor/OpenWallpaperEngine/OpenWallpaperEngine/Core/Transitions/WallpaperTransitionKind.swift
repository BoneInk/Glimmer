import Foundation

/// A transition between two wallpapers: WE's playlist transitions, by the id WE stores
/// (`settings.transition`, `transitionpool`) and compiles its transition shader with (`FADEEFFECT`).
enum WallpaperTransitionKind: Int, CaseIterable, Codable, Identifiable, Sendable {
    case fade = 0
    case mosaic = 1
    case diffuse = 2
    case horizontalSlide = 3
    case verticalSlide = 4
    case horizontalFade = 5
    case verticalFade = 6
    case clouds = 7
    case burntPaper = 8
    case circular = 9
    case zipper = 10
    case door = 11
    case lines = 12
    case zoom = 13
    case drip = 14
    case pixelate = 15
    case bricks = 16
    case paint = 17
    case fadeToBlack = 18
    case twister = 19
    case blackHole = 20
    case crt = 21
    case radialWipe = 22
    case glassShatter = 23
    case bullets = 24
    case ice = 25
    case boilover = 26

    var id: Int { rawValue }

    /// The order WE's settings list them in (`getTransitionOptions`).
    static let menuOrder: [WallpaperTransitionKind] = [
        .fade, .fadeToBlack, .mosaic, .diffuse, .horizontalSlide, .verticalSlide, .horizontalFade,
        .verticalFade, .clouds, .burntPaper, .circular, .zipper, .door, .lines, .radialWipe, .zoom,
        .drip, .pixelate, .bricks, .paint, .twister, .blackHole, .crt, .glassShatter, .bullets, .ice,
        .boilover,
    ]

    /// The value WE stores for it: its id as a string.
    var storedValue: String { String(rawValue) }

    init?(storedValue: String) {
        guard let id = Int(storedValue), let kind = WallpaperTransitionKind(rawValue: id) else { return nil }
        self = kind
    }

    var title: LocalizedStringResource {
        switch self {
        case .fade: return LocalizedStringResource("Fade", comment: "Wallpaper transition")
        case .mosaic: return LocalizedStringResource("Mosaic", comment: "Wallpaper transition")
        case .diffuse: return LocalizedStringResource("Diffuse", comment: "Wallpaper transition")
        case .horizontalSlide: return LocalizedStringResource("Horizontal slide", comment: "Wallpaper transition")
        case .verticalSlide: return LocalizedStringResource("Vertical slide", comment: "Wallpaper transition")
        case .horizontalFade: return LocalizedStringResource("Horizontal fade", comment: "Wallpaper transition")
        case .verticalFade: return LocalizedStringResource("Vertical fade", comment: "Wallpaper transition")
        case .clouds: return LocalizedStringResource("Clouds", comment: "Wallpaper transition")
        case .burntPaper: return LocalizedStringResource("Burnt paper", comment: "Wallpaper transition")
        case .circular: return LocalizedStringResource("Circular", comment: "Wallpaper transition")
        case .zipper: return LocalizedStringResource("Zipper", comment: "Wallpaper transition")
        case .door: return LocalizedStringResource("Door", comment: "Wallpaper transition")
        case .lines: return LocalizedStringResource("Lines", comment: "Wallpaper transition")
        case .zoom: return LocalizedStringResource("Zoom", comment: "Wallpaper transition")
        case .drip: return LocalizedStringResource("Drip", comment: "Wallpaper transition")
        case .pixelate: return LocalizedStringResource("Pixelate", comment: "Wallpaper transition")
        case .bricks: return LocalizedStringResource("Bricks", comment: "Wallpaper transition")
        case .paint: return LocalizedStringResource("Paint", comment: "Wallpaper transition")
        case .fadeToBlack: return LocalizedStringResource("Fade to black", comment: "Wallpaper transition")
        case .twister: return LocalizedStringResource("Twister", comment: "Wallpaper transition")
        case .blackHole: return LocalizedStringResource("Black hole", comment: "Wallpaper transition")
        case .crt: return LocalizedStringResource("CRT", comment: "Wallpaper transition")
        case .radialWipe: return LocalizedStringResource("Radial wipe", comment: "Wallpaper transition")
        case .glassShatter: return LocalizedStringResource("Glass shatter", comment: "Wallpaper transition")
        case .bullets: return LocalizedStringResource("Bullets", comment: "Wallpaper transition")
        case .ice: return LocalizedStringResource("Ice", comment: "Wallpaper transition")
        case .boilover: return LocalizedStringResource("Boilover", comment: "Wallpaper transition")
        }
    }
}
