import SwiftUI
import OWESceneEditing

/// The user-property editor (project.json `general.properties`): the list to add, remove and
/// reorder properties, the selected one's details (label, type, default, slider range, combo
/// options, condition) and a live preview of the panel as the user sees it. Every change is one
/// undo step of the editor window; the properties are written into project.json when the
/// wallpaper is saved as a local wallpaper.
struct UserPropertiesEditorView: View {
    @ObservedObject var authoring: EditorAuthoringModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?

    private var properties: UserPropertyAuthoring { authoring.properties }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("User Properties")).font(.headline)
                Spacer()
                Button(L("Undo")) { authoring.session.undo() }
                    .disabled(!authoring.session.canUndo)
                Button(L("Revert to the Wallpaper’s Properties")) {
                    properties.revertToAuthored(actionName: L("Revert User Properties"))
                }
                .disabled(!properties.isEdited)
                Button(L("Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            HSplitView {
                propertyList
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                detail
                    .frame(minWidth: 340, maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 0) {
                    Text(L("Preview")).font(.subheadline.weight(.semibold)).padding([.horizontal, .top], 12)
                    Text(L("As the user sees the properties: try a value to see the conditions at work."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                    UserPropertiesPreview(properties: properties.properties)
                }
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
            }
        }
        .frame(minWidth: 900, idealWidth: 1040, minHeight: 540, idealHeight: 640)
        .onAppear { selection = selection ?? properties.properties.first?.key }
    }

    // MARK: List

    private var propertyList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(properties.properties) { property in
                    HStack {
                        if UserPropertyGroup.group(of: property.key, in: properties.properties) != nil {
                            Spacer().frame(width: 12)
                        }
                        Image(systemName: property.kind.symbol).foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(PropertyTitle.title(property)).lineLimit(1)
                                .fontWeight(property.kind == .group ? .semibold : nil)
                            Text(property.key).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if property.condition != nil {
                            Spacer()
                            Image(systemName: "eye.trianglebadge.exclamationmark")
                                .foregroundStyle(.secondary)
                                .help(L("Shown only when its condition holds"))
                        }
                    }
                    .tag(property.key)
                }
                .onMove { source, destination in
                    properties.move(fromOffsets: source, toOffset: destination, actionName: L("Move User Property"))
                }
            }
            .onDeleteCommand(perform: removeSelected)
            Divider()
            HStack(spacing: 2) {
                Menu {
                    ForEach(UserPropertyDraft.Kind.authorable, id: \.self) { kind in
                        Button {
                            selection = properties.add(kind, label: kind.newLabel, actionName: L("Add User Property"))
                        } label: {
                            Label(kind.title, systemImage: kind.symbol)
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("Add a property"))
                .accessibilityLabel(L("Add a property"))
                Button(action: removeSelected) {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selection == nil)
                .help(L("Remove the selected property"))
                .accessibilityLabel(L("Remove the selected property"))
                Spacer()
            }
            .padding(6)
        }
    }

    private func removeSelected() {
        guard let selection, let index = properties.properties.firstIndex(where: { $0.key == selection }) else { return }
        properties.remove([selection], actionName: L("Remove User Property"))
        let remaining = properties.properties
        self.selection = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].key
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let key = selection, let property = properties.property(key) {
            UserPropertyDetailForm(authoring: authoring, property: property) { renamed in selection = renamed }
                .id(key)
        } else {
            VStack(spacing: 8) {
                Text(properties.properties.isEmpty ? L("This wallpaper has no user properties.") : L("Select a property."))
                    .foregroundStyle(.secondary)
                Text(L("Add one with + to let users change the wallpaper: bind it to a layer’s field from the inspector."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The selected property's details.
private struct UserPropertyDetailForm: View {
    @ObservedObject var authoring: EditorAuthoringModel
    let property: UserPropertyDraft
    let renamed: (String) -> Void
    @State private var key = ""
    @State private var keyProblem: String?

    private var properties: UserPropertyAuthoring { authoring.properties }

    private func update(_ actionName: String, coalescing: Bool = true, _ change: (inout UserPropertyDraft) -> Void) {
        properties.update(property.key, actionName: actionName, coalescing: coalescing, change)
    }

    var body: some View {
        Form {
            Section {
                TextField(L("Label"), text: Binding(get: { property.text }, set: { text in
                    update(L("Change Label")) { $0.text = text }
                }))
                LabeledContent(L("Key")) {
                    VStack(alignment: .trailing, spacing: 2) {
                        TextField(L("Key"), text: $key)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .onSubmit(commitKey)
                        if let keyProblem {
                            Text(keyProblem).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                Picker(L("Type"), selection: Binding(get: { property.kind }, set: changeKind)) {
                    ForEach(kinds, id: \.self) { kind in
                        Label(kind.title, systemImage: kind.symbol).tag(kind)
                    }
                }
            } footer: {
                bindingsFooter
            }
            if property.kind.hasDefault {
                Section(L("Default")) { defaultControl }
            }
            if property.kind == .slider { sliderSection }
            if property.kind == .combo { comboSection }
            if property.kind == .directory { fetchModeSection }
            if property.kind == .file { fileTypeSection }
            if property.kind == .group { groupSection }
            if property.kind.bindsTexture {
                UserTextureBindingSection(authoring: authoring, property: property)
            }
            ConditionSection(authoring: authoring, property: property)
        }
        .formStyle(.grouped)
        .onAppear { key = property.key }
    }

    private var kinds: [UserPropertyDraft.Kind] {
        UserPropertyDraft.Kind.authorable.contains(property.kind) ? UserPropertyDraft.Kind.authorable
            : UserPropertyDraft.Kind.authorable + [property.kind]
    }

    @ViewBuilder private var bindingsFooter: some View {
        let bound = authoring.session.fields(boundTo: property.key)
        if !bound.isEmpty {
            let fields = bound.map { authoring.title(of: FieldTarget(layer: $0.layer, path: $0.path)) }.joined(separator: ", ")
            Text(L("Bound to: \(fields)"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func commitKey() {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        guard trimmed != property.key else { keyProblem = nil; return }
        if !UserPropertyDraft.isValidKey(trimmed) {
            keyProblem = L("Letters, digits and _ only, not starting with a digit.")
        } else if properties.keys.contains(trimmed) {
            keyProblem = L("Another property has this key.")
        } else if properties.rename(property.key, to: trimmed, actionName: L("Rename User Property")) {
            keyProblem = nil
            renamed(trimmed)
        }
    }

    private func changeKind(_ kind: UserPropertyDraft.Kind) {
        guard kind != property.kind else { return }
        update(L("Change Property Type"), coalescing: false) { draft in
            var changed = UserPropertyDraft.new(kind, key: draft.key, text: draft.text)
            changed.condition = draft.condition
            // WE resets the type's own keys (`mode`, …) when the type changes; the rest stays.
            changed.extra = draft.extra.filter { !["mode", "fileType"].contains($0.key) }
                .merging(changed.extra) { _, new in new }
            draft = changed
        }
    }

    // MARK: Folder, file and group

    private var fetchModeSection: some View {
        Section {
            Picker(L("Fetch Mode"), selection: Binding(get: { property.fetchMode ?? .onDemand }, set: { mode in
                update(L("Change Fetch Mode"), coalescing: false) { $0.fetchMode = mode }
            })) {
                Text(L("On Demand")).tag(UserPropertyDraft.FetchMode.onDemand)
                Text(L("All")).tag(UserPropertyDraft.FetchMode.fetchAll)
            }
        } footer: {
            Text(property.fetchMode == .fetchAll
                 ? L("The page gets every file in the folder, and each change (userDirectoryFilesAddedOrChanged, userDirectoryFilesRemoved).")
                 : L("The page asks for one random file at a time (wallpaperRequestRandomFileForProperty)."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var fileTypeSection: some View {
        Section {
            Picker(L("File Type"), selection: Binding(get: { property.fileType }, set: { type in
                update(L("Change File Type"), coalescing: false) { $0.fileType = type }
            })) {
                Text(L("Any File")).tag(UserPropertyDraft.FileType?.none)
                Text(L("Image")).tag(UserPropertyDraft.FileType?.some(.image))
                Text(L("Video")).tag(UserPropertyDraft.FileType?.some(.video))
            }
        }
    }

    private var groupSection: some View {
        Section {
            Text(L("The properties after this one, up to the next group, fold under its label. Properties that belong to no group go before the first one."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Default

    @ViewBuilder private var defaultControl: some View {
        let text = property.defaultText
        switch property.kind {
        case .bool:
            Toggle(L("On"), isOn: Binding(get: { text == "true" || text == "1" },
                                          set: { on in update(L("Change Default")) { $0.value = .bool(on) } }))
        case .slider:
            let lower = property.minimum ?? 0
            let upper = max(property.maximum ?? 1, lower)
            LabeledContent(L("Value")) {
                HStack {
                    Slider(value: Binding(get: { min(max(Double(text) ?? lower, lower), upper) },
                                          set: { number in update(L("Change Default")) { $0.value = .number(PropertyFormat.rounded(number, $0)) } }),
                           in: lower...max(upper, lower + 0.0001))
                    TextField(L("Value"), value: Binding(get: { Double(text) ?? lower },
                                                         set: { number in update(L("Change Default")) { $0.value = .number(number) } }),
                              format: .number)
                        .labelsHidden()
                        .frame(width: 70)
                }
            }
        case .color:
            ColorPicker(L("Color"), selection: Binding(get: { PropertyColor.color(text) },
                                                       set: { color in update(L("Change Default")) { $0.value = .string(PropertyColor.text(color)) } }),
                        supportsOpacity: false)
        case .combo:
            Picker(L("Option"), selection: Binding(get: { text },
                                                   set: { value in update(L("Change Default")) { $0.value = .string(value) } })) {
                ForEach(property.options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
        default:
            TextField(L("Value"), text: Binding(get: { text },
                                                set: { value in update(L("Change Default")) { $0.value = .string(value) } }))
        }
    }

    // MARK: Slider

    private var sliderSection: some View {
        Section(L("Range")) {
            numberField(L("Minimum"), get: { $0.minimum ?? 0 }) { $0.minimum = $1 }
            numberField(L("Maximum"), get: { $0.maximum ?? 1 }) { $0.maximum = $1 }
            numberField(L("Step"), get: { $0.step ?? 1 }) { $0.step = $1 > 0 ? $1 : nil }
            Stepper(value: Binding(get: { property.decimals },
                                   set: { decimals in update(L("Change Decimals")) { $0.decimals = min(max(decimals, 0), 6) } }),
                    in: 0...6) {
                LabeledContent(L("Decimals"), value: String(property.decimals))
            }
            Toggle(L("Whole Numbers Only"), isOn: Binding(get: { property.fraction == false },
                                                          set: { whole in update(L("Change Slider")) { $0.fraction = whole ? false : nil } }))
        }
    }

    private func numberField(_ title: String, get: @escaping (UserPropertyDraft) -> Double,
                             set: @escaping (inout UserPropertyDraft, Double) -> Void) -> some View {
        TextField(title, value: Binding(get: { get(property) },
                                        set: { number in update(L("Change Slider")) { set(&$0, number) } }),
                  format: .number)
    }

    // MARK: Combo

    private var comboSection: some View {
        Section {
            ForEach(property.options.indices, id: \.self) { index in
                HStack {
                    TextField(L("Label"), text: Binding(get: { property.options[index].label },
                                                        set: { label in updateOption(index) { $0.label = label } }))
                    TextField(L("Value"), text: Binding(get: { property.options[index].value },
                                                        set: { value in updateOption(index) { $0.value = value } }))
                        .frame(maxWidth: 110)
                    Button {
                        update(L("Remove Option"), coalescing: false) { draft in
                            guard draft.options.indices.contains(index) else { return }
                            draft.options.remove(at: index)
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(L("Remove the option"))
                    .accessibilityLabel(L("Remove the option"))
                }
            }
            .onMove { source, destination in
                update(L("Move Option"), coalescing: false) { draft in
                    let moving = source.sorted().map { draft.options[$0] }
                    let before = source.filter { $0 < destination }.count
                    for index in source.sorted(by: >) { draft.options.remove(at: index) }
                    draft.options.insert(contentsOf: moving, at: max(0, min(draft.options.count, destination - before)))
                }
            }
            Button {
                update(L("Add Option"), coalescing: false) { draft in
                    let values = Set(draft.options.map(\.value))
                    var number = draft.options.count + 1
                    while values.contains(String(number)) { number += 1 }
                    draft.options.append(.init(label: L("Option \(number)"), value: String(number)))
                }
            } label: {
                Label(L("Add Option"), systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } header: {
            Text(L("Options"))
        } footer: {
            Text(L("A label can be a localisation key. Conditions and bindings compare the value."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func updateOption(_ index: Int, _ change: (inout UserPropertyDraft.Option) -> Void) {
        update(L("Change Option")) { draft in
            guard draft.options.indices.contains(index) else { return }
            change(&draft.options[index])
        }
    }
}

/// "Show only when…": a property's condition as a rule (property, comparison, value), or as a
/// JavaScript expression for anything a rule can't say.
private struct ConditionSection: View {
    @ObservedObject var authoring: EditorAuthoringModel
    let property: UserPropertyDraft
    @State private var asExpression = false

    private var others: [UserPropertyDraft] {
        authoring.properties.properties.filter { $0.key != property.key && $0.kind.hasValue }
    }

    private func setCondition(_ condition: String?) {
        authoring.properties.update(property.key, actionName: L("Change Condition")) { $0.condition = condition }
    }

    var body: some View {
        Section {
            Toggle(L("Show Only When…"), isOn: Binding(get: { property.condition != nil }, set: { on in
                if on {
                    let first = others.first
                    let rule = UserPropertyConditionRule(key: first?.key ?? "property",
                                                         value: first.map(Self.sampleValue) ?? "true")
                    setCondition(rule.condition)
                } else {
                    setCondition(nil)
                }
            }))
            if let condition = property.condition {
                if !asExpression, let rule = UserPropertyConditionRule(condition) {
                    ruleEditor(rule)
                } else {
                    TextField(L("Expression"), text: Binding(get: { condition }, set: { setCondition($0) }),
                              axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                    if !UserPropertyConditionExpression(condition).isUnderstood {
                        Label(L("The preview can’t evaluate this expression and always shows the property."),
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(L("Edit as Expression"), isOn: $asExpression)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
        } header: {
            Text(L("Condition"))
        }
        .onAppear { asExpression = property.condition.map { UserPropertyConditionRule($0) == nil } ?? false }
    }

    @ViewBuilder private func ruleEditor(_ rule: UserPropertyConditionRule) -> some View {
        let referenced = authoring.properties.property(rule.key)
        Picker(L("Property"), selection: Binding(get: { rule.key }, set: { key in
            var changed = rule
            changed.key = key
            changed.value = authoring.properties.property(key).map(Self.sampleValue) ?? rule.value
            setCondition(changed.condition)
        })) {
            ForEach(others) { other in
                Text(PropertyTitle.title(other)).tag(other.key)
            }
            if referenced == nil {
                Text(rule.key).tag(rule.key)
            }
        }
        Picker(L("Comparison"), selection: Binding(get: { rule.comparison }, set: { comparison in
            var changed = rule
            changed.comparison = comparison
            setCondition(changed.condition)
        })) {
            ForEach(UserPropertyConditionRule.Comparison.allCases, id: \.self) { comparison in
                Text(comparison.title).tag(comparison)
            }
        }
        let setValue: (String) -> Void = { value in
            var changed = rule
            changed.value = value
            setCondition(changed.condition)
        }
        if referenced?.kind == .bool {
            Picker(L("Value"), selection: Binding(get: { rule.value == "1" ? "true" : rule.value == "0" ? "false" : rule.value },
                                                  set: setValue)) {
                Text(L("On")).tag("true")
                Text(L("Off")).tag("false")
            }
        } else if referenced?.kind == .combo {
            Picker(L("Value"), selection: Binding(get: { rule.value }, set: setValue)) {
                ForEach(referenced?.options ?? [], id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
                if referenced?.options.contains(where: { $0.value == rule.value }) == false {
                    Text(rule.value).tag(rule.value)
                }
            }
        } else {
            TextField(L("Value"), text: Binding(get: { rule.value }, set: setValue))
        }
    }

    static func sampleValue(_ property: UserPropertyDraft) -> String {
        switch property.kind {
        case .bool: return "true"
        case .combo: return property.options.first?.value ?? ""
        default: return property.defaultText
        }
    }
}

extension UserPropertyConditionRule.Comparison {
    var title: String {
        switch self {
        case .equal: return L("is")
        case .notEqual: return L("is not")
        case .less: return L("is less than")
        case .lessOrEqual: return L("is at most")
        case .greater: return L("is greater than")
        case .greaterOrEqual: return L("is at least")
        }
    }
}

extension UserPropertyDraft.Kind {
    var title: String {
        switch self {
        case .bool: return L("Checkbox")
        case .slider: return L("Slider")
        case .color: return L("Color")
        case .combo: return L("Combo")
        case .textInput: return L("Text Input")
        case .file: return L("File")
        case .directory: return L("Folder")
        case .sceneTexture: return L("Texture")
        case .userShortcut: return L("User Shortcut")
        case .group: return L("Group")
        case .text: return L("Label")
        default: return rawValue
        }
    }

    /// The label a new property of the kind starts with.
    var newLabel: String {
        switch self {
        case .text: return L("Notice")
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .bool: return "checkmark.square"
        case .slider: return "slider.horizontal.3"
        case .color: return "paintpalette"
        case .combo: return "list.bullet"
        case .textInput: return "character.cursor.ibeam"
        case .file: return "doc"
        case .directory: return "folder"
        case .sceneTexture: return "photo"
        case .userShortcut: return "arrow.up.forward.app"
        case .group: return "rectangle.3.group"
        case .text: return "text.alignleft"
        default: return "questionmark.square"
        }
    }
}

/// A property's label as text: HTML tags dropped, an empty one shown as its key.
enum PropertyTitle {
    static func title(_ property: UserPropertyDraft) -> String {
        let plain = plainText(property.text)
        return plain.isEmpty ? property.key : plain
    }

    static func plainText(_ html: String) -> String {
        guard html.contains("<") else { return html.trimmingCharacters(in: .whitespacesAndNewlines) }
        var text = html.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\"")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum PropertyFormat {
    /// A slider value as the property shows it: whole without `fraction`, else to its decimals.
    static func rounded(_ number: Double, _ property: UserPropertyDraft) -> Double {
        if property.fraction == false { return number.rounded() }
        let scale = pow(10, Double(property.decimals))
        return (number * scale).rounded() / scale
    }
}
