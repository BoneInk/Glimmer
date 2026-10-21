import OWEInspectorKit
import OWESceneEditing
import SwiftUI
import UniformTypeIdentifiers

/// The Materials tab: what WE's Advanced Texture Settings changes on an imported model's
/// materials. The shader (WE's model shaders `generic4`, `foliage4`, `fur4`, `chroma4`), its
/// combos (Lighting, Reflection, Rim lighting, Toon shading, Tint mask in albedo alpha, Fog…),
/// its textures (Albedo, Normal map, the PBR map's metallic, roughness, reflection and emissive
/// channels…) and its constants (Metallic, Roughness, Reflectivity, Emissive colour…), all read
/// from the shader's annotations.
struct ModelMaterialsTab: View {
    @ObservedObject var editor: ModelEditorModel
    @State private var selection: String?
    @State private var importingSlot: Int?

    struct MaterialItem: Identifiable { var id: String }

    var body: some View {
        ModelEditorColumns {
            ModelEditorList(title: ML("Materials"), items: editor.materialNames.map(MaterialItem.init), selection: $selection) { item in
                VStack(alignment: .leading) {
                    Text(item.id)
                    Text(editor.material(item.id).shader).font(.caption).foregroundStyle(.secondary)
                }
            } buttons: {
                EmptyView()
            }
        } right: {
            if let name = selection {
                MaterialOptions(editor: editor, name: name, importingSlot: $importingSlot)
            } else {
                Text(ML("Pick a material.")).foregroundStyle(.secondary)
            }
        }
        .fileImporter(isPresented: Binding(get: { importingSlot != nil }, set: { if !$0 { importingSlot = nil } }),
                      allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result, let slot = importingSlot, let name = selection else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            editor.importTexture(url, material: name, slot: slot)
        }
    }
}

private struct MaterialOptions: View {
    @ObservedObject var editor: ModelEditorModel
    let name: String
    @Binding var importingSlot: Int?

    var body: some View {
        let document = editor.material(name)
        let schema = ModelShaderSchema.load(document.shader, read: editor.readFile)
        Section(ML("Shader")) {
            Picker(ML("Shader"), selection: Binding(get: { document.shader }, set: { shader in editor.updateMaterial(name) { $0.shader = shader } })) {
                ForEach(ModelShaderSchema.modelShaders, id: \.self) { Text(ModelMaterialLabels.shaderTitle($0)).tag($0) }
                if !ModelShaderSchema.modelShaders.contains(document.shader) { Text(document.shader).tag(document.shader) }
            }
            LabeledContent(ML("File"), value: editor.materialPath(name))
        }
        if let schema {
            let values = { (combo: String) -> Int in
                document.combo(combo, default: schema.combos.first { $0.name == combo }?.defaultValue ?? 0)
            }
            if !schema.combos.isEmpty {
                Section(ML("Options")) {
                    ForEach(schema.combos.filter { ModelShaderSchema.holds($0.requirements, values: values) }) { combo in
                        comboControl(combo, value: values(combo.name))
                    }
                }
            }
            Section(ML("Textures")) {
                ForEach(schema.textures.filter { ModelShaderSchema.holds($0.requirements, values: values) }) { texture in
                    textureRow(texture, current: document.texture(texture.slot))
                }
            }
            let groups = Dictionary(grouping: schema.constants, by: { $0.group ?? "" })
            ForEach(groups.keys.sorted(), id: \.self) { group in
                Section(group.isEmpty ? ML("Values") : ModelMaterialLabels.title(group)) {
                    ForEach(groups[group] ?? []) { constant in constantControl(constant, value: document.constant(constant.key)) }
                }
            }
        } else {
            Text(ML("The shader’s settings can’t be read without Wallpaper Engine’s assets.")).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func comboControl(_ combo: ModelShaderSchema.Combo, value: Int) -> some View {
        if combo.options.isEmpty {
            Toggle(ModelMaterialLabels.title(combo.label), isOn: Binding(get: { value != 0 }, set: { on in
                editor.updateMaterial(name) { $0.setCombo(combo.name, on ? 1 : 0) }
            }))
        } else {
            Picker(ModelMaterialLabels.title(combo.label), selection: Binding(get: { value }, set: { choice in
                editor.updateMaterial(name) { $0.setCombo(combo.name, choice) }
            })) {
                ForEach(combo.options, id: \.value) { Text(ModelMaterialLabels.title($0.label)).tag($0.value) }
            }
        }
    }

    @ViewBuilder private func textureRow(_ texture: ModelShaderSchema.Texture, current: String?) -> some View {
        LabeledContent(ModelMaterialLabels.title(texture.label)) {
            HStack {
                Text(current ?? texture.defaultTexture ?? ML("None")).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(current == nil ? .secondary : .primary)
                Button(ML("Choose…")) { importingSlot = texture.slot }
                if current != nil {
                    Button { editor.updateMaterial(name) { $0.setTexture(texture.slot, nil) } } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).help(ML("Remove Texture"))
                }
            }
        }
        if !texture.components.isEmpty, current != nil {
            ForEach(texture.components, id: \.combo) { component in
                let document = editor.material(name)
                Toggle(ModelMaterialLabels.title(component.label), isOn: Binding(get: { document.combo(component.combo, default: 0) != 0 }, set: { on in
                    editor.updateMaterial(name) { $0.setCombo(component.combo, on ? 1 : nil) }
                }))
                .padding(.leading, 12)
            }
        }
    }

    @ViewBuilder private func constantControl(_ constant: ModelShaderSchema.Constant, value: [Double]?) -> some View {
        let current = value ?? constant.defaultValue
        if constant.isColor, current.count >= 3 {
            ColorPicker(ModelMaterialLabels.title(constant.label), selection: Binding(get: {
                Color(red: current[0], green: current[1], blue: current[2])
            }, set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                editor.updateMaterial(name) { $0.setConstant(constant.key, [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]) }
            }), supportsOpacity: false)
        } else if current.count == 1 {
            LabeledContent(ModelMaterialLabels.title(constant.label)) {
                NumericSliderInput<Double>(value: Binding(get: { current[0] }, set: { number in
                    editor.updateMaterial(name) { $0.setConstant(constant.key, [number]) }
                }), range: constant.minimum...max(constant.maximum, constant.minimum + 0.001), defaultValue: constant.defaultValue[0],
                    fractionDigits: 2, fieldWidth: 52)
            }
        } else {
            LabeledContent(ModelMaterialLabels.title(constant.label)) {
                HStack(spacing: 4) {
                    ForEach(current.indices, id: \.self) { index in
                        TextField("", value: Binding(get: { current[index] }, set: { number in
                            var next = current
                            next[index] = number
                            editor.updateMaterial(name) { $0.setConstant(constant.key, next) }
                        }), format: .number.precision(.fractionLength(0...3)))
                        .labelsHidden().frame(width: 56)
                    }
                }
            }
        }
    }
}

/// Titles of WE's material labels (`ui_editor_properties_…`), from the Model Editor's catalog;
/// a label it doesn't have is shown from its key.
enum ModelMaterialLabels {
    static func title(_ label: String) -> String {
        let fallback = label.replacingOccurrences(of: "ui_editor_properties_", with: "").replacingOccurrences(of: "_", with: " ").capitalized
        guard label.hasPrefix("ui_") else { return label }
        return Bundle.module.localizedString(forKey: label, value: fallback, table: "ModelEditor")
    }

    static func shaderTitle(_ shader: String) -> String {
        switch shader {
        case "generic4": return ML("Generic")
        case "foliage4": return ML("Foliage")
        case "fur4": return ML("Fur")
        case "chroma4": return ML("Chroma")
        default: return shader
        }
    }
}
