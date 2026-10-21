import SwiftUI
import UniformTypeIdentifiers

/// WE's display profiles in the Displays sheet: "Save profile…" names the whole layout (layout,
/// groups, splits, flips, mute and each display's wallpaper), "Load profile" applies one, and a
/// profile can be deleted. A Wallpaper Engine `config.json` imports as a profile of its own.
struct DisplayProfilesMenu: View {
    @ObservedObject var profiles: DisplayProfiles
    @State private var isSaveShown = false
    @State private var importError: String?

    var body: some View {
        Menu {
            Button("Save profile…") { isSaveShown = true }
            Button("Import Wallpaper Engine Profile…") { importConfig() }
            Divider()
            if profiles.profiles.isEmpty {
                Text("You have not created any profiles yet.")
            } else {
                Section("Load profile") {
                    ForEach(profiles.names, id: \.self) { name in
                        Button(name) { profiles.load(name: name) }
                    }
                }
                ProfileHotKeysMenu(names: profiles.names, hotKeys: AppDelegate.shared.userHotKeys)
                Menu("Delete Profile") {
                    ForEach(profiles.names, id: \.self) { name in
                        Button(name, role: .destructive) { profiles.delete(name: name) }
                    }
                }
            }
        } label: {
            Label("Profile", systemImage: "rectangle.stack")
        }
        .fixedSize()
        .sheet(isPresented: $isSaveShown) {
            SaveDisplayProfileSheet { name in profiles.save(name: name) }
        }
        .alert("Import Wallpaper Engine Profile…", isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: importError ?? "")
        }
    }

    /// Reads a Wallpaper Engine `config.json` the user picks into the profile "Wallpaper Engine".
    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try profiles.importWallpaperEngineConfig(at: url)
        } catch {
            OWELog.error(.app, "Wallpaper Engine config not imported from \(url.lastPathComponent): \(error)")
            importError = error.localizedDescription
        }
    }
}

/// WE's "Save Profile" dialog: a name; a profile of the same name is overwritten.
private struct SaveDisplayProfileSheet: View {
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Profile")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !trimmed.isEmpty { commit(trimmed) } }
            Text("If a profile with the same name exists already, it will be overwritten.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .glassButtonStyle()
                Button("Save") { commit(trimmed) }
                    .keyboardShortcut(.defaultAction)
                    .glassButtonStyle(.prominent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func commit(_ name: String) {
        save(name)
        dismiss()
    }
}
