import SwiftUI
import OWESceneEditing

/// Drawing the gizmo's handles for each mode: the 2D scene's around a layer's rectangle, the 3D
/// scene's at an object's origin through the camera. Axes are red, green and blue (x, y, z), as
/// Wallpaper Engine colours them.
enum GizmoDrawing {
    static let axisColors: [Color] = [Color(red: 0.93, green: 0.26, blue: 0.24), Color(red: 0.36, green: 0.78, blue: 0.27),
                                      Color(red: 0.26, green: 0.52, blue: 0.96)]

    // MARK: 2D

    /// The selected layer's handles in `mode` (its outline is drawn by the caller).
    static func draw2D(_ geometry: LayerGeometry, mode: GizmoMode, space: GizmoSpace, viewport: CanvasViewport, accent: Color,
                       in context: inout GraphicsContext) {
        let pivot = viewport.canvasPoint(geometry.pivot)
        switch mode {
        case .multi:
            drawMulti(geometry, viewport: viewport, accent: accent, in: &context)
        case .translate:
            for index in 0..<2 {
                arrow(from: pivot, direction: LayerGizmo.translateAxis(index, geometry: geometry, space: space, in: viewport),
                      length: LayerGizmo.axisLength,
                      color: axisColors[index], in: &context)
            }
            square(at: pivot, size: 10, fill: .white.opacity(0.9), stroke: accent, in: &context)
        case .rotate:
            let radius = LayerGizmo.ringRadius
            let ring = Path(ellipseIn: CGRect(x: pivot.x - radius, y: pivot.y - radius, width: radius * 2, height: radius * 2))
            context.stroke(ring, with: .color(axisColors[2]), lineWidth: 2)
            cross(at: pivot, color: accent, in: &context)
        case .scale:
            for index in 0..<2 {
                let direction = LayerGizmo.layerAxis(index, geometry: geometry, in: viewport)
                line(from: pivot, to: pivot + direction * LayerGizmo.axisLength, color: axisColors[index], in: &context)
                square(at: pivot + direction * LayerGizmo.axisLength, size: 9, fill: axisColors[index], stroke: .white, in: &context)
            }
            for corner in geometry.corners.map(viewport.canvasPoint) {
                square(at: corner, size: 8, fill: .white, stroke: accent, in: &context)
            }
            square(at: pivot, size: 10, fill: .white.opacity(0.9), stroke: accent, in: &context)
        case .none:
            break
        }
    }

    /// The corners, the rotation handle above the top edge and the pivot.
    private static func drawMulti(_ geometry: LayerGeometry, viewport: CanvasViewport, accent: Color,
                                  in context: inout GraphicsContext) {
        let corners = geometry.corners.map(viewport.canvasPoint)
        let top = (corners[2] + corners[3]) / 2
        let rotate = LayerGizmo.rotateHandle(geometry, in: viewport)
        line(from: top, to: rotate, color: accent, width: 1, in: &context)
        for point in corners {
            square(at: point, size: 8, fill: .white, stroke: accent, in: &context)
        }
        let rect = CGRect(x: rotate.x - 4, y: rotate.y - 4, width: 8, height: 8)
        context.fill(Path(ellipseIn: rect), with: .color(.white))
        context.stroke(Path(ellipseIn: rect), with: .color(accent), lineWidth: 1.5)
        cross(at: viewport.canvasPoint(geometry.pivot), color: accent, in: &context)
    }

    // MARK: 3D

    /// Each object's origin as a small dot (the selection's in the accent colour), so they can be
    /// found and picked in a 3D scene.
    static func drawOrigins(_ points: [(point: SIMD2<Double>, selected: Bool)], accent: Color, in context: inout GraphicsContext) {
        for entry in points {
            let radius: Double = entry.selected ? 5 : 3.5
            let rect = CGRect(x: entry.point.x - radius, y: entry.point.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(entry.selected ? accent : .white.opacity(0.85)))
            context.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.5)), lineWidth: 1)
        }
    }

    /// The 3D gizmo of one object in `mode`.
    static func draw3D(_ frame: Gizmo3D.Frame, mode: GizmoMode, accent: Color, in context: inout GraphicsContext) {
        guard mode != .none else { return }
        if mode.rotates {
            for (index, ring) in frame.rings.enumerated() where ring.count > 1 {
                var path = Path()
                path.addLines(ring.map { CGPoint($0) })
                path.closeSubpath()
                context.stroke(path, with: .color(axisColors[index]), lineWidth: 1.5)
            }
        }
        if mode.translates {
            for index in 0..<3 {
                guard let direction = frame.direction(index) else { continue }
                arrow(from: frame.pivot, direction: direction, length: Gizmo3D.axisLength, color: axisColors[index], in: &context)
            }
        }
        if mode == .scale || mode == .multi {
            let length = mode == .multi ? Gizmo3D.axisLength * 0.6 : Gizmo3D.axisLength
            for index in 0..<3 {
                guard let tip = frame.tip(index, own: true, length: length) else { continue }
                if mode == .scale { line(from: frame.pivot, to: tip, color: axisColors[index], in: &context) }
                square(at: tip, size: 9, fill: axisColors[index], stroke: .white, in: &context)
            }
        }
        square(at: frame.pivot, size: 10, fill: .white.opacity(0.9), stroke: accent, in: &context)
    }

    // MARK: Shapes

    private static func line(from: SIMD2<Double>, to: SIMD2<Double>, color: Color, width: Double = 2,
                             in context: inout GraphicsContext) {
        var path = Path()
        path.move(to: CGPoint(from))
        path.addLine(to: CGPoint(to))
        context.stroke(path, with: .color(color), lineWidth: width)
    }

    private static func arrow(from origin: SIMD2<Double>, direction: SIMD2<Double>, length: Double, color: Color,
                              in context: inout GraphicsContext) {
        let tip = origin + direction * length
        line(from: origin + direction * 8, to: tip - direction * 9, color: color, in: &context)
        let side = SIMD2(-direction.y, direction.x)
        var head = Path()
        head.move(to: CGPoint(tip))
        head.addLine(to: CGPoint(tip - direction * 11 + side * 5))
        head.addLine(to: CGPoint(tip - direction * 11 - side * 5))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }

    private static func square(at point: SIMD2<Double>, size: Double, fill: Color, stroke: Color,
                               in context: inout GraphicsContext) {
        let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        let shape = Path(roundedRect: rect, cornerRadius: 1.5)
        context.fill(shape, with: .color(fill))
        context.stroke(shape, with: .color(stroke), lineWidth: 1.5)
    }

    private static func cross(at point: SIMD2<Double>, color: Color, in context: inout GraphicsContext) {
        var path = Path()
        path.move(to: CGPoint(x: point.x - 4, y: point.y))
        path.addLine(to: CGPoint(x: point.x + 4, y: point.y))
        path.move(to: CGPoint(x: point.x, y: point.y - 4))
        path.addLine(to: CGPoint(x: point.x, y: point.y + 4))
        context.stroke(path, with: .color(color), lineWidth: 1)
    }
}
