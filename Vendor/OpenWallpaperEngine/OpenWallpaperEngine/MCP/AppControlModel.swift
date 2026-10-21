import AppKit
import Foundation
import OWEControlProtocol

/// The control channel's view of Open Wallpaper Engine: each request does what the app's own
/// controls do (the menu bar's Pause and Mute, the library's apply, the Details panel's
/// properties, a playlist's shortcut, Next and Previous Wallpaper, Import › From Folder, the
/// editors), through the same models.
@MainActor
final class AppControlModel: ControlAppModel {
    private unowned let app: AppDelegate
    private var wallpaperViewModel: WallpaperViewModel { app.wallpaperViewModel }
    private var contentViewModel: ContentViewModel { app.contentViewModel }

    init(app: AppDelegate) {
        self.app = app
    }

    // MARK: - Reading

    func displays() -> [ControlDisplay] {
        let main = String(CGMainDisplayID())
        return NSScreen.screens.map { screen in
            let id = WallpaperViewModel.screenId(for: screen)
            return ControlDisplay(id: id, name: WallpaperViewModel.screenName(for: screen), isMain: id == main,
                                  isEnabled: wallpaperViewModel.isScreenEnabled(id),
                                  width: Int(screen.frame.width), height: Int(screen.frame.height),
                                  scale: Double(screen.backingScaleFactor),
                                  rule: Self.ruleName(wallpaperViewModel.playback(onScreen: id)))
        }
    }

    func wallpapers() -> [ControlWallpaper] {
        contentViewModel.library.allWallpapers.filter { $0.project != .invalid }.map(control)
    }

    func wallpaper(onDisplay id: String) -> ControlWallpaper? {
        let wallpaper = wallpaperViewModel.wallpaper(for: id)
        guard wallpaper.project != .invalid else { return nil }
        return control(wallpaper)
    }

    func properties(of wallpaper: ControlWallpaper) -> [ControlUserProperty] {
        guard let found = find(wallpaper) else { return [] }
        let model = SceneUserPropertiesModel(wallpaper: found, scopes: scopes(of: found))
        let conditions = Self.conditions(of: found)
        return model.properties.map { property in
            ControlUserProperty(key: property.id, title: property.title, type: property.type,
                                value: model.values[property.id] ?? property.defaultValue,
                                defaultValue: property.defaultValue, minimum: property.minimum,
                                maximum: property.maximum, step: property.step, fraction: property.fraction,
                                editable: property.editable,
                                options: property.options.map { ControlUserProperty.Option(label: $0.title, value: $0.value) },
                                condition: conditions[property.id])
        }
    }

    var playback: ControlPlayback {
        ControlPlayback(paused: wallpaperViewModel.playRate == 0, volume: Double(wallpaperViewModel.playVolume),
                        stopped: wallpaperViewModel.isStopped)
    }

    func playlists() -> [ControlPlaylist] {
        let model = wallpaperViewModel
        return model.playlists.map { playlist in
            ControlPlaylist(id: playlist.id, name: playlist.name,
                            wallpapers: playlist.items.map { control($0.wallpaper) },
                            duration: playlist.duration, isActive: playlist.id == model.activePlaylistID,
                            isRotating: playlist.id == model.activePlaylistID && model.playlistEnabled,
                            shuffles: model.playlistShuffle, displays: playlist.displays ?? [])
        }
    }

    // MARK: - Changing

    func setWallpaper(_ wallpaper: ControlWallpaper, displays: [String]) throws {
        guard let found = find(wallpaper) else { throw Self.missing(wallpaper) }
        let type = found.project.type.lowercased()
        if !WallpaperViewModel.mayRunWithoutAsking(found) {
            // The library asks before a web wallpaper's first run, and again when its files change;
            // that stays the user's to answer.
            throw ControlError(.refused, "\"\(wallpaper.title)\" is a \(type) wallpaper that hasn't been trusted yet, or changed since. Apply it once in Open Wallpaper Engine and choose \"Don't ask again for this wallpaper\"; then it can be set from here.")
        }
        guard wallpaperViewModel.confirmApply?(found) ?? true else {
            throw ControlError(.refused, "\"\(wallpaper.title)\" wasn't applied: safe restart holds it back after it stopped the app.")
        }
        wallpaperViewModel.setWallpaper(found, for: Set(displays))
        if type == "web" { ChromiumFeatureAdvisor.shared.wallpaperApplied(found) }
    }

    func setPaused(_ paused: Bool) {
        if paused { app.pause() } else { app.resume() }
    }

    func stop() { app.stopWallpapers() }

    func setVolume(_ volume: Double) {
        wallpaperViewModel.playVolume = Float(volume)
    }

    func setMuted(_ muted: Bool) {
        if muted { app.mute() } else if wallpaperViewModel.playVolume == 0 { app.unmute() }
    }

    func setUserProperty(_ key: String, to value: String, of wallpaper: ControlWallpaper) -> [String] {
        guard let found = find(wallpaper) else { return [] }
        let scopes = scopes(of: found)
        // The Details panel's own model: applied to the running wallpapers at once, then saved.
        let model = SceneUserPropertiesModel(wallpaper: found, scopes: scopes)
        model.set(value, forID: key)
        // Saved before answering, so a get_wallpaper right after reads the new value.
        model.saveNow()
        return scopes.map(\.description)
    }

    func playPlaylist(_ playlist: ControlPlaylist, displays: [String]) {
        let model = wallpaperViewModel
        // As its shortcut starts it, on the displays asked for.
        if let index = model.playlists.firstIndex(where: { $0.id == playlist.id }), model.playlists[index].displays != displays.sorted() {
            model.playlists[index].displays = displays.sorted()
        }
        model.startPlaylist(id: playlist.id)
    }

    func step(forward: Bool, displays: [String]) -> [String: ControlWallpaper?] {
        let model = wallpaperViewModel
        let selection = model.selectedScreenIds
        model.selectedScreenIds = Set(displays)
        if forward {
            // Never one that would wait on the trust prompt, which no one may be there to answer.
            model.stepToNextWallpaper(shown: contentViewModel.library.autoRefreshWallpapers.filter { !WallpaperViewModel.needsTrust($0) })
        } else {
            model.stepToPreviousWallpaper()
        }
        model.selectedScreenIds = selection
        return Dictionary(uniqueKeysWithValues: displays.map { ($0, wallpaper(onDisplay: $0)) })
    }

    func importWallpapers(at url: URL) async throws -> ControlImportResult {
        let library = FileManager.default.wallpapersDirectory
        let outcome = await Task.detached(priority: .userInitiated) { () -> FolderImport.Outcome? in
            let sources = FolderImport.sources(in: [url])
            return sources.isEmpty ? nil : FolderImport.importWallpapers(sources, into: library)
        }.value
        guard let outcome else {
            throw ControlError(.notFound, "\(url.path) has no wallpaper: choose a wallpaper folder (with project.json), a folder of them, or a .zip.")
        }
        contentViewModel.refresh()
        let imported = outcome.imported.map { folder in
            InstalledLibrary.wallpaper(at: folder, hiding: []).map(control)
                ?? ControlWallpaper(id: folder.lastPathComponent, title: folder.lastPathComponent, type: "", tags: [],
                                    folder: folder, workshopID: nil, description: nil, contentRating: nil)
        }
        let skipped = outcome.skipped.map { skip -> (path: String, reason: String) in
            switch skip.reason {
            case .alreadyInLibrary: return (skip.source.path, "a wallpaper with this folder name is in the library already")
            case .copyFailed(let reason): return (skip.source.path, "couldn't be copied: \(reason)")
            case .noWallpaper: return (skip.source.path, "has no wallpaper in it")
            }
        }
        return ControlImportResult(imported: imported, skipped: skipped)
    }

    func openEditor(_ editor: ControlEditor, for wallpaper: ControlWallpaper) throws {
        guard let found = find(wallpaper) else { throw Self.missing(wallpaper) }
        switch editor {
        case .scene:
            app.showSceneInspector(for: found, scopes: scopes(of: found))
            NSApp.activate(ignoringOtherApps: true)
        case .wallpaper:
            guard WallpaperEditorController.canEdit(found) else {
                throw ControlError(.unsupported, "The Wallpaper Editor can't open \"\(wallpaper.title)\".")
            }
            app.showWallpaperEditor(for: found)
        }
    }

    func snapshot(display id: String) async throws -> ControlSnapshot {
        let shown = wallpaperViewModel.wallpaper(for: id)
        guard shown.project != .invalid else {
            throw ControlError(.unavailable, "Display \(id) shows no wallpaper.")
        }
        let screen = NSScreen.screens.first { WallpaperViewModel.screenId(for: $0) == id }
        let scale = screen?.backingScaleFactor ?? 2
        let pixelSize = SIMD2(Int((screen?.frame.width ?? 0) * scale), Int((screen?.frame.height ?? 0) * scale))
        let directory = shown.wallpaperDirectory
        let type = shown.project.type.lowercased()
        let media = shown.isRemoteMedia ? nil : shown.mediaURL
        let preview = shown.previewURL
        let picture = await Task.detached(priority: .userInitiated) {
            ControlSnapshotPicture.make(wallpaperDirectory: directory, type: type, mediaURL: media, previewURL: preview,
                                        pixelSize: pixelSize)
        }.value
        guard let picture else {
            throw ControlError(.unavailable, "There is no picture of \"\(shown.project.title)\" yet: it has no preview, and the scene hasn't been captured on this display.")
        }
        return ControlSnapshot(display: id, wallpaper: control(shown), source: picture.source.rawValue,
                               png: picture.png, width: picture.width, height: picture.height)
    }

    // MARK: - Helpers

    func control(_ wallpaper: WEWallpaper) -> ControlWallpaper {
        let folder = wallpaper.settingsDirectory
        let projectID = wallpaper.project.workshopid?.rawValue
        let folderName = folder.lastPathComponent
        let workshopID = (projectID?.allSatisfy(\.isNumber) == true ? projectID : nil)
            ?? (folderName.allSatisfy(\.isNumber) ? folderName : nil)
        return ControlWallpaper(id: folderName, title: wallpaper.project.title, type: wallpaper.project.type.lowercased(),
                                tags: contentViewModel.library.tags(of: wallpaper), folder: folder, workshopID: workshopID,
                                description: wallpaper.project.description, contentRating: wallpaper.project.contentrating)
    }

    /// The library's wallpaper a control result names; nil when it is no longer there.
    func find(_ wallpaper: ControlWallpaper) -> WEWallpaper? {
        let path = wallpaper.folder.standardizedFileURL.path
        return contentViewModel.library.allWallpapers.first { $0.settingsDirectory.standardizedFileURL.path == path }
            ?? wallpaperViewModel.wallpapers.values.first { $0.settingsDirectory.standardizedFileURL.path == path }
    }

    /// The property stores of the displays showing `wallpaper` (the shared one while synced, or
    /// when no display shows it), as the Details panel edits them.
    func scopes(of wallpaper: WEWallpaper) -> [WallpaperPropertyScope] {
        let model = wallpaperViewModel
        let path = wallpaper.settingsDirectory.standardizedFileURL.path
        var scopes: [WallpaperPropertyScope] = []
        for screen in model.wallpapers.keys.sorted()
        where model.wallpapers[screen]?.settingsDirectory.standardizedFileURL.path == path {
            let scope = model.propertyScope(for: screen)
            if !scopes.contains(scope) { scopes.append(scope) }
        }
        return scopes.isEmpty ? [.shared] : scopes
    }

    /// Each authored property's `condition` as written in project.json.
    private static func conditions(of wallpaper: WEWallpaper) -> [String: String] {
        // The panel's model read it a moment ago; no conditions without it.
        guard let root = try? WEProject.json(in: wallpaper.wallpaperDirectory) else { return [:] }
        var conditions: [String: String] = [:]
        for definition in UserPropertyDefinition.all(projectJSON: root) {
            if let condition = definition.condition { conditions[definition.key] = condition }
        }
        return conditions
    }

    private static func ruleName(_ playback: DisplayPlayback) -> String {
        switch playback {
        case .run: "run"
        case .mute: "mute"
        case .pause: "pause"
        case .stop: "stop"
        }
    }

    static func missing(_ wallpaper: ControlWallpaper) -> ControlError {
        ControlError(.notFound, "\"\(wallpaper.title)\" is no longer in the library.")
    }
}
