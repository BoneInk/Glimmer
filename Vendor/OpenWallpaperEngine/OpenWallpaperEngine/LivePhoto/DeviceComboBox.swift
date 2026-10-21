import OWEInspectorKit
import SwiftUI

/// The device picker: a combo box showing the chosen iPhone or iPad. Its drop-down lists every
/// model by family, newest first, and typing in its search field narrows the list by name,
/// family, year or resolution (`DeviceModelSearch`); Return picks the first match.
struct DeviceComboBox: View {
    @Binding var selection: DeviceModel
    @State private var isOpen = false
    @State private var query = ""

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selection.family.systemImage)
                    .foregroundStyle(.secondary)
                Text(verbatim: selection.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .glassButtonStyle()
        .help("Choose the iPhone or iPad the Live Photo is made for")
        .accessibilityLabel(Text("Device"))
        .accessibilityValue(Text(verbatim: selection.name))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            DeviceComboBoxList(selection: $selection, query: $query, isOpen: $isOpen)
        }
    }
}

/// The combo box's drop-down: the search field and the matching models by family.
private struct DeviceComboBoxList: View {
    @Environment(\.appAccentColor) private var accentColor
    @Binding var selection: DeviceModel
    @Binding var query: String
    @Binding var isOpen: Bool
    @FocusState private var isSearchFocused: Bool

    private var matches: [DeviceModel] { DeviceModelSearch.filter(DeviceModel.all, query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search by name, year or resolution", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .onSubmit { if let first = matches.first { choose(first) } }
            let groups = DeviceModelSearch.groups(matches)
            if groups.isEmpty {
                Text("No matching devices")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                deviceList(groups)
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { isSearchFocused = true }
    }

    private func deviceList(_ groups: [DeviceModelGroup]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.models) { model in
                                row(model).id(model.id)
                            }
                        } header: {
                            Label(group.family.name, systemImage: group.family.systemImage)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .background(.regularMaterial)
                        }
                    }
                }
            }
            .frame(height: 320)
            .onAppear { proxy.scrollTo(selection.id, anchor: .center) }
        }
    }

    private func row(_ model: DeviceModel) -> some View {
        Button {
            choose(model)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .opacity(model == selection ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: model.name)
                    Text(verbatim: Self.detail(model))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6).fill(model == selection ? accentColor.opacity(0.15) : .clear))
    }

    /// "2025 · 1320 × 2868"
    private static func detail(_ model: DeviceModel) -> String {
        let year = model.year.formatted(.number.grouping(.never))
        return "\(year) · \(model.pixelSize.x.formatted(.number.grouping(.never))) × \(model.pixelSize.y.formatted(.number.grouping(.never)))"
    }

    private func choose(_ model: DeviceModel) {
        selection = model
        query = ""
        isOpen = false
    }
}
