import AppKit
import OWESceneEditing
import SwiftUI

/// The separation's canvas: the picture as the View buttons choose, the marks over it, and the
/// pointer input of the brush (drag to paint, ⌥ erases, ⌃-drag sideways sizes the brush) and of
/// the polygon tool (click to add points, click the first point to close, drag a point, click a
/// side to insert one, ⌥-click or Delete removes one). Space or the middle button pans; the wheel
/// or ⌘-scroll zooms.
struct SeparationCanvasView: View {
    @ObservedObject var editor: SeparationEditor
    @Binding var viewport: ImageToolViewport
    @State private var pointer: SIMD2<Double>?
    @State private var drag: Drag?

    private enum Drag {
        case paint(erasing: Bool)
        case point(SeparationEditor.PolygonPoint)
        case brushSize(startX: Double, startSize: Double)
    }

    /// Canvas points within which a click picks a point or a side.
    private static let reach: Double = 8

    var body: some View {
        ImageToolCanvas(image: baseImage, viewport: $viewport, handlers: handlers) { viewport in
            ZStack(alignment: .topLeading) {
                if editor.preview == .foregroundAndOriginal, let foreground = editor.foregroundImage {
                    picture(foreground, viewport)
                }
                if editor.showsMarks, editor.mode == .brush, let marks = editor.marksImage {
                    picture(marks, viewport).opacity(editor.marksOpacity / 100)
                }
                if editor.showsMarks, editor.mode == .brush, editor.stroke.count > 0 {
                    Canvas { context, _ in drawStroke(&context, viewport) }
                        .opacity(editor.marksOpacity / 100)
                }
                if editor.showsMarks, editor.mode == .polygon {
                    Canvas { context, _ in drawPolygons(&context, viewport) }
                }
                if editor.mode == .brush, let pointer {
                    let diameter = editor.brushDiameter * viewport.zoom
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 1)
                        .background(Circle().strokeBorder(Color.black, lineWidth: 3))
                        .frame(width: diameter, height: diameter)
                        .position(x: pointer.x, y: pointer.y)
                        .allowsHitTesting(false)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// What the canvas shows under the marks.
    private var baseImage: CGImage? {
        switch editor.preview {
        case .original: return editor.original
        case .foregroundAndOriginal: return editor.fadesOriginal ? editor.fadedOriginal : editor.original
        case .foreground: return editor.foregroundImage ?? editor.original
        case .background: return editor.backgroundImage ?? editor.original
        }
    }

    private func picture(_ image: CGImage, _ viewport: ImageToolViewport) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(viewport.zoom >= 2 ? .none : .high)
            .frame(width: viewport.imageRect.width, height: viewport.imageRect.height)
            .offset(x: viewport.imageRect.minX, y: viewport.imageRect.minY)
    }

    /// The stroke being painted, until it joins the marks.
    private func drawStroke(_ context: inout GraphicsContext, _ viewport: ImageToolViewport) {
        var path = Path()
        for (index, point) in editor.stroke.enumerated() {
            if index == 0 { path.move(to: viewport.view(point)) } else { path.addLine(to: viewport.view(point)) }
        }
        if editor.stroke.count == 1, let point = editor.stroke.first { path.addLine(to: viewport.view(point)) }
        let colour: Color = editor.strokeErases ? .gray : (editor.brush == .foreground ? .white : .black)
        context.stroke(path, with: .color(colour),
                       style: StrokeStyle(lineWidth: editor.brushDiameter * viewport.zoom, lineCap: .round, lineJoin: .round))
    }

    private func drawPolygons(_ context: inout GraphicsContext, _ viewport: ImageToolViewport) {
        let marks = editor.marks
        let opacity = editor.marksOpacity / 100
        var fill = Path()
        for outline in marks.outlines(smoothing: Double(editor.settings.smoothing)) {
            guard let first = outline.first else { continue }
            fill.move(to: viewport.view(first))
            for point in outline.dropFirst() { fill.addLine(to: viewport.view(point)) }
            fill.closeSubpath()
        }
        context.fill(fill, with: .color(.white.opacity(0.51 * opacity)), style: FillStyle(eoFill: true))
        for (polygonIndex, polygon) in marks.polygons.enumerated() {
            var line = Path()
            for (index, point) in polygon.enumerated() {
                if index == 0 { line.move(to: viewport.view(point)) } else { line.addLine(to: viewport.view(point)) }
            }
            context.stroke(line, with: .color(.black), lineWidth: 1.5)
            for (pointIndex, point) in polygon.enumerated() {
                let centre = viewport.view(point)
                let selected = editor.selectedPoint == SeparationEditor.PolygonPoint(polygon: polygonIndex, point: pointIndex)
                let side: CGFloat = selected ? 8 : 5
                let rect = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
                context.fill(Path(rect), with: .color(selected ? .red : .black))
                context.stroke(Path(rect), with: .color(.white), lineWidth: 0.5)
            }
        }
    }

    private var handlers: CanvasEventView.Handlers {
        var handlers = CanvasEventView.Handlers()
        handlers.mouseDown = { point, event, _ in
            let pixel = viewport.pixel(point)
            let reach = Self.reach / max(viewport.zoom, 1e-6)
            switch editor.mode {
            case .brush:
                if event.modifierFlags.contains(.control) {
                    drag = .brushSize(startX: point.x, startSize: editor.brushSize)
                } else {
                    let erasing = event.modifierFlags.contains(.option)
                    drag = .paint(erasing: erasing)
                    editor.beginStroke(at: pixel, erasing: erasing)
                }
            case .polygon:
                if event.modifierFlags.contains(.option), let hit = editor.point(near: pixel, reach: reach) {
                    editor.deletePoint(hit)
                    return
                }
                editor.polygonClick(at: pixel, reach: reach)
                if let selected = editor.selectedPoint { drag = .point(selected) }
            }
        }
        handlers.mouseDragged = { point, _ in
            pointer = point
            switch drag {
            case .paint(let erasing)?: editor.continueStroke(to: viewport.pixel(point), erasing: erasing)
            case .point(let selected)?: editor.dragPoint(selected, to: viewport.pixel(point))
            case .brushSize(let startX, let startSize)?: editor.brushSize = min(max(startSize + 0.5 * (point.x - startX), 1), 100)
            case nil: break
            }
        }
        handlers.mouseUp = { _, _ in
            switch drag {
            case .paint?: editor.endStroke()
            case .point?: editor.endDrag()
            default: break
            }
            drag = nil
        }
        handlers.mouseMoved = { point in pointer = point }
        handlers.key = { event in
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "m":
                editor.showsMarks.toggle()
                return true
            case "r":
                editor.recalculate()
                return true
            default:
                if event.keyCode == 51 || event.keyCode == 117, let selected = editor.selectedPoint {
                    editor.deletePoint(selected)
                    return true
                }
                return false
            }
        }
        handlers.cursor = { _ in editor.mode == .polygon ? .crosshair : .arrow }
        return handlers
    }
}
