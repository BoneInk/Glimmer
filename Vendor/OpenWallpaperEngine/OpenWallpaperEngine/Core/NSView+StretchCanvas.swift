import AppKit

/// A view that shows its display's part of a stretched wallpaper's canvas (a wallpaper window's
/// content while its display is in a stretch).
protocol StretchCanvasHosting: AnyObject {
    /// The canvas in global desktop points (`DisplayCanvas`), nil while the display isn't stretched.
    var stretchCanvas: CGRect? { get }
}

extension NSView {
    /// The canvas of the stretch this view's display shows a part of, from the nearest ancestor
    /// hosting one; nil while it isn't stretched.
    var stretchCanvasOnScreen: CGRect? {
        var ancestor = superview
        while let view = ancestor {
            if let host = view as? StretchCanvasHosting { return host.stretchCanvas }
            ancestor = view.superview
        }
        return nil
    }
}
