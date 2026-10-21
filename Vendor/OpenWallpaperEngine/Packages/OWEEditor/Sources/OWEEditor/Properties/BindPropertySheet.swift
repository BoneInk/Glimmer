import SwiftUI
import OWESceneEditing

/// Bind to User Property…: pick one of the wallpaper's properties for a field, or create one,
/// as WE's editor binds a property from its inspector. A flag (a layer's or an effect's
/// visibility) can also follow a combo: on while the combo has one value.
struct BindPropertySheet: View {
    @ObservedObject var authoring: EditorAuthoringModel
    let target: FieldTarget
    @Environment(\.dismiss) private var dismiss
    @State private var choice = Choice.existing
    @State private var selectedKey = ""
    @State private var comboValue = ""
    @State private var newLabel = ""

    enum Choice: Hashable { case existing, new }

    private var kind: UserPropertyDraft.Kind { EditorAuthoringModel.propertyKind(for: target.path) ?? .slider }

    private var candidates: [UserPropertyDraft] { authoring.properties.candidates(for: kind) }

    private var selected: UserPropertyDraft? { authoring.properties.property(selectedKey) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Bind to User Property")).font(.headline)
            let field = authoring.title(of: target)
            Text(L("The user property sets “\(field)” wherever the wallpaper runs. Its current value stays as the fallback."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(selection: $choice) {
                Text(L("Existing Property")).tag(Choice.existing)
                Text(L("New Property")).tag(Choice.new)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Form {
                switch choice {
                case .existing:
                    if candidates.isEmpty {
                        Text(L("The wallpaper has no property of this kind yet."))
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(L("Property"), selection: $selectedKey) {
                            ForEach(candidates) { property in
                                Text(PropertyTitle.title(property)).tag(property.key)
                            }
                        }
                        if kind == .bool, let selected, selected.kind == .combo {
                            Picker(L("On When"), selection: $comboValue) {
                                ForEach(selected.options, id: \.value) { option in
                                    Text(option.label).tag(option.value)
                                }
                            }
                        }
                    }
                case .new:
                    TextField(L("Label"), text: $newLabel)
                    LabeledContent(L("Type"), value: kind.title)
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 120)
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Bind"), action: bind)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canBind)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: start)
        .onChange(of: selectedKey) { _, _ in comboValue = selected?.options.first?.value ?? "" }
    }

    private func start() {
        let current = authoring.session.drivers(target.path, of: target.layer).user
        selectedKey = current?.name ?? candidates.first?.key ?? ""
        comboValue = current?.condition ?? selected?.options.first?.value ?? ""
        choice = candidates.isEmpty ? .new : .existing
        newLabel = EditorAuthoringModel.fieldTitle(target.path, layer: authoring.session.outline.layer(target.layer))
    }

    private var canBind: Bool {
        switch choice {
        case .existing: return selected != nil
        case .new: return !newLabel.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func bind() {
        switch choice {
        case .existing:
            guard let selected else { return }
            let condition = kind == .bool && selected.kind == .combo ? comboValue : nil
            authoring.session.bind(target.path, of: target.layer, to: SceneUserBinding(name: selected.key, condition: condition),
                                   actionName: L("Bind User Property"))
        case .new:
            authoring.properties.addAndBind(kind, label: newLabel.trimmingCharacters(in: .whitespaces),
                                            path: target.path, of: target.layer,
                                            defaultValue: defaultValue, actionName: L("Bind User Property"))
        }
        dismiss()
    }

    /// The new property's default: the field's value now, in the property's form.
    private var defaultValue: SceneJSONValue? {
        let session = authoring.session
        let current: SceneJSONValue?
        if let field = target.path.objectField {
            current = session.value(field, of: target.layer)
        } else if let index = target.path.effectIndex,
                  let effect = session.outline.layer(target.layer)?.effects.first(where: { $0.id == index }) {
            current = .bool(session.isEffectVisible(effect, of: target.layer))
        } else {
            current = nil
        }
        guard let current else { return nil }
        switch kind {
        case .bool: return current.boolValue.map(SceneJSONValue.bool)
        case .slider: return SceneVector.components(current).first.map(SceneJSONValue.number)
        case .color: return .string(SceneVector.string(SceneVector.components(current, fallback: [1, 1, 1])))
        default: return .string(UserPropertyDraft.text(of: current))
        }
    }
}
