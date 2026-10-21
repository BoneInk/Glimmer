import AppKit

extension NSView {
    /// Whether an ancestor mirrors this view horizontally on screen (a wallpaper window showing a flipped clone),
    /// so a point read in its coordinates must be mirrored to match what the display shows.
    var isMirroredOnScreen: Bool {
        var mirrored = false
        var ancestor = superview
        while let view = ancestor {
            if let layer = view.layer, layer.sublayerTransform.m11 < 0 { mirrored.toggle() }
            ancestor = view.superview
        }
        return mirrored
    }
}
