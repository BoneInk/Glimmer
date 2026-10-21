import AppKit
import MetalKit

/// A view's AppKit state as a frame needs it, taken on the main thread (`SceneViewSnapshots.refresh`)
/// so a render thread never reads the view, its window or its screen.
struct SceneViewSnapshot {
    /// The view, in points.
    var pointSize: SIMD2<Float> = .zero
    var frameRateLimit = 60
    /// The view's bounds in screen coordinates, and its screen's frame; nil off-screen.
    var viewInScreen: CGRect?
    var screenFrame: CGRect?
    var headroom = SceneDisplayHeadroom()
    /// The display shows the view mirrored (a flipped clone): the cursor is mirrored to match.
    var mirrored = false
    /// The canvas the view's display shows its part of while it is in a stretch, in global points.
    var canvas: CGRect?
    /// The view's layer, which Core Animation lets any thread configure.
    weak var layer: CAMetalLayer?

    /// The cursor in the view's points (origin bottom-left) when `mouse` is on the view (its
    /// screen, or its region of a split screen).
    func cursor(at mouse: CGPoint) -> SIMD2<Float>? {
        guard let viewInScreen, let screenFrame, screenFrame.contains(mouse), viewInScreen.contains(mouse) else { return nil }
        let x = mirrored ? viewInScreen.maxX - mouse.x : mouse.x - viewInScreen.minX
        return SIMD2(Float(x), Float(mouse.y - viewInScreen.minY))
    }

    /// The cursor on the stretch's canvas, in points from its bottom-left, when `mouse` is on this
    /// view's display: each display maps the cursor it has into the one canvas.
    func canvasCursor(at mouse: CGPoint) -> SIMD2<Float>? {
        guard let canvas, let viewInScreen, viewInScreen.contains(mouse) else { return nil }
        let point = DisplayCanvas.point(mouse, in: canvas)
        return SIMD2(Float(point.x), Float(point.y))
    }

    /// The view's rect on the stretch's canvas, in points from the canvas's bottom-left.
    var rectInCanvas: CGRect? {
        guard let canvas, let viewInScreen else { return nil }
        return viewInScreen.offsetBy(dx: -canvas.minX, dy: -canvas.minY)
    }
}

/// The snapshots of the views a render thread draws (`SceneRenderLoop`). A view without one is
/// drawn on the main thread and read directly. Keyed by the view, which each entry holds weakly:
/// a released view's entry never answers for a new view that reuses its address. Thread-safe.
enum SceneViewSnapshots {
    private struct Entry {
        weak var view: MTKView?
        var snapshot: SceneViewSnapshot
    }
    private static let lock = NSLock()
    private static var entries: [ObjectIdentifier: Entry] = [:]

    /// Main: takes `view`'s state now.
    static func refresh(_ view: MTKView) {
        dispatchPrecondition(condition: .onQueue(.main))
        var snapshot = SceneViewSnapshot()
        snapshot.pointSize = SIMD2(Float(view.bounds.width), Float(view.bounds.height))
        snapshot.frameRateLimit = view.preferredFramesPerSecond
        if let window = view.window, let screen = window.screen {
            snapshot.viewInScreen = window.convertToScreen(view.convert(view.bounds, to: nil))
            snapshot.screenFrame = screen.frame
            snapshot.headroom = SceneDisplayHeadroom(screen: screen)
            snapshot.mirrored = view.isMirroredOnScreen
            snapshot.canvas = view.stretchCanvasOnScreen
        }
        snapshot.layer = view.layer as? CAMetalLayer
        lock.withLock {
            entries = entries.filter { $0.value.view != nil }
            entries[ObjectIdentifier(view)] = Entry(view: view, snapshot: snapshot)
        }
    }

    /// `view` is no longer drawn on a render thread.
    static func remove(_ view: MTKView) {
        lock.withLock { entries[ObjectIdentifier(view)] = nil }
    }

    static func snapshot(of view: MTKView) -> SceneViewSnapshot? {
        lock.withLock {
            guard let entry = entries[ObjectIdentifier(view)], entry.view === view else { return nil }
            return entry.snapshot
        }
    }
}
