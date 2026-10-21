import AppKit
import SwiftUI

/// WE's "Shortcut for '…'" modal (`views/modals/browseassignusershortcut.html`): the user binds a
/// `usershortcut` property to a file, a folder, a website or a command. Changing the kind clears
/// the path, Test opens the draft without saving it, Clear unbinds, and Apply saves the binding
/// with this Mac's hash (`UserShortcutBinding.storedValue`; no path unbinds, as in WE).
struct UserShortcutBindSheet: View {
    /// WE caps the arguments and the command at 512 characters (`maxlength="512"`).
    static let maximumLength = 512

    let name: String
    let launcher: UserShortcutLauncher
    let onApply: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: UserShortcutBinding.Kind?
    @State private var path: String
    @State private var arguments: String

    init(name: String, value: String, launcher: UserShortcutLauncher, onApply: @escaping (String) -> Void) {
        self.name = name
        self.launcher = launcher
        self.onApply = onApply
        let binding = UserShortcutBinding(storedValue: value)
        _kind = State(initialValue: binding?.kind)
        _path = State(initialValue: binding?.path ?? "")
        _arguments = State(initialValue: binding?.arguments ?? "")
    }

    /// The value Apply saves: empty while nothing is chosen.
    var draftValue: String {
        guard let kind else { return "" }
        return UserShortcutBinding(kind: kind, systemHash: launcher.systemHash,
                                   path: kind == .cmd ? String(path.prefix(Self.maximumLength)) : path,
                                   arguments: String(arguments.prefix(Self.maximumLength))).storedValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shortcut for “\(name)”")
                .font(.headline)
            Picker(selection: kindSelection) {
                Label("Open File", systemImage: "doc").tag(UserShortcutBinding.Kind?.some(.file))
                Label("Open Folder", systemImage: "folder").tag(UserShortcutBinding.Kind?.some(.directory))
                Label("Open Website", systemImage: "globe").tag(UserShortcutBinding.Kind?.some(.web))
                Label("Run Command", systemImage: "apple.terminal").tag(UserShortcutBinding.Kind?.some(.cmd))
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            details
            HStack {
                Button("Clear", role: .destructive) {
                    onApply("")
                    dismiss()
                }
                Button("Test") { _ = launcher.open(draftValue) }
                    .disabled(draftValue.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    onApply(draftValue)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    /// WE clears the path when the kind changes.
    private var kindSelection: Binding<UserShortcutBinding.Kind?> {
        Binding(get: { kind }, set: { newKind in
            guard newKind != kind else { return }
            kind = newKind
            path = ""
            arguments = ""
        })
    }

    @ViewBuilder
    private var details: some View {
        switch kind {
        case nil:
            Text("Open a file or folder, a website or a command by clicking the wallpaper element made for it. A shortcut stays on this Mac: it isn’t shared, and presets leave it out.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .file?, .directory?:
            if kind == .file { securityNotice }
            LabeledContent("Path") {
                Button(kind == .file ? "Choose File…" : "Choose Folder…") { choosePath() }
            }
            if !path.isEmpty {
                Text(verbatim: path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if kind == .file {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Arguments")
                    TextField("", text: $arguments, axis: .vertical)
                        .lineLimit(2...3)
                        .labelsHidden()
                    Text("Arguments are passed when the file is an app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .web?:
            securityNotice
            LabeledContent("URL") {
                TextField("", text: $path)
                    .labelsHidden()
            }
        case .cmd?:
            securityNotice
            VStack(alignment: .leading, spacing: 4) {
                Text("Command")
                TextEditor(text: $path)
                    .font(.body.monospaced())
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                Text("Runs in zsh with your login environment, in your home folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var securityNotice: some View {
        Label("Only enter files and websites you fully trust, and don’t paste commands you don’t understand.",
              systemImage: "exclamationmark.shield")
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = kind == .directory
        panel.canChooseFiles = kind == .file
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Without a folder's trailing slash, so its name shows (`displayName`).
        path = (url.path(percentEncoded: false) as NSString).standardizingPath
    }
}
