import SwiftUI
import AppKit

/// Import from an existing Steam install (Windows, CrossOver, Boot Camp): pick its Steam library
/// or a detected CrossOver bottle, check the items, and copy them into the Wallpaper Storage
/// folder. Steam's own copies stay where they are.
struct SteamLibraryImportView: View {
    @ObservedObject var model: SteamLibraryImportModel
    var showsDoneButton = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from a Steam Library")
                .font(.title2.bold())
            Text("Bring the Workshop wallpapers of Wallpaper Engine on Windows, in a CrossOver bottle or on a Boot Camp disk. Choose that Steam folder or its steamapps folder. The wallpapers are copied; application wallpapers and ones already in your library are skipped.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if !model.detectedLibraries.isEmpty {
                    Picker("Found", selection: Binding(
                        get: { model.library },
                        set: { if let url = $0 { model.open(url) } })) {
                        ForEach(model.detectedLibraries, id: \.self) { url in
                            Text(verbatim: Self.displayName(of: url)).tag(Optional(url))
                        }
                        if let library = model.library, !model.detectedLibraries.contains(library) {
                            Text(verbatim: library.path).tag(Optional(library))
                        }
                    }
                    .frame(maxWidth: 360)
                } else if let library = model.library {
                    Text(verbatim: library.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose Steam Folder…") { choose() }
            }
            content
            if showsDoneButton {
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .onAppear { model.detect() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Reading the Steam library…")
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .loaded, .copying:
            ImportChecklistView(checklist: model.checklist)
            HStack {
                if model.phase == .copying {
                    ProgressView().controlSize(.small)
                    Text("Copying…")
                } else if let result = model.result {
                    Text("Copied: \(result.copied.count). Already there: \(result.existing.count). Failed: \(result.failed.count).",
                         comment: "Result of copying wallpapers from a Steam library; each %lld is a number of items")
                        .font(.caption)
                        .foregroundStyle(result.failed.isEmpty ? Color.secondary : Color.red)
                }
                Spacer()
                Button("Copy Selected (\(model.checklist.selection.count))") { model.copySelected() }
                    .glassButtonStyle(.prominent)
                    .disabled(model.checklist.selection.isEmpty || model.phase == .copying)
            }
        }
    }

    /// "Bottle name › steamapps" for a CrossOver library.
    static func displayName(of steamapps: URL) -> String {
        let components = steamapps.pathComponents
        if let index = components.firstIndex(of: "Bottles"), index + 1 < components.count {
            return "CrossOver: \(components[index + 1])"
        }
        return steamapps.path
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = String(localized: "Choose a Steam folder or its steamapps folder.",
                               comment: "Open panel message; steamapps is a folder name")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.choose(url)
    }
}
