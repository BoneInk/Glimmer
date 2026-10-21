import SwiftUI
import AVFoundation
import OWEInspectorKit
import OWESceneEditing

extension SceneInspectorContent {
    @ViewBuilder func movementControls(for item: SceneInspectorItem?) -> some View {
        let origin = item.map(model.origin(for:))
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Move Element", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.title3.bold())
                Spacer()
                if let origin {
                    Text("X \(Int(origin.x))  Y \(Int(origin.y))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Color.clear.frame(width: 48, height: 40)
                    moveButton(systemImage: "arrow.up", title: "Move Up",
                               help: "Move up. Shift = 50 px, Control = 1 px, default = 10 px") {
                        guard let item else { return }
                        model.moveObject(item, deltaX: 0, deltaY: movementStep())
                    }
                    Color.clear.frame(width: 48, height: 40)
                }
                GridRow {
                    moveButton(systemImage: "arrow.left", title: "Move Left",
                               help: "Move left. Shift = 50 px, Control = 1 px, default = 10 px") {
                        guard let item else { return }
                        model.moveObject(item, deltaX: -movementStep(), deltaY: 0)
                    }
                    Text("Move")
                        .font(.callout.weight(.semibold))
                        .frame(width: 58, height: 40)
                    moveButton(systemImage: "arrow.right", title: "Move Right",
                               help: "Move right. Shift = 50 px, Control = 1 px, default = 10 px") {
                        guard let item else { return }
                        model.moveObject(item, deltaX: movementStep(), deltaY: 0)
                    }
                }
                GridRow {
                    Color.clear.frame(width: 48, height: 40)
                    moveButton(systemImage: "arrow.down", title: "Move Down",
                               help: "Move down. Shift = 50 px, Control = 1 px, default = 10 px") {
                        guard let item else { return }
                        model.moveObject(item, deltaX: 0, deltaY: -movementStep())
                    }
                    Color.clear.frame(width: 48, height: 40)
                }
            }
            // The arrows point at screen directions, so the pad doesn't mirror in right-to-left languages.
            .environment(\.layoutDirection, .leftToRight)
            .disabled(item == nil)
            .opacity(item == nil ? 0.4 : 1)
            Text(item == nil ? "Select an object to move it." : "Arrow keys work when this panel is focused. Shift moves faster, Control moves slower.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GroupBoxed())
    }

    func moveButton(systemImage: String, title: LocalizedStringKey, help: LocalizedStringKey,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .frame(width: 48, height: 40)
        }
        .glassButtonStyle(.prominent)
        .help(help)
    }

    @ViewBuilder func scaleControls(for item: SceneInspectorItem?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Size", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.headline)
                Spacer()
                if let item {
                    Text(verbatim: model.scale(for: item).formatted(.number.precision(.fractionLength(2))) + "×")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let item {
                let binding = Binding(
                    get: { model.scale(for: item) },
                    set: { model.setObjectScale(item, scale: $0) })
                NumericSliderInput(value: binding, range: 0.05...5,
                                   defaultValue: 1, step: 0.05, suffix: "x",
                                   fractionDigits: 2, sliderWidth: 120, fieldWidth: 52)
                Button("Reset to 1x") { model.setObjectScale(item, scale: 1) }
                    .buttonStyle(.link)
                    .font(.caption)
                if item.kind == "Image" {
                    appearanceControls(for: item)
                    blendModePicker(for: item)
                }
                if !SceneInspectorModel.blendingOptions(for: item).isEmpty {
                    materialBlendingPicker(for: item)
                }
            } else {
                Text("Select an object to resize it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The image layer's opacity and colour (its `alpha` and `color`), when nothing else sets them.
    @ViewBuilder func appearanceControls(for item: SceneInspectorItem) -> some View {
        if let alpha = model.alpha(for: item) {
            SceneLayerOpacitySlider(value: alpha) { model.setAlpha($0, for: item) }
        }
        if let color = model.color(for: item) {
            ColorPicker(selection: Binding(get: { Color(red: color.x, green: color.y, blue: color.z) },
                                           set: { model.setColor($0, for: item) }),
                        supportsOpacity: false) {
                Text("Color")
            }
            .anchorsColorPanel()
        }
    }

    /// The selected layer's adjustments in an isolated mode's panel: the Wallpaper mode's own
    /// controls (visibility, move, size, opacity and colour, blending, alignment, effects), on the
    /// isolated store.
    @ViewBuilder func layerAdjustments(for item: SceneInspectorItem?) -> some View {
        if let item, !item.isSynthetic {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(get: { item.isSwitchedOn }, set: { model.setObjectVisible($0, item: item) })) {
                    Text(verbatim: item.name)
                        .font(.headline)
                        .lineLimit(1)
                }
                .toggleStyle(.switch)
                .help(Self.visibilityHelp(item))
                movementControls(for: item)
                scaleControls(for: item)
                alignmentControls(for: item)
                effectList(for: item)
            }
            .modifier(ArrowKeyMove { direction in move(item, direction: direction) })
        } else {
            Text("Select a layer in the list to adjust it here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The image layer's blend mode, WE's 33 in its editor's order and groups.
    func blendModePicker(for item: SceneInspectorItem) -> some View {
        let combo = model.blendModeCombo
        return Picker(combo.title, selection: Binding(get: { model.blendMode(for: item) },
                                                      set: { model.setBlendMode($0, for: item) })) {
            ForEach(Self.optionGroups(combo), id: \.offset) { group in
                Section(group.heading ?? "") {
                    ForEach(group.options, id: \.value) { option in Text(option.title).tag(option.value) }
                }
            }
        }
    }

    /// The blending the layer's material draws with, of those its kind of layer draws
    /// (`WEMaterialBlending`), and a reset to its material's own.
    func materialBlendingPicker(for item: SceneInspectorItem) -> some View {
        HStack {
            Picker("Blending", selection: Binding(get: { model.materialBlending(for: item) },
                                                  set: { model.setMaterialBlending($0, for: item) })) {
                ForEach(SceneInspectorModel.blendingOptions(for: item), id: \.self) { blending in
                    Self.title(of: blending).tag(blending)
                }
            }
            Button("Reset") { model.resetMaterialBlending(for: item) }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(model.materialBlending(for: item) == model.authoredBlending(for: item))
        }
    }

    static func title(of blending: WEMaterialBlending) -> Text {
        switch blending {
        case .normal: Text("Normal")
        case .translucent: Text("Translucent")
        case .additive: Text("Additive")
        case .alphaToCoverage: Text("Alpha to Coverage")
        }
    }

    func movementColumn(for item: SceneInspectorItem?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                movementControls(for: item)
                Divider()
                scaleControls(for: item)
                Divider()
                alignmentControls(for: item)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Step")
                        .font(.headline)
                    Text("Default 10 px")
                    Text("Shift 50 px")
                    Text("Control 1 px")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .modifier(ArrowKeyMove { direction in
            if let item { move(item, direction: direction) }
        })
    }

    func alignmentControls(for item: SceneInspectorItem?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Align Element", systemImage: "align.horizontal.center")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("Horizontal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    alignmentButton("Left", help: "Align Left", systemImage: "align.horizontal.left") {
                        guard let item else { return }
                        model.alignObject(item, horizontal: .left)
                    }
                    alignmentButton("Center", help: "Align Center", systemImage: "align.horizontal.center") {
                        guard let item else { return }
                        model.alignObject(item, horizontal: .center)
                    }
                    alignmentButton("Right", help: "Align Right", systemImage: "align.horizontal.right") {
                        guard let item else { return }
                        model.alignObject(item, horizontal: .right)
                    }
                }
                // Left, centre, right on screen, in every language.
                .environment(\.layoutDirection, .leftToRight)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Vertical")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    alignmentButton("Top", help: "Align Top", systemImage: "align.vertical.top") {
                        guard let item else { return }
                        model.alignObject(item, vertical: .top)
                    }
                    alignmentButton("Middle", help: "Align Middle", systemImage: "align.vertical.center") {
                        guard let item else { return }
                        model.alignObject(item, vertical: .center)
                    }
                    alignmentButton("Bottom", help: "Align Bottom", systemImage: "align.vertical.bottom") {
                        guard let item else { return }
                        model.alignObject(item, vertical: .bottom)
                    }
                }
            }
        }
        .disabled(item == nil)
        .opacity(item == nil ? 0.4 : 1)
    }

    func alignmentButton(_ title: LocalizedStringKey, help: LocalizedStringKey, systemImage: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.callout.weight(.semibold))
                Text(title)
                    .font(.caption2)
            }
            .frame(width: 68, height: 46)
        }
        .glassButtonStyle()
        .help(help)
    }

    func move(_ item: SceneInspectorItem, direction: MoveCommandDirection) {
        let step = movementStep()
        switch direction {
        case .up:
            model.moveObject(item, deltaX: 0, deltaY: step)
        case .down:
            model.moveObject(item, deltaX: 0, deltaY: -step)
        case .left:
            model.moveObject(item, deltaX: -step, deltaY: 0)
        case .right:
            model.moveObject(item, deltaX: step, deltaY: 0)
        @unknown default:
            break
        }
    }

    func movementStep() -> Double {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) { return 50 }
        if flags.contains(.control) { return 1 }
        return 10
    }
}
