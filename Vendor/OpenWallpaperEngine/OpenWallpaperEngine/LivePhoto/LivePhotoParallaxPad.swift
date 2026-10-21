import OWEInspectorKit
import SwiftUI

/// Export Settings' Parallax Position pad: the device's screen as a small glass rounded rectangle,
/// with a dot where the pointer rests over the wallpaper (`LivePhotoParallax`: normalised over the
/// scene, y up). Dragging or clicking moves the dot; the arrow keys nudge it.
struct LivePhotoParallaxPad: View {
    @Environment(\.appAccentColor) private var accentColor
    let position: SIMD2<Double>
    /// The device's width over its height, portrait.
    let aspect: Double
    let onChange: (SIMD2<Double>) -> Void

    private static let height: CGFloat = 132
    private static let dot: CGFloat = 14
    /// How far an arrow key moves the dot.
    private static let step = 0.05

    var body: some View {
        let size = CGSize(width: Self.height * max(min(aspect, 2), 0.3), height: Self.height)
        let shape = RoundedRectangle(cornerRadius: min(size.width, size.height) * 0.14, style: .continuous)
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: size.width / 2, y: 0))
                path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            }
            .stroke(.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            Circle()
                .fill(accentColor)
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2))
                .shadow(radius: 2)
                .frame(width: Self.dot, height: Self.dot)
                .position(x: position.x * size.width, y: (1 - position.y) * size.height)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(shape)
        .glassBackground(in: shape, interactive: true) { pad in
            pad.background(.quaternary, in: shape)
        }
        .overlay { shape.strokeBorder(.secondary.opacity(0.4), lineWidth: 1) }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                onChange(SIMD2(Double(value.location.x / size.width), 1 - Double(value.location.y / size.height)))
            })
        .accessibilityElement()
        .accessibilityLabel(Text("Parallax Position"))
        .accessibilityValue(Text(verbatim: [position.x, position.y]
            .map { $0.formatted(.percent.precision(.fractionLength(0))) }.joined(separator: ", ")))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(position + SIMD2(Self.step, 0))
            case .decrement: onChange(position - SIMD2(Self.step, 0))
            @unknown default: break
            }
        }
        .focusable()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            switch press.key {
            case .leftArrow: onChange(position - SIMD2(Self.step, 0))
            case .rightArrow: onChange(position + SIMD2(Self.step, 0))
            case .upArrow: onChange(position + SIMD2(0, Self.step))
            default: onChange(position - SIMD2(0, Self.step))
            }
            return .handled
        }
    }
}
