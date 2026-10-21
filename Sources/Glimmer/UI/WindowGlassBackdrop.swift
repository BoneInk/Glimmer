import AppKit
import SwiftUI

private struct WindowGlassReduceTransparencyKey: EnvironmentKey {
    static let defaultValue = false
}

private struct WindowGlassReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Review-only injection; production follows the OS accessibility setting.
    var windowGlassReduceMotionOverride: Bool {
        get { self[WindowGlassReduceMotionKey.self] }
        set { self[WindowGlassReduceMotionKey.self] = newValue }
    }

    /// Review-only injection; production follows the OS accessibility setting.
    var windowGlassReduceTransparencyOverride: Bool {
        get { self[WindowGlassReduceTransparencyKey.self] }
        set { self[WindowGlassReduceTransparencyKey.self] = newValue }
    }
}

/// Native compositing of the pixels behind the manager window. This never reads,
/// copies or captures desktop images and does not affect wallpaper/player windows.
@MainActor
enum WindowGlassBackdrop {
    static func makeWindow<Content: View>(rootView: Content, forceReduceTransparency: Bool = false,
                                          hidesPageTitle: Bool = false) -> NSWindow {
        let root = rootView.background {
            WindowGlassBackdropLayer(forceReduceTransparency: forceReduceTransparency)
                .ignoresSafeArea()
        }
        let controller = NSHostingController(rootView: root)
        let window = GlassHostingWindow(contentViewController: controller)
        window.hidesPageTitle = hidesPageTitle
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        return window
    }
}

/// SwiftUI resets title visibility when adding/removing a toolbar. Keep this policy
/// on the window itself so every route obeys it, while retaining its accessible title.
@MainActor
private final class GlassHostingWindow: NSWindow {
    var hidesPageTitle = false {
        didSet {
            if hidesPageTitle { super.titleVisibility = .hidden }
        }
    }

    override var titleVisibility: NSWindow.TitleVisibility {
        get { super.titleVisibility }
        set { super.titleVisibility = hidesPageTitle ? .hidden : newValue }
    }
}

/// Keep the effect within SwiftUI's own background ordering. AppKit may rearrange
/// frame/titlebar views during navigation; no view is inserted into that hierarchy.
private struct WindowGlassBackdropLayer: NSViewRepresentable {
    let forceReduceTransparency: Bool

    func makeNSView(context: Context) -> WindowBackdropView {
        WindowBackdropView(forceReduceTransparency: forceReduceTransparency)
    }

    func updateNSView(_ view: WindowBackdropView, context: Context) {}
}

@MainActor
private final class WindowBackdropView: NSView {
    private let effect = NSVisualEffectView()
    private let opaqueFallback = NSView()
    private let forceReduceTransparency: Bool

    init(forceReduceTransparency: Bool) {
        self.forceReduceTransparency = forceReduceTransparency
        super.init(frame: .zero)
        effect.blendingMode = .behindWindow
        effect.material = .underWindowBackground
        effect.state = .active
        opaqueFallback.wantsLayer = true
        for child in [effect, opaqueFallback] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: leadingAnchor),
                child.trailingAnchor.constraint(equalTo: trailingAnchor),
                child.topAnchor.constraint(equalTo: topAnchor),
                child.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateAccessibility),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAccessibility()
    }

    @objc private func updateAccessibility() {
        let reduced = forceReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        effect.isHidden = reduced
        opaqueFallback.isHidden = !reduced
        effectiveAppearance.performAsCurrentDrawingAppearance {
            opaqueFallback.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
