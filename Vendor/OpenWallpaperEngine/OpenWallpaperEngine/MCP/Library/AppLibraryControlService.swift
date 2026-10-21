import AppKit
import Foundation
import OWEControlProtocol
import OWEEditor

/// `LibraryControlService` for the running app: each change goes through what the app's own
/// control calls (the playlist sidebar and view, the library's heart and Unsubscribe, Display
/// Settings' Enabled switch, the Settings pages' bindings), so it saves and applies as they do.
@MainActor
final class AppLibraryControlService: LibraryControlService {
    private unowned let app: AppDelegate
    private let model: AppControlModel
    private var wallpaperViewModel: WallpaperViewModel { app.wallpaperViewModel }
    private var settingsViewModel: GlobalSettingsViewModel { app.globalSettingsViewModel }

    init(app: AppDelegate, model: AppControlModel) {
        self.app = app
        self.model = model
    }

    // MARK: - Playlists

    func createPlaylist(named name: String, wallpapers: [ControlWallpaper]) throws -> UUID {
        let found = try wallpapers.map(library)
        guard wallpaperViewModel.createPlaylist(named: name, wallpapers: found),
              let id = wallpaperViewModel.activePlaylistID else {
            throw ControlError(.failed, "The playlist \"\(name)\" wasn't created.")
        }
        return id
    }

    func changesWhenVideoEnds(playlist id: UUID) -> Bool {
        wallpaperViewModel.playlists.first { $0.id == id }?.changeWhenVideoEnds ?? false
    }

    func setDuration(_ seconds: Double, playlist id: UUID) throws {
        try requirePlaylist(id)
        wallpaperViewModel.setPlaylistDuration(seconds, playlistID: id)
    }

    func setChangesWhenVideoEnds(_ enabled: Bool, playlist id: UUID) throws {
        try requirePlaylist(id)
        wallpaperViewModel.setPlaylistChangeWhenVideoEnds(enabled, playlistID: id)
    }

    func playlistSettings(playlist id: UUID) -> ControlPlaylistSettings {
        wallpaperViewModel.playlists.first { $0.id == id }.map(ControlPlaylistSettings.init) ?? ControlPlaylistSettings()
    }

    func setPlaylistSettings(_ settings: ControlPlaylistSettings, playlist id: UUID) throws {
        try requirePlaylist(id)
        wallpaperViewModel.updatePlaylistSettings(id) { settings.apply(to: &$0) }
    }

    func add(_ wallpapers: [ControlWallpaper], toPlaylist id: UUID) throws {
        try requirePlaylist(id)
        wallpaperViewModel.addToPlaylist(try wallpapers.map(library), playlistID: id)
    }

    func remove(_ wallpapers: [ControlWallpaper], fromPlaylist id: UUID) throws {
        for wallpaper in wallpapers {
            wallpaperViewModel.removeFromPlaylist(itemID: try itemID(of: wallpaper, in: id), playlistID: id)
        }
    }

    func moveOnePlace(_ wallpaper: ControlWallpaper, by step: Int, inPlaylist id: UUID) throws {
        wallpaperViewModel.movePlaylistItem(itemID: try itemID(of: wallpaper, in: id), offset: step, playlistID: id)
    }

    func deletePlaylist(_ id: UUID) throws {
        guard let playlist = wallpaperViewModel.playlists.first(where: { $0.id == id }) else { throw Self.noPlaylist }
        wallpaperViewModel.deletePlaylist(playlist)
    }

    private func requirePlaylist(_ id: UUID) throws {
        guard wallpaperViewModel.playlists.contains(where: { $0.id == id }) else { throw Self.noPlaylist }
    }

    /// The playlist item showing `wallpaper` (items keep the wallpaper they were added with).
    private func itemID(of wallpaper: ControlWallpaper, in id: UUID) throws -> UUID {
        guard let playlist = wallpaperViewModel.playlists.first(where: { $0.id == id }) else { throw Self.noPlaylist }
        let path = wallpaper.folder.standardizedFileURL.path
        guard let item = playlist.items.first(where: { $0.wallpaper.settingsDirectory.standardizedFileURL.path == path }) else {
            throw ControlError(.notFound, "\"\(wallpaper.title)\" isn't in the playlist \"\(playlist.name)\".")
        }
        return item.id
    }

    private static let noPlaylist = ControlError(.notFound, "The playlist is no longer there. list_playlists lists them.")

    // MARK: - Wallpapers

    func isFavorite(_ wallpaper: ControlWallpaper) -> Bool {
        model.find(wallpaper).map { FavoritesStore.shared.contains($0) } ?? false
    }

    func setFavorite(_ favorite: Bool, for wallpaper: ControlWallpaper) throws {
        let found = try library(wallpaper)
        // The heart toggles; it is only pressed when the state differs.
        if FavoritesStore.shared.contains(found) != favorite { FavoritesStore.shared.toggle(found) }
    }

    func delete(_ wallpaper: ControlWallpaper, toTrash: Bool) async throws {
        let found = try library(wallpaper)
        let directory = found.wallpaperDirectory
        // The library lists the storage folder's wallpapers only; nothing else is ever deleted.
        let storage = FileManager.default.wallpapersDirectory.standardizedFileURL.path
        guard directory.standardizedFileURL.deletingLastPathComponent().path == storage else {
            throw ControlError(.refused, "\"\(wallpaper.title)\" isn't in the wallpaper storage folder, so it isn't deleted from here.")
        }
        // Unsubscribe's own steps: the folder, the library index and snapshots, the displays
        // showing it, and the Workshop dependencies nothing else uses.
        if let failure = await app.contentViewModel.library.deleteWallpapersNow(at: [directory], toTrash: toTrash,
                                                                           wallpaperViewModel: wallpaperViewModel) {
            throw ControlError(.failed, "\"\(wallpaper.title)\" couldn't be deleted: \(failure.failureReason ?? "unknown reason").")
        }
    }

    /// The library's wallpaper for a control result.
    private func library(_ wallpaper: ControlWallpaper) throws -> WEWallpaper {
        guard let found = model.find(wallpaper) else { throw AppControlModel.missing(wallpaper) }
        return found
    }

    // MARK: - Installed folders

    var installedFolders: InstalledFolderTree { app.contentViewModel.library.folders.tree }

    func changeInstalledFolders(_ change: (inout InstalledFolderTree) -> Void) {
        app.contentViewModel.library.folders.update(change)
    }

    func folderKey(of wallpaper: ControlWallpaper) -> String {
        model.find(wallpaper).map(FavoritesStore.key(for:)) ?? wallpaper.folder.standardizedFileURL.path
    }

    // MARK: - Displays

    func setDisplay(_ id: String, enabled: Bool) {
        guard wallpaperViewModel.isScreenEnabled(id) != enabled else { return }
        wallpaperViewModel.toggleScreen(id)
    }

    // MARK: - Settings

    func value(of setting: LibrarySetting) -> JSONValue {
        let settings = settingsViewModel.settings
        switch setting.key {
        case "other_application_focused": return .string(Self.name(settings.otherApplicationFocused))
        case "other_application_maximized": return .string(Self.name(settings.otherApplicationMaximized))
        case "other_application_fullscreen": return .string(Self.name(settings.otherApplicationFullscreen))
        case "other_application_playing_audio": return .string(Self.name(settings.otherApplicationPlayingAudio))
        case "display_asleep": return .string(Self.name(settings.displayAsleep))
        case "laptop_on_battery": return .string(Self.name(settings.laptopOnBattery))
        case "anti_aliasing": return .string(settings.antiAliasing.rawValue)
        case "post_processing": return .string(settings.postProcessing == .displayhdr ? "display_hdr" : settings.postProcessing.rawValue)
        case "texture_resolution": return .string(Self.snakeCase(settings.textureResolution.rawValue))
        case "scene_detail": return .string(Self.snakeCase(settings.sceneDetail.rawValue))
        case "render_resolution": return .string(Self.name(settings.renderResolution))
        case "upscaling": return .string(settings.upscaling.rawValue.lowercased())
        case "render_scale": return .string(String(settings.renderScale.rawValue.dropFirst("percent".count)))
        case "shadows": return .string(settings.shadows.rawValue)
        case "volumetrics": return .string(settings.volumetrics.rawValue)
        case "fps": return .number(settings.fps)
        case "quality_efficiency": return .number(Double(settings.qualityEfficiency))
        case "particle_budget": return .string(settings.particleBudget.rawValue)
        case "reflections": return .bool(settings.reflections)
        case "sync_properties_across_displays": return .bool(settings.syncPropertiesAcrossDisplays)
        case "video_framework": return .string(settings.videoFramework.rawValue)
        case "audio_output": return .bool(settings.audioOutput)
        case "reload_on_output_device_change": return .bool(settings.reloadWhenChangingOutputDevice)
        case "media_integration": return .bool(settings.mediaIntegration)
        case "optimise_textures": return .bool(settings.optimiseTextures)
        case "cheaper_shadows": return .bool(settings.cheaperShadows)
        case "web_standard_resolution": return .bool(settings.webStandardResolution)
        case "reduced_resolution_particles": return .bool(settings.reducedResolutionParticles)
        case "process_priority": return .string(Self.snakeCase(settings.processPiority.rawValue))
        case "pause_on_vram_exhausted": return .bool(settings.pauseOnVRAMExhausted)
        case "appearance": return .string(Self.snakeCase(settings.appearance.rawValue))
        case "adjust_menu_bar_tint": return .bool(settings.adjustMenuBarTint)
        case "wallpaper_placement": return .string(wallpaperViewModel.wallpaperPlacement.rawValue.lowercased())
        case "playlist_rotate": return .bool(wallpaperViewModel.playlistEnabled)
        case "playlist_shuffle": return .bool(wallpaperViewModel.playlistShuffle)
        case "playlist_repeat": return .bool(wallpaperViewModel.playlistRepeats)
        default: return .null
        }
    }

    func set(_ value: JSONValue, of setting: LibrarySetting) throws {
        let text = value.stringValue ?? ""
        let flag = value.boolValue ?? false
        let number = value.doubleValue ?? 0
        let viewModel = settingsViewModel
        switch setting.key {
        case "other_application_focused": viewModel.settings.otherApplicationFocused = try Self.playback(text)
        case "other_application_maximized": viewModel.settings.otherApplicationMaximized = try Self.playback(text)
        case "other_application_fullscreen": viewModel.settings.otherApplicationFullscreen = try Self.playback(text)
        case "other_application_playing_audio": viewModel.settings.otherApplicationPlayingAudio = try Self.playback(text)
        case "display_asleep": viewModel.settings.displayAsleep = try Self.playback(text)
        case "laptop_on_battery": viewModel.settings.laptopOnBattery = try Self.playback(text)
        case "quality_preset": viewModel.setQuality(try Self.preset(text))
        case "anti_aliasing": viewModel.settings.antiAliasing = try Self.choice(GSAntiAliasingQuality.self, text)
        case "post_processing":
            let quality = try Self.choice(GSPostProcessingQuality.self, text == "display_hdr" ? "displayhdr" : text)
            // Settings offers Display HDR only while a display can show it.
            guard quality != .displayhdr || DisplayHDRSupport.isAvailable() else {
                throw ControlError(.unsupported, "display_hdr needs a display that shows HDR; none is connected. Use ultra.")
            }
            viewModel.settings.postProcessing = quality
        case "texture_resolution": viewModel.settings.textureResolution = try Self.choice(GSTextureResolutionQuality.self, text)
        case "scene_detail": viewModel.settings.sceneDetail = try Self.choice(GSSceneDetail.self, text)
        case "render_resolution": viewModel.settings.renderResolution = try Self.renderResolution(text)
        case "upscaling": viewModel.settings.upscaling = try Self.choice(GSUpscaling.self, text)
        case "render_scale": viewModel.settings.renderScale = try Self.choice(GSRenderScale.self, "percent" + text)
        case "shadows": viewModel.settings.shadows = try Self.choice(GSLightingQuality.self, text)
        case "volumetrics": viewModel.settings.volumetrics = try Self.choice(GSLightingQuality.self, text)
        case "fps":
            // The FPS slider's binding: a rate set by hand wins over the efficiency stop's cap.
            viewModel.settings.fps = number
            viewModel.settings.fpsSetByUser = true
        case "quality_efficiency": viewModel.settings.qualityEfficiency = QualityEfficiency(stop: Int(number.rounded())).stop
        case "particle_budget": viewModel.settings.particleBudget = try Self.choice(GSParticleBudget.self, text)
        case "reflections": viewModel.settings.reflections = flag
        case "sync_properties_across_displays": viewModel.settings.syncPropertiesAcrossDisplays = flag
        case "video_framework": viewModel.settings.videoFramework = try Self.choice(GSVideoFramework.self, text)
        case "audio_output": viewModel.settings.audioOutput = flag
        case "reload_on_output_device_change": viewModel.settings.reloadWhenChangingOutputDevice = flag
        case "media_integration": viewModel.settings.mediaIntegration = flag
        case "optimise_textures": viewModel.settings.optimiseTextures = flag
        case "cheaper_shadows": viewModel.settings.cheaperShadows = flag
        case "web_standard_resolution": viewModel.settings.webStandardResolution = flag
        case "reduced_resolution_particles": viewModel.settings.reducedResolutionParticles = flag
        case "process_priority": viewModel.settings.processPiority = try Self.choice(GSProcessPiority.self, text)
        case "pause_on_vram_exhausted": viewModel.settings.pauseOnVRAMExhausted = flag
        case "appearance": viewModel.settings.appearance = try Self.choice(GSAppearance.self, text)
        case "adjust_menu_bar_tint": viewModel.settings.adjustMenuBarTint = flag
        case "wallpaper_placement":
            guard let placement = WallpaperPlacement.allCases.first(where: { $0.rawValue.lowercased() == text }) else {
                throw Self.unknownValue(setting, text)
            }
            wallpaperViewModel.wallpaperPlacement = placement
        case "playlist_rotate": wallpaperViewModel.playlistEnabled = flag
        case "playlist_shuffle": wallpaperViewModel.playlistShuffle = flag
        case "playlist_repeat": wallpaperViewModel.playlistRepeats = flag
        default:
            throw ControlError(.notFound, "There is no setting \"\(setting.key)\".")
        }
        OWELog.info(.settings, "MCP: set \(setting.key)")
    }

    /// A choice as `settings_get` writes it: the enum's case in snake_case.
    private static func snakeCase(_ name: String) -> String {
        var result = ""
        for character in name {
            if character.isUppercase {
                if !result.isEmpty { result += "_" }
                result += character.lowercased()
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// The enum case whose snake_case name is `text`.
    private static func choice<Value: RawRepresentable & CaseIterable>(_ type: Value.Type, _ text: String) throws -> Value
        where Value.RawValue == String {
        guard let value = Value.allCases.first(where: {
            snakeCase($0.rawValue) == text || $0.rawValue.lowercased() == text
        }) else {
            throw ControlError(.invalidParams, "\"\(text)\" isn't one of the setting's values.")
        }
        return value
    }

    private static func name(_ playback: GSPlayback) -> String { snakeCase(playback.rawValue) }

    /// `render_resolution`'s names: `your_display`, `uhd4k`, `full`.
    static func name(_ resolution: GSRenderResolution) -> String {
        switch resolution {
        case .yourDisplay: return "your_display"
        case .uhd4K: return "uhd4k"
        case .full: return "full"
        }
    }

    /// A `render_resolution` name (`LibrarySetting` maps the earlier ones to these).
    static func renderResolution(_ text: String) throws -> GSRenderResolution {
        guard let resolution = GSRenderResolution.allCases.first(where: { name($0) == text }) else {
            throw ControlError(.invalidParams, "\"\(text)\" isn't one of render_resolution's values.")
        }
        return resolution
    }

    private static func playback(_ text: String) throws -> GSPlayback { try choice(GSPlayback.self, text) }

    private static func preset(_ text: String) throws -> GSQuality {
        switch text {
        case "low": return .low
        case "medium": return .medium
        case "high": return .high
        case "ultra": return .ultra
        default: throw ControlError(.invalidParams, "quality_preset takes low, medium, high or ultra.")
        }
    }

    private static func unknownValue(_ setting: LibrarySetting, _ text: String) -> ControlError {
        ControlError(.invalidParams, "\"\(text)\" isn't one of \(setting.key)'s values.")
    }

    // MARK: - Caches

    func cacheSizes() async -> [ControlCacheSize] {
        await Task.detached(priority: .utility) {
            let own = CacheSweeper(folders: CacheFolder.current).sizes()
            let sizes = CacheFolder.ID.allCases.compactMap { id in own[id].map { ControlCacheSize(id: id.mcpName, bytes: $0) } }
            return sizes + [ControlCacheSize(id: "metal_shader_cache", bytes: MetalShaderCache.current?.allocatedSize() ?? 0)]
        }.value
    }

    func clearCaches() async -> ControlCacheClearResult {
        let result = await CacheMaintenance.clearAll()
        return ControlCacheClearResult(removedEntries: result.removed.removedFiles, removedBytes: result.removed.removedBytes,
                                       metalCacheResetRequested: result.metalCacheResetRequested)
    }

    // MARK: - Plugins

    func plugins() -> [ControlPluginStatus] {
        let mcp = app.mcpServerPlugin
        let depthRoot = DepthMapPluginInstaller.defaultRoot
        let depthVersion = DepthMapPluginLayout.activeModel(in: depthRoot)?.version
        let chromiumRoot = ChromiumEngineInstaller.defaultRoot
        let chromiumPin = ChromiumEnginePin.current()
        let chromiumVersion = VersionedInstallState.read(in: chromiumRoot).active.flatMap { active in
            ChromiumEnginePackage.manifest(in: chromiumRoot.appending(path: active)) == nil ? nil : active
        }
        return [
            ControlPluginStatus(id: "screen_saver", name: "Screen Saver", installed: ScreenSaverInstaller.current.isInstalled,
                                enabled: settingsViewModel.settings.screenSaver, version: nil, updateAvailable: false,
                                detail: nil),
            ControlPluginStatus(id: "chromium_engine", name: "Chromium web engine", installed: chromiumVersion != nil,
                                enabled: nil, version: chromiumVersion,
                                updateAvailable: chromiumVersion != nil && chromiumPin != nil && chromiumVersion != chromiumPin?.version,
                                detail: chromiumPin == nil ? "Not available for this Mac." : nil),
            ControlPluginStatus(id: "depth_map_generation", name: "Depth Map Generation", installed: depthVersion != nil,
                                enabled: nil, version: depthVersion,
                                updateAvailable: depthVersion != nil && depthVersion != DepthMapModelPin.pinned.version,
                                detail: nil),
            ControlPluginStatus(id: "mcp_server", name: "MCP Server", installed: mcp.isInstalled, enabled: nil,
                                version: mcp.isInstalled ? mcp.layout.manifest.version : nil, updateAvailable: false,
                                detail: mcp.serverError),
        ]
    }
}
