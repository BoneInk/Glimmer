import SwiftUI

/// The library window's own buttons: Displays and Settings, and on Installed the Details toggle.
/// Each tab ends its toolbar with these, so they follow the tab's items and Details sits at the
/// trailing edge of the window, as macOS places an inspector toggle. (Items a parent view adds
/// come before its children's, so `ContentView` can't add them itself.)
struct WindowActionsToolbar: ToolbarContent {
    var viewModel: ContentViewModel
    /// Installed only: the Details panel is its inspector.
    var showsDetails = false
    /// Off while the Installed tab picks wallpapers for an export.
    var isEnabled = true

    var body: some ToolbarContent {
        // On macOS 26 a fixed spacer gives each group its own glass capsule.
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed)
        }
        ToolbarItemGroup {
            Button {
                viewModel.presentation.isDisplaySettingsReveal = true
            } label: {
                Label("Displays", systemImage: "display")
            }
            .help("Display Settings")
            .disabled(!isEnabled)
            Button {
                AppDelegate.shared.openSettingsWindow()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings", shortcut: .settings)
            .disabled(!isEnabled)
        }
        if showsDetails {
            if #available(macOS 26, *) {
                ToolbarSpacer(.fixed)
            }
            ToolbarItem {
                Button {
                    withAnimation { viewModel.navigation.isDetailsReveal.toggle() }
                } label: {
                    Label("Details", systemImage: "sidebar.right")
                }
                .help("Show or hide the wallpaper details")
                .disabled(!isEnabled)
            }
        }
    }
}
