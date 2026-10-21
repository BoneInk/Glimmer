import SwiftUI

/// Import a Workshop collection: paste its link or number, check the items, download them with
/// SteamCMD (dependencies included), optionally into a playlist named after the collection.
/// Shown from the setup assistant, the Installed tab's Add menu and the Workshop tab.
struct WorkshopCollectionImportView: View {
    @ObservedObject var model: WorkshopItemsImportModel
    /// Shown as a sheet with its own Done button; inline in the setup assistant without.
    var showsDoneButton = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import a Workshop Collection")
                .font(.title2.bold())
            Text("Paste the link of a public Steam Workshop collection, or its number. Open Wallpaper Engine lists its items from Steam; the ones you check download with SteamCMD, with the items they need.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Collection Link or Number", text: $model.input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.loadCollection() } }
                Button("Load") { Task { await model.loadCollection() } }
                    .disabled(model.input.isEmpty || model.phase == .loading)
            }
            WorkshopItemsImportBody(model: model, showsPlaylistOption: true)
            if showsDoneButton {
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
    }
}

/// What a Workshop list import shows once it runs: progress, the checklist and the download.
struct WorkshopItemsImportBody: View {
    @ObservedObject var model: WorkshopItemsImportModel
    var showsPlaylistOption: Bool

    var body: some View {
        switch model.phase {
        case .idle, .noSubscriptions:
            EmptyView()
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Asking Steam…")
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .loaded:
            loaded
        }
    }

    @ViewBuilder
    private var loaded: some View {
        if let title = model.sourceTitle {
            Text(verbatim: title).font(.headline)
        }
        ImportChecklistView(checklist: model.checklist)
        if showsPlaylistOption {
            HStack {
                Toggle("Create a playlist", isOn: $model.createsPlaylist)
                TextField("Playlist Name", text: $model.playlistName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.createsPlaylist)
            }
        }
        HStack {
            if !model.canDownload {
                Label("Log in to Steam to download. You can do it in the Workshop tab or the setup assistant.",
                      systemImage: "person.badge.key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.queuedCount > 0 {
                Label("Queued. Downloads continue in the background; see the Downloads tab.",
                      systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Download Selected (\(model.checklist.selection.count))") { model.downloadSelected() }
                .glassButtonStyle(.prominent)
                .disabled(!model.canDownload || model.checklist.selection.isEmpty)
        }
    }
}
