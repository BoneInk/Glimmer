import Foundation
import OWEEditor
import OWESceneEditing

/// What a headless edit session reads of one wallpaper: the scene as it ships, its project, the
/// effects and particle systems it can add, its files and WE's, its puppets, and the depth map
/// services. The Wallpaper Editor's window reads the same through the same app types
/// (`WallpaperEditorController`); tests give their own.
@MainActor
protocol SceneEditResources: AnyObject {
    /// The wallpaper's folder (a Workshop preset item's own), which messages and instances key by.
    var folder: URL { get }
    var identity: WallpaperSettingsIdentity { get }
    /// scene.json as it ships.
    var sceneData: Data { get }
    var projectJSON: Data? { get }
    /// The files the editor added for the wallpaper (imported images, copied effect files, depth maps).
    var assetStore: EditorAssetStore { get }
    var puppetAssets: PuppetEditorAssets { get }

    func effectCatalog(outline: SceneOutline) -> [EffectCatalogEntry]
    func effectSchema(_ file: String) -> EffectSchema?
    /// Copies a built-in effect's files into the edit files, as adding it in the editor does.
    func prepareEffect(_ entry: EffectCatalogEntry) throws
    /// A file of the wallpaper, else of WE's assets (particle definitions and materials).
    func readAsset(_ path: String) -> Data?
    func particleCatalog() -> ParticleCatalog
    /// The depth map section's services; nil where depth maps can't be made (tests).
    func depthMapServices() -> DepthMapEditorServices?
    /// The wallpaper's user-property stores, whose Wallpaper Editor draft a save saves too; nil
    /// leaves the properties out (tests).
    var propertyTargets: WallpaperPropertyTargets? { get }
}

extension SceneEditResources {
    var propertyTargets: WallpaperPropertyTargets? { nil }
}

/// A library wallpaper's resources, read as the Wallpaper Editor's window reads them.
@MainActor
final class WallpaperSceneEditResources: SceneEditResources {
    let wallpaper: WEWallpaper
    let identity: WallpaperSettingsIdentity
    let sceneData: Data
    let projectJSON: Data?
    let puppetAssets: PuppetEditorAssets
    private let resources: EditorWallpaperResources
    private let particles: WallpaperEditorParticleAssets
    private let labels: WallpaperEngineLabels
    private let depthMapGenerator: DepthMapGenerator?

    init(wallpaper: WEWallpaper, depthMapGenerator: DepthMapGenerator?) throws {
        self.wallpaper = wallpaper
        identity = WallpaperSettingsIdentity.resolve(directory: wallpaper.wallpaperDirectory)
        let source = try WallpaperEditorSource.read(wallpaper)
        sceneData = source.scene
        let projectURL = WEProject.url(in: wallpaper.wallpaperDirectory)
        do {
            projectJSON = try Data(contentsOf: projectURL)
        } catch {
            OWELog.error(.scene, "MCP: \(projectURL.path) can't be read; the wallpaper's user properties start empty: \(error)")
            projectJSON = nil
        }
        labels = WallpaperEngineLabels.load()
        resources = EditorWallpaperResources(wallpaper: wallpaper, package: source.package,
                                             assets: SceneEditOverlayFiles.assets(for: identity), labels: labels)
        particles = WallpaperEditorParticleAssets(wallpaper: wallpaper, package: source.package)
        puppetAssets = EditorPuppetAssets.make(for: wallpaper)
        self.depthMapGenerator = depthMapGenerator
    }

    var folder: URL { wallpaper.wallpaperDirectory }
    var assetStore: EditorAssetStore { resources.assets }
    var propertyTargets: WallpaperPropertyTargets? { WallpaperPropertyTargets(wallpaper: wallpaper, scopes: [.shared]) }

    func effectCatalog(outline: SceneOutline) -> [EffectCatalogEntry] { resources.effectCatalog(outline: outline) }
    func effectSchema(_ file: String) -> EffectSchema? { resources.effectSchema(file) }
    func prepareEffect(_ entry: EffectCatalogEntry) throws { try resources.prepareEffect(entry) }
    func readAsset(_ path: String) -> Data? { particles.data(path) }
    func particleCatalog() -> ParticleCatalog { particles.catalog(labels: labels) }

    func depthMapServices() -> DepthMapEditorServices? {
        // Without an app delegate (the editor's process, tests) there is no Settings to open.
        DepthMapPlugin.services(for: wallpaper, resources: resources, generator: depthMapGenerator, openPlugins: {})
    }
}
