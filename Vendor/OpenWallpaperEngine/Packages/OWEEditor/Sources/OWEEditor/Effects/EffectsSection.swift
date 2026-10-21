import AppKit
import SwiftUI
import OWEInspectorKit
import OWESceneEditing

/// The inspector's Effects: the layer's effects in the order they apply, each with its on/off
/// switch, its parameters (the effect's own constants, combos and textures, with WE's control
/// for each), its menu (move, remove) and help; Add Effect opens the catalog.
struct EffectsSection: View {
    @ObservedObject var session: SceneEditSession
    @ObservedObject var tools: EditorTools
    let services: WallpaperEditorServices
    let layer: SceneLayer
    @State private var isBrowsing = false

    var body: some View {
        Section {
            if layer.effects.isEmpty {
                Text(L("No effects")).foregroundStyle(.secondary)
            }
            ForEach(Array(layer.effects.enumerated()), id: \.element.key) { position, effect in
                // An open effect shows its gizmos on the canvas (`EffectGizmoCanvas`).
                DisclosureGroup(isExpanded: Binding(
                    get: { tools.isExpanded(effect.key, of: layer.id) },
                    set: { tools.setExpanded($0, effect.key, of: layer.id) })) {
                    EffectParametersView(session: session, tools: tools, services: services, layer: layer, effect: effect)
                    CustomEffectSection(session: session, layer: layer, effect: effect)
                } label: {
                    header(effect, position: position)
                }
            }
            Button {
                isBrowsing = true
            } label: {
                Label(L("Add Effect…"), systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
        } header: {
            Text(L("Effects"))
        }
        .sheet(isPresented: $isBrowsing) {
            EffectBrowserView(entries: services.effectCatalog(), previews: services.previews,
                              hasWEAssets: services.hasWEAssets(), openAssetsSetup: services.openAssetsSetup,
                              custom: CustomEffectActions(session: session, read: services.readFile)) { entry in
                do {
                    try services.prepareEffect(entry)
                } catch {
                    let title = entry.title
                    tools.problem = L("“\(title)” couldn’t be added: \(error.localizedDescription)")
                    return
                }
                if let key = session.addEffect(entry, to: layer.id, actionName: L("Add Effect")) { tools.setExpanded(true, key, of: layer.id) }
            }
        }
    }

    @ViewBuilder private func header(_ effect: SceneLayerEffect, position: Int) -> some View {
        let bound: String? = {
            if case .userProperty(let name) = SceneFieldBinding(session.baseEffect(effect.key, of: layer.id)?.visible ?? effect.visible) {
                return name
            }
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
                Text(effect.title).lineLimit(1)
            }
            .toggleStyle(.checkbox)
            .disabled(bound != nil)
            .help(bound.map { key in
                let name = services.userPropertyTitle(key, properties: session.overlay.authoring?.properties)
                return L("Set by the user property “\(name)”")
            } ?? "")
            Spacer(minLength: 4)
            InfoTip(services.effectHelp(effect.folderName))
            Menu {
                EffectClipboardItems(actions: LayerActions(session: session, services: services, tools: tools), layer: layer, effect: effect)
                Divider()
                Button(L("Move Up")) { move(position, by: -1) }
                    .disabled(position == 0)
                Button(L("Move Down")) { move(position, by: 1) }
                    .disabled(position >= layer.effects.count - 1)
                Divider()
                Button(L("Remove Effect"), role: .destructive) {
                    session.removeEffect(effect.key, of: layer.id, actionName: L("Remove Effect"))
                }
            } label: {
                Label(L("Effect Actions"), systemImage: "ellipsis.circle").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        // Scripts and bindings name an effect by its authored index (they apply before effects are
        // added or reordered).
        .fieldAuthoring(layer: layer.id, path: .effect(Int(effect.key) ?? effect.id))
    }

    /// Up is earlier (applied first), as the list reads top to bottom.
    private func move(_ position: Int, by step: Int) {
        let target = position + step
        guard layer.effects.indices.contains(target) else { return }
        session.moveEffects(of: layer.id, from: IndexSet(integer: position), to: step > 0 ? target + 1 : target,
                            actionName: L("Reorder Effects"))
    }
}

/// One effect's parameters, with WE's control per type: sliders (number field beside), checkboxes
/// for on/off integers, colour wells, a slider per vector component (linked ones as one), pickers
/// for combos, and texture slots (masks painted or imported). A parameter can be bound to a user
/// property, which then sets it.
struct EffectParametersView: View {
    @ObservedObject var session: SceneEditSession
    @ObservedObject var tools: EditorTools
    let services: WallpaperEditorServices
    let layer: SceneLayer
    let effect: SceneLayerEffect
    @State private var schema: EffectSchema?
    @State private var unlinked: Set<String> = []
    /// The wallpaper's textures a slot can take, read once.
    @State private var wallpaperTextures: [String] = []

    var body: some View {
        Group {
            if let schema {
                if schema.parameters.isEmpty && schema.combos.isEmpty && schema.textures.isEmpty {
                    Text(L("This effect has no settings.")).foregroundStyle(.secondary)
                }
                ForEach(visibleCombos(schema)) { combo in comboRow(combo) }
                ForEach(schema.parameters) { parameter in parameterRow(parameter) }
                ForEach(schema.textures) { slot in textureRow(slot) }
            } else {
                Text(L("This effect’s settings can’t be read.")).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            schema = services.effectSchema(effect.file)
            if schema?.textures.isEmpty == false {
                wallpaperTextures = services.wallpaperAssets().compactMap(\.textureName)
            }
        }
        // A shader edited in the shader editor declares its controls anew.
        .onChange(of: session.overlay.effectFiles) { _, _ in schema = services.effectSchema(effect.file) }
    }

    // MARK: Combos

    private func visibleCombos(_ schema: EffectSchema) -> [EffectSchema.Combo] {
        schema.combos.filter { combo in
            EffectSchema.requirementsHold(combo) { name in
                let declared = schema.combos.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                return session.effectCombo(name, effect: effect.key, of: layer.id, default: declared?.defaultValue ?? 0)
            }
        }
    }

    @ViewBuilder private func comboRow(_ combo: EffectSchema.Combo) -> some View {
        let binding = Binding<Int>(
            get: { session.effectCombo(combo.name, effect: effect.key, of: layer.id, default: combo.defaultValue) },
            set: { session.setEffectCombo(combo.name, to: $0, effect: effect.key, of: layer.id, defaultValue: combo.defaultValue,
                                          actionName: L("Change Effect Option")) })
        if combo.options.isEmpty {
            Toggle(combo.title, isOn: Binding(get: { binding.wrappedValue != 0 }, set: { binding.wrappedValue = $0 ? 1 : 0 }))
                .toggleStyle(.checkbox)
        } else {
            LabeledContent(combo.title) {
                InspectorOptionPicker(options: combo.options.map { InspectorOption(title: $0.title, value: $0.value, group: $0.group) },
                                      selection: binding) { EmptyView() }
                    .labelsHidden()
            }
        }
    }

    // MARK: Constants

    @ViewBuilder private func parameterRow(_ parameter: EffectSchema.Parameter) -> some View {
        if let property = session.effectBinding(parameter.key, effect: effect.key, of: layer.id) {
            let name = propertyTitle(property)
            LabeledContent(parameter.title) {
                HStack(spacing: 4) {
                    Text(L("Set by the user property “\(name)”"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                    bindMenu(parameter, bound: property)
                }
            }
        } else {
            LabeledContent {
                HStack(spacing: 4) {
                    control(parameter)
                    bindMenu(parameter, bound: nil)
                }
            } label: {
                Text(parameter.title)
                    .help(session.isEffectConstantDriven(parameter.key, effect: effect.key, of: layer.id)
                          ? L("A script or animation changes this value; the edit sets where it starts.") : "")
            }
        }
    }

    @ViewBuilder private func control(_ parameter: EffectSchema.Parameter) -> some View {
        switch parameter.control {
        case .toggle:
            Toggle(isOn: Binding(
                get: { components(parameter)[0] != 0 },
                set: { set(parameter, [$0 ? 1 : 0], coalescing: false) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
        case .slider:
            slider(parameter, component: 0)
        case .position:
            EffectPositionField(value: Binding(get: { components(parameter) }, set: { set(parameter, $0, coalescing: true) }),
                                defaultValue: parameter.defaultValue)
        case .direction:
            EffectDirectionDial(radians: Binding(get: { components(parameter)[safe: 0] ?? 0 }, set: { set(parameter, [$0], coalescing: true) }),
                                defaultValue: parameter.defaultValue[safe: 0] ?? 0, showsDegrees: parameter.showsDegrees)
        case .color:
            ColorPicker(selection: Binding(
                get: {
                    let rgb = components(parameter) + [1, 1, 1]
                    return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
                },
                set: { color in
                    let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .white
                    var values = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(Double.init)
                    if parameter.defaultValue.count == 4 { values.append(components(parameter)[safe: 3] ?? 1) }
                    set(parameter, values, coalescing: true)
                }), supportsOpacity: false) { EmptyView() }
                .labelsHidden()
        case .vector(let count):
            let linked = parameter.isLinked && count == 2 && !unlinked.contains(parameter.key)
                && components(parameter)[0] == components(parameter)[1]
            VStack(alignment: .trailing, spacing: 4) {
                if linked {
                    slider(parameter, component: 0, linked: true)
                } else {
                    ForEach(0..<count, id: \.self) { component in
                        HStack(spacing: 4) {
                            Text(verbatim: ["X", "Y", "Z", "W"][min(component, 3)]).foregroundStyle(.secondary)
                            slider(parameter, component: component)
                        }
                    }
                }
                if parameter.isLinked && count == 2 {
                    Toggle(isOn: Binding(
                        get: { linked },
                        set: { link in
                            if link {
                                unlinked.remove(parameter.key)
                                let x = components(parameter)[0]
                                set(parameter, [x, x], coalescing: false)
                            } else {
                                unlinked.insert(parameter.key)
                            }
                        })) {
                        Label(L("Link"), systemImage: "link")
                    }
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }
            }
        }
    }

    private func slider(_ parameter: EffectSchema.Parameter, component: Int, linked: Bool = false) -> some View {
        let low = min(parameter.minimum, parameter.maximum), high = max(parameter.minimum, parameter.maximum)
        return NumericSliderInput<Double>(value: Binding<Double>(
            get: { components(parameter)[safe: component] ?? 0 },
            set: { value in
                var values = components(parameter)
                if linked {
                    values = values.map { _ in value }
                } else if values.indices.contains(component) {
                    values[component] = value
                }
                set(parameter, values, coalescing: true)
            }), range: low...(high > low ? high : low + 1), defaultValue: parameter.defaultValue[safe: component] ?? 0,
            step: parameter.isInteger ? 1 : nil, fractionDigits: parameter.isInteger ? 0 : 2, fieldWidth: 52,
            clampsTypedValue: false)
    }

    private func components(_ parameter: EffectSchema.Parameter) -> [Double] {
        session.effectConstantComponents(parameter.key, effect: effect.key, of: layer.id, default: parameter.defaultValue)
    }

    /// Writes the constant as WE does: a number, or a vector's space-separated components.
    private func set(_ parameter: EffectSchema.Parameter, _ values: [Double], coalescing: Bool) {
        let rounded = parameter.isInteger ? values.map { $0.rounded() } : values
        let value: SceneJSONValue = rounded.count == 1 ? .number(rounded[0]) : SceneVector.value(rounded)
        let fallback: SceneJSONValue = parameter.defaultValue.count == 1
            ? .number(parameter.defaultValue[0]) : SceneVector.value(parameter.defaultValue)
        session.setEffectConstant(parameter.key, to: value, effect: effect.key, of: layer.id, defaultValue: fallback,
                                  actionName: L("Change \(parameter.title)"), coalescing: coalescing)
    }

    // MARK: Binding

    private func bindMenu(_ parameter: EffectSchema.Parameter, bound: String?) -> some View {
        let choices = services.userPropertyChoices()
        return Menu {
            if let bound {
                let name = propertyTitle(bound)
                Button(L("Stop Following “\(name)”")) {
                    session.bindEffectConstant(parameter.key, to: nil, effect: effect.key, of: layer.id,
                                               actionName: L("Unbind Property"))
                }
                Divider()
            }
            if choices.isEmpty {
                Text(L("The wallpaper has no user properties."))
            }
            ForEach(choices) { choice in
                Button(choice.title) {
                    session.bindEffectConstant(parameter.key, to: choice.key, effect: effect.key, of: layer.id,
                                               actionName: L("Bind to User Property"))
                }
                .disabled(choice.key == bound)
            }
        } label: {
            Label(L("Bind to User Property"), systemImage: bound == nil ? "link.badge.plus" : "link")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Bind to User Property"))
    }

    private func propertyTitle(_ key: String) -> String {
        services.userPropertyTitle(key, properties: session.overlay.authoring?.properties)
    }

    // MARK: Textures

    @ViewBuilder private func textureRow(_ slot: EffectSchema.TextureSlot) -> some View {
        let current = session.effectTexture(slot.slot, pass: slot.pass, effect: effect.key, of: layer.id)
        LabeledContent(slot.title) {
            HStack(spacing: 6) {
                TextureThumbnail(path: current, services: services)
                Menu {
                    if slot.isMask {
                        Button(L("Paint Mask…")) { startPainting(slot, existing: current) }
                            .disabled(services.assetStore == nil || session.geometry(of: layer.id) == nil)
                    }
                    Button(L("Import Image…")) { importTexture(slot) }
                        .disabled(services.assetStore == nil)
                    if !wallpaperTextures.isEmpty {
                        Menu(L("Wallpaper Texture")) {
                            ForEach(wallpaperTextures, id: \.self) { name in
                                Button(name) { setTexture(slot, name) }
                            }
                        }
                    }
                    Divider()
                    Button(slot.isMask ? L("Clear Mask") : L("Use Default")) { setTexture(slot, nil) }
                        .disabled(current == nil)
                } label: {
                    Text(current.map { ($0 as NSString).lastPathComponent } ?? (slot.isMask ? L("No Mask") : L("Default")))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .fixedSize()
            }
        }
    }

    private func setTexture(_ slot: EffectSchema.TextureSlot, _ path: String?) {
        session.setEffectTexture(path, slot: slot.slot, pass: slot.pass, effect: effect.key, of: layer.id, combo: slot.combo,
                                 actionName: slot.isMask ? L("Change Mask") : L("Change Texture"))
    }

    private func importTexture(_ slot: EffectSchema.TextureSlot) {
        guard let store = services.assetStore, let url = EditorFilePicker.choose(.mask).first else { return }
        do {
            setTexture(slot, try store.importMask(from: url))
        } catch {
            tools.problem = L("“\(url.lastPathComponent)” couldn’t be added: \(error.localizedDescription)")
        }
    }

    private func startPainting(_ slot: EffectSchema.TextureSlot, existing: String?) {
        guard let geometry = session.geometry(of: layer.id) else { return }
        tools.maskPainting = MaskPainting(layer: layer.id, effectKey: effect.key, effectTitle: effect.title, slot: slot,
                                          layerSize: geometry.size, existing: existing.flatMap(services.texture))
    }
}

/// A texture's picture, small.
struct TextureThumbnail: View {
    let path: String?
    let services: WallpaperEditorServices
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .frame(width: 22, height: 22)
        .task(id: path) { image = path.flatMap(services.texture) }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
