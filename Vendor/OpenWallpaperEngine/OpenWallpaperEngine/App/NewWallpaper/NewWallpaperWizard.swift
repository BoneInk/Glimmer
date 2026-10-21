import AppKit
import SwiftUI
import OWEEditor
import OWESceneEditing

/// The library's New Wallpaper… (Wallpaper Engine's welcome page and template wizard,
/// `NewWallpaperSheet`): a sheet on the main window that makes the wallpaper in the Wallpaper
/// Storage folder, which the library then lists, and opens a new scene in the Wallpaper Editor.
extension AppDelegate {
    @objc func openNewWallpaperWizard() {
        guard let window = mainWindowController.window else { return }
        var sheet: NSWindow?
        let services = NewWallpaperServices(
            library: FileManager.default.wallpapersDirectory,
            templates: { NewWallpaperTemplates.templates() },
            copyFolder: { try ImportedFolderLinks.copyWithoutLinks(from: $0, to: $1) },
            importWallpapers: { urls in
                let sources = FolderImport.sources(in: urls)
                guard !sources.isEmpty else { return false }
                return !FolderImport.importWallpapers(sources, into: FileManager.default.wallpapersDirectory).imported.isEmpty
            },
            created: { [weak self] folder, isScene in self?.newWallpaperCreated(folder, isScene: isScene) })
        let view = NewWallpaperSheet(services: services) {
            guard let sheet else { return }
            window.endSheet(sheet)
        }
        let controller = NSHostingController(rootView: view.appAccentTint())
        let panel = NSWindow(contentViewController: controller)
        sheet = panel
        window.beginSheet(panel)
    }

    /// A wallpaper the sheet made: prepared as an imported one, and a scene opened for editing.
    private func newWallpaperCreated(_ folder: URL, isScene: Bool) {
        OWELog.info(.library, "New wallpaper \(folder.path)")
        DispatchQueue.global(qos: .utility).async { WallpaperPreparation.prepare(wallpaperDirectory: folder) }
        guard isScene else { return }
        do {
            let project = try WEProject.read(in: folder)
            showWallpaperEditor(for: WEWallpaper(using: project, where: folder))
        } catch {
            OWELog.error(.library, "Can't open the new wallpaper \(folder.path) in the Wallpaper Editor: \(error)")
        }
    }
}

/// WE's project templates: the assets cache's copy (`templates`), or a WE install's
/// `projects/templates` beside its `assets`.
enum NewWallpaperTemplates {
    static func templates(assets: URL? = WallpaperEngineAssets.directory, fileManager: FileManager = .default) -> [WallpaperTemplate] {
        guard let assets else { return [] }
        let folders = [assets.appending(path: WallpaperEngineAssetsCache.templatesFolder, directoryHint: .isDirectory),
                       assets.deletingLastPathComponent().appending(path: WallpaperEngineAssetsCache.installTemplatesPath,
                                                                   directoryHint: .isDirectory)]
        guard let folder = folders.first(where: { fileManager.fileExists(atPath: $0.path) }) else { return [] }
        return WallpaperTemplate.templates(in: folder, fileManager: fileManager)
    }
}
