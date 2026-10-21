import AppKit
import SwiftUI

/// A frosted window or pane background: the desktop (the live wallpaper) shows through, blurred.
///
/// It blends behind the window and follows the window's active state instead of forcing `.active`,
/// so an inactive window dims as usual and Reduce Transparency turns it opaque. Only for surfaces
/// that aren't content; never under wallpaper previews, tiles or editors.
struct FrostedBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

extension View {
    /// Puts a frosted, behind-window material under the whole view, safe areas included.
    func frostedWindowBackground(_ material: NSVisualEffectView.Material = .underWindowBackground) -> some View {
        background {
            FrostedBackground(material: material)
                .ignoresSafeArea()
        }
    }
}
