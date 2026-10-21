import OWEInspectorKit
import SwiftUI

/// The "Show only" checkboxes, shared by the Installed and Workshop filter sidebars. Option `i` is
/// `FRShowOnly.options[i]` (and `WorkshopShowOnly(rawValue: i)`).
struct ShowOnlyFilterRows: View {
    @Environment(\.appAccentColor) private var accentColor
    let isOn: (Int) -> Bool
    let set: (Int, Bool) -> Void

    private static let colors: [Color] = [.green, .pink, .orange]

    var body: some View {
        ForEach(Array(FRShowOnly.options.enumerated()), id: \.offset) { index, option in
            Toggle(isOn: Binding(get: { isOn(index) }, set: { set(index, $0) })) {
                HStack(spacing: 2) {
                    Image(systemName: option.systemImage ?? "")
                        .foregroundStyle(index < Self.colors.count ? Self.colors[index] : accentColor)
                    Text(option.label)
                }
            }
            .toggleStyle(.checkbox)
        }
    }
}

/// WE's resolution filter (`WEResolutionTags`): a group title with All/None and a checkbox per
/// tag, shared by the Installed and Workshop filter sidebars.
struct ResolutionFilterRows: View {
    let isOn: (String) -> Bool
    let set: (String, Bool) -> Void

    var body: some View {
        ForEach(WEResolutionTags.groups) { group in
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedLabels.filterOption(group.title))
                    .bold()
                HStack {
                    Button("All") { group.tags.forEach { set($0, true) } }
                    Button("None") { group.tags.forEach { set($0, false) } }
                }
                .buttonStyle(.link)
            }
            .padding(.top, 5)
            ForEach(group.tags, id: \.self) { tag in
                Toggle(isOn: Binding(get: { isOn(tag) }, set: { set(tag, $0) })) {
                    Text(LocalizedLabels.filterOption(tag))
                }
                    .toggleStyle(.checkbox)
            }
        }
    }
}
