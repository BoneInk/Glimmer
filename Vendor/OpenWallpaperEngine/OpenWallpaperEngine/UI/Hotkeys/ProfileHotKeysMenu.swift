import SwiftUI

/// The profiles menu's hotkey entries: each profile with its hotkey, if it has one; choosing one
/// opens Assign Hotkey for it, where its hotkey can be changed or removed (WE's profile dialog's
/// hotkey field).
struct ProfileHotKeysMenu: View {
    let names: [String]
    @ObservedObject var hotKeys: UserHotKeyController

    var body: some View {
        Menu {
            ForEach(names, id: \.self) { name in
                Button {
                    AppDelegate.shared.showAssignHotKey(.profile(name: name))
                } label: {
                    if let hotKey = hotKeys.hotKey(forProfile: name) {
                        Text(verbatim: "\(name)  \(hotKey.shortcut.symbols)")
                    } else {
                        Text(verbatim: name)
                    }
                }
            }
        } label: {
            Label("Hotkeys", systemImage: "keyboard")
        }
        .help("A system-wide shortcut that loads a profile.")
    }
}
