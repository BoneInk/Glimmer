import SwiftUI
import OWEInspectorKit
import OWESceneEditing

/// A `"position": true` constant's control: X and Y on the layer (0…1 from its top-left corner),
/// also dragged by its handle on the canvas while the effect is open.
struct EffectPositionField: View {
    @Binding var value: [Double]
    let defaultValue: [Double]

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(0..<2, id: \.self) { component in
                HStack(spacing: 4) {
                    Text(verbatim: component == 0 ? "X" : "Y").foregroundStyle(.secondary)
                    NumericSliderInput<Double>(value: Binding<Double>(
                        get: { value[safe: component] ?? 0.5 },
                        set: { number in
                            var next = value.count >= 2 ? value : [0.5, 0.5]
                            next[component] = number
                            value = next
                        }), range: 0...1, defaultValue: defaultValue[safe: component] ?? 0.5,
                        fractionDigits: 3, fieldWidth: 52, clampsTypedValue: false)
                }
            }
            Label(EG("Drag its handle on the canvas"), systemImage: "scope")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A `"direction": true` constant's control: a dial (up is 0, turning clockwise, as Wallpaper
/// Engine's emitters point) and the angle in degrees where the shader asks for them
/// (`"conversion": "rad2deg"`), else radians.
struct EffectDirectionDial: View {
    @Binding var radians: Double
    let defaultValue: Double
    let showsDegrees: Bool

    var body: some View {
        HStack(spacing: 8) {
            Dial(radians: $radians)
                .frame(width: 26, height: 26)
            NumericSliderInput<Double>(value: $radians, range: 0...(2 * .pi), defaultValue: defaultValue,
                                       displayScale: showsDegrees ? 180 / .pi : 1, suffix: showsDegrees ? "°" : "",
                                       fractionDigits: showsDegrees ? 0 : 2, fieldWidth: 52, clampsTypedValue: false)
        }
    }

    private struct Dial: View {
        @Binding var radians: Double

        var body: some View {
            GeometryReader { (proxy: GeometryProxy) in
                let size = min(proxy.size.width, proxy.size.height)
                let centre = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                ZStack {
                    Circle().strokeBorder(.secondary, lineWidth: 1)
                    Path { path in
                        path.move(to: centre)
                        path.addLine(to: CGPoint(x: centre.x + sin(radians) * size * 0.42, y: centre.y - cos(radians) * size * 0.42))
                    }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let dx = Double(drag.location.x - centre.x), dy = Double(drag.location.y - centre.y)
                    guard dx * dx + dy * dy > 4 else { return }
                    var angle = atan2(dx, -dy)
                    if angle < 0 { angle += 2 * .pi }
                    radians = angle
                })
            }
        }
    }
}
