import SwiftUI
import OWESceneEditing

/// Show Particle Collision: each visible particle system's collision operators drawn where they
/// collide, as the renderer places them in a 2D scene (`ParticleCollision.placed`): a plane as
/// its line across the scene with the kept side marked, a sphere as its circle, a rectangle as
/// its edge, and the scene's bounds as its frame.
struct ParticleCollisionOverlay: View {
    @ObservedObject var model: ParticleEditingModel
    @ObservedObject var session: SceneEditSession
    let viewport: CanvasViewport

    private static let color = Color(red: 0.3, green: 0.85, blue: 1)

    init(model: ParticleEditingModel, viewport: CanvasViewport) {
        self.model = model
        session = model.session
        self.viewport = viewport
    }

    var body: some View {
        Canvas { context, _ in
            for layer in model.canvasSystems {
                guard let path = model.particlePath(of: layer), let definition = model.definition(path) else { continue }
                let world = model.sceneTransform(of: layer)
                for shape in ParticleCollisionShape.shapes(definition.items(.operator), world: world,
                                                            sceneSize: session.outline.size ?? .zero) {
                    draw(shape, in: &context)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ shape: ParticleCollisionShape, in context: inout GraphicsContext) {
        var path = Path()
        switch shape {
        case .segment(let from, let to, let normal):
            path.move(to: CGPoint(viewport.canvasPoint(from)))
            path.addLine(to: CGPoint(viewport.canvasPoint(to)))
            // Ticks on the side particles stay on.
            for t in stride(from: 0.0, through: 1.0, by: 0.1) {
                let point = from + (to - from) * t
                path.move(to: CGPoint(viewport.canvasPoint(point)))
                path.addLine(to: CGPoint(viewport.canvasPoint(point) + SIMD2(normal.x, -normal.y) * 6))
            }
        case .circle(let centre, let radius):
            let c = viewport.canvasPoint(centre), r = radius * viewport.scale
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        case .rectangle(let size):
            let a = viewport.canvasPoint(SIMD2(0, size.y)), b = viewport.canvasPoint(SIMD2(size.x, 0))
            path.addRect(CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y).insetBy(dx: 1, dy: 1))
        }
        context.stroke(path, with: .color(Self.color), lineWidth: 1.5)
    }
}
