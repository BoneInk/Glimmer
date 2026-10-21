import AppKit
import SwiftUI
import OWEInspectorKit
import OWESceneEditing

/// The particle editor in the inspector of a particle layer, after its transform, laid out as WE's
/// panel: the system (restart, duplicate, delete, control points on the canvas), the layer's
/// instance override, the system's general settings and material, then its emitters,
/// initializers, operators, renderers, children and control points. A child system opens in the
/// same place (Edit), with a way back.
struct ParticleSystemSections: View {
    @ObservedObject var services: ParticleEditorServices
    @ObservedObject var model: ParticleEditingModel
    let layer: SceneLayer
    /// A bound user property's label (`WallpaperEditorServices.userPropertyTitle`).
    let propertyTitle: (String) -> String
    /// The child systems opened from the layer's system, the one shown last.
    @State private var childPath: [String] = []

    init(services: ParticleEditorServices, layer: SceneLayer, propertyTitle: @escaping (String) -> String = { $0 }) {
        self.services = services
        model = services.model
        self.layer = layer
        self.propertyTitle = propertyTitle
    }

    var body: some View {
        if let rootPath = model.particlePath(of: layer.id) {
            let path = childPath.last ?? rootPath
            systemSection(root: rootPath, path: path)
            if childPath.isEmpty {
                ParticleInstanceSection(model: model, layer: layer, propertyTitle: propertyTitle)
            }
            if let definition = model.definition(path) {
                ParticleGeneralSection(services: services, model: model, path: path, definition: definition)
                ForEach(ParticleEditorSchema.Section.lists, id: \.self) { section in
                    ParticleListSection(model: model, section: section, path: path) { child in
                        childPath.append(child)
                    }
                }
            } else {
                Section {
                    Label(PartL("This particle system’s file can’t be read."), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func systemSection(root: String, path: String) -> some View {
        Section {
            if !childPath.isEmpty {
                let parent = Self.fileName(childPath.dropLast().last ?? root)
                Button {
                    childPath.removeLast()
                } label: {
                    Label(PartL("Back to \(parent)"), systemImage: "chevron.backward")
                }
                .buttonStyle(.link)
            }
            LabeledContent(PartL("File")) {
                HStack(spacing: 4) {
                    Text(path).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    if model.isEdited(path) {
                        Circle().fill(.tint).frame(width: 6, height: 6)
                            .help(PartL("Edited"))
                            .accessibilityLabel(PartL("Edited"))
                    }
                }
            }
            HStack(spacing: 8) {
                Button {
                    services.restart(layer.id)
                } label: {
                    Label(PartL("Restart System"), systemImage: "arrow.clockwise")
                }
                .help(PartL("Start the system again from its first particle"))
                Spacer(minLength: 4)
                Button {
                    model.duplicateSystem(layer.id, name: PartL("\(layer.title) Copy"), actionName: PartL("Duplicate Particle System"))
                } label: {
                    Label(PartL("Duplicate"), systemImage: "plus.square.on.square").labelStyle(.iconOnly)
                }
                .help(PartL("Duplicate Particle System"))
                Button(role: .destructive) {
                    model.deleteSystem(layer.id, actionName: PartL("Delete Particle System"))
                } label: {
                    Label(PartL("Delete"), systemImage: "trash").labelStyle(.iconOnly)
                }
                .help(PartL("Delete Particle System"))
            }
            .buttonStyle(.borderless)
            if model.pixelUnits {
                Toggle(PartL("Show Control Points on the Canvas"), isOn: $model.showsControlPoints)
            }
        } header: {
            Text(childPath.isEmpty ? PartL("Particle System") : PartL("Child System"))
        }
    }

    static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

/// The layer's `instanceoverride`: WE's Particle Instance sliders and colour, which scale the
/// system for this layer only.
private struct ParticleInstanceSection: View {
    @ObservedObject var model: ParticleEditingModel
    let layer: SceneLayer
    let propertyTitle: (String) -> String

    var body: some View {
        let values = model.instanceOverride(of: layer.id)
        Section {
            if let component = model.schema.component(.instanceoverride) {
                ForEach(component.fields) { field in
                    row(field.key, values: values) {
                        ParticleFieldRow(field: field, kind: field.kind,
                                         value: SceneFieldBinding.literal(of: values[field.key]) ?? field.addDefault) { value, coalescing in
                            model.setInstanceOverride(field.key, to: value, of: layer.id,
                                                      actionName: PartL("Change Instance Override"), coalescing: coalescing)
                        }
                    }
                }
            }
            row("colorn", values: values) {
                LabeledContent(PLSchema("Color")) {
                    ParticleColorWell(value: SceneFieldBinding.literal(of: values["colorn"]) ?? .string("1 1 1"),
                                      normalized: true) { value in
                        model.setInstanceOverride("colorn", to: value, of: layer.id,
                                                  actionName: PartL("Change Instance Override"), coalescing: true)
                    }
                }
            }
        } header: {
            Text(PartL("Instance Override"))
        } footer: {
            Text(PartL("Scales this layer’s system without changing its file."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The control, or which user property sets the value.
    @ViewBuilder private func row<Control: View>(_ key: String, values: [String: SceneJSONValue],
                                                 @ViewBuilder control: () -> Control) -> some View {
        if case .userProperty(let property) = SceneFieldBinding(values[key]) {
            let name = propertyTitle(property)
            LabeledContent(PLSchema(Self.labels[key] ?? key)) {
                Text(PartL("Set by the user property “\(name)”"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        } else {
            control()
        }
    }

    static let labels = ["alpha": "Opacity", "rate": "Playback rate", "speed": "Speed", "size": "Size",
                         "count": "Count", "lifetime": "Lifetime", "colorn": "Color"]
}

/// The system's material (texture, blending, overbright, depth, culling) and its own fields
/// (max count, start time, flags, animation mode).
private struct ParticleGeneralSection: View {
    @ObservedObject var services: ParticleEditorServices
    @ObservedObject var model: ParticleEditingModel
    let path: String
    let definition: ParticleDefinition
    @State private var isPickingTexture = false

    var body: some View {
        Section {
            materialRows
            if let component = model.schema.component(.system) {
                let values = ParticleDefinition.conditionValues(definition.root, component: component, pixelUnits: model.pixelUnits)
                ForEach(component.fields.filter { $0.isVisible(in: values) }) { field in
                    ParticleFieldRow(field: field, kind: field.effectiveKind(in: values),
                                     value: ParticleDefinition.shownValue(of: field, in: definition.root, pixelUnits: model.pixelUnits)) { value, coalescing in
                        model.setField(field, to: value, section: .system, index: nil, definition: path,
                                       actionName: PartL("Change \(field.localizedLabel)"), coalescing: coalescing)
                    }
                }
            }
        } header: {
            Text(PartL("General"))
        }
    }

    @ViewBuilder private var materialRows: some View {
        let material = model.material(ofDefinition: path)
        LabeledContent(PartL("Texture")) {
            Button {
                isPickingTexture = true
            } label: {
                HStack(spacing: 6) {
                    ParticleTextureThumbnail(services: services, name: material?.texture, size: 22)
                    Text(material?.texture ?? PartL("None")).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .disabled(material == nil)
            .popover(isPresented: $isPickingTexture, arrowEdge: .leading) {
                ParticleTexturePicker(services: services, selected: material?.texture) { name in
                    model.editMaterial(ofDefinition: path, actionName: PartL("Change Texture")) { $0.texture = name }
                    isPickingTexture = false
                }
            }
        }
        if let material {
            LabeledContent(PartL("Blending")) {
                Picker(selection: Binding(
                    get: { material.string("blending")?.lowercased() ?? "translucent" },
                    set: { value in model.editMaterial(ofDefinition: path, actionName: PartL("Change Blending")) { $0.setString(value, for: "blending") } })) {
                    Text(PartL("Normal")).tag("normal")
                    Text(PartL("Translucent")).tag("translucent")
                    Text(PartL("Additive")).tag("additive")
                    if !ParticleMaterial.blendings.contains(material.string("blending")?.lowercased() ?? "translucent") {
                        Text(verbatim: material.string("blending") ?? "").tag(material.string("blending")?.lowercased() ?? "")
                    }
                } label: { EmptyView() }
                .labelsHidden()
                .fixedSize()
            }
            LabeledContent(PartL("Overbright")) {
                NumericSliderInput<Double>(value: Binding<Double>(
                    get: { material.constant(ParticleMaterial.overbrightKey)?.doubleValue ?? 1 },
                    set: { value in
                        model.editMaterial(ofDefinition: path, actionName: PartL("Change Overbright"),
                                           coalescingKey: "particle-material:\(path):overbright") {
                            $0.setConstant(.number(value), for: ParticleMaterial.overbrightKey)
                        }
                    }), range: 0...5, defaultValue: 1, fractionDigits: 2, fieldWidth: 48, clampsTypedValue: false)
            }
            modePicker(PartL("Depth Test"), key: "depthtest", material: material,
                       options: [("enabled", PartL("Enabled")), ("disabled", PartL("Disabled"))], fallback: "disabled")
            modePicker(PartL("Depth Write"), key: "depthwrite", material: material,
                       options: [("enabled", PartL("Enabled")), ("disabled", PartL("Disabled"))], fallback: "disabled")
            modePicker(PartL("Culling"), key: "cullmode", material: material,
                       options: [("normal", PartL("Normal")), ("nocull", PartL("No Cull"))], fallback: "nocull")
            if let materialPath = definition.materialPath {
                LabeledContent(PartL("Material")) {
                    Text(materialPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        } else if let materialPath = definition.materialPath {
            Label(PartL("The material “\(materialPath)” can’t be read."), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }

    private func modePicker(_ title: String, key: String, material: ParticleMaterial,
                            options: [(String, String)], fallback: String) -> some View {
        LabeledContent(title) {
            Picker(selection: Binding(
                get: { material.string(key)?.lowercased() ?? fallback },
                set: { value in model.editMaterial(ofDefinition: path, actionName: PartL("Change \(title)")) { $0.setString(value, for: key) } })) {
                ForEach(options, id: \.0) { option in Text(option.1).tag(option.0) }
            } label: { EmptyView() }
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// A texture's preview, from the app's TEX reader.
struct ParticleTextureThumbnail: View {
    @ObservedObject var services: ParticleEditorServices
    let name: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let name, let image = services.thumbnail(name) {
                Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.6)))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// The textures a particle material can draw: the wallpaper's own and WE's particle sprites,
/// sprite sheets marked with their frame count.
struct ParticleTexturePicker: View {
    @Environment(\.appAccentColor) private var accentColor
    @ObservedObject var services: ParticleEditorServices
    let selected: String?
    let pick: (String) -> Void
    @State private var search = ""

    var body: some View {
        let matching = services.textures.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        VStack(alignment: .leading, spacing: 8) {
            TextField(PartL("Search Textures"), text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    group(PartL("This Wallpaper"), matching.filter { !$0.isShared })
                    group(PartL("Wallpaper Engine"), matching.filter(\.isShared))
                    if matching.isEmpty {
                        Text(PartL("No textures")).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 340, height: 420)
    }

    @ViewBuilder private func group(_ title: String, _ textures: [ParticleTextureChoice]) -> some View {
        if !textures.isEmpty {
            Text(title).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                ForEach(textures) { texture in
                    Button {
                        pick(texture.name)
                    } label: {
                        VStack(spacing: 3) {
                            ParticleTextureThumbnail(services: services, name: texture.name, size: 56)
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .stroke(texture.name == selected ? accentColor : .clear, lineWidth: 2))
                            Text((texture.name as NSString).lastPathComponent)
                                .font(.caption2).lineLimit(1).truncationMode(.middle)
                            if texture.frames > 1 {
                                Text(PartL("\(texture.frames) frames"))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 72)
                    }
                    .buttonStyle(.plain)
                    .help(texture.frames > 1 ? PartL("\(texture.name): sprite sheet of \(texture.frames) frames") : texture.name)
                }
            }
        }
    }
}
