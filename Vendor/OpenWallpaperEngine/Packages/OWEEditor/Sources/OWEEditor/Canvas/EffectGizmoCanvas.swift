import AppKit
import SwiftUI
import OWESceneEditing

/// The effect gizmos on the canvas: for each effect open in the inspector of the selected layer,
/// the handles its `effect.json` lists (`EffectGizmo`) and a point for each `"position": true`
/// constant, drawn on the layer and dragged to set the constants. A drag is one undo step.
@MainActor
enum EffectGizmoCanvas {
    /// Canvas points a press may be from a handle.
    static let handleRadius: Double = 7

    /// The gizmos of one open effect, ready for the canvas.
    struct Item {
        var layer: Int
        var schema: EffectSchema
        var instance: EffectGizmoInstance
        var mapping: EffectGizmoLayout.Mapping
    }

    struct Drag {
        var item: Item
        var role: String
        var startPoint: SIMD2<Double>
        var moved: Bool
    }

    /// The selected layer's open effects' gizmos (a 2D scene's planar layer only).
    static func items(session: SceneEditSession, tools: EditorTools, services: WallpaperEditorServices,
                      viewport: CanvasViewport) -> [Item] {
        guard tools.maskPainting == nil, let selected = session.selection, let layer = session.outline.layer(selected),
              let geometry = session.geometry(of: selected) else { return [] }
        let mapping = EffectGizmoLayout.Mapping(geometry: geometry, viewport: viewport)
        var items: [Item] = []
        for effect in layer.effects where tools.isExpanded(effect.key, of: selected) {
            guard let schema = services.effectSchema(effect.file) else { continue }
            for instance in session.effectGizmos(effect, of: selected, schema: schema) {
                items.append(Item(layer: selected, schema: schema, instance: instance, mapping: mapping))
            }
        }
        return items
    }

    /// The handle under `point`, topmost (last drawn) first.
    static func press(at point: SIMD2<Double>, session: SceneEditSession, tools: EditorTools,
                      services: WallpaperEditorServices, viewport: CanvasViewport) -> Drag? {
        guard let selected = session.selection, !session.isLocked(selected) else { return nil }
        for item in items(session: session, tools: tools, services: services, viewport: viewport).reversed() {
            for handle in item.instance.layout.handles(item.mapping).reversed()
            where !item.instance.boundRoles.contains(handle.role) && item.instance.keys[handle.role] != nil {
                let delta = handle.point - point
                if (delta * delta).sum() <= handleRadius * handleRadius {
                    return Drag(item: item, role: handle.role, startPoint: point, moved: false)
                }
            }
        }
        return nil
    }

    static func drag(_ drag: inout Drag, to point: SIMD2<Double>, session: SceneEditSession) {
        if !drag.moved {
            let delta = point - drag.startPoint
            guard (delta * delta).sum().squareRoot() >= 3 else { return }
            drag.moved = true
        }
        let item = drag.item
        var values: [String: [Double]] = [:]
        for (role, value) in item.instance.layout.dragged(drag.role, to: point, item.mapping) {
            guard let key = item.instance.keys[role], !item.instance.boundRoles.contains(role) else { continue }
            values[key] = value
        }
        guard !values.isEmpty else { return }
        session.setEffectConstants(values, effect: item.instance.effectKey, of: item.layer, schema: item.schema,
                                   actionName: EG("Move Effect Handle"), coalescingKey: "\(item.instance.id):\(drag.role)")
    }

    static func cursor(at point: SIMD2<Double>, session: SceneEditSession, tools: EditorTools,
                       services: WallpaperEditorServices, viewport: CanvasViewport) -> NSCursor? {
        press(at: point, session: session, tools: tools, services: services, viewport: viewport) == nil ? nil : .crosshair
    }
}

/// The open effects' gizmos over the canvas: each gizmo's outline and its handles (a bound
/// constant's handle hollow, as it can't be dragged).
struct EffectGizmoOverlay: View {
    @ObservedObject var session: SceneEditSession
    @ObservedObject var tools: EditorTools
    let services: WallpaperEditorServices
    let viewport: CanvasViewport

    private static let color = Color(red: 1, green: 0.78, blue: 0.2)

    var body: some View {
        Canvas { context, _ in
            for item in EffectGizmoCanvas.items(session: session, tools: tools, services: services, viewport: viewport) {
                draw(item, in: &context)
            }
        }
    }

    private func draw(_ item: EffectGizmoCanvas.Item, in context: inout GraphicsContext) {
        let layout = item.instance.layout, mapping = item.mapping
        for outline in layout.outlines(aspect: mapping.aspect) where outline.points.count > 1 {
            var path = Path()
            path.addLines(outline.points.map { CGPoint(mapping.toCanvas($0)) })
            if outline.closed { path.closeSubpath() }
            context.stroke(path, with: .color(Self.color), style: StrokeStyle(lineWidth: 1.5, dash: outline.closed ? [] : [5, 3]))
        }
        let handles = layout.handles(mapping)
        if let arrow = handles.first(where: { $0.role == "angle" }) {
            let base = layout.kind == .lineEmitter ? (handles.first { $0.role == "p0" }?.point).map { start in
                (start + (handles.first { $0.role == "p1" }?.point ?? start)) / 2
            } : handles.first { $0.role == "center" }?.point
            if let base {
                var path = Path()
                path.move(to: CGPoint(base))
                path.addLine(to: CGPoint(arrow.point))
                context.stroke(path, with: .color(Self.color), lineWidth: 2)
            }
        }
        for handle in handles {
            let bound = item.instance.boundRoles.contains(handle.role)
            let size: Double = handle.role == "center" || handle.role == "position" ? 10 : 8
            let rect = CGRect(x: handle.point.x - size / 2, y: handle.point.y - size / 2, width: size, height: size)
            let shape = handle.role == "angle" ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 2)
            if !bound { context.fill(shape, with: .color(Self.color)) }
            context.stroke(shape, with: .color(bound ? Self.color : .black.opacity(0.6)), lineWidth: 1.2)
        }
    }
}
