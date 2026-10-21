import SwiftUI

/// "Import Wallpaper Engine Folders…" with its status line and question, beside the favourites
/// import where Open Wallpaper Engine asks for Wallpaper Engine's assets (the setup assistant's
/// Assets step and Settings › Assets). Shown when the chosen Wallpaper Engine folder has its
/// `config.json`; when a folder is chosen it checks by itself and asks only if there is
/// something to add.
struct WallpaperEngineFoldersImportView: View {
    @ObservedObject var assets: WallpaperEngineAssetsService
    @StateObject private var model: WallpaperEngineFoldersImportModel

    init(assets: WallpaperEngineAssetsService, library: InstalledLibraryModel) {
        self.assets = assets
        _model = StateObject(wrappedValue: WallpaperEngineFoldersImportModel(assets: assets, library: library))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isSourceAvailable {
                HStack {
                    Button("Import Wallpaper Engine Folders…") {
                        Task { await model.check() }
                    }
                    .disabled(model.isChecking)
                    .help("Adds the folders you made in Wallpaper Engine's Installed tab to the Installed tab here. Nothing is removed or replaced.")
                    if model.isChecking {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                status
            }
            Text("Wallpaper Engine keeps its Installed folders in its config.json. They can be imported from a Wallpaper Engine folder chosen for the assets.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.refreshSource() }
        // A folder was just chosen for the assets.
        .onChange(of: assets.status.chosenFolder) { _, folder in
            model.refreshSource()
            if folder != nil { Task { await model.check() } }
        }
        .alert("Also import your Wallpaper Engine folders?", isPresented: $model.isAsking) {
            Button("Import") { model.importPending() }
            Button("Not Now", role: .cancel) { model.decline() }
        } message: {
            Text("Wallpaper Engine has folders, or wallpapers in them, that aren't in the Installed tab yet. They're added to your folders; nothing here is moved or removed.",
                 comment: "Message of the Also import your Wallpaper Engine folders? question")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .imported:
            Label {
                Text("Imported your Wallpaper Engine folders", comment: "Status after Wallpaper Engine's Installed folders were added to the Installed tab")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.callout)
        case .upToDate:
            Text("Your Wallpaper Engine folders are already in the Installed tab.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .noFolders:
            Text("Wallpaper Engine has no folders in its Installed tab.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.callout)
                .foregroundStyle(.red)
        case .idle, .checking, .asking:
            EmptyView()
        }
    }
}
