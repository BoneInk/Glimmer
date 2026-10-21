import SwiftUI
import OWEInspectorKit

/// A `usershortcut` property in the properties panel, as WE's sidebar row
/// (`property.type=='usershortcut'`): what it is bound to (a file's or folder's name, the URL or
/// the command; "Nothing bound" otherwise), a button that opens the bind sheet, and Clear.
struct UserShortcutPropertyRow: View {
    let title: String
    let help: String
    /// The binding as stored (`UserShortcutBinding.storedValue`); empty when unbound.
    let value: String
    let launcher: UserShortcutLauncher
    let onChange: (String) -> Void

    @State private var isBinding = false

    var body: some View {
        let binding = UserShortcutBinding(storedValue: value)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(title)
                InfoTip(help)
            }
            HStack(spacing: 6) {
                if let binding {
                    Image(systemName: Self.symbol(binding.kind))
                        .foregroundStyle(.secondary)
                    Text(verbatim: binding.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(binding.path)
                } else {
                    Text("Nothing bound")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(binding == nil ? "Assign Shortcut" : "Edit…") { isBinding = true }
                if binding != nil {
                    Button("Clear") { onChange("") }
                }
            }
            if let binding, binding.systemHash != launcher.systemHash {
                Text("Bound on another Mac: it won’t open here until you assign it again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $isBinding) {
            UserShortcutBindSheet(name: title, value: value, launcher: launcher, onApply: onChange)
        }
    }

    static func symbol(_ kind: UserShortcutBinding.Kind) -> String {
        switch kind {
        case .file: "doc"
        case .directory: "folder"
        case .web: "globe"
        case .cmd: "apple.terminal"
        }
    }
}
