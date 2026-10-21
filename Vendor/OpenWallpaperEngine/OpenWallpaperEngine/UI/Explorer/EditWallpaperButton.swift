import SwiftUI

/// Whether the library's Edit Wallpaper button can open the Wallpaper Editor for the selected
/// wallpaper, and why not when it can't. Only scene wallpapers can be edited.
enum EditWallpaperButtonState: Equatable {
    case enabled
    case nothingSelected
    case notAScene

    init(selection: WEWallpaper?) {
        guard let selection else {
            self = .nothingSelected
            return
        }
        self = WallpaperEditorController.canEdit(selection) ? .enabled : .notAScene
    }

    /// The selection as the Details panel shows it: the placeholder it falls back to when no
    /// wallpaper is selected or set counts as nothing selected.
    init(displayed: WEWallpaper) {
        self.init(selection: Self.selection(displayed: displayed))
    }

    /// `displayed`, or nil when it is the placeholder.
    static func selection(displayed: WEWallpaper) -> WEWallpaper? {
        displayed.wallpaperDirectory == WallpaperViewModel.defaultWallpaper.wallpaperDirectory ? nil : displayed
    }

    var isEnabled: Bool { self == .enabled }
}

/// The library bottom bar's Edit Wallpaper button: opens the selected wallpaper in the Wallpaper
/// Editor, as Window › Wallpaper Editor (⌥⌘E) does.
struct EditWallpaperButton: View {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel

    var body: some View {
        let selection = EditWallpaperButtonState.selection(displayed: wallpaperViewModel.displayedWallpaper)
        let state = EditWallpaperButtonState(selection: selection)
        Button {
            guard let selection, state.isEnabled else { return }
            AppDelegate.shared.showWallpaperEditor(for: selection)
        } label: {
            Label(String(localized: "Edit Wallpaper", comment: "Library bottom bar: opens the selected wallpaper in the Wallpaper Editor"),
                  systemImage: "slider.horizontal.below.rectangle")
        }
        .glassButtonStyle()
        .disabled(!state.isEnabled)
        .accessibilityLabel(Text("Edit Wallpaper", comment: "Library bottom bar: opens the selected wallpaper in the Wallpaper Editor"))
        .modifier(EditWallpaperHelp(state: state))
    }
}

/// The Edit Wallpaper button's tooltip: the editor and its shortcut, or why it is unavailable.
private struct EditWallpaperHelp: ViewModifier {
    let state: EditWallpaperButtonState

    func body(content: Content) -> some View {
        switch state {
        case .enabled:
            content.help("Wallpaper Editor", shortcut: .wallpaperEditor)
        case .nothingSelected:
            content.help("Select a wallpaper to edit it")
        case .notAScene:
            content.help("Only scene wallpapers can be edited")
        }
    }
}
