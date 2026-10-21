import AppKit
import SwiftUI
import OWEInspectorKit
import OWESceneEditing

/// One field of a particle component with the control WE's panel gives its type: a free number
/// box, a slider with a number box (its range from the schema, a typed value never clamped, as in
/// WE), a checkbox, per-axis number boxes (degrees for angles), a colour or hue picker, a list of
/// colours, or a menu of options.
struct ParticleFieldRow: View {
    let field: ParticleEditorSchema.Field
    /// The control: the field's own, or a remap range's vector form.
    let kind: ParticleEditorSchema.Field.Kind
    /// The value shown: authored, else the editor's default.
    let value: SceneJSONValue?
    /// Writes a value; `coalescing` for a run of changes of one control (dragging, typing).
    let set: (SceneJSONValue?, _ coalescing: Bool) -> Void

    var body: some View {
        if kind == .checkbox || kind == .checkboxbit {
            Toggle(isOn: Binding(get: { value?.boolValue ?? false }, set: { set(.bool($0), false) })) {
                labelText
            }
        } else if kind == .colorlist {
            VStack(alignment: .leading, spacing: 6) {
                labelText
                ParticleColorList(field: field, value: value, set: set)
            }
        } else {
            LabeledContent { control } label: { labelText }
        }
    }

    private var slider: some View {
        let lower: Double = field.minimum ?? 0
        let upper: Double = max(field.maximum ?? 1, lower + 0.001)
        let isInteger: Bool = kind == .sliderint
        let binding = Binding<Double>(
            get: { value?.doubleValue ?? lower },
            set: { (newValue: Double) in set(.number(isInteger ? newValue.rounded() : newValue), true) })
        let fractionDigits: Int = isInteger ? 0 : (upper - lower < 0.5 ? 3 : 2)
        let step: Double? = isInteger ? 1 : nil
        return NumericSliderInput<Double>(value: binding, range: lower...upper,
                                          defaultValue: field.addDefault?.doubleValue ?? lower, step: step,
                                          fractionDigits: fractionDigits, fieldWidth: 52, clampsTypedValue: false)
    }

    private var labelText: some View {
        HStack(spacing: 4) {
            Text(field.localizedLabel)
            if let hint = field.hint { InfoTip(PLSchema(hint)) }
        }
    }

    @ViewBuilder private var control: some View {
        switch kind {
        case .number:
            ParticleNumberField(value: value?.doubleValue ?? SceneVector.components(value).first ?? 0,
                                isInteger: field.isInteger) { set(.number($0), true) }
        case .slider, .sliderint, .hue:
            HStack(spacing: 6) {
                if kind == .hue {
                    Circle()
                        .fill(Color(hue: value?.doubleValue ?? 0, saturation: 1, brightness: 1))
                        .frame(width: 14, height: 14)
                }
                slider
            }
        case .vec2, .vec3:
            ParticleVectorField(field: field, count: kind == .vec2 ? 2 : 3, value: value) { set($0, true) }
        case .color:
            ParticleColorWell(value: value, normalized: field.isNormalized) { set($0, true) }
        case .combo:
            ParticleOptionPicker(options: field.options, value: value) { set($0, false) }
        case .checkbox, .checkboxbit, .colorlist:
            EmptyView()
        }
    }
}

/// A number box as WE's (`<input type=number step=any>`): any value, the arrow keys step by 1.
struct ParticleNumberField: View {
    let value: Double
    var isInteger = false
    var width: CGFloat = 64
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        TextField("", text: $text)
            .focused($isEditing)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: width)
            .onAppear { text = Self.format(value, isInteger: isInteger) }
            .onChange(of: value) { _, newValue in
                if !isEditing || Self.parse(text, isInteger: isInteger) != newValue {
                    text = Self.format(newValue, isInteger: isInteger)
                }
            }
            .onChange(of: text) { _, newText in
                guard isEditing, let parsed = Self.parse(newText, isInteger: isInteger), parsed != value else { return }
                commit(parsed)
            }
            .onSubmit {
                if let parsed = Self.parse(text, isInteger: isInteger), parsed != value { commit(parsed) }
                text = Self.format(value, isInteger: isInteger)
            }
            .onChange(of: isEditing) { _, editing in
                if !editing { text = Self.format(value, isInteger: isInteger) }
            }
            .onKeyPress(.upArrow) { commit(value + 1); return .handled }
            .onKeyPress(.downArrow) { commit(value - 1); return .handled }
    }

    /// Up to four decimals, without trailing zeros.
    static func format(_ value: Double, isInteger: Bool) -> String {
        guard value.isFinite else { return "0" }
        if isInteger || value.rounded() == value { return String(Int(value.rounded())) }
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func parse(_ text: String, isInteger: Bool) -> Double? {
        guard let number = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              number.isFinite else { return nil }
        return isInteger ? number.rounded() : number
    }
}

/// Per-component number boxes of a `"x y z"` vector; an angle shows degrees and stores radians.
struct ParticleVectorField: View {
    let field: ParticleEditorSchema.Field
    let count: Int
    let value: SceneJSONValue?
    let set: (SceneJSONValue) -> Void

    var body: some View {
        let components = Self.components(value, count: count)
        let scale = field.isAngle ? 180 / Double.pi : 1
        // Baseline-aligned so the degree sign sits beside the numbers, not halfway down to the
        // axis captions under them.
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            ForEach(0..<count, id: \.self) { index in
                VStack(spacing: 1) {
                    ParticleNumberField(value: components[index] * scale, width: 52) { typed in
                        var next = components
                        next[index] = typed / scale
                        set(SceneVector.value(next))
                    }
                    Text(verbatim: field.localizedComponent(index))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if field.isAngle {
                Text(verbatim: "°")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /// The vector's components; a bare number is that value on every axis, as WE reads it.
    static func components(_ value: SceneJSONValue?, count: Int) -> [Double] {
        if case .number(let number)? = value { return Array(repeating: number, count: count) }
        return SceneVector.components(value, fallback: Array(repeating: 0, count: count))
    }
}

/// A colour of `"r g b"`: 0–1 per channel when `normalized`, else 0–255 (WE's `colorrandom`).
struct ParticleColorWell: View {
    let value: SceneJSONValue?
    let normalized: Bool
    let set: (SceneJSONValue) -> Void

    var body: some View {
        ColorPicker(selection: Binding(get: { Self.color(value, normalized: normalized) },
                                       set: { set(Self.value($0, normalized: normalized)) }),
                    supportsOpacity: false) { EmptyView() }
            .labelsHidden()
    }

    static func color(_ value: SceneJSONValue?, normalized: Bool) -> Color {
        let scale = normalized ? 1 : 255.0
        let rgb = SceneVector.components(value, fallback: [scale, scale, scale]).map { min(max($0 / scale, 0), 1) }
        return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    static func value(_ color: Color, normalized: Bool) -> SceneJSONValue {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .white
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(Double.init)
        if normalized {
            return SceneVector.value(channels.map { ($0 * 1000).rounded() / 1000 })
        }
        return SceneVector.value(channels.map { ($0 * 255).rounded() })
    }
}

/// WE's colour list: one to ten colours (`colors`), each 0–1.
struct ParticleColorList: View {
    let field: ParticleEditorSchema.Field
    let value: SceneJSONValue?
    let set: (SceneJSONValue?, Bool) -> Void

    var body: some View {
        let colors: [SceneJSONValue] = {
            if case .array(let values)? = value { return values }
            return []
        }()
        let lower = Int(field.minimum ?? 1), upper = Int(field.maximum ?? 10)
        HStack(spacing: 6) {
            ForEach(colors.indices, id: \.self) { index in
                ParticleColorWell(value: colors[index], normalized: true) { color in
                    var next = colors
                    next[index] = color
                    set(.array(next), true)
                }
            }
            Spacer(minLength: 4)
            Stepper(value: Binding(get: { colors.count }, set: { count in
                var next = colors
                while next.count < count { next.append(next.last ?? .string("1 1 1")) }
                if next.count > count { next.removeLast(next.count - count) }
                set(.array(next), false)
            }), in: lower...upper) {
                Text(verbatim: "\(colors.count)").monospacedDigit()
            }
            .help(PartL("Number of colours"))
        }
    }
}

/// A menu of the field's options; a value WE's panel doesn't list is kept and shown as authored.
struct ParticleOptionPicker: View {
    let options: [ParticleEditorSchema.Option]
    let value: SceneJSONValue?
    let set: (SceneJSONValue) -> Void

    var body: some View {
        let selected = Self.match(value, in: options)
        Picker(selection: Binding(get: { selected }, set: { set($0) })) {
            ForEach(options, id: \.value) { option in
                Text(option.localizedLabel).tag(option.value)
            }
            if !options.contains(where: { $0.value == selected }) {
                Text(verbatim: Self.describe(selected)).tag(selected)
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .fixedSize()
    }

    /// The option `value` names: WE matches names without case, and numbers by value.
    static func match(_ value: SceneJSONValue?, in options: [ParticleEditorSchema.Option]) -> SceneJSONValue {
        guard let value else { return options.first?.value ?? .null }
        if let option = options.first(where: { option in
            if let left = option.value.stringValue, let right = value.stringValue { return left.lowercased() == right.lowercased() }
            if case .number(let left) = option.value, let right = value.doubleValue { return left == right }
            return option.value == value
        }) {
            return option.value
        }
        return value
    }

    static func describe(_ value: SceneJSONValue) -> String {
        switch value {
        case .string(let text): return text
        case .number(let number): return ParticleNumberField.format(number, isInteger: false)
        case .bool(let flag): return flag ? "true" : "false"
        default: return "—"
        }
    }
}

/// What a value-over-lifetime operator does, drawn over the particle's life: the colour of
/// `colorchange`, the curve of `sizechange` and `alphachange` (start value until the start time,
/// a straight change to the end value at the end time, then the end value).
struct ParticleLifetimeRamp: View {
    @Environment(\.appAccentColor) private var accentColor
    let name: String
    let item: [String: SceneJSONValue]
    let field: (String) -> SceneJSONValue?

    static let names: Set<String> = ["colorchange", "sizechange", "alphachange"]

    var body: some View {
        let start = field("starttime")?.doubleValue ?? 0
        let end = field("endtime")?.doubleValue ?? 1
        VStack(alignment: .leading, spacing: 2) {
            if name == "colorchange" {
                let from = ParticleColorWell.color(field("startvalue"), normalized: true)
                let to = ParticleColorWell.color(field("endvalue"), normalized: true)
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(stops: [
                        .init(color: from, location: min(max(start, 0), 1)),
                        .init(color: to, location: min(max(end, 0), 1)),
                    ], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 14)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            } else {
                let from = field("startvalue")?.doubleValue ?? 1
                let to = field("endvalue")?.doubleValue ?? 0
                Canvas { context, size in
                    let top = max(from, to, 1), bottom = min(from, to, 0)
                    let span = max(top - bottom, 1e-6)
                    func y(_ value: Double) -> Double { size.height - (value - bottom) / span * size.height }
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y(from)))
                    path.addLine(to: CGPoint(x: min(max(start, 0), 1) * size.width, y: y(from)))
                    path.addLine(to: CGPoint(x: min(max(end, 0), 1) * size.width, y: y(to)))
                    path.addLine(to: CGPoint(x: size.width, y: y(to)))
                    context.stroke(path, with: .color(accentColor), lineWidth: 1.5)
                }
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.4)))
            }
            Text(PartL("Over the particle’s lifetime"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
