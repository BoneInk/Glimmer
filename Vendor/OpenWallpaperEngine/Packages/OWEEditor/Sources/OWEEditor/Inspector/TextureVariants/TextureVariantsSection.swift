import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OWEInspectorKit
import OWESceneEditing

/// The texture variants' text, from their own table (`Resources/TextureVariants.xcstrings`), in
/// every language the app ships; WE's own wording (`ui_editor_properties_*variant*`) where it has one.
let TVL = EditorText(table: "TextureVariants")

/// WE's Texture Properties › Variants for an image layer's texture (WE 2.6; `scripts.js`
/// `textureAddVariant`, the `texturevariant` row): Add Variant Group, and per group its options,
/// each with its picture, Rename Option / Replace Texture / Remove Option, the order (the first
/// option whose condition holds wins), Replace or Alpha blended (RGBA8888 textures only,
/// `variantallowcomplexblend`) and its Condition (a bool or combo user property, warned while
/// unset). Every change writes the texture again (`SceneEditSession.applyTextureVariants`), one
/// undo step, and the canvas shows it; Preview switches the bound properties on the canvas.
struct TextureVariantsSection: View {
    @ObservedObject var session: SceneEditSession
    let services: WallpaperEditorServices
    let layer: SceneLayer

    @StateObject private var cache = TextureVariantCache()
    @State private var naming: Naming?
    @State private var nameText = ""
    @State private var conditionTarget: ConditionTarget?
    @State private var problem: Problem?
    /// Moves when Preview changed a value, which the pickers read again.
    @State private var previewRevision = 0

    enum Naming: Equatable {
        case newGroup
        case option(group: UUID, option: UUID)
    }

    struct ConditionTarget: Identifiable {
        var group: UUID
        var option: UUID
        var id: UUID { option }
    }

    struct Problem: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    private var imageKey: String { "\(layer.id):\(session.value("image", of: layer.id)?.stringValue ?? "")" }

    /// The layer's variants, read again only when its `image` changes (the texture can be large).
    private var state: TextureVariantState? {
        cache.state(for: imageKey) { session.textureVariants(of: layer.id, store: services.assetStore, readFile: services.readFile) }
    }

    var body: some View {
        Group {
            if let state, let store = services.assetStore, store.encoder != nil {
                Section {
                    content(state)
                } header: {
                    Text(TVL("Variants"))
                } footer: {
                    Text(TVL("Each group shows at most one of its options over the texture. Options must have the texture’s size and kind."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .alert(naming == .newGroup ? TVL("Add Texture Variant") : TVL("Rename Variant Option"),
               isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField(TVL("Name"), text: $nameText)
            Button(TVL("Cancel"), role: .cancel) { naming = nil }
            Button(TVL("OK")) { finishNaming() }
        } message: {
            if naming == .newGroup { Text(TVL("Enter variant name:")) }
        }
        .alert(item: $problem) { problem in
            Alert(title: Text(problem.title), message: Text(problem.message))
        }
        .sheet(item: $conditionTarget) { target in
            if let state, let group = state.document.groups.first(where: { $0.id == target.group }),
               let option = group.options.first(where: { $0.id == target.option }) {
                TextureVariantConditionSheet(group: group, option: option, properties: properties,
                                             title: { services.userPropertyTitle($0, properties: properties) }) { result in
                    applyCondition(result, target: target)
                }
            }
        }
    }

    @ViewBuilder private func content(_ state: TextureVariantState) -> some View {
        if !state.isImported {
            Text(TVL("Only textures imported with the editor can have variants."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(state.document.groups) { group in
                groupRows(group, state: state)
            }
            Button {
                nameText = TVL("Variant")
                naming = .newGroup
            } label: {
                Label(TVL("Add Variant Group"), systemImage: "plus")
            }
        }
    }

    @ViewBuilder private func groupRows(_ group: TextureVariantDocument.Group, state: TextureVariantState) -> some View {
        HStack {
            Text(group.name).fontWeight(.semibold).lineLimit(1)
            Spacer()
            Button {
                addOption(to: group.id)
            } label: {
                Label(TVL("Add Option"), systemImage: "plus")
            }
            .buttonStyle(.borderless)
            Menu {
                Button(TVL("Remove Variant"), role: .destructive) {
                    change(TVL("Remove Variant")) { $0.groups.removeAll { $0.id == group.id } }
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(TVL("Variants"))
        }
        ForEach(Array(group.options.enumerated()), id: \.element.id) { index, option in
            optionRow(option, index: index, group: group, state: state)
        }
        if services.userPropertyValues != nil, !group.options.isEmpty {
            previewPicker(group)
        }
    }

    @ViewBuilder private func optionRow(_ option: TextureVariantDocument.Option, index: Int,
                                        group: TextureVariantDocument.Group, state: TextureVariantState) -> some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail(option)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(option.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button {
                        move(option.id, in: group.id, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                    .accessibilityLabel(TVL("Move Up"))
                    Button {
                        move(option.id, in: group.id, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == group.options.count - 1)
                    .accessibilityLabel(TVL("Move Down"))
                    Menu {
                        Button(TVL("Rename Option")) {
                            nameText = option.name
                            naming = .option(group: group.id, option: option.id)
                        }
                        Button(TVL("Replace Texture")) { replaceTexture(of: option.id, in: group.id) }
                        Divider()
                        Button(TVL("Remove Option"), role: .destructive) {
                            change(TVL("Remove Option")) { document in
                                Self.update(&document, group: group.id) { $0.options.removeAll { $0.id == option.id } }
                            }
                        }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel(option.name)
                }
                if state.base?.allowsAlphaBlend ?? false {
                    Picker(TVL("Blend"), selection: Binding(get: { option.blend }, set: { blend in
                        change(TVL("Change Blend")) { document in
                            Self.update(&document, group: group.id, option: option.id) { $0.blend = blend }
                        }
                    })) {
                        Text(TVL("Replace")).tag(TextureVariantDocument.Blend.replace)
                        Text(TVL("Alpha blended")).tag(TextureVariantDocument.Blend.alphaBlend)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Button {
                    conditionTarget = ConditionTarget(group: group.id, option: option.id)
                } label: {
                    Label(conditionTitle(option.condition), systemImage: option.condition == nil ? "exclamationmark.triangle" : "gearshape")
                        .lineLimit(1)
                }
                .tint(option.condition == nil ? .orange : nil)
                .help(option.condition == nil ? TVL("No condition: the option never shows.")
                                              : TVL("The option shows while its condition holds; in a group the first option whose condition holds wins."))
            }
        }
    }

    @ViewBuilder private func thumbnail(_ option: TextureVariantDocument.Option) -> some View {
        let isVideo = EditorAssetStore.videoTypes.contains((option.file as NSString).pathExtension.lowercased())
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            if !isVideo, let image = services.texture(Self.textureName(of: option.file)) {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: isVideo ? "film" : "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 48)
    }

    // MARK: Preview

    private func previewPicker(_ group: TextureVariantDocument.Group) -> some View {
        let _ = previewRevision
        return Picker(TVL("Preview"), selection: Binding(get: { previewedOption(group) }, set: { preview($0, in: group) })) {
            Text(TVL("None")).tag(UUID?.none)
            ForEach(group.options.filter { $0.condition != nil }) { option in
                Text(option.name).tag(UUID?.some(option.id))
            }
        }
    }

    /// The option the canvas shows for the group: the first whose condition holds.
    private func previewedOption(_ group: TextureVariantDocument.Group) -> UUID? {
        group.options.first { option in option.condition.map(holds) ?? false }?.id
    }

    private func currentValue(_ key: String) -> String? {
        services.userPropertyValues?.value(key) ?? properties.first { $0.key == key }?.defaultText
    }

    private func holds(_ condition: TextureVariantDocument.Condition) -> Bool {
        switch condition {
        case .flag(let key):
            let value = currentValue(key)?.lowercased()
            return value == "true" || value == "1"
        case .equals(let key, let expected):
            return currentValue(key) == expected
        }
    }

    /// Sets the bound properties so the canvas shows `optionID` (none: the base): its condition
    /// made to hold, and those of the options before it (all, for none) not to.
    private func preview(_ optionID: UUID?, in group: TextureVariantDocument.Group) {
        guard let values = services.userPropertyValues else { return }
        options: for option in group.options {
            guard let condition = option.condition else { continue }
            if option.id == optionID {
                switch condition {
                case .flag(let key): values.set(key, "true")
                case .equals(let key, let value): values.set(key, value)
                }
                break options
            }
            switch condition {
            case .flag(let key):
                values.set(key, "false")
            case .equals(let key, _):
                // A value of the combo no option of the group shows for.
                let used = Set(group.options.compactMap { other -> String? in
                    if case .equals(key, let value)? = other.condition { return value }
                    return nil
                })
                if holds(condition),
                   let free = properties.first(where: { $0.key == key })?.options.first(where: { !used.contains($0.value) }) {
                    values.set(key, free.value)
                }
            }
        }
        previewRevision += 1
    }

    private var properties: [UserPropertyDraft] { authoring.properties.properties }

    // MARK: Changing

    private func reload() { cache.invalidate() }

    /// Changes the document and writes it; one undo step named `actionName`. Returns whether it did.
    @discardableResult
    private func change(_ actionName: String, _ edit: (inout TextureVariantDocument) -> Void) -> Bool {
        guard var document = state?.document, let store = services.assetStore else { return false }
        edit(&document)
        do {
            try session.applyTextureVariants(document, to: layer.id, store: store, readFile: services.readFile, actionName: actionName)
            reload()
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func report(_ error: Error) {
        if case TextureVariantError.incompatible = error {
            problem = Problem(title: TVL("Incompatible Variant Option"),
                              message: TVL("The image or video you selected is not compatible with this texture. It must have the same resolution and needs to be the same type, you cannot mix images and videos in a texture."))
        } else {
            problem = Problem(title: TVL("Variants"), message: TVL("The variants couldn’t be saved: \(error.localizedDescription)"))
        }
    }

    private func finishNaming() {
        let name = nameText.trimmingCharacters(in: .whitespaces)
        defer { naming = nil }
        guard !name.isEmpty, let naming else { return }
        switch naming {
        case .newGroup:
            change(TVL("Add Variant Group")) { $0.groups.append(TextureVariantDocument.Group(name: name)) }
        case .option(let group, let option):
            change(TVL("Rename Option")) { document in
                Self.update(&document, group: group, option: option) { $0.name = name }
            }
        }
    }

    private func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let types = (state?.base?.isVideo ?? false) ? EditorAssetStore.videoTypes : EditorAssetStore.variantImageTypes
        panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func importFile(_ url: URL) -> String? {
        guard let store = services.assetStore else { return nil }
        do {
            return try store.importVariantFile(from: url)
        } catch {
            report(error)
            return nil
        }
    }

    private func addOption(to group: UUID) {
        guard let url = chooseFile(), let file = importFile(url) else { return }
        let name = url.deletingPathExtension().lastPathComponent
        change(TVL("Add Option")) { document in
            Self.update(&document, group: group) { $0.options.append(TextureVariantDocument.Option(name: name, file: file)) }
        }
    }

    private func replaceTexture(of option: UUID, in group: UUID) {
        guard let url = chooseFile(), let file = importFile(url) else { return }
        change(TVL("Replace Texture")) { document in
            Self.update(&document, group: group, option: option) { $0.file = file }
        }
    }

    private func move(_ option: UUID, in group: UUID, by offset: Int) {
        change(TVL("Move Option")) { document in
            Self.update(&document, group: group) { group in
                guard let index = group.options.firstIndex(where: { $0.id == option }),
                      group.options.indices.contains(index + offset) else { return }
                group.options.swapAt(index, index + offset)
            }
        }
    }

    private func applyCondition(_ result: TextureVariantConditionSheet.Result, target: ConditionTarget) {
        guard var document = state?.document, let store = services.assetStore else { return }
        let actionName = TVL("Change Condition")
        switch result {
        case .condition(let condition):
            change(actionName) { document in
                Self.update(&document, group: target.group, option: target.option) { $0.condition = condition }
            }
        case .newProperty(var draft, let conditions):
            let propertyAuthoring = authoring.properties
            draft.key = UserPropertyDraft.key(from: draft.key, taken: propertyAuthoring.keys)
            let key = draft.key
            Self.update(&document, group: target.group) { group in
                for index in group.options.indices {
                    if let condition = conditions[group.options[index].id] { group.options[index].condition = condition.rekeyed(key) }
                }
            }
            do {
                let model = try session.preparedTextureVariants(document, for: layer.id, store: store, readFile: services.readFile)
                propertyAuthoring.add(draft, actionName: actionName) { overlay in
                    if let model { overlay.setField("image", to: .string(model), of: layer.id) }
                }
                reload()
            } catch {
                report(error)
            }
        }
    }

    @EnvironmentObject private var authoring: EditorAuthoringModel

    // MARK: Helpers

    private func conditionTitle(_ condition: TextureVariantDocument.Condition?) -> String {
        guard let condition else { return TVL("Condition") }
        let title = services.userPropertyTitle(condition.property, properties: session.overlay.authoring?.properties)
        switch condition {
        case .flag: return title
        case .equals(_, let value):
            let label = properties.first { $0.key == condition.property }?.options.first { $0.value == value }?.label ?? value
            return "\(title) = \(label)"
        }
    }

    /// The texture name of a file in `materials/` (`materials/editor/variants/a.png` → `editor/variants/a`).
    static func textureName(of file: String) -> String {
        var name = (file as NSString).deletingPathExtension
        if name.hasPrefix("materials/") { name.removeFirst("materials/".count) }
        return name
    }

    static func update(_ document: inout TextureVariantDocument, group: UUID, _ change: (inout TextureVariantDocument.Group) -> Void) {
        guard let index = document.groups.firstIndex(where: { $0.id == group }) else { return }
        change(&document.groups[index])
    }

    static func update(_ document: inout TextureVariantDocument, group: UUID, option: UUID,
                       _ change: (inout TextureVariantDocument.Option) -> Void) {
        update(&document, group: group) { group in
            guard let index = group.options.firstIndex(where: { $0.id == option }) else { return }
            change(&group.options[index])
        }
    }
}

extension TextureVariantDocument.Condition {
    /// The condition naming `key` instead (a property made for it, whose key is only known then).
    func rekeyed(_ key: String) -> Self {
        switch self {
        case .flag: return .flag(key)
        case .equals(_, let value): return .equals(key, value)
        }
    }
}

/// The last variants read, by the layer's `image`; filled while the view draws, so it publishes
/// only when emptied.
@MainActor
final class TextureVariantCache: ObservableObject {
    private var key: String?
    private var cached: TextureVariantState?

    func state(for key: String, _ read: () -> TextureVariantState?) -> TextureVariantState? {
        if key != self.key {
            self.key = key
            cached = read()
        }
        return cached
    }

    func invalidate() {
        key = nil
        objectWillChange.send()
    }
}
