import Foundation

/// The canvas's gizmo, as Wallpaper Engine's editor picks it in the canvas's upper left corner
/// (`ui_editor_gizmo_translate`, `_rotate`, `_scale`, `_multi`; its UI's `setGizmoMode`): one kind
/// of handle at a time, all of them together (2D scenes only), or none, which clicking the active
/// mode's button again picks. A scene opens in Multi (2D) or Translate (3D).
public enum GizmoMode: String, CaseIterable, Sendable, Identifiable {
    /// Arrows along the axes and a centre square: dragging moves the layer.
    case translate
    /// Rings about the axes: dragging turns the layer.
    case rotate
    /// Handles along the layer's own axes and a centre square: dragging scales it.
    case scale
    /// Every handle at once, as the editor's canvas had before the modes (2D scenes only).
    case multi
    /// No handles: a click only picks a layer.
    case none

    public var id: String { rawValue }

    /// The modes the canvas offers: Multi only in a 2D scene, as WE's toolbar shows it.
    public static func offered(spatial: Bool) -> [GizmoMode] {
        spatial ? [.translate, .rotate, .scale] : [.multi, .translate, .rotate, .scale]
    }

    /// The mode a scene opens in (WE: `setGizmoMode(is2d ? "multi" : "translate")`).
    public static func initial(spatial: Bool) -> GizmoMode { spatial ? .translate : .multi }

    /// Whether the mode's axes can be switched between World and Local Space: WE locks Multi,
    /// Scale and none (`isGizmoOrientationLocked`).
    public var hasSpaceChoice: Bool { self == .translate || self == .rotate }

    /// The space each mode starts in (WE's `resetGizmoOrientationState`): Translate the world's,
    /// the others the object's own. A 3D scene opens with Translate in World Space.
    public var defaultSpace: GizmoSpace { self == .translate ? .world : .local }

    public var translates: Bool { self == .translate || self == .multi }
    public var rotates: Bool { self == .rotate || self == .multi }
    public var scales: Bool { self == .scale || self == .multi }
}

/// Which axes the gizmo's handles follow (`ui_editor_gizmo_world_space`, `_local_space`): the
/// scene's, or the selected object's own turned with it. Each mode keeps its own; scaling is
/// always along the object's own axes.
public enum GizmoSpace: String, CaseIterable, Sendable, Identifiable {
    case world
    case local

    public var id: String { rawValue }
}
