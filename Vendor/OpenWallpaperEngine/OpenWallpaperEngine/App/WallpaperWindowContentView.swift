import AppKit
import OWETheming

/// A wallpaper window's content: the display's wallpaper view, mirrored horizontally while the
/// display is a flipped clone (WE's "Flip clone display"). The mirror is a layer transform, so the
/// compositor flips the frame the display shows anyway: nothing renders again. While the display
/// is in a stretch it names the stretch's canvas, which a scene's view reads
/// (`NSView.stretchCanvasOnScreen`) to show its rect of the one frame.
final class WallpaperWindowContentView: NSView, StretchCanvasHosting {
    var isMirrored = false {
        didSet { if isMirrored != oldValue { applyMirror() } }
    }

    var stretchCanvas: CGRect?

    /// Theming's menu bar strip (Settings › Theming › Menu Bar): the window's top in the colour,
    /// fading out downwards over a few menu bar heights (`MenuBarStrip.fadeStops`). The menu bar is transparent over the wallpaper
    /// window, which covers the desktop picture, so this is what it shows. A plain layer above the
    /// wallpaper: the compositor draws it and nothing renders again.
    var menuBarStrip: MenuBarStripFill? {
        didSet { if menuBarStrip != oldValue { layoutStrip() } }
    }

    private var stripLayer: CAGradientLayer?

    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        applyMirror()
        layoutStrip()
    }

    /// The wallpaper's view, where a web wallpaper's page takes the desktop's mouse events.
    var content: NSView? { subviews.first }

    private func layoutStrip() {
        guard let strip = menuBarStrip, strip.height > 0, let host = layer else {
            stripLayer?.removeFromSuperlayer()
            stripLayer = nil
            return
        }
        let gradient = stripLayer ?? {
            let gradient = CAGradientLayer()
            gradient.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull(), "colors": NSNull()]
            // Above the wallpaper's view; layers don't take the desktop's mouse events.
            host.addSublayer(gradient)
            stripLayer = gradient
            return gradient
        }()
        let height = MenuBarStrip.fadeHeight(menuBarHeight: strip.height)
        gradient.frame = CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        // A layer-backed view's layer is not flipped: y grows upwards, so the colour starts at the top.
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.colors = MenuBarStrip.fadeStops.compactMap { strip.cgColor.copy(alpha: $0.alpha) }
        gradient.locations = MenuBarStrip.fadeStops.map { NSNumber(value: Double($0.location)) }
    }

    private func applyMirror() {
        // A view's backing layer has its anchor at the origin: mirror about x = 0, then move back.
        layer?.sublayerTransform = isMirrored
            ? CATransform3DTranslate(CATransform3DMakeScale(-1, 1, 1), -bounds.width, 0, 0)
            : CATransform3DIdentity
    }
}

/// A wallpaper window's menu bar strip: the colour and the menu bar's height in points.
struct MenuBarStripFill: Equatable {
    var color: ThemeColor
    var height: CGFloat

    /// `display`'s strip in `strips`; nil without one (no strips, or no menu bar on the display).
    init?(_ strips: DesktopPictureStrips?, display: CGDirectDisplayID?) {
        guard let strips, let display, let geometry = strips.displays[display], geometry.menuBarHeight > 0 else {
            return nil
        }
        color = strips.color
        height = geometry.menuBarHeight
    }

    var cgColor: CGColor {
        CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }
}
