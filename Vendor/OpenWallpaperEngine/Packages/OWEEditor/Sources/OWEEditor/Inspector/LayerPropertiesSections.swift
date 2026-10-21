import AppKit
import SwiftUI
import OWEInspectorKit
import OWESceneEditing

/// The image layer fields WE's editor shows besides the transform and appearance, grouped as its
/// property table groups them (`wallpaperui.exe`): parallax depth (with the scene's camera
/// parallax, on a layer without a parent), the Miscellaneous group (perspective rendering, click
/// events, click propagation, copy background, alignment), the texture's Clamp UVs, and Lighting
/// & Reflections (the layer material's combos, normal map and material constants).
struct LayerPropertiesSections: View {
    @ObservedObject var session: SceneEditSession
    let services: WallpaperEditorServices
    let layer: SceneLayer

    /// WE's `alignment` values, its 3 × 3 anchor grid in reading order.
    static let alignments = ["topleft", "top", "topright", "left", "center", "right", "bottomleft", "bottom", "bottomright"]

    var body: some View {
        if layer.kind == .image || layer.kind == .text {
            miscellaneousSection
        }
        if layer.imageRole == .picture {
            Section(L("Texture")) {
                LayerToggleRow(session: session, services: services, layerID: layer.id, field: "clampuvs", title: L("Clamp UVs"))
            }
            LayerLightingSection(session: session, services: services, layer: layer)
            TextureVariantsSection(session: session, services: services, layer: layer)
        }
    }

    // MARK: Miscellaneous

    private var miscellaneousSection: some View {
        Section(L("Miscellaneous")) {
            if layer.kind == .image {
                LayerToggleRow(session: session, services: services, layerID: layer.id, field: "perspective",
                               title: L("Perspective Rendering"))
            }
            // WE's objects are solid (they take clicks) unless the scene says otherwise.
            LayerToggleRow(session: session, services: services, layerID: layer.id, field: "solid",
                           title: L("Enable Click Events"), fallback: true)
            LayerToggleRow(session: session, services: services, layerID: layer.id, field: "disablepropagation",
                           title: L("Disable Click Propagation"))
            if layer.imageRole == .composition || layer.imageRole == .fullscreen {
                LayerToggleRow(session: session, services: services, layerID: layer.id, field: "copybackground",
                               title: L("Copy Background"), fallback: true)
            }
            if layer.isPlanar {
                LayerFieldRow(session: session, services: services, layerID: layer.id, field: "alignment", title: L("Alignment")) {
                    Picker(selection: Binding(
                        get: { session.value("alignment", of: layer.id)?.stringValue?.lowercased() ?? "center" },
                        set: {
                            // The inner text first: a nested L() hides the key from the catalog check.
                            let field = L("Alignment")
                            session.setValue(.string($0), for: "alignment", of: layer.id, actionName: L("Change \(field)"))
                        })) {
                        ForEach(Self.alignments, id: \.self) { value in
                            Text(Self.alignmentTitle(value)).tag(value)
                        }
                    } label: {
                        EmptyView()
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    static func alignmentTitle(_ value: String) -> String {
        switch value {
        case "topleft": return L("Top Left")
        case "top": return L("Top")
        case "topright": return L("Top Right")
        case "left": return L("Left")
        case "right": return L("Right")
        case "bottomleft": return L("Bottom Left")
        case "bottom": return L("Bottom")
        case "bottomright": return L("Bottom Right")
        default: return L("Center")
        }
    }
}

/// WE's Lighting & Reflections for an image layer whose material is one of its generic image
/// shaders: Lighting and Reflection (the `LIGHTING` and `REFLECTION` combos) and, with either on,
/// the normal map and the shader's material constants. The edited material is kept in the
/// overlay; the scene reads it again.
struct LayerLightingSection: View {
    @ObservedObject var session: SceneEditSession
    let services: WallpaperEditorServices
    let layer: SceneLayer

    private var material: ImageLayerLighting? {
        session.imageMaterial(of: layer.id, readAsset: services.readAsset)
    }

    var body: some View {
        if let material, material.isLightable {
            Section(L("Lighting & Reflections")) {
                comboToggle(material, combo: "LIGHTING", title: L("Lighting"))
                comboToggle(material, combo: "REFLECTION", title: L("Reflection"))
                if material.lighting || material.reflection {
                    LabeledContent(L("Normal Map")) {
                        Picker(selection: Binding(
                            get: { material.normalMap ?? "" },
                            set: { name in
                                write(material.settingNormalMap(name.isEmpty ? nil : name), material, L("Normal Map"))
                            })) {
                            Text(L("None")).tag("")
                            ForEach(normalMapChoices(material), id: \.self) { name in
                                Text(name).tag(name)
                            }
                        } label: {
                            EmptyView()
                        }
                        .labelsHidden()
                        .frame(maxWidth: 180)
                    }
                    ForEach(ImageLayerLighting.constants(shader: material.shader)) { constant in
                        constantRow(constant, material)
                    }
                }
            }
        }
    }

    /// The wallpaper's textures (and the one the material names, if it isn't among them).
    private func normalMapChoices(_ material: ImageLayerLighting) -> [String] {
        var names = services.wallpaperAssets().compactMap(\.textureName)
        if let current = material.normalMap, !names.contains(current) { names.insert(current, at: 0) }
        return names
    }

    private func write(_ document: SceneJSONValue, _ material: ImageLayerLighting, _ title: String, coalescing: String? = nil) {
        session.setImageMaterial(document, path: material.path, readAsset: services.readAsset,
                                 actionName: L("Change \(title)"), coalescingKey: coalescing.map { "\(material.path):\($0)" })
    }

    private func comboToggle(_ material: ImageLayerLighting, combo: String, title: String) -> some View {
        LabeledContent(title) {
            Toggle(isOn: Binding(
                get: { material.combo(combo) != 0 },
                set: { write(material.settingCombo(combo, to: $0 ? 1 : 0), material, title) })) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    @ViewBuilder private func constantRow(_ constant: ImageLayerLighting.Constant, _ material: ImageLayerLighting) -> some View {
        let title = Self.title(constant.label)
        LabeledContent(title) {
            switch constant.kind {
            case .number(let range):
                NumericSliderInput<Double>(value: Binding<Double>(
                    get: { material.constant(constant).first ?? 0 },
                    set: { write(material.settingConstant(constant.key, to: [$0]), material, title, coalescing: constant.key) }),
                    range: range, defaultValue: constant.defaultValue.first ?? 0, fractionDigits: 2, fieldWidth: 52,
                    clampsTypedValue: false)
            case .color:
                ColorPicker(selection: Binding(
                    get: {
                        let rgb = SceneVector.components(.array(material.constant(constant).map(SceneJSONValue.number)), fallback: [1, 1, 1])
                        return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
                    },
                    set: { color in
                        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .white
                        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(Double.init)
                        write(material.settingConstant(constant.key, to: components), material, title, coalescing: constant.key)
                    }), supportsOpacity: false) {
                    EmptyView()
                }
                .labelsHidden()
            }
        }
    }

    /// The editor's title for one of WE's material labels.
    static func title(_ label: String) -> String {
        switch label {
        case "ui_editor_properties_roughness": return L("Roughness")
        case "ui_editor_properties_metallic": return L("Metallic")
        case "ui_editor_properties_specular_tint": return L("Specular Tint")
        case "ui_editor_properties_emissive_color": return L("Emissive Color")
        case "ui_editor_properties_emissive_brightness": return L("Emissive Brightness")
        default: return L("Reflectivity")
        }
    }
}

/// The layer's parallax depth (`parallaxDepth`), which WE's editor shows in the transform while
/// the scene's camera parallax is on and the layer has no parent.
struct LayerParallaxDepthRow: View {
    @ObservedObject var session: SceneEditSession
    let services: WallpaperEditorServices
    let layer: SceneLayer

    /// WE shows a layer's parallax depth while the scene's camera parallax is on.
    private var sceneHasCameraParallax: Bool {
        let setting = session.overlay.generalSetting("cameraparallax") ?? session.authored.general["cameraparallax"]
        return SceneFieldBinding.literal(of: setting)?.boolValue ?? false
    }

    var body: some View {
        if sceneHasCameraParallax, layer.parentID == nil {
            LayerFieldRow(session: session, services: services, layerID: layer.id, field: "parallaxDepth", title: L("Parallax Depth")) {
                HStack(spacing: 4) {
                    depthField(component: 0, axis: "X")
                    depthField(component: 1, axis: "Y")
                }
            }
        }
    }

    private func depthField(component: Int, axis: String) -> some View {
        TextField(value: Binding<Double>(
            get: { session.vector("parallaxDepth", of: layer.id, default: [1, 1])[component] },
            set: { value in
                var depth = session.vector("parallaxDepth", of: layer.id, default: [1, 1])
                depth[component] = value
                let field = L("Parallax Depth")
                session.setValue(SceneVector.value(depth), for: "parallaxDepth", of: layer.id,
                                 actionName: L("Change \(field)"), coalescing: true)
            }), format: .number.precision(.fractionLength(0...3))) {
            Text(verbatim: axis)
        }
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .frame(width: 56)
    }
}
