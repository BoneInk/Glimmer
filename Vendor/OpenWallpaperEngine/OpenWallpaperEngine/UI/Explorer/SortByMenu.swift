import SwiftUI

/// The Installed tab's sort menu. A menu-style `Picker` in the window toolbar shows only its own
/// title, so the menu's label is the selected method's localized name and the choices sit inline.
struct SortByMenu: View {
    @Binding var selection: WEWallpaperSortingMethod

    /// The label the toolbar shows: the selected sorting method's name.
    var title: LocalizedStringResource { selection.displayName }

    var body: some View {
        Menu {
            Picker("Sort By", selection: $selection) {
                ForEach(WEWallpaperSortingMethod.allCases) { method in
                    Text(method.displayName).tag(method)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(title)
        }
        .help("Sort By")
    }
}
