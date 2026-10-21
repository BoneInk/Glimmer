import SwiftUI
import UniformTypeIdentifiers

/// WE's "Your Presets" in the Details panel: save the properties as a named preset, then apply,
/// rename, delete, export and import presets of this wallpaper.
struct WallpaperPresetsSection: View {
    @StateObject private var model: WallpaperPresetsViewModel
    /// Called after a preset is applied, so the property rows reload the new values.
    private let onApply: () -> Void

    @State private var isNamingNewPreset = false
    @State private var newPresetName = ""
    @State private var renaming: WallpaperPreset?
    @State private var renameText = ""
    @State private var deleting: WallpaperPreset?
    @State private var applyingToAll: WallpaperPreset?
    @State private var applyToAllMode = WallpaperPresetBulkApply.Mode.uncustomizedOnly
    /// The outcome of Apply to All Wallpapers or a config.json import, shown until dismissed.
    @State private var resultMessage: String?

    init(wallpaper: WEWallpaper, scopes: [WallpaperPropertyScope], onApply: @escaping () -> Void) {
        _model = StateObject(wrappedValue: WallpaperPresetsViewModel(wallpaper: wallpaper, scopes: scopes))
        self.onApply = onApply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.presets.isEmpty {
                Text("No presets saved yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.presets) { preset in
                    presetRow(preset)
                }
            }
            HStack(spacing: 3) {
                Button {
                    newPresetName = ""
                    isNamingNewPreset = true
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down.fill")
                        .frame(maxWidth: .infinity)
                }
                .glassButtonStyle()
                .help("Save the current properties as a preset")
                Button {
                    importPreset()
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down.on.square")
                        .frame(maxWidth: .infinity)
                }
                .glassButtonStyle()
                .help("Import a preset file exported for this wallpaper")
                Menu {
                    Button {
                        model.pasteJSON()
                    } label: {
                        Label("Paste JSON", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        importWallpaperEngineConfig()
                    } label: {
                        Label("Import from Wallpaper Engine config.json…", systemImage: "square.and.arrow.down.on.square")
                    }
                } label: {
                    Label("More Preset Actions", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .sheet(item: $applyingToAll) { preset in
            applyToAllSheet(preset)
        }
        .alert("Your Presets", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(verbatim: resultMessage ?? "")
        }
        .alert("Save Preset", isPresented: $isNamingNewPreset) {
            TextField("Preset Name", text: $newPresetName)
            Button("Save") { model.saveCurrent(named: newPresetName) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Saves the current properties and scene edits. A preset with the same name is replaced.")
        }
        .alert("Rename Preset", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Preset Name", text: $renameText)
            Button("Rename") {
                if let renaming { model.rename(renaming, to: renameText) }
            }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Delete Preset", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let deleting { model.delete(deleting) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            if let deleting {
                Text("Do you want to delete the preset “\(deleting.name)”?")
            }
        }
        .alert("Preset Error", isPresented: Binding(get: { model.errorMessage != nil },
                                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(verbatim: model.errorMessage ?? "")
        }
    }

    private func presetRow(_ preset: WallpaperPreset) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: preset.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                if model.apply(preset) { onApply() }
            } label: {
                Label("Apply", systemImage: "checkmark.circle")
            }
            .glassButtonStyle()
            .help("Apply this preset's properties")
            Menu {
                Button {
                    renameText = preset.name
                    renaming = preset
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                Button {
                    exportPreset(preset)
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                Button {
                    shareJSON(preset)
                } label: {
                    Label("Share JSON…", systemImage: "square.and.arrow.up.on.square")
                }
                Button {
                    model.copyJSON(preset)
                } label: {
                    Label("Copy JSON", systemImage: "doc.on.doc")
                }
                Button {
                    applyToAllMode = .uncustomizedOnly
                    applyingToAll = preset
                } label: {
                    Label("Apply to All Wallpapers…", systemImage: "rectangle.stack")
                }
                Divider()
                Button(role: .destructive) {
                    deleting = preset
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Label("Preset Actions", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func exportPreset(_ preset: WallpaperPreset) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = model.suggestedFileName(for: preset)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.export(preset, to: url)
    }

    /// macOS's share sheet with the preset as a Share JSON file.
    private func shareJSON(_ preset: WallpaperPreset) {
        guard let file = model.shareJSONFile(preset), let window = NSApp.keyWindow, let view = window.contentView else { return }
        let point = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        NSSharingServicePicker(items: [file]).show(relativeTo: NSRect(origin: point, size: CGSize(width: 1, height: 1)),
                                                   of: view, preferredEdge: .minY)
    }

    private func applyToAllSheet(_ preset: WallpaperPreset) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Apply “\(preset.name)” to all wallpapers?")
                .font(.headline)
            Picker(selection: $applyToAllMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Only wallpapers you haven't customized")
                    Text("Wallpapers where you've changed settings or applied a preset keep them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(WallpaperPresetBulkApply.Mode.uncustomizedOnly)
                VStack(alignment: .leading, spacing: 2) {
                    Text("All wallpapers, replacing your customizations")
                    Text("Every wallpaper with matching settings uses this preset.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(WallpaperPresetBulkApply.Mode.replaceCustomizations)
            } label: {
                EmptyView()
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { applyingToAll = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    let mode = applyToAllMode
                    applyingToAll = nil
                    if let result = model.applyToAll(preset, mode: mode) {
                        resultMessage = String(localized: "Wallpapers changed: \(result.applied)",
                                               comment: "Result of applying a preset to all wallpapers; the number of wallpapers changed")
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func importWallpaperEngineConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose the config.json of a Wallpaper Engine install.",
                               comment: "Open panel message when importing presets from Wallpaper Engine")
        guard panel.runModal() == .OK, let url = panel.url,
              let summary = model.importWallpaperEngineConfig(at: url) else { return }
        resultMessage = String(localized: "Presets imported: \(summary.presets). Wallpapers: \(summary.wallpapers). Not installed: \(summary.notInstalled).",
                               comment: "Result of importing Wallpaper Engine's config.json: presets added, wallpapers they belong to, Workshop items not installed")
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importFile(at: url)
    }
}
