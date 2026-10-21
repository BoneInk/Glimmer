import SwiftUI
import OWESceneEditing

/// The properties panel as the user will see it, live: the properties in order, each with its
/// control, shown only while its condition holds, a group's properties folded under its label
/// (closed at first, as in WE). Values here are the preview's own (starting at the defaults) and
/// never change the wallpaper.
struct UserPropertiesPreview: View {
    let properties: [UserPropertyDraft]
    @State private var values: [String: String] = [:]
    @State private var openGroups: Set<String> = []

    var body: some View {
        let current = resolvedValues
        Form {
            let visible = properties.filter { property in
                property.condition.map { UserPropertyConditionExpression($0).evaluate(current) } ?? true
            }
            if visible.isEmpty {
                Text(L("No properties to show.")).foregroundStyle(.secondary)
            }
            ForEach(UserPropertyGroup.groups(visible)) { group in
                if let header = group.header {
                    DisclosureGroup(isExpanded: Binding(get: { openGroups.contains(header.key) }, set: { open in
                        if open { openGroups.insert(header.key) } else { openGroups.remove(header.key) }
                    })) {
                        ForEach(group.members) { property in
                            row(property, value: current[property.key] ?? property.defaultText)
                        }
                    } label: {
                        Text(PropertyTitle.title(header)).fontWeight(.semibold)
                    }
                } else {
                    ForEach(group.members) { property in
                        row(property, value: current[property.key] ?? property.defaultText)
                    }
                }
            }
            if !values.isEmpty {
                Button(L("Reset Preview")) { values = [:] }
                    .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
    }

    /// The preview's values over the defaults.
    private var resolvedValues: [String: String] {
        var resolved: [String: String] = [:]
        for property in properties where property.kind.hasValue {
            resolved[property.key] = values[property.key] ?? property.defaultText
        }
        return resolved
    }

    private func set(_ key: String, _ value: String) {
        values[key] = value
    }

    @ViewBuilder private func row(_ property: UserPropertyDraft, value: String) -> some View {
        let title = PropertyTitle.title(property)
        if property.kind == .bool {
            Toggle(title, isOn: Binding(get: { value == "true" || value == "1" },
                                        set: { set(property.key, $0 ? "true" : "false") }))
        } else if property.kind == .slider {
            let lower: Double = property.minimum ?? 0
            let upper: Double = max(property.maximum ?? 1, lower + 0.0001)
            let sliderValue = Binding<Double>(
                get: { min(max(Double(value) ?? lower, lower), upper) },
                set: { (newValue: Double) in
                    let rounded: Double = PropertyFormat.rounded(newValue, property)
                    set(property.key, SceneVector.string([rounded]))
                })
            LabeledContent(title) {
                HStack {
                    Slider(value: sliderValue, in: lower...upper)
                    Text(Self.formatted(Double(value) ?? lower, property))
                        .monospacedDigit()
                        .frame(minWidth: 40, alignment: .trailing)
                }
            }
        } else if property.kind == .color {
            ColorPicker(title, selection: Binding(get: { PropertyColor.color(value) },
                                                  set: { set(property.key, PropertyColor.text($0)) }),
                        supportsOpacity: false)
        } else if property.kind == .combo {
            Picker(title, selection: Binding(get: { value }, set: { set(property.key, $0) })) {
                ForEach(property.options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
        } else if property.kind == .textInput {
            TextField(title, text: Binding(get: { value }, set: { set(property.key, $0) }))
        } else if property.kind == .file || property.kind == .directory || property.kind == .sceneTexture {
            LabeledContent(title) {
                Button(property.kind == .directory ? L("Choose Folder…") : L("Choose File…")) {}
                    .disabled(true)
            }
        } else if property.kind == .userShortcut {
            LabeledContent(title) {
                Button(L("Set Shortcut…")) {}
                    .disabled(true)
            }
        } else if property.kind == .text {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            LabeledContent(title, value: value)
        }
    }

    static func formatted(_ number: Double, _ property: UserPropertyDraft) -> String {
        property.fraction == false ? String(Int(number.rounded())) : String(format: "%.\(property.decimals)f", number)
    }
}
