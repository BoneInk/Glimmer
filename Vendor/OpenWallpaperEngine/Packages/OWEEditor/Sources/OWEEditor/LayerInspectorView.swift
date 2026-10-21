import AppKit
import SwiftUI
import OWEInspectorKit
import OWESceneEditing

/// The contextual inspector: the selected layer's transform, appearance and effects, or, with no
/// selection, the scene and its user properties. Controls are Scene Edit / Export's own
/// (`NumericSliderInput`, `InfoTip`, its blend-mode picker); a field a user property sets shows
/// which one instead of a control, as WE's editor does.
struct LayerInspectorView: View {
    @ObservedObject var session: SceneEditSession
    @ObservedObject var tools: EditorTools
    let services: WallpaperEditorServices

    var body: some View {
        if let selected = session.selection, let layer = session.outline.layer(selected) {
            LayerForm(session: session, tools: tools, services: services, layer: layer)
                .id(layer.id)
        } else {
            SceneForm(session: session, services: services)
        }
    }
}

private struct LayerForm: View {
    @ObservedObject var session: SceneEditSession
    @ObservedObject var tools: EditorTools
    let services: WallpaperEditorServices
    let layer: SceneLayer
    @State private var isScaleLinked = true

    /// "Set by the user property “Clock Location”", by the property's label.
    private func boundHelp(_ key: String) -> String {
        let name = services.userPropertyTitle(key, properties: session.overlay.authoring?.properties)
        return L("Set by the user property “\(name)”")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(L("Kind"), value: layer.kind.title)
                if !session.isVisible(layer.id) {
                    Label(L("Hidden"), systemImage: "eye.slash").foregroundStyle(.secondary)
                }
            } header: {
                Text(layer.title).font(.headline)
            }
            if layer.kind != .sound && !layer.fillsScene {
                transformSection
            }
            if layer.kind == .sound {
                LayerSoundSection(session: session, services: services, layer: layer)
            }
            if layer.kind == .text {
                LayerTextSection(session: session, tools: tools, services: services, layer: layer)
            }
            if layer.kind == .particle, let particles = services.particles {
                ParticleSystemSections(services: particles, layer: layer) { key in
                    services.userPropertyTitle(key, properties: session.overlay.authoring?.properties)
                }
            }
            if layer.kind == .image || layer.kind == .text {
                appearanceSection
            }
            LayerPropertiesSections(session: session, services: services, layer: layer)
            if layer.kind == .image || layer.kind == .text {
                EffectsSection(session: session, tools: tools, services: services, layer: layer)
            } else if !layer.effects.isEmpty {
                effectsSection
            }
            if let depthMaps = services.depthMaps, SceneDepthParallax.placement(for: layer) == .onLayer {
                DepthMapSection(session: session, layerID: layer.id, services: depthMaps)
            }
            if layer.kind == .model { ModelInspectorSection(session: session, layer: layer, services: services) }
            if layer.kind == .image, let assets = services.puppetEditorAssets {
                PuppetInspectorSection(session: session, layer: layer, assets: assets)
            }
            if layer.kind == .image { NormalMapSection(session: session, tools: tools, services: services, layer: layer) }
            LayerScriptsSection(layer: layer)
            Section {
                DisclosureGroup(L("Details")) {
                    if let source = layer.sourcePath {
                        LabeledContent(L("Source")) { Text(source).textSelection(.enabled).lineLimit(2).truncationMode(.middle) }
                    }
                    LabeledContent(L("ID"), value: String(layer.id))
                    if let parent = layer.parentID.flatMap(session.outline.layer) {
                        LabeledContent(L("Parent"), value: parent.title)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            let scale = session.transform(of: layer.id).scale
            isScaleLinked = scale.x == scale.y
        }
    }

    // MARK: Transform

    @ViewBuilder private var transformSection: some View {
        Section(L("Transform")) {
            fieldRow("origin", title: L("Position")) {
                HStack {
                    numberField("X", component: 0, field: "origin", actionName: L("Change Position"))
                    numberField("Y", component: 1, field: "origin", actionName: L("Change Position"))
                }
            }
            fieldRow("scale", title: L("Scale")) {
                VStack(alignment: .leading, spacing: 6) {
                    if isScaleLinked {
                        scaleSlider(components: [0, 1])
                    } else {
                        HStack { Text(verbatim: "X").foregroundStyle(.secondary); scaleSlider(components: [0]) }
                        HStack { Text(verbatim: "Y").foregroundStyle(.secondary); scaleSlider(components: [1]) }
                    }
                    Toggle(isOn: $isScaleLinked) {
                        Label(L("Keep Proportions"), systemImage: "link")
                    }
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }
            }
            fieldRow("angles", title: L("Rotation")) {
                NumericSliderInput<Double>(value: Binding<Double>(
                    get: { session.transform(of: layer.id).angles.z * 180 / .pi },
                    set: { degrees in
                        var transform = session.transform(of: layer.id)
                        transform.angles.z = degrees * .pi / 180
                        session.setTransform(transform, of: layer.id, actionName: L("Change Rotation"), coalescing: true)
                    }), range: -180...180, defaultValue: 0, step: 1, suffix: "°", fractionDigits: 1,
                    fieldWidth: 56, clampsTypedValue: false)
            }
            LayerSizeRows(session: session, layer: layer)
            LayerParallaxDepthRow(session: session, services: services, layer: layer)
            if layer.isPlanar, session.outline.size != nil {
                LabeledContent(L("Align")) {
                    Menu {
                        AlignmentButtons(actions: LayerActions(session: session, services: services, tools: tools), layerID: layer.id)
                    } label: {
                        Label(L("Align to Scene"), systemImage: "align.horizontal.center")
                    }
                    .fixedSize()
                }
            }
        }
    }

    private func numberField(_ axis: String, component: Int, field: String, actionName: String) -> some View {
        let binding = Binding<Double>(
            get: { session.vector(field, of: layer.id, default: [0, 0, 0])[component] },
            set: { value in
                var vector = session.vector(field, of: layer.id, default: [0, 0, 0])
                vector[component] = value
                session.setValue(SceneVector.value(vector), for: field, of: layer.id, actionName: actionName, coalescing: true)
            })
        return TextField(value: binding, format: .number.precision(.fractionLength(0...2))) {
            Text(verbatim: axis)
        }
        .multilineTextAlignment(.trailing)
    }

    private func scaleSlider(components: [Int]) -> some View {
        NumericSliderInput<Double>(value: Binding<Double>(
            get: { session.vector("scale", of: layer.id, default: [1, 1, 1])[components[0]] },
            set: { value in
                var transform = session.transform(of: layer.id)
                for component in components {
                    if component == 0 { transform.scale.x = value } else { transform.scale.y = value }
                }
                session.setTransform(transform, of: layer.id, actionName: L("Change Scale"), coalescing: true)
            }), range: 0.05...5, defaultValue: 1, step: 0.01, suffix: "×", fractionDigits: 2,
            fieldWidth: 52, clampsTypedValue: false)
    }

    // MARK: Appearance

    @ViewBuilder private var appearanceSection: some View {
        Section(L("Appearance")) {
            fieldRow("alpha", title: L("Opacity")) {
                NumericSliderInput<Double>(value: Binding<Double>(
                    get: { session.number("alpha", of: layer.id, default: 1) },
                    set: { session.setValue(.number($0), for: "alpha", of: layer.id, actionName: L("Change Opacity"), coalescing: true) }),
                    range: 0...1, defaultValue: 1, displayScale: 100, suffix: "%", fractionDigits: 0, fieldWidth: 44)
            }
            fieldRow("color", title: L("Color")) {
                ColorPicker(selection: Binding(
                    get: {
                        let rgb = session.vector("color", of: layer.id, default: [1, 1, 1])
                        return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
                    },
                    set: { color in
                        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .white
                        let value = SceneVector.value([rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(Double.init))
                        session.setValue(value, for: "color", of: layer.id, actionName: L("Change Color"), coalescing: true)
                    }), supportsOpacity: false) {
                    EmptyView()
                }
                .labelsHidden()
            }
            if layer.kind == .image {
                LayerNumberRow(session: session, services: services, layerID: layer.id, field: "brightness",
                               title: L("Brightness"), range: 0...2, fallback: 1)
                fieldRow("colorBlendMode", title: services.blendModeTitle) {
                    InspectorOptionPicker(options: services.blendModes, selection: Binding(
                        get: { Int(session.number("colorBlendMode", of: layer.id, default: 0)) },
                        set: { session.setValue(.number(Double($0)), for: "colorBlendMode", of: layer.id,
                                                actionName: L("Change Blend Mode")) })) {
                        EmptyView()
                    }
                    .labelsHidden()
                }
            }
        }
    }

    // MARK: Effects

    @ViewBuilder private var effectsSection: some View {
        Section(L("Effects")) {
            if layer.effects.isEmpty {
                Text(L("No effects")).foregroundStyle(.secondary)
            }
            ForEach(layer.effects) { effect in
                let bound: String? = {
                    if case .userProperty(let name) = session.effectBinding(effect, of: layer.id) { return name }
                    return nil
                }()
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                    Toggle(isOn: Binding(
                        get: { session.isEffectVisible(effect, of: layer.id) },
                        set: { visible in
                            session.setEffectVisible(visible, effect: effect, of: layer.id,
                                                     actionName: visible ? L("Turn Effect On") : L("Turn Effect Off"))
                        })) {
                        Text(effect.title)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(bound != nil)
                    .help(bound.map { boundHelp($0) } ?? "")
                    InfoTip(services.effectHelp(effect.folderName))
                }
                .fieldAuthoring(layer: layer.id, path: .effect(effect.id))
            }
        }
    }

    /// The field's control, or, for one a user property sets, which property.
    private func fieldRow<Control: View>(_ field: String, title: String,
                                         @ViewBuilder control: () -> Control) -> some View {
        Group {
            if case .userProperty(let name) = session.binding(field, of: layer.id) {
                LabeledContent(title) {
                    Text(boundHelp(name))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            } else {
                LabeledContent(title) {
                    HStack(spacing: 6) {
                        control()
                        KeyframeButton(target: .field(field, of: layer.id))
                    }
                }
            }
        }
        .fieldAuthoring(layer: layer.id, path: SceneFieldPath(components: [field]))
    }
}

/// With nothing selected: the scene, and the wallpaper's user properties.
private struct SceneForm: View {
    @ObservedObject var session: SceneEditSession
    let services: WallpaperEditorServices

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent(L("Size")) {
                            if let size = session.outline.size {
                                Text(verbatim: "\(Int(size.x)) × \(Int(size.y))").monospacedDigit()
                            } else {
                                Text(L("3D scene"))
                            }
                        }
                        LabeledContent(L("Layers"), value: String(session.outline.layers.count))
                        LabeledContent(L("Edited Layers"),
                                       value: String(session.outline.layers.filter { session.isEdited($0.id) }.count))
                    }
                    .padding(4)
                } label: {
                    Text(L("Scene")).font(.headline)
                }
                ProjectSettingsSection(session: session, services: services)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Scene Options")).font(.headline)
                    SceneOptionsSection(session: session, services: services)
                }
                if let depthMaps = services.depthMaps {
                    DepthMapBox(session: session, layerID: nil, services: depthMaps)
                }
                if let userProperties = services.userProperties {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("User Properties")).font(.headline)
                            Spacer()
                            if services.projectJSON != nil {
                                EditUserPropertiesButton()
                            }
                        }
                        userProperties()
                    }
                }
                Text(L("Select a layer in the list or on the canvas to edit it. Edits show here until you save them, then wherever this wallpaper runs; its own files are never changed."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
