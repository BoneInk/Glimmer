import SwiftUI
import OWESceneEditing

/// A texture variant option's Condition (WE opens its user properties with the types `bool` and
/// `combo`, `textureEditVariantOptionCondition`): an existing checkbox (on while true) or combo
/// (on while it has one value), none, or a new property made for it. A new checkbox binds the
/// option; a new combo gets one value per option of the group and a Default for the base (the
/// docs' "leave one value unassigned"), and binds every option of the group without a condition.
struct TextureVariantConditionSheet: View {
    enum Result {
        case condition(TextureVariantDocument.Condition?)
        /// The property to add (its `key` still the label) and the options' conditions on it, by
        /// option, naming the label until its key is known (`rekeyed`).
        case newProperty(UserPropertyDraft, [UUID: TextureVariantDocument.Condition])
    }

    enum Choice: Hashable { case existing, new }

    let group: TextureVariantDocument.Group
    let option: TextureVariantDocument.Option
    let properties: [UserPropertyDraft]
    let title: (String) -> String
    let done: (Result) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var choice = Choice.existing
    @State private var selectedKey = ""
    @State private var comboValue = ""
    @State private var newLabel = ""
    @State private var newKind = UserPropertyDraft.Kind.bool

    private var candidates: [UserPropertyDraft] {
        properties.filter { $0.kind == .bool || $0.kind == .combo }
    }

    private var selected: UserPropertyDraft? { candidates.first { $0.key == selectedKey } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(TVL("Condition")).font(.headline)
            Text(TVL("The option shows while its condition holds; in a group the first option whose condition holds wins."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(selection: $choice) {
                Text(TVL("Existing Property")).tag(Choice.existing)
                Text(TVL("New Property")).tag(Choice.new)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Form {
                switch choice {
                case .existing:
                    if candidates.isEmpty {
                        Text(TVL("The wallpaper has no checkbox or combo property yet."))
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(TVL("Property"), selection: $selectedKey) {
                            Text(TVL("None")).tag("")
                            ForEach(candidates) { property in
                                Text(title(property.key)).tag(property.key)
                            }
                        }
                        if let selected, selected.kind == .combo {
                            Picker(TVL("Selected combo value for this link:"), selection: $comboValue) {
                                ForEach(selected.options, id: \.value) { option in
                                    Text(option.label).tag(option.value)
                                }
                            }
                        }
                    }
                case .new:
                    TextField(TVL("Label"), text: $newLabel)
                    Picker(TVL("Type"), selection: $newKind) {
                        Text(TVL("Checkbox")).tag(UserPropertyDraft.Kind.bool)
                        Text(TVL("Combo")).tag(UserPropertyDraft.Kind.combo)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 130)
            HStack {
                Spacer()
                Button(TVL("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(TVL("OK"), action: finish)
                    .keyboardShortcut(.defaultAction)
                    .disabled(choice == .new && newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: start)
        .onChange(of: selectedKey) { _, _ in
            if let selected, !selected.options.contains(where: { $0.value == comboValue }) {
                comboValue = selected.options.first?.value ?? ""
            }
        }
    }

    private func start() {
        selectedKey = option.condition?.property ?? ""
        if case .equals(_, let value)? = option.condition { comboValue = value }
        choice = candidates.isEmpty ? .new : .existing
        newLabel = group.name
    }

    private func finish() {
        switch choice {
        case .existing:
            guard let selected else {
                done(.condition(nil))
                break
            }
            done(.condition(selected.kind == .combo ? .equals(selected.key, comboValue) : .flag(selected.key)))
        case .new:
            let label = newLabel.trimmingCharacters(in: .whitespaces)
            let made = Self.newProperty(newKind, label: label, group: group, option: option.id)
            done(.newProperty(made.draft, made.conditions))
        }
        dismiss()
    }

    /// The property a new condition makes and the conditions it gives the group's options.
    static func newProperty(_ kind: UserPropertyDraft.Kind, label: String, group: TextureVariantDocument.Group, option: UUID)
        -> (draft: UserPropertyDraft, conditions: [UUID: TextureVariantDocument.Condition]) {
        var draft = UserPropertyDraft.new(kind, key: label, text: label)
        guard kind == .combo else { return (draft, [option: .flag(label)]) }
        // Value 0 is the base; each option its position from 1.
        draft.options = [UserPropertyDraft.Option(label: TVL("Default"), value: "0")]
        var conditions: [UUID: TextureVariantDocument.Condition] = [:]
        for (index, member) in group.options.enumerated() {
            let value = String(index + 1)
            draft.options.append(UserPropertyDraft.Option(label: member.name, value: value))
            if member.id == option || member.condition == nil { conditions[member.id] = .equals(label, value) }
        }
        draft.value = .string("0")
        return (draft, conditions)
    }
}
