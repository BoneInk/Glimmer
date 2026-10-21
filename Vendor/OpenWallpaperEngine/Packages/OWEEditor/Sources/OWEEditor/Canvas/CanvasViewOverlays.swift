import SwiftUI
import OWESceneEditing

/// The View menu's drawing over the canvas: the grid on the scene, and Desktop or Phone Preview's
/// frame, the scene outside what such a screen shows dimmed.
struct CanvasViewOverlay: View {
    @ObservedObject var options: EditorViewOptions
    let viewport: CanvasViewport

    var body: some View {
        Canvas { context, size in
            let rect = viewport.sceneRect
            let scene = CGRect(x: rect.origin.x, y: rect.origin.y, width: rect.size.x, height: rect.size.y)
            if options.showsGrid { drawGrid(in: &context, scene: scene) }
            if let aspect = options.previewAspect { drawPreviewFrame(aspect, in: &context, size: size, scene: scene) }
        }
        .allowsHitTesting(false)
    }

    private func drawGrid(in context: inout GraphicsContext, scene: CGRect) {
        let spacing = EditorViewOptions.gridSpacing(pointsPerUnit: viewport.scale)
        var minor = Path(), major = Path()
        let size = viewport.sceneSize
        var x = 0.0, index = 0
        while x <= size.x {
            let point = viewport.canvasPoint(SIMD2(x, 0))
            var path = index % 5 == 0 ? major : minor
            path.move(to: CGPoint(x: point.x, y: scene.minY))
            path.addLine(to: CGPoint(x: point.x, y: scene.maxY))
            if index % 5 == 0 { major = path } else { minor = path }
            x += spacing
            index += 1
        }
        var y = 0.0
        index = 0
        while y <= size.y {
            let point = viewport.canvasPoint(SIMD2(0, y))
            var path = index % 5 == 0 ? major : minor
            path.move(to: CGPoint(x: scene.minX, y: point.y))
            path.addLine(to: CGPoint(x: scene.maxX, y: point.y))
            if index % 5 == 0 { major = path } else { minor = path }
            y += spacing
            index += 1
        }
        context.stroke(minor, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
        context.stroke(major, with: .color(.white.opacity(0.35)), lineWidth: 1)
    }

    private func drawPreviewFrame(_ aspect: Double, in context: inout GraphicsContext, size: CGSize, scene: CGRect) {
        let visible = EditorViewOptions.visibleRect(sceneSize: viewport.sceneSize, aspect: aspect)
        let topLeft = viewport.canvasPoint(SIMD2(visible.minimum.x, visible.maximum.y))
        let bottomRight = viewport.canvasPoint(SIMD2(visible.maximum.x, visible.minimum.y))
        let frame = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
        var outside = Path(scene)
        outside.addRect(frame)
        context.fill(outside, with: .color(.black.opacity(0.6)), style: FillStyle(eoFill: true))
        context.stroke(Path(roundedRect: frame, cornerRadius: options.preview == .phone ? 10 : 2), with: .color(.white.opacity(0.85)),
                       lineWidth: 2)
    }
}

/// The canvas's view buttons beside its zoom, as Wallpaper Engine's toolbar has them: the grid,
/// the selection box, Desktop and Phone Preview, and Low FPS Simulation.
struct CanvasViewButtons: View {
    @ObservedObject var options: EditorViewOptions
    /// A 2D scene: the grid, the selection box and the previews frame it.
    let isPlanar: Bool

    var body: some View {
        if isPlanar {
            Toggle(isOn: $options.showsGrid) {
                Label(EditorViewCommand.showGrid.title, systemImage: "grid").labelStyle(.iconOnly)
            }
            .help(EditorViewCommand.showGrid.title)
            Toggle(isOn: $options.showsSelectionBox) {
                Label(EditorViewCommand.showSelectionBox.title, systemImage: "square.dashed").labelStyle(.iconOnly)
            }
            .help(EditorViewCommand.showSelectionBox.title)
            Divider().frame(height: 16)
            Toggle(isOn: Binding(get: { options.preview == .desktop }, set: { _ in options.toggle(.desktop) })) {
                Label(EditorViewCommand.desktopPreview.title, systemImage: "display").labelStyle(.iconOnly)
            }
            .help(EditorViewCommand.desktopPreview.title)
            Toggle(isOn: Binding(get: { options.preview == .phone }, set: { _ in options.toggle(.phone) })) {
                Label(EditorViewCommand.phonePreview.title, systemImage: "iphone").labelStyle(.iconOnly)
            }
            .help(EditorViewCommand.phonePreview.title)
        }
        Toggle(isOn: $options.simulatesLowFrameRate) {
            Label(EditorViewCommand.lowFrameRate.title, systemImage: "gauge.with.dots.needle.33percent").labelStyle(.iconOnly)
        }
        .help(CV("Low FPS Simulation: the canvas runs at 22 frames per second, as on a slow computer"))
    }
}
