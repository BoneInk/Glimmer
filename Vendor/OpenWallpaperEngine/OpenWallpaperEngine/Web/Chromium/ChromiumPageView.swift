import AppKit
import Metal
import QuartzCore

/// Shows a `ChromiumBrowserPage` in a wallpaper window: each frame is presented in the view's
/// `CAMetalLayer` (`ChromiumFramePresenter`).
/// The page is sized to the view in points at the display's scale, or less (`WebPageScale`),
/// and the desktop's mouse is forwarded to it (`ChromiumMouseForwarder`).
final class ChromiumPageView: NSView {
    let page: ChromiumBrowserPage
    private let presenter: ChromiumFramePresenter
    private var metalLayer: CAMetalLayer { presenter.layer }
    private var mouse: ChromiumMouseForwarder?

    /// The displays mirroring this page (a clone's or stretch's other members): the mouse over
    /// them reaches the page too, at the point they show.
    var mirrors: () -> [WebPageMirrorView] = { [] }

    /// Render web pages at one pixel per point on Retina displays (`WebPageScale`).
    var standardResolution = false {
        didSet { if standardResolution != oldValue { updateSize() } }
    }
    /// Render web pages at half the display's scale, WE's `-halfresolution` (`WebPageScale`).
    var halfResolution = false {
        didSet { if halfResolution != oldValue { updateSize() } }
    }

    init(page: ChromiumBrowserPage, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.page = page
        presenter = ChromiumFramePresenter(device: device)
        super.init(frame: .zero)
        wantsLayer = true
        layer = presenter.layer
        page.view = self
        page.onFrame = { [presenter] frame in presenter.enqueue(frame) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func makeBackingLayer() -> CALayer { metalLayer }

    override func layout() {
        super.layout()
        updateSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSize()
        if window != nil {
            if mouse == nil {
                let forwarder = ChromiumMouseForwarder(view: self, locate: { [weak self] in self?.pageScreenPoint($0) ?? $0 }) {
                    [weak self] event in self?.page.sendMouse(event)
                }
                forwarder.start()
                mouse = forwarder
            }
        } else {
            mouse?.stop()
            mouse = nil
        }
    }

    /// The screen point over this view showing what `screenPoint` shows: itself over this
    /// view's window, the matching point over the page's own window when it is over a mirror.
    func pageScreenPoint(_ screenPoint: NSPoint) -> NSPoint {
        guard let window, !window.frame.contains(screenPoint) else { return screenPoint }
        let frame = window.convertToScreen(convert(bounds, to: nil))
        for mirror in mirrors() {
            if let point = mirror.sourcePoint(screenPoint, sourceFrame: frame) { return point }
        }
        return screenPoint
    }

    /// Points to pixels for the page (`WebPageScale.pixelsPerPoint`).
    static func pageScale(standardResolution: Bool, halfResolution: Bool, backingScale: CGFloat) -> Double {
        Double(WebPageScale.pixelsPerPoint(standardResolution: standardResolution, halfResolution: halfResolution,
                                           backingScale: backingScale))
    }

    private func updateSize() {
        let width = Int(bounds.width.rounded()), height = Int(bounds.height.rounded())
        guard width > 0, height > 0 else { return }
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let scale = Self.pageScale(standardResolution: standardResolution, halfResolution: halfResolution,
                                   backingScale: backing)
        metalLayer.contentsScale = backing
        page.resize(width: width, height: height, scale: scale)
    }
}

/// Forwards the desktop's mouse to a Chromium page as WE does for an interactive web wallpaper:
/// wallpaper windows ignore mouse events, so presses, releases, moves and scrolls are watched with
/// the same global and local monitors as `DesktopClickMonitor`, and only those that land on the
/// wallpaper (no other window above it at that point) reach the page.
final class ChromiumMouseForwarder {
    private weak var view: NSView?
    private let send: (ChromiumMouseEvent) -> Void
    private let landsOnWallpaper: (NSPoint) -> Bool
    /// The point over `view` that shows what a screen point shows (over a mirror, its source's).
    private let locate: (NSPoint) -> NSPoint
    private var monitors: [Any] = []
    private var inside = false
    /// A button pressed on the wallpaper: its drags and release go to the page wherever they are.
    private var pressed: ChromiumMouseEvent.Button?

    init(view: NSView, landsOnWallpaper: @escaping (NSPoint) -> Bool = DesktopClickMonitor.landsOnWallpaper,
         locate: @escaping (NSPoint) -> NSPoint = { $0 }, send: @escaping (ChromiumMouseEvent) -> Void) {
        self.view = view
        self.landsOnWallpaper = landsOnWallpaper
        self.locate = locate
        self.send = send
    }

    deinit { stop() }

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                           .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                           .otherMouseDown, .otherMouseUp, .scrollWheel]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handle(_ event: NSEvent) {
        guard let view, let window = view.window else { return }
        let hitPoint = NSEvent.mouseLocation
        let viewFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
        // Each NSEvent property is read only for the event types that have it (AppKit raises otherwise).
        var input = ChromiumMouseMapping.Input(type: event.type, screenPoint: locate(hitPoint),
                                               modifierFlags: event.modifierFlags)
        input.hitPoint = hitPoint
        switch event.type {
        case .scrollWheel:
            input.scrollDeltaX = event.scrollingDeltaX
            input.scrollDeltaY = event.scrollingDeltaY
            input.preciseScrolling = event.hasPreciseScrollingDeltas
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            input.buttonNumber = event.buttonNumber
            input.clickCount = event.clickCount
        default:
            break
        }
        var state = ChromiumMouseMapping.State(inside: inside, pressed: pressed)
        let events = ChromiumMouseMapping.events(for: input, viewFrameInScreen: viewFrame, state: &state,
                                                 landsOnWallpaper: landsOnWallpaper)
        inside = state.inside
        pressed = state.pressed
        events.forEach(send)
    }
}

/// The pure part of `ChromiumMouseForwarder`: AppKit's screen coordinates (bottom-left origin) to
/// a page's points (top-left origin), and which events the page gets.
enum ChromiumMouseMapping {
    struct Input {
        var type: NSEvent.EventType
        var screenPoint: NSPoint
        var buttonNumber: Int = 0
        var clickCount: Int = 1
        var scrollDeltaX: CGFloat = 0
        var scrollDeltaY: CGFloat = 0
        var preciseScrolling = true
        var modifierFlags: NSEvent.ModifierFlags = []
        /// Where the pointer really is, when `screenPoint` is the point over the page's own view
        /// that a mirror shows there: whether it lands on the wallpaper is judged here.
        var hitPoint: NSPoint?

        var landingPoint: NSPoint { hitPoint ?? screenPoint }
    }

    struct State: Equatable {
        var inside = false
        var pressed: ChromiumMouseEvent.Button?
    }

    /// `screenPoint` in the view whose frame on screen is `viewFrameInScreen`, from its top-left
    /// corner; nil outside it. Half-open from the top-left: the top edge (`maxY` on screen) is the
    /// view's first row, the bottom edge is outside.
    static func viewPoint(_ screenPoint: NSPoint, viewFrameInScreen frame: NSRect) -> CGPoint? {
        guard screenPoint.x >= frame.minX, screenPoint.x < frame.maxX,
              screenPoint.y > frame.minY, screenPoint.y <= frame.maxY else { return nil }
        return CGPoint(x: screenPoint.x - frame.minX, y: frame.maxY - screenPoint.y)
    }

    /// CEF's `cef_event_flags_t` for AppKit's modifiers and the held button.
    static func modifiers(_ flags: NSEvent.ModifierFlags, pressed: ChromiumMouseEvent.Button?) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.capsLock) { result |= 1 << 0 }
        if flags.contains(.shift) { result |= 1 << 1 }
        if flags.contains(.control) { result |= 1 << 2 }
        if flags.contains(.option) { result |= 1 << 3 }
        switch pressed {
        case .left: result |= 1 << 4
        case .middle: result |= 1 << 5
        case .right: result |= 1 << 6
        case nil: break
        }
        if flags.contains(.command) { result |= 1 << 7 }
        return result
    }

    static func button(_ type: NSEvent.EventType, buttonNumber: Int) -> ChromiumMouseEvent.Button {
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged: return .left
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: return .right
        default: return buttonNumber == 1 ? .right : buttonNumber == 0 ? .left : .middle
        }
    }

    /// The page events for one desktop event. Presses count only where they land on the wallpaper;
    /// a press's drags and release follow it; moves outside the wallpaper end with one leave.
    static func events(for input: Input, viewFrameInScreen frame: NSRect, state: inout State,
                       landsOnWallpaper: (NSPoint) -> Bool) -> [ChromiumMouseEvent] {
        let point = viewPoint(input.screenPoint, viewFrameInScreen: frame)
        // While a button is held the page keeps hearing it, clamped to the view.
        let clamped = point ?? CGPoint(x: min(max(input.screenPoint.x - frame.minX, 0), frame.width),
                                       y: min(max(frame.maxY - input.screenPoint.y, 0), frame.height))
        func event(_ kind: ChromiumMouseEvent.Kind, at location: CGPoint, button: ChromiumMouseEvent.Button = .left,
                   deltaX: Double = 0, deltaY: Double = 0) -> ChromiumMouseEvent {
            ChromiumMouseEvent(kind: kind, x: location.x, y: location.y, button: button,
                               clickCount: max(1, input.clickCount), deltaX: deltaX, deltaY: deltaY,
                               modifiers: modifiers(input.modifierFlags, pressed: state.pressed))
        }
        switch input.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard let point, landsOnWallpaper(input.landingPoint) else { return [] }
            let pressedButton = button(input.type, buttonNumber: input.buttonNumber)
            state.pressed = pressedButton
            state.inside = true
            return [event(.move, at: point), event(.down, at: point, button: pressedButton)]
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard let pressed = state.pressed else { return [] }
            let up = event(.up, at: clamped, button: pressed)
            state.pressed = nil
            return [up]
        case .leftMouseDragged, .rightMouseDragged:
            guard state.pressed != nil else { return [] }
            return [event(.move, at: clamped)]
        case .mouseMoved:
            if let point, landsOnWallpaper(input.landingPoint) {
                state.inside = true
                return [event(.move, at: point)]
            }
            guard state.inside else { return [] }
            state.inside = false
            return [event(.leave, at: clamped)]
        case .scrollWheel:
            guard let point, landsOnWallpaper(input.landingPoint) else { return [] }
            // CEF takes wheel deltas in pixels; a notched wheel's lines are 40 px, as Chromium's.
            let factor: CGFloat = input.preciseScrolling ? 1 : 40
            return [event(.wheel, at: point, deltaX: Double(input.scrollDeltaX * factor),
                          deltaY: Double(input.scrollDeltaY * factor))]
        default:
            return []
        }
    }
}
