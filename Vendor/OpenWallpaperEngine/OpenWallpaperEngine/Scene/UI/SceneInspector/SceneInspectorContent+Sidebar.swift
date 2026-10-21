import SwiftUI
import AVFoundation
import OWEInspectorKit
import OWESceneEditing

extension SceneInspectorContent {
    /// A row's name takes the width beside its switch, cut in the middle (names often differ only
    /// at their ends), with the whole name in its tooltip.
    static func rowTitle(_ name: String, caption: String? = nil, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let caption {
                    Text(verbatim: caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
        .help(Text(verbatim: name))
    }

    var sidebarColumn: some View {
        List(selection: $selectedID) {
            let versions = model.shownVersionProperties.filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) }
            if !versions.isEmpty {
                Section("Versions") {
                    ForEach(versions) { property in
                        HStack(spacing: 8) {
                            Self.rowTitle(property.title, systemImage: "square.stack.3d.up")
                            Picker(property.title, selection: Binding(
                                get: { model.propertyValue(property.id) },
                                set: { model.setProperty(property.id, to: $0) }
                            )) {
                                ForEach(property.options, id: \.value) { option in
                                    Text(verbatim: option.title).tag(option.value)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }
                    }
                }
            }
            Section("Scene Objects") {
                // The hierarchy as the Wallpaper Editor lists it; a search lists the matches flat.
                if searchText.isEmpty, !model.objectTree.isEmpty {
                    OutlineGroup(model.objectTree, children: \.children) { node in
                        if let item = model.items.first(where: { $0.id == String(node.id) }) {
                            objectRow(item, symbol: node.layer.listSymbol)
                        }
                    }
                } else {
                    ForEach(model.items.filter(matches)) { item in
                        objectRow(item, symbol: Self.kindSymbol(item.kind))
                    }
                }
            }
        }
    }

    /// A scene object: its name (with the version it belongs to, if any) and its visibility switch.
    func objectRow(_ item: SceneInspectorItem, symbol: String) -> some View {
        HStack(spacing: 8) {
            Self.rowTitle(item.name, caption: model.versionCaption(item), systemImage: symbol)
                .opacity(item.visible && !model.isHiddenByParent(item) ? 1 : 0.5)
            Toggle("Visible", isOn: Binding(
                get: { item.isSwitchedOn },
                set: { model.setObjectVisible($0, item: item) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .fixedSize()
            .help(Self.visibilityHelp(item))
        }
        .contentShape(Rectangle())
        .tag(item.id)
    }

    /// The switch's help; on an object a user property shows, what showing it again does.
    static func visibilityHelp(_ item: SceneInspectorItem) -> String {
        guard let property = item.visibility?.property else {
            return item.isSwitchedOn ? String(localized: "Hide object") : String(localized: "Show object")
        }
        return item.isSwitchedOn
            ? String(localized: "Hide this object; “\(property)” sets it again when you show it",
                     comment: "Scene Edit / Export: help of the switch of an object a user property shows; the property's key")
            : String(localized: "Show this object; “\(property)” sets it again",
                     comment: "Scene Edit / Export: help of the switch of an object hidden over the user property that shows it; the property's key")
    }
}
