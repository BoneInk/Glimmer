import SwiftUI
import AppKit

/// Settings › Assets: the Wallpaper Engine assets scenes need, from the user's own Steam copy,
/// SteamCMD, the Wallpaper Storage folder, the library folders, the Steam Web API key and the
/// Workshop block list. Shows which copy is in use
/// and installs, updates or removes it. Changes apply at once; the
/// window's OK and Cancel don't cover them.
struct AssetsPage: SettingsPage {
    var viewModel: GlobalSettingsViewModel
    @ObservedObject private var assets: WallpaperEngineAssetsService
    @ObservedObject private var steamCmd: SteamCmdService
    private let installer: SteamCmdInstaller
    private let editorPreviews: EditorPreviewPrewarm
    @State private var confirmsRemoval = false
    @State private var folderError: String?

    init(globalSettings: GlobalSettingsViewModel) {
        self.viewModel = globalSettings
        self.assets = AppDelegate.shared.assets
        self.steamCmd = AppDelegate.shared.contentViewModel.steamCmd
        self.installer = AppDelegate.shared.steamCmdInstaller
        self.editorPreviews = AppDelegate.shared.editorPreviewPrewarm
    }

    var body: some View {
        SettingsForm {
            Section {
                Text("Scenes need Wallpaper Engine assets from your Steam copy: built-in effects, shaders, materials and fonts. Video and web wallpapers play without them.")
                    .foregroundStyle(.secondary)
                statusRows
            } header: {
                Label("Wallpaper Engine Assets", systemImage: "shippingbox")
            }
            .settingsAnchor(SettingsAnchor.assets)

            Section {
                progress
                actions
            } footer: {
                Text("Downloads your Wallpaper Engine copy with SteamCMD, keeps only its assets and default wallpapers, and deletes the rest. Log in to Steam in the Workshop tab first.")
            }

            Section {
                WallpaperEngineFavoritesImportView(assets: assets, steamCmd: steamCmd)
            } header: {
                Label("Wallpaper Engine Favourites", systemImage: "heart")
            }
            .settingsAnchor(SettingsAnchor.weFavorites)

            Section {
                WallpaperEngineFoldersImportView(assets: assets, library: AppDelegate.shared.contentViewModel.library)
            } header: {
                Label("Wallpaper Engine Folders", systemImage: "folder")
            }

            SteamCmdSection(steamCmd: steamCmd, installer: installer)
                .settingsAnchor(SettingsAnchor.steamCmd)

            WallpaperStorageSection()
                .settingsAnchor(SettingsAnchor.storage)

            LibraryFoldersSection()
                .settingsAnchor(SettingsAnchor.libraryFolders)

            Section {
                SteamWebAPIKeyView()
            } header: {
                Label("Steam Web API Key", systemImage: "key")
            } footer: {
                Text("Needed to browse and search the Workshop. It is stored in your keychain and checked with Steam before saving. Without it, author names come from public Steam profiles.")
            }
            .settingsAnchor(SettingsAnchor.apiKey)

            WorkshopBlockListSection(blockList: AppDelegate.shared.contentViewModel.workshopBlockList)
                .settingsAnchor(SettingsAnchor.blockList)
        }
        .onAppear { assets.refresh() }
        .confirmationDialog("Remove the assets?", isPresented: $confirmsRemoval) {
            if assets.defaultWallpapers.isEmpty {
                Button("Remove Assets", role: .destructive) { assets.removeCache(includingDefaultWallpapers: false) }
            } else {
                Button("Remove Assets and Default Wallpapers", role: .destructive) {
                    assets.removeCache(includingDefaultWallpapers: true)
                }
                Button("Remove Assets Only", role: .destructive) { assets.removeCache(includingDefaultWallpapers: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scenes won't render until you install the assets again. Default wallpapers go to the Trash.")
        }
    }

    private var status: WallpaperEngineAssetsService.Status { assets.status }

    @ViewBuilder
    private var statusRows: some View {
        HStack {
            Text("Status")
            Spacer()
            if status.resolution != nil {
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("Missing", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        if let resolution = status.resolution {
            row("Source", Text(sourceName(resolution.source)))
            row("Location", Text(verbatim: resolution.directory.path).font(.caption.monospaced()))
        }
        if status.resolution?.source == .cache, let info = status.info {
            if let build = info.steamBuildID {
                row("Steam build", Text(verbatim: build))
            }
            row("Updated", Text(info.installedAt, format: .dateTime))
            if let size = status.cacheSize {
                row("Size", Text(size.formatted(.byteCount(style: .file))))
            }
        }
        if !assets.defaultWallpapers.isEmpty {
            row("Default wallpapers added", Text(assets.defaultWallpapers.count, format: .number))
        }
        if let free = status.freeSpace {
            row("Free space", Text(free.formatted(.byteCount(style: .file))))
        }
        EditorPreviewPrewarmRow(prewarm: editorPreviews)
    }

    private func sourceName(_ source: WallpaperEngineAssets.Source) -> LocalizedStringKey {
        switch source {
        case .chosenFolder, .testEnvironment: return "Chosen folder"
        case .cache: return status.info?.origin == .folder ? "Copied from a folder" : "Downloaded from Steam"
        }
    }

    @ViewBuilder
    private var progress: some View {
        AssetsInstallProgressView(assets: assets)
        if let folderError {
            Label(folderError, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private var actions: some View {
        HStack {
            if assets.isBusy {
                Button("Cancel") { assets.cancel() }
            } else {
                if steamCmd.steamCmdPath == nil {
                    // Installing from Steam needs SteamCMD first; offer it here.
                    SteamCmdSetupView(installer: installer)
                } else {
                    Button(status.info == nil ? "Install from Steam" : "Update from Steam") { assets.installFromSteam() }
                        .glassButtonStyle(.prominent)
                        .help("Downloads your Wallpaper Engine copy with SteamCMD and keeps only its assets and default wallpapers. Needs a Steam login that owns Wallpaper Engine.")
                    if status.info != nil {
                        Button("Re-download") { assets.installFromSteam(force: true) }
                            .help("Downloads the assets from Steam again even when they're up to date, to repair a damaged copy.")
                    }
                }
                Button("Choose Folder…") { chooseFolder() }
                    .help("Uses the assets of a Wallpaper Engine folder already on this Mac, read in place instead of downloaded.")
                if status.chosenFolder != nil {
                    Button("Stop Using Folder") { assets.forgetChosenFolder() }
                        .help("Stops reading assets from the chosen folder; downloaded assets are used if there are any. The folder itself isn't changed.")
                }
                if status.info != nil || status.resolution?.source == .cache {
                    Button("Remove…") { confirmsRemoval = true }
                        .help("Removes the downloaded assets, and optionally the default wallpapers, to free disk space. Scenes won't render until you install them again.")
                }
            }
            Spacer()
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: Text) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            value
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a Wallpaper Engine folder or its assets folder.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try assets.chooseFolder(url)
            folderError = nil
        } catch {
            folderError = error.localizedDescription
        }
    }
}

/// One line while the Wallpaper Editor's previews render in the background
/// (`EditorPreviewPrewarm`): how many are done, or that the run is paused; nothing otherwise.
private struct EditorPreviewPrewarmRow: View {
    @ObservedObject var prewarm: EditorPreviewPrewarm

    var body: some View {
        if let progress = prewarm.progress {
            HStack(alignment: .firstTextBaseline) {
                Text("Wallpaper Editor previews")
                Spacer()
                Group {
                    if progress.isPaused {
                        Text("Paused, \(progress.done) of \(progress.total)")
                    } else {
                        Text("Rendering, \(progress.done) of \(progress.total)")
                    }
                }
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .help("The previews of Add Effect and Add Particle System render in the background at low priority, so the browsers open at once. They wait while the Mac is on low battery or too hot.")
        }
    }
}
