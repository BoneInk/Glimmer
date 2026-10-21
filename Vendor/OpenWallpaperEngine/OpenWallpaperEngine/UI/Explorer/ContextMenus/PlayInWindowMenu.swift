import AppKit
import SwiftUI

/// The wallpaper context menu's Play in Window submenu, as WE's: Full HD Preview, Phone Preview
/// and Maximized Preview, each in the window WE names "Wallpaper Pop-out".
struct PlayInWindowMenu: View {
    let wallpaper: WEWallpaper

    var body: some View {
        Menu {
            Button {
                play(.fullHD)
            } label: {
                Label {
                    Text("Full HD Preview", comment: "Play in Window submenu: a 1920 × 1080 window")
                } icon: {
                    Image(systemName: "desktopcomputer")
                }
            }
            Button {
                play(.phone)
            } label: {
                Label {
                    Text("Phone Preview", comment: "Play in Window submenu: a window of a phone's shape")
                } icon: {
                    Image(systemName: "iphone")
                }
            }
            Divider()
            Button {
                play(.maximized)
            } label: {
                Label {
                    Text("Maximized Preview", comment: "Play in Window submenu: a window filling the screen")
                } icon: {
                    Image(systemName: "macwindow")
                }
            }
        } label: {
            Label {
                Text("Play in Window", comment: "Wallpaper context menu: plays the wallpaper in a window of its own, beside the desktop")
            } icon: {
                Image(systemName: "macwindow.on.rectangle")
            }
        }
        .disabled(!PlayInWindowController.canPlay(wallpaper))
    }

    private func play(_ size: PlayInWindowRequest.Size) {
        guard let refusal = AppDelegate.shared.playInWindow.open(PlayInWindowRequest(wallpaper: wallpaper, size: size)) else { return }
        let alert = NSAlert()
        alert.messageText = wallpaper.project.displayTitle
        alert.informativeText = refusal.message
        alert.runModal()
    }
}
