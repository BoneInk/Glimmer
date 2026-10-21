import Combine
import Foundation

/// The document actions the app's menu asks the editor window for (File › Save, Save as New
/// Wallpaper…, Revert to Saved…): the window answers them as its toolbar buttons do.
@MainActor
public final class WallpaperEditorCommands {
    public enum Command: Equatable, Sendable {
        /// Saves the draft as the wallpaper's edits (`WallpaperEditorDocument.save`).
        case save
        /// Asks for a title, then saves a new wallpaper with the edits to the library.
        case saveAsNewWallpaper
        /// Asks before going back to the last save (undoable).
        case revertToSaved
        /// The View menu.
        case view(EditorViewCommand)
    }

    /// The window's view options, for the View menu's checkmarks; set while its window is open.
    public internal(set) weak var viewOptions: EditorViewOptions?
    /// Whether the window has particle systems to show Show Particle Control Points for.
    public internal(set) var hasParticles = false
    /// The particle editor's Show Control Points, for its checkmark.
    var showsParticleControlPoints: () -> Bool = { false }

    /// Whether the View menu's `command` is on (its checkmark).
    public func isOn(_ command: EditorViewCommand) -> Bool {
        guard let options = viewOptions else { return false }
        switch command {
        case .resetCamera: return false
        case .previewRatio(let ratio): return options.previewRatio == ratio
        case .showGrid: return options.showsGrid
        case .showSelectionBox: return options.showsSelectionBox
        case .showParticleCollision: return options.showsParticleCollision
        case .showParticleControlPoints: return showsParticleControlPoints()
        case .showHitboxes: return options.showsHitboxes
        case .desktopPreview: return options.preview == .desktop
        case .phonePreview: return options.preview == .phone
        case .lowFrameRate: return options.simulatesLowFrameRate
        }
    }

    /// Whether the View menu's `command` can be chosen now.
    public func isEnabled(_ command: EditorViewCommand) -> Bool {
        guard viewOptions != nil else { return false }
        switch command {
        case .showParticleControlPoints, .showParticleCollision: return hasParticles
        default: return true
        }
    }

    let requests = PassthroughSubject<Command, Never>()

    public init() {}

    public func send(_ command: Command) {
        requests.send(command)
    }
}
