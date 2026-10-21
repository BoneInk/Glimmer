import OWEInspectorKit
import SwiftUI

/// The measured motion of the scene's first seconds as bars, with the clip's window over them:
/// the automatic pick (the most motion), which a click or drag moves.
struct LivePhotoMotionTimeline: View {
    @Environment(\.appAccentColor) private var accentColor
    @ObservedObject var model: LivePhotoExportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let motion = model.motion {
                chart(motion)
                    .frame(height: 40)
                Text(model.motionWindowIsAutomatic ? "The window with the most motion is picked. Drag to choose another."
                                                   : "Drag to move the clip.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(model.motion == nil ? "Find Best Motion" : "Find Best Motion Again") { model.measureMotion() }
                .disabled(model.isRendering)
                .help("Render the first seconds of the scene small and move the clip to where it moves the most")
        }
    }

    private func chart(_ motion: LivePhotoMotion.Analysis) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let seconds = max(motion.seconds, 0.001)
            Canvas { context, size in
                Self.draw(motion, clip: model.clip, accent: accentColor, in: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let center = Double(value.location.x / max(width, 1)) * seconds
                model.clipStart = max(0, center - model.clipLength / 2)
            })
            .accessibilityElement()
            .accessibilityLabel(Text("Motion timeline"))
            .accessibilityValue(Text("\(model.clipStart.formatted(.number.precision(.fractionLength(1)))) s – \(model.clip.end.formatted(.number.precision(.fractionLength(1)))) s"))
        }
    }

    private static func draw(_ motion: LivePhotoMotion.Analysis, clip: LivePhotoClip, accent: Color,
                             in context: inout GraphicsContext, size: CGSize) {
        let count = motion.differences.count
        guard count > 0 else { return }
        let seconds = max(motion.seconds, 0.001)
        let most = max(motion.differences.max() ?? 0, 1e-9)
        let barWidth = size.width / CGFloat(count)
        let background = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4)
        context.fill(background, with: .color(.secondary.opacity(0.12)))
        var bars = Path()
        for (index, value) in motion.differences.enumerated() {
            let height = max(1, CGFloat(value / most) * (size.height - 4))
            bars.addRect(CGRect(x: CGFloat(index) * barWidth, y: size.height - height, width: max(barWidth - 0.5, 0.5), height: height))
        }
        context.fill(bars, with: .color(.secondary.opacity(0.6)))
        let start = CGFloat(clip.start / seconds) * size.width
        let end = CGFloat(min(clip.end, seconds) / seconds) * size.width
        guard end > start else { return }
        let window = Path(roundedRect: CGRect(x: start, y: 0, width: end - start, height: size.height), cornerRadius: 4)
        context.fill(window, with: .color(accent.opacity(0.22)))
        context.stroke(window, with: .color(accent), lineWidth: 1.5)
    }
}
