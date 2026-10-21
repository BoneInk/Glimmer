import Foundation

/// The Wallpaper Editor's View menu, Wallpaper Engine's editor View menu and its canvas toolbar's
/// view buttons, as the app's menu bar lists them (`EditorViewCommand.menu`) and sends them
/// (`WallpaperEditorCommands.Command.view`). WE's Restart Preview (web wallpapers), Reset Layout,
/// Windows, Enable Asset Creation and Show Stats aren't here: the editor has no such panes or
/// they live elsewhere.
public enum EditorViewCommand: Hashable, Sendable {
    /// The canvas fitted again (WE's `resetView`).
    case resetCamera
    case previewRatio(EditorViewOptions.PreviewRatio)
    case showGrid
    case showSelectionBox
    case showParticleCollision
    case showParticleControlPoints
    /// Show Hitboxes: the puppets' per-bone hit boxes (`PuppetHitBoxOverlay`).
    case showHitboxes
    case desktopPreview
    case phonePreview
    /// Low FPS Simulation: the canvas drawn at WE's 22 frames a second.
    case lowFrameRate

    /// The menu's title.
    public var title: String {
        switch self {
        case .resetCamera: return CV("Reset Camera")
        case .previewRatio(let ratio): return ratio.title
        case .showGrid: return CV("Show Grid")
        case .showSelectionBox: return CV("Show Selection Box")
        case .showParticleCollision: return CV("Show Particle Collision")
        case .showParticleControlPoints: return CV("Show Particle Control Points")
        case .showHitboxes: return CV("Show Hitboxes")
        case .desktopPreview: return CV("Show Desktop Preview")
        case .phonePreview: return CV("Show Phone Preview")
        case .lowFrameRate: return CV("Low FPS Simulation")
        }
    }

    /// A menu's entries: a command, a submenu, or a separator.
    public indirect enum MenuEntry: Sendable {
        case command(EditorViewCommand)
        case submenu(String, [MenuEntry])
        case separator
    }

    /// The View menu, in Wallpaper Engine's order.
    public static var menu: [MenuEntry] {
        [
            .command(.resetCamera),
            .submenu(CV("Preview Aspect Ratio"), EditorViewOptions.PreviewRatio.allCases.map { .command(.previewRatio($0)) }),
            .separator,
            .command(.showGrid),
            .command(.showSelectionBox),
            .submenu(CV("Show Debug"), [.command(.showParticleCollision), .command(.showParticleControlPoints),
                                             .command(.showHitboxes)]),
            .separator,
            .command(.desktopPreview),
            .command(.phonePreview),
            .command(.lowFrameRate),
        ]
    }

    /// The View menu's own title.
    public static var menuTitle: String { CV("View") }
}
