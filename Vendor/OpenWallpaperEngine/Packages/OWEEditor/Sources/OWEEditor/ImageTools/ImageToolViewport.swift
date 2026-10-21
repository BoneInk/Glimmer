import AppKit
import SwiftUI
import OWEInspectorKit

/// The image tools' text, from their own table (`Resources/ImageTools.xcstrings`), in every
/// language the app ships; WE's own wording (`ui_editor_character_separation_*`) where it has one.
let IL = EditorText(table: "ImageTools")

/// Where an image tool's picture (its pixels, y down) lands in its canvas: fitted, zoomed about
/// the pointer, panned (WE's tools: the wheel zooms, a drag with the other button pans).
struct ImageToolViewport: Equatable {
    var zoom: Double = 1
    var pan = SIMD2<Double>.zero
    var size = SIMD2<Double>(800, 600)
    var imageSize = SIMD2<Double>(1, 1)

    /// The picture's top-left corner in the canvas.
    var origin: SIMD2<Double> { size / 2 + pan - imageSize * zoom / 2 }

    func view(_ pixel: SIMD2<Double>) -> CGPoint {
        let point = origin + pixel * zoom
        return CGPoint(x: point.x, y: point.y)
    }

    func pixel(_ point: SIMD2<Double>) -> SIMD2<Double> { (point - origin) / max(zoom, 1e-6) }

    var imageRect: CGRect {
        let corner = origin
        return CGRect(x: corner.x, y: corner.y, width: imageSize.x * zoom, height: imageSize.y * zoom)
    }

    /// Fits the picture with a margin (WE's Reset View).
    mutating func fit() {
        let room = SIMD2(max(size.x - 40, 1), max(size.y - 40, 1))
        zoom = min(room.x / max(imageSize.x, 1), room.y / max(imageSize.y, 1))
        pan = .zero
    }

    /// Zooms by `factor` keeping the pixel under `anchor` still (WE: 0.1…10 times the fit).
    mutating func zoom(by factor: Double, anchor: SIMD2<Double>) {
        let fixed = pixel(anchor)
        zoom = min(max(zoom * factor, 0.01), 64)
        let moved = view(fixed)
        pan += anchor - SIMD2(Double(moved.x), Double(moved.y))
    }
}

/// A picture the image tools show, zoomable and pannable, with something drawn over it.
struct ImageToolCanvas<Overlay: View>: View {
    let image: CGImage?
    @Binding var viewport: ImageToolViewport
    var handlers = CanvasEventView.Handlers()
    @ViewBuilder var overlay: (ImageToolViewport) -> Overlay
    @State private var panStart: (pan: SIMD2<Double>, point: SIMD2<Double>)?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ImageToolCheckerboard()
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(viewport.zoom >= 2 ? .none : .high)
                        .frame(width: viewport.imageRect.width, height: viewport.imageRect.height)
                        .offset(x: viewport.imageRect.minX, y: viewport.imageRect.minY)
                }
                overlay(viewport)
                CanvasEventView(handlers: combinedHandlers)
            }
            .clipped()
            .onAppear { resize(to: proxy.size, refit: true) }
            .onChange(of: proxy.size) { _, size in resize(to: size, refit: false) }
        }
    }

    private func resize(to size: CGSize, refit: Bool) {
        let wasFitted = viewport.pan == .zero
        viewport.size = SIMD2(Double(size.width), Double(size.height))
        if refit || wasFitted { viewport.fit() }
    }

    /// Panning (Space or the middle button) and zooming come first; the tool gets the rest.
    private var combinedHandlers: CanvasEventView.Handlers {
        var combined = handlers
        let tool = handlers
        combined.mouseDown = { point, event, pans in
            if pans {
                panStart = (viewport.pan, point)
            } else {
                tool.mouseDown(point, event, false)
            }
        }
        combined.mouseDragged = { point, event in
            if let panStart {
                viewport.pan = panStart.pan + point - panStart.point
            } else {
                tool.mouseDragged(point, event)
            }
        }
        combined.mouseUp = { point, event in
            if panStart != nil {
                panStart = nil
            } else {
                tool.mouseUp(point, event)
            }
        }
        combined.scroll = { delta, point, event in
            if event.modifierFlags.contains(.command) || !event.hasPreciseScrollingDeltas {
                viewport.zoom(by: delta.y > 0 ? 1.1 : 1 / 1.1, anchor: point)
            } else {
                viewport.pan += delta
            }
        }
        combined.magnify = { factor, point in viewport.zoom(by: factor, anchor: point) }
        return combined
    }
}

/// The transparent area's checkerboard.
struct ImageToolCheckerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 10
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .controlBackgroundColor)))
            var path = Path()
            for row in 0...Int(size.height / cell) {
                for column in 0...Int(size.width / cell) where (row + column).isMultiple(of: 2) {
                    path.addRect(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                }
            }
            context.fill(path, with: .color(Color(nsColor: .separatorColor).opacity(0.35)))
        }
    }
}
