import Foundation

/// How the editor's canvas shows the scene: the scene's rectangle inside the canvas, at a zoom and
/// pan. Scene space has y up from the bottom-left corner (WE's orthographic space); the canvas has
/// y down from its top-left, as SwiftUI and flipped AppKit views do.
public struct CanvasViewport: Hashable, Sendable {
    /// The scene's size in scene units.
    public var sceneSize: SIMD2<Double>
    /// The canvas's size in points.
    public var canvasSize: SIMD2<Double>
    /// Points per scene unit.
    public private(set) var scale: Double
    /// The scene's centre, offset from the canvas's centre, in points.
    public var pan: SIMD2<Double>
    /// The largest scale: the live view's drawable can't pass `maximumPixels` on its longer side.
    public var maximumPixels: Double = 16384
    /// Points to pixels of the canvas's display.
    public var backingScale: Double = 2

    /// Room left around the fitted scene, in points.
    public static let fitMargin: Double = 24

    public init(sceneSize: SIMD2<Double>, canvasSize: SIMD2<Double>) {
        self.sceneSize = SIMD2(max(sceneSize.x, 1), max(sceneSize.y, 1))
        self.canvasSize = canvasSize
        scale = 1
        pan = .zero
        fit()
    }

    /// The scale that shows the whole scene with a margin.
    public var fitScale: Double {
        let room = SIMD2(max(canvasSize.x - 2 * Self.fitMargin, 1), max(canvasSize.y - 2 * Self.fitMargin, 1))
        return min(room.x / sceneSize.x, room.y / sceneSize.y)
    }

    public var minimumScale: Double { fitScale / 10 }

    public var maximumScale: Double {
        let longest = max(sceneSize.x, sceneSize.y) * max(backingScale, 1)
        return max(min(32, maximumPixels / longest), fitScale)
    }

    /// The scene's rectangle in the canvas: top-left corner and size, in points.
    public var sceneRect: (origin: SIMD2<Double>, size: SIMD2<Double>) {
        let size = sceneSize * scale
        let centre = canvasSize / 2 + pan
        return (centre - size / 2, size)
    }

    public func canvasPoint(_ scenePoint: SIMD2<Double>) -> SIMD2<Double> {
        let rect = sceneRect
        return SIMD2(rect.origin.x + scenePoint.x * scale, rect.origin.y + (sceneSize.y - scenePoint.y) * scale)
    }

    public func scenePoint(_ canvasPoint: SIMD2<Double>) -> SIMD2<Double> {
        let rect = sceneRect
        return SIMD2((canvasPoint.x - rect.origin.x) / scale, sceneSize.y - (canvasPoint.y - rect.origin.y) / scale)
    }

    public mutating func fit() {
        scale = fitScale
        pan = .zero
    }

    /// Zooms to `newScale` (clamped) keeping the scene point under `anchor` (canvas points) where
    /// it is, as pinching and ⌘-scrolling do; the canvas's centre without one.
    public mutating func zoom(to newScale: Double, anchor: SIMD2<Double>? = nil) {
        let anchor = anchor ?? canvasSize / 2
        let fixed = scenePoint(anchor)
        scale = min(max(newScale, minimumScale), maximumScale)
        let moved = canvasPoint(fixed)
        pan += anchor - moved
    }

    /// Scene units to display pixels: 1 shows the scene at its own resolution (a 1920 × 1080
    /// scene pixel for pixel on a 1080p display). The zoom readout shows it as a percentage.
    public var zoomFactor: Double { scale * max(backingScale, 1) }

    /// The zoom steps of ⌘+ and ⌘−, as Preview and Pixelmator Pro step.
    public static let zoomSteps: [Double] = [0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.5, 2, 3, 4, 6, 8, 12, 16, 32]

    public mutating func zoomIn() {
        let next = Self.zoomSteps.first { $0 > zoomFactor * 1.001 }
        zoom(to: next.map { $0 / max(backingScale, 1) } ?? maximumScale)
    }

    public mutating func zoomOut() {
        let next = Self.zoomSteps.last { $0 < zoomFactor * 0.999 }
        zoom(to: next.map { $0 / max(backingScale, 1) } ?? minimumScale)
    }

    /// The scene at its own resolution: one scene unit to one display pixel.
    public mutating func actualSize() {
        zoom(to: 1 / max(backingScale, 1))
    }

    public mutating func resize(canvas size: SIMD2<Double>) {
        let wasFitted = abs(scale - fitScale) < 1e-9 && pan == .zero
        canvasSize = size
        if wasFitted { fit() } else { scale = min(max(scale, minimumScale), maximumScale) }
    }
}
