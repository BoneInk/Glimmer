import SwiftUI

/// The wallpaper context menu's hotkey entries, as WE's: Assign Hotkey for the wallpaper on the
/// selected display, or, when it has one there, the hotkey with Change and Remove.
struct WallpaperHotKeyMenu: View {
    let wallpaper: WEWallpaper
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @ObservedObject var hotKeys: UserHotKeyController

    /// The selected display's location, which the hotkey belongs to.
    private var location: String? {
        UserHotKey.location(ofScreen: wallpaperViewModel.selectedScreenId, connected: wallpaperViewModel.connectedDisplays())
    }

    var body: some View {
        if let location, let hotKey = hotKeys.hotKey(for: wallpaper, location: location) {
            Menu {
                Button {
                    AppDelegate.shared.showAssignHotKey(.wallpaper(wallpaper, location: location))
                } label: {
                    Label("Change Hotkey…", systemImage: "keyboard")
                }
                Button(role: .destructive) {
                    hotKeys.remove(hotKey.id)
                } label: {
                    Label("Remove Hotkey", systemImage: "xmark")
                }
            } label: {
                Label {
                    Text("Hotkey: \(hotKey.shortcut.symbols)", comment: "Wallpaper context menu: the submenu of the wallpaper's hotkey on the selected display; the shortcut, e.g. ⌃⌥1")
                } icon: {
                    Image(systemName: "keyboard")
                }
            }
        } else {
            Button {
                if let location { AppDelegate.shared.showAssignHotKey(.wallpaper(wallpaper, location: location)) }
            } label: {
                Label("Assign Hotkey…", systemImage: "keyboard")
            }
            .disabled(location == nil || !WallpaperSetAsRules.canSetWallpaper(wallpaper))
            .help("A system-wide shortcut that sets this wallpaper on the selected display.")
        }
    }
}
