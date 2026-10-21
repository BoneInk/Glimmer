import OWEInspectorKit
import SwiftUI

/// The Android device combo box's search: every word of the query has to match the maker and
/// name, the kind, the year or the resolution ("1440", "1440x3120", "1440 × 3120").
enum AndroidDeviceSearch {
    static func filter(_ devices: [AndroidDevice], query: String) -> [AndroidDevice] {
        let words = DeviceModelSearch.words(in: query)
        guard !words.isEmpty else { return devices }
        return devices.filter { device in words.allSatisfy { matches(device, word: $0) } }
    }

    /// `devices` by kind (phones, foldables, tablets), each kind keeping its order.
    static func groups(_ devices: [AndroidDevice]) -> [(kind: AndroidDeviceKind, devices: [AndroidDevice])] {
        AndroidDeviceKind.allCases.compactMap { kind in
            let members = devices.filter { $0.kind == kind }
            return members.isEmpty ? nil : (kind, members)
        }
    }

    private static func matches(_ device: AndroidDevice, word: String) -> Bool {
        let size = device.pixelSize
        let fields = [device.displayName.lowercased(), device.kind.rawValue, String(localized: device.kind.title).lowercased(),
                      String(device.year), "\(size.x)x\(size.y)", "\(size.y)x\(size.x)"]
        return fields.contains { $0.contains(word) }
    }
}

/// The device picker: a combo box showing the chosen Android device or "Custom". Its drop-down
/// lists the devices by kind, newest first; typing narrows them (`AndroidDeviceSearch`) and
/// Return picks the first match. "Custom…" leads the list.
struct AndroidDeviceComboBox: View {
    let selection: AndroidDevice?
    let onChoose: (AndroidDevice?) -> Void
    @State private var isOpen = false
    @State private var query = ""

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selection?.kind.systemImage ?? "aspectratio")
                    .foregroundStyle(.secondary)
                Group {
                    if let selection {
                        Text(verbatim: selection.displayName)
                    } else {
                        Text("Custom", comment: "Android Export: the custom screen size, chosen in the device list")
                    }
                }
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
        .help("Choose the Android phone or tablet the wallpaper is made for, or a custom size")
        .accessibilityLabel(Text("Device"))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            AndroidDeviceComboBoxList(selection: selection, query: $query, onChoose: { device in
                onChoose(device)
                query = ""
                isOpen = false
            })
        }
    }
}

private struct AndroidDeviceComboBoxList: View {
    @Environment(\.appAccentColor) private var accentColor
    let selection: AndroidDevice?
    @Binding var query: String
    let onChoose: (AndroidDevice?) -> Void
    @FocusState private var isSearchFocused: Bool

    private var matches: [AndroidDevice] { AndroidDeviceSearch.filter(AndroidDevice.all, query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search by name, year or resolution", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .onSubmit { if let first = matches.first { onChoose(first) } }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        if query.isEmpty { customRow.id(AndroidExportEditorModel.customID) }
                        let groups = AndroidDeviceSearch.groups(matches)
                        if groups.isEmpty {
                            Text("No matching devices")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 80)
                        }
                        ForEach(groups, id: \.kind) { group in
                            Section {
                                ForEach(group.devices) { device in row(device).id(device.id) }
                            } header: {
                                Label { Text(group.kind.title) } icon: { Image(systemName: group.kind.systemImage) }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                                    .background(.regularMaterial)
                            }
                        }
                    }
                }
                .frame(height: 340)
                .onAppear { proxy.scrollTo(selection?.id ?? AndroidExportEditorModel.customID, anchor: .center) }
            }
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { isSearchFocused = true }
    }

    private var customRow: some View {
        Button {
            onChoose(nil)
        } label: {
            HStack(spacing: 8) {
                checkmark(selection == nil)
                Label("Custom…", systemImage: "aspectratio")
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Enter the screen's width and height in pixels")
    }

    private func row(_ device: AndroidDevice) -> some View {
        Button {
            onChoose(device)
        } label: {
            HStack(spacing: 8) {
                checkmark(device == selection)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: device.displayName)
                    Text(verbatim: Self.detail(device))
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
        .background(RoundedRectangle(cornerRadius: 6).fill(device == selection ? accentColor.opacity(0.15) : .clear))
    }

    private func checkmark(_ on: Bool) -> some View {
        Image(systemName: "checkmark")
            .font(.caption.weight(.bold))
            .opacity(on ? 1 : 0)
    }

    /// "2025 · 1440 × 3120"
    private static func detail(_ device: AndroidDevice) -> String {
        let number = IntegerFormatStyle<Int>.number.grouping(.never)
        return "\(device.year.formatted(number)) · \(device.pixelSize.x.formatted(number)) × \(device.pixelSize.y.formatted(number))"
    }
}
