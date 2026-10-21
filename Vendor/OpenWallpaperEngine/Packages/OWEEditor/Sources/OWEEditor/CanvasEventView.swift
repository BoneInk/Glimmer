import AppKit
import SwiftUI

/// The canvas's pointer, scroll, pinch and key input, in canvas points (y down). An AppKit view,
/// since SwiftUI has no scroll-wheel or modifier-aware drag events on macOS 14.
struct CanvasEventView: NSViewRepresentable {
    struct Handlers {
        /// The flag says the press pans (Space held, or the middle button).
        var mouseDown: (SIMD2<Double>, NSEvent, Bool) -> Void = { _, _, _ in }
        var mouseDragged: (SIMD2<Double>, NSEvent) -> Void = { _, _ in }
        var mouseUp: (SIMD2<Double>, NSEvent) -> Void = { _, _ in }
        /// nil when the pointer leaves the canvas.
        var mouseMoved: (SIMD2<Double>?) -> Void = { _ in }
        /// Scrolling pans; ⌘-scroll zooms about the pointer.
        var scroll: (_ delta: SIMD2<Double>, _ at: SIMD2<Double>, NSEvent) -> Void = { _, _, _ in }
        var magnify: (_ factor: Double, _ at: SIMD2<Double>) -> Void = { _, _ in }
        /// Returns whether the key was handled.
        var key: (NSEvent) -> Bool = { _ in false }
        var cursor: (SIMD2<Double>) -> NSCursor = { _ in .arrow }
    }

    var handlers: Handlers

    func makeNSView(context: Context) -> CanvasEventNSView {
        let view = CanvasEventNSView()
        view.handlers = handlers
        return view
    }

    func updateNSView(_ view: CanvasEventNSView, context: Context) {
        view.handlers = handlers
    }
}

final class CanvasEventNSView: NSView {
    var handlers = CanvasEventView.Handlers()
    /// Space held: dragging pans, as in Photoshop, Pixelmator Pro and Figma.
    private(set) var isSpaceDown = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func point(_ event: NSEvent) -> SIMD2<Double> {
        let location = convert(event.locationInWindow, from: nil)
        return SIMD2(Double(location.x), Double(location.y))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        handlers.mouseDown(point(event), event, isSpaceDown)
    }

    override func mouseDragged(with event: NSEvent) { handlers.mouseDragged(point(event), event) }
    override func mouseUp(with event: NSEvent) { handlers.mouseUp(point(event), event) }
    // The middle button pans too.
    override func otherMouseDown(with event: NSEvent) { handlers.mouseDown(point(event), event, true) }
    override func otherMouseDragged(with event: NSEvent) { handlers.mouseDragged(point(event), event) }
    override func otherMouseUp(with event: NSEvent) { handlers.mouseUp(point(event), event) }

    override func mouseMoved(with event: NSEvent) {
        let location = point(event)
        handlers.mouseMoved(location)
        handlers.cursor(location).set()
    }

    override func mouseExited(with event: NSEvent) {
        handlers.mouseMoved(nil)
        NSCursor.arrow.set()
    }

    override func scrollWheel(with event: NSEvent) {
        // Line scrolls (a mouse wheel) are a few points each; trackpads report points.
        let scale = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        handlers.scroll(SIMD2(Double(event.scrollingDeltaX), Double(event.scrollingDeltaY)) * scale, point(event), event)
    }

    override func magnify(with event: NSEvent) {
        handlers.magnify(1 + Double(event.magnification), point(event))
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            isSpaceDown = true
            NSCursor.openHand.set()
            return
        }
        if !handlers.key(event) { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            isSpaceDown = false
            NSCursor.arrow.set()
            return
        }
        super.keyUp(with: event)
    }

    override func resignFirstResponder() -> Bool {
        isSpaceDown = false
        return super.resignFirstResponder()
    }
}
