import SwiftUI

/// "Import Wallpaper Engine Favourites…" with its status line and question, where Open Wallpaper
/// Engine asks for Wallpaper Engine's assets (the setup assistant's Assets step and Settings ›
/// Assets). When the assets arrive (an install from Steam finishes or a folder is chosen) it checks
/// Steam by itself and asks only if there are new favourites.
struct WallpaperEngineFavoritesImportView: View {
    @ObservedObject var assets: WallpaperEngineAssetsService
    @StateObject private var model: WallpaperEngineFavoritesImportModel

    init(assets: WallpaperEngineAssetsService, steamCmd: SteamCmdService) {
        self.assets = assets
        _model = StateObject(wrappedValue: WallpaperEngineFavoritesImportModel(steamCmd: steamCmd, assets: assets))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isSourceAvailable {
                HStack {
                    Button("Import Wallpaper Engine Favourites…") {
                        Task { await model.check() }
                    }
                    .disabled(model.isChecking)
                    .help("Adds the wallpapers you favourited in Wallpaper Engine to My Favourites. Nothing is removed.")
                    if model.isChecking {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                status
            }
            Text("Wallpaper Engine keeps favourites in your Steam account, not in its folder. Importing them needs a Steam Web API key and a Steam login, or a Wallpaper Engine folder inside a Steam folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.refreshSource() }
        // The assets were just requested: a folder was chosen, or an install from Steam ended.
        .onChange(of: assets.status.chosenFolder) { _, folder in
            model.refreshSource()
            if folder != nil { Task { await model.check() } }
        }
        .onChange(of: assets.isBusy) { wasBusy, isBusy in
            guard wasBusy, !isBusy, assets.phase == .idle, assets.status.resolution != nil else { return }
            Task { await model.check() }
        }
        .alert("Also import your Wallpaper Engine favourites?", isPresented: $model.isAsking) {
            Button("Import") { model.importPending() }
            Button("Not Now", role: .cancel) { model.decline() }
        } message: {
            if case .asking(let count) = model.phase {
                Text("\(count) wallpapers you favourited in Wallpaper Engine aren't in My Favourites yet. They're added; your current favourites stay.",
                     comment: "%lld is the number of new favourites found in the user's Steam account; message of the Also import your Wallpaper Engine favourites? question")
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .imported(let count):
            Label {
                Text("Imported \(count) favourites", comment: "%lld is the number of favourites added to My Favourites")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.callout)
        case .upToDate:
            Text("Your Wallpaper Engine favourites are already in My Favourites.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .noFavorites:
            Text("Steam returned no Wallpaper Engine favourites for this account.")
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
