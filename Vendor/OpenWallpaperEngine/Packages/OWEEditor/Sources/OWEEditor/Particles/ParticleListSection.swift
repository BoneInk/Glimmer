import SwiftUI
import OWEInspectorKit
import OWESceneEditing

/// One list of the particle system (emitters, initializers, …) as WE's panel lists it: each item
/// folded under its name with its fields, an Add menu of the components WE offers, and Move Up,
/// Move Down and Remove per item. Initializers and operators run in list order, so order matters.
struct ParticleListSection: View {
    typealias Section = ParticleEditorSchema.Section

    @ObservedObject var model: ParticleEditingModel
    let section: Section
    let path: String
    /// Opens a child system's definition in the panel.
    let openChild: (String) -> Void

    var body: some View {
        let items = model.definition(path)?.items(section) ?? []
        SwiftUI.Section {
            if items.isEmpty {
                Text(section.emptyText).foregroundStyle(.secondary)
            }
            ForEach(items.indices, id: \.self) { index in
                ParticleComponentRow(model: model, section: section, path: path, index: index, item: items[index],
                                     count: items.count, openChild: openChild)
            }
        } header: {
            HStack {
                Text(section.title)
                Text(verbatim: "\(items.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                addControl(count: items.count)
            }
        }
    }

    @ViewBuilder private func addControl(count: Int) -> some View {
        let full = count >= ParticleDefinition.capacity(of: section)
        if section.isTyped {
            Menu {
                ForEach(model.schema.components(in: section).filter(\.isAddable)) { component in
                    Button(component.localizedTitle) {
                        model.addComponent(component, to: path, actionName: PartL("Add \(component.localizedTitle)"))
                    }
                }
            } label: {
                Label(section.addTitle, systemImage: "plus").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(section.addTitle)
        } else {
            Button {
                if section == .children {
                    model.addChild(to: path, actionName: PartL("Add Child System"))
                } else if let component = model.schema.component(section) {
                    model.addComponent(component, to: path, actionName: section.addTitle)
                }
            } label: {
                Label(section.addTitle, systemImage: "plus").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(full)
            .help(full ? PartL("A system has at most eight control points.") : section.addTitle)
        }
    }
}

/// One item of a list: its name with Move Up, Move Down and Remove, and, unfolded, its fields.
private struct ParticleComponentRow: View {
    @ObservedObject var model: ParticleEditingModel
    let section: ParticleEditorSchema.Section
    let path: String
    let index: Int
    let item: ParticleDefinition.Item
    let count: Int
    let openChild: (String) -> Void
    @State private var isExpanded = false

    private var component: ParticleEditorSchema.Component? {
        model.schema.component(section, name: item["name"]?.stringValue)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let component {
                fields(component)
            } else {
                Text(PartL("WE’s editor doesn’t offer this component; it is kept as authored."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } label: {
            HStack(spacing: 6) {
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                Group {
                    Button { move(-1) } label: {
                        Label(PartL("Move Up"), systemImage: "chevron.up").labelStyle(.iconOnly)
                    }
                    .disabled(index == 0)
                    .help(PartL("Move Up"))
                    Button { move(1) } label: {
                        Label(PartL("Move Down"), systemImage: "chevron.down").labelStyle(.iconOnly)
                    }
                    .disabled(index >= count - 1)
                    .help(PartL("Move Down"))
                    Button(role: .destructive) { remove() } label: {
                        Label(PartL("Remove"), systemImage: "minus.circle").labelStyle(.iconOnly)
                    }
                    .help(PartL("Remove"))
                }
                .buttonStyle(.borderless)
            }
            .contextMenu {
                Button(PartL("Move Up")) { move(-1) }.disabled(index == 0)
                Button(PartL("Move Down")) { move(1) }.disabled(index >= count - 1)
                Divider()
                Button(PartL("Remove"), role: .destructive) { remove() }
            }
        }
    }

    private var title: String {
        switch section {
        case .controlpoint:
            return PartL("Control Point \(index)")
        case .children:
            let name = item["name"]?.stringValue.map { ($0 as NSString).lastPathComponent } ?? PartL("Child")
            return name
        default:
            return component?.localizedTitle ?? item["name"]?.stringValue ?? PartL("Unnamed")
        }
    }

    @ViewBuilder private func fields(_ component: ParticleEditorSchema.Component) -> some View {
        let pixelUnits = model.pixelUnits
        let values = ParticleDefinition.conditionValues(item, component: component, pixelUnits: pixelUnits)
        if section == .children {
            LabeledContent(PartL("File")) {
                HStack(spacing: 6) {
                    Text(item["name"]?.stringValue ?? "—").lineLimit(1).truncationMode(.middle)
                    if let child = item["name"]?.stringValue, model.definition(child) != nil {
                        Button(PartL("Edit")) { openChild(child) }
                            .help(PartL("Edit the child system"))
                    }
                }
            }
        }
        let visible = component.fields.filter { $0.isVisible(in: values) }
        ForEach(Array(visible.enumerated()), id: \.element.id) { position, field in
            if let group = field.group, position == 0 || visible[position - 1].group != group {
                Text(PLSchema(group))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            ParticleFieldRow(field: field, kind: field.effectiveKind(in: values),
                             value: ParticleDefinition.shownValue(of: field, in: item, pixelUnits: pixelUnits)) { value, coalescing in
                model.setField(field, to: value, section: section, index: index, definition: path,
                               actionName: PartL("Change \(field.localizedLabel)"), coalescing: coalescing)
            }
        }
        if let name = component.name, ParticleLifetimeRamp.names.contains(name) {
            ParticleLifetimeRamp(name: name, item: item) { key in
                component.fields.first { $0.key == key }.flatMap {
                    ParticleDefinition.shownValue(of: $0, in: item, pixelUnits: pixelUnits)
                }
            }
        }
    }

    private func move(_ step: Int) {
        let destination = index + step
        guard destination >= 0, destination < count else { return }
        model.moveComponent(section, from: index, to: destination, in: path,
                            actionName: step < 0 ? PartL("Move Up") : PartL("Move Down"))
    }

    private func remove() {
        model.removeComponent(section, at: index, from: path, actionName: PartL("Remove \(title)"))
    }
}
