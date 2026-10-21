import AppKit
import SwiftUI
import OWEInspectorKit
import OWESceneEditing

/// A press on the canvas that grabbed a particle system's handle.
enum ParticleCanvasDrag {
    /// The system's origin: dragging moves the layer (its `origin`), as WE's move gizmo does.
    case move(layer: Int, drag: LayerGizmo.Drag, startPoint: SIMD2<Double>, moved: Bool)
    /// One of its control points: dragging changes the point's `offset` in the definition.
    case controlPoint(layer: Int, path: String, handle: ParticleControlPointHandle, startPoint: SIMD2<Double>, moved: Bool)
}

/// The particle systems on the canvas: a handle at each visible system's origin (2D scenes), and
/// the selected system's control points, both draggable. A drag previews on the canvas and
/// commits once, on release, as one undo step.
@MainActor
enum ParticleCanvasInteraction {
    /// Canvas points a press may be from a handle.
    static let handleRadius: Double = 9
    /// A press moves this far (points) before it drags, so a click only selects.
    static let dragThreshold: Double = 3

    /// The handle under `canvasPoint`: the selected system's control points, then any system's origin.
    static func press(at canvasPoint: SIMD2<Double>, viewport: CanvasViewport,
                      services: ParticleEditorServices) -> ParticleCanvasDrag? {
        let model = services.model, session = model.session
        let scenePoint = viewport.scenePoint(canvasPoint)
        let radius = handleRadius / max(viewport.scale, 1e-6)
        if model.showsControlPoints, let selected = session.selection, !session.isLocked(selected),
           session.outline.layer(selected)?.kind == .particle, let path = model.particlePath(of: selected),
           let handle = model.controlPoint(of: selected, at: scenePoint, radius: radius) {
            return .controlPoint(layer: selected, path: path, handle: handle, startPoint: canvasPoint, moved: false)
        }
        guard let layer = model.system(at: scenePoint, radius: radius) else { return nil }
        session.selection = layer
        return .move(layer: layer, drag: model.moveDrag(of: layer, from: scenePoint), startPoint: canvasPoint, moved: false)
    }

    static func drag(_ drag: inout ParticleCanvasDrag, to canvasPoint: SIMD2<Double>, viewport: CanvasViewport,
                     free: Bool, services: ParticleEditorServices) {
        let model = services.model
        func far(_ start: SIMD2<Double>) -> Bool {
            let delta = canvasPoint - start
            return (delta * delta).sum().squareRoot() >= dragThreshold
        }
        switch drag {
        case .move(let layer, let gizmo, let start, let moved):
            guard moved || far(start) else { return }
            drag = .move(layer: layer, drag: gizmo, startPoint: start, moved: true)
            model.session.dragPreview = (layer, gizmo.transform(at: viewport.scenePoint(canvasPoint), free: free))
        case .controlPoint(let layer, let path, let handle, let start, let moved):
            guard moved || far(start) else { return }
            drag = .controlPoint(layer: layer, path: path, handle: handle, startPoint: start, moved: true)
            let offset = model.controlPointOffset(handle, at: viewport.scenePoint(canvasPoint), of: layer)
            model.controlPointPreview = .init(layer: layer, index: handle.index, offset: offset)
        }
    }

    static func end(_ drag: ParticleCanvasDrag, services: ParticleEditorServices) {
        let model = services.model
        switch drag {
        case .move(_, _, _, let moved):
            guard moved else { model.session.dragPreview = nil; return }
            model.session.endDrag(actionName: PartL("Move Particle System"))
        case .controlPoint(_, let path, let handle, _, let moved):
            let preview = model.controlPointPreview
            model.controlPointPreview = nil
            guard moved, let preview else { return }
            model.setControlPointOffset(preview.offset, index: handle.index, definition: path,
                                        actionName: PartL("Move Control Point"))
        }
    }

    static func cursor(at canvasPoint: SIMD2<Double>, viewport: CanvasViewport, services: ParticleEditorServices) -> NSCursor? {
        let model = services.model, session = model.session
        let scenePoint = viewport.scenePoint(canvasPoint)
        let radius = handleRadius / max(viewport.scale, 1e-6)
        if model.showsControlPoints, let selected = session.selection, !session.isLocked(selected),
           session.outline.layer(selected)?.kind == .particle,
           model.controlPoint(of: selected, at: scenePoint, radius: radius) != nil {
            return .crosshair
        }
        return model.system(at: scenePoint, radius: radius) != nil ? .openHand : nil
    }
}

/// Draws the particle handles over the live canvas.
struct ParticleCanvasOverlay: View {
    @Environment(\.appAccentColor) private var accentColor
    @ObservedObject var services: ParticleEditorServices
    @ObservedObject var model: ParticleEditingModel
    @ObservedObject var session: SceneEditSession
    let viewport: CanvasViewport

    init(services: ParticleEditorServices, viewport: CanvasViewport) {
        self.services = services
        model = services.model
        session = services.model.session
        self.viewport = viewport
    }

    var body: some View {
        Canvas { context, _ in
            let selected = session.selection
            for layer in model.canvasSystems {
                let origin = CGPoint(viewport.canvasPoint(model.origin(of: layer)))
                let isSelected = layer == selected
                let size: CGFloat = isSelected ? 14 : 10
                let ring = Path(ellipseIn: CGRect(x: origin.x - size / 2, y: origin.y - size / 2, width: size, height: size))
                context.fill(ring, with: .color(.black.opacity(0.35)))
                context.stroke(ring, with: .color(isSelected ? accentColor : .white.opacity(0.8)),
                               style: StrokeStyle(lineWidth: isSelected ? 2 : 1.25, dash: session.isLocked(layer) ? [3, 2] : []))
                var cross = Path()
                cross.move(to: CGPoint(x: origin.x - size, y: origin.y))
                cross.addLine(to: CGPoint(x: origin.x + size, y: origin.y))
                cross.move(to: CGPoint(x: origin.x, y: origin.y - size))
                cross.addLine(to: CGPoint(x: origin.x, y: origin.y + size))
                context.stroke(cross, with: .color(isSelected ? accentColor : .white.opacity(0.6)), lineWidth: 1)
            }
            guard model.showsControlPoints, let selected, session.outline.layer(selected)?.kind == .particle else { return }
            let origin = CGPoint(viewport.canvasPoint(model.origin(of: selected)))
            for handle in model.controlPoints(of: selected) {
                let point = CGPoint(viewport.canvasPoint(handle.position))
                var line = Path()
                line.move(to: origin)
                line.addLine(to: point)
                context.stroke(line, with: .color(.orange.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                var diamond = Path()
                let half: CGFloat = 6
                diamond.move(to: CGPoint(x: point.x, y: point.y - half))
                diamond.addLine(to: CGPoint(x: point.x + half, y: point.y))
                diamond.addLine(to: CGPoint(x: point.x, y: point.y + half))
                diamond.addLine(to: CGPoint(x: point.x - half, y: point.y))
                diamond.closeSubpath()
                context.fill(diamond, with: .color(handle.followsPointer ? .yellow : .orange))
                context.stroke(diamond, with: .color(.white), lineWidth: 1)
                context.draw(Text(verbatim: "\(handle.index)").font(.caption2.bold()).foregroundStyle(.white),
                             at: CGPoint(x: point.x + 10, y: point.y - 9))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Adds a particle system: a blank one from WE's template, or, from the browser, one of WE's
/// default systems or presets.
struct ParticleAddMenu: View {
    @ObservedObject var services: ParticleEditorServices
    @State private var isBrowsing = false

    var body: some View {
        Menu {
            Button(PartL("Blank Particle System")) {
                services.model.addBlankSystem(name: PartL("Particle System"), actionName: PartL("Add Particle System"))
            }
            Divider()
            Button(PartL("Particle Systems and Presets…")) { isBrowsing = true }
        } label: {
            Label(PartL("Add Particle System"), systemImage: "sparkles")
        }
        .help(PartL("Add a particle system: a blank one or one of WE’s presets"))
        .sheet(isPresented: $isBrowsing) {
            ParticleSystemBrowserView(services: services)
        }
    }
}
