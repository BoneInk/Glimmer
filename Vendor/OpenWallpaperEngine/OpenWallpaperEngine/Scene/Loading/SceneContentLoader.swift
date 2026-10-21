//
//  SceneContentLoader.swift
//  Open Wallpaper Engine
//
//  Loads Wallpaper Engine scene wallpapers and builds the content the Metal renderer draws.
//  Follows the same ViewModel pattern as VideoWallpaperViewModel.
//

import SwiftUI
import CoreText
import CryptoKit
import OWESceneEditing

class SceneContentLoader: ObservableObject {
    static func log(_ msg: String) {
        OWELog.info(.scene, msg)
    }

    /// High-volume per-asset/per-texture diagnostics; only surfaces at verbose log level.
    static func logDetail(_ msg: String) {
        OWELog.debug(.scene, msg)
    }

    @Published var currentWallpaper: WEWallpaper {
        willSet {
            if loadsInBackground { startLoad(from: newValue) } else { loadScene(from: newValue) }
        }
    }

    /// Loads run on the preparation pool (`startLoad`) instead of the calling thread. The app's
    /// instances load this way, so setting a wallpaper never blocks the main thread; tools and
    /// tests that want the scene at once load synchronously.
    let loadsInBackground: Bool
    /// Edits to read the scene with instead of the wallpaper's saved overlay (a depth map's still
    /// frame, `DepthMapSceneCapture`); nil reads the saved one.
    let overlayOverride: SceneEditOverlay?

    /// Guards the small state the main thread reads and writes (the revision, the settings, what
    /// the loaded scene declares), so the main thread never waits on a load or a content build
    /// holding `sceneLock`.
    let stateLock = NSLock()
    private var _metalRevision = 0
    var metalRevision: Int { stateLock.withLock { _metalRevision } }
    /// The settings `setRenderSettings` last gave; the next content build takes them.
    var pendingRenderSettings = SceneRenderSettings()
    var loadedTextureReductionSize: SIMD2<Float>?
    var loadedBindingTable = UserPropertyBindingTable()
    /// The Wallpaper Editor's overlay the loaded scene was read with; the editor's newer edits
    /// are drawn live against it (`SceneEditLiveValues`).
    var _loadedEditOverlay: SceneEditOverlay?
    var loadedEditOverlay: SceneEditOverlay? { stateLock.withLock { _loadedEditOverlay } }
    /// The newest load; an older one that finishes later is dropped.
    var loadGeneration = 0
    var loadJob: PreparationPool.Job?
    /// Guards `settings` (the resolved settings identity), which loads resolve off the main thread.
    let identityLock = NSLock()

    /// Every content invalidation must both bump the revision and tell SwiftUI, or `updateNSView`
    /// never runs and the renderer keeps drawing the previous wallpaper until some unrelated
    /// re-render happens to come along.
    func bumpRevision() {
        stateLock.withLock { _metalRevision &+= 1 }
        if Thread.isMainThread {
            objectWillChange.send()
        } else {
            DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
        }
    }

    /// Guards the parsed scene and its asset caches. `metalContent()` runs on a background queue,
    /// so it must not race a `loadScene` triggered from the main thread.
    let sceneLock = NSRecursiveLock()
    let contentQueue = DispatchQueue(label: "app.openwallpaperengine.scene-content", qos: .userInitiated)
    var cachedContent: SceneMetalContent?
    var cachedContentRevision = -1
    /// The user's quality settings the content is built for: `pendingRenderSettings` as the
    /// build in progress took them (under the scene lock).
    var renderSettings = SceneRenderSettings()
    /// The engine combos of the content being built, for every material plan built with it.
    var sceneEngineCombos = SceneEngineCombos()
    /// The content's model plans by `.mdl` and skin (`buildModels`), for script clones.
    var modelPlans: [String: SceneModelPlan] = [:]
    /// The factor the particle budget put on the scene's systems (`ParticleBudget`); systems
    /// scripts create later are thinned by it too.
    var particleBudgetScale: Float = 1
    /// The particles each object's systems hold as authored (`ParticleBudget.capacity`), by object
    /// id, as the last content build made them: an object rebuilt alone is thinned by the scene's
    /// factor while that stays the same.
    var particleCapacities: [Int: Int] = [:]
    /// Time spent planning particle materials (`buildParticleMaterial`) since the content build
    /// began, and the plans made, for its load log line.
    var particleMaterialPlanTime: (nanoseconds: UInt64, plans: Int) = (0, 0)
    /// The budget scaling last logged, so a rebuild of the same scene doesn't log it again.
    var loggedParticleBudget: (directory: URL, report: ParticleBudget.Report)?
    /// Retained for video wallpapers rendered through the scene pipeline.
    var videoStream: VideoTextureStream?
    /// The last video's range (`videoDynamicRange(of:)`), read once per file.
    var videoRangeByURL: (url: URL, range: VideoDynamicRange)?
    /// Scene images' video textures, which follow the wallpaper's playback (`setEmbeddedVideoRate`).
    let embeddedVideoStreams = NSHashTable<VideoTextureStream>.weakObjects()
    var embeddedVideoRate: Float = 1
    let embeddedVideoLock = NSLock()
    var builtVideoFrameSize: SIMD2<Float>?
    /// The cache entries the wallpaper on screen uses (its texture blobs and loading snapshots),
    /// which the cache expiry and Clear Caches keep (`CacheLeases`).
    let cacheLeases = CacheLeaseSet()

    /// Builds the render content off the main thread and delivers it on the main queue. While a
    /// load is in flight it delivers the previous content (nil at first); the load's commit bumps
    /// the revision, and the content is built again.
    func contentAsync(completion: @escaping (SceneMetalContent?) -> Void) {
        contentQueue.async { [weak self] in
            let content = self?.metalContent()
            DispatchQueue.main.async { completion(content) }
        }
    }

    var pkgParser: PKGParser?
    /// The `.pkg` `pkgParser` reads, which keys the sound cache's copies.
    var pkgURL: URL?
    var loadedScene: WEScene?
    /// The loaded scene.json and its parse signature (`ParsedScene`), which the scripts run from.
    var loadedDocument: (document: SceneJSON, signature: String)?
    /// The loaded wallpaper's project.json, which declares its user properties.
    var loadedProject: SceneJSON?
    /// Every user-property binding of the loaded scene and the documents its build read; every
    /// bound value the build decodes is resolved through it.
    var bindingTable: UserPropertyBindingTable { stateLock.withLock { loadedBindingTable } }
    /// Copies of a particle definition share its built parts within one build
    /// (`ParticleDefinitionCache`); false builds every copy in full (tests compare the two).
    var sharesParticleDefinitions = true
    /// The loaded scene has SceneScripts.
    var hasScriptSites = false
    var loadedWallpaperDirectory: URL?
    var assetDataCache: [String: Data] = [:]
    /// The Wallpaper Editor's documents (particle definitions and their materials,
    /// `SceneParticleOverlay`), by path, read in place of the wallpaper's and WE's files.
    var editorAssets: [String: Data] = [:]
    let editorAssetsLock = NSLock()
    /// Where the loaded wallpaper's settings are stored, and the directory it was resolved for.
    var settings: (directory: URL, settingsDirectory: URL, identity: WallpaperSettingsIdentity)?
    /// Whose user properties this instance runs with: every display's, or one display's
    /// (`WallpaperPropertyScope`, `WallpaperPropertyGroups`).
    let propertyScope: WallpaperPropertyScope
    /// Other Workshop items' assets (`…/workshop/<id>/…`), loose or inside the item's `.pkg`.
    var workshopAssets = WorkshopAssetResolver(roots: WorkshopAssetResolver.defaultRoots())
    /// WE's fixed copies of broken Workshop shaders (`assets/zcompat`).
    var shaderCompat: SceneShaderCompat?
    /// The loaded wallpaper's Workshop id, which bounds the zcompat fixes.
    var loadedProjectId: String?

    /// The textures decoded by the build in progress, so every layer, clone and effect that names
    /// the same file shares one image (and the renderer one upload). Emptied when the build ends:
    /// once the renderer uploaded them, the only copy of the pixels is on the GPU, and the next
    /// build loads the files again. Guarded by `sceneLock`, which every build holds.
    private var buildTextures: [String: SceneMetalTextureSource] = [:]

    /// Every screen showing the same wallpaper parses the identical PKG index and scene.json.
    /// PKGParser is immutable after init and WEScene is a value type, so both are safe to share.
    struct ParsedScene {
        let parser: PKGParser?
        let scene: WEScene
        let signature: String
        /// scene.json as `scene` was decoded from (the user's object edits applied), for scripts.
        let document: SceneJSON?
    }

    private static let parseCacheLock = NSLock()
    nonisolated(unsafe) private static var parseCache: [String: ParsedScene] = [:]

    static func cachedParse(for directory: URL, signature: String) -> ParsedScene? {
        parseCacheLock.lock()
        defer { parseCacheLock.unlock() }
        guard let entry = parseCache[directory.path], entry.signature == signature else { return nil }
        return entry
    }

    /// Forgets the shared parses, so the next load reads the scene cache or the source (tests).
    static func dropSharedParses() {
        parseCacheLock.lock()
        defer { parseCacheLock.unlock() }
        parseCache.removeAll()
    }

    static func storeParse(_ entry: ParsedScene, for directory: URL) {
        parseCacheLock.lock()
        defer { parseCacheLock.unlock() }
        // Deliberately tiny: every display showing one wallpaper shares a single entry, so this
        // only needs the current wallpaper plus one for switching back. A larger cap would pin
        // mapped PKG data across playlist rotation for no benefit.
        if parseCache.count >= 2, parseCache[directory.path] == nil {
            parseCache.removeAll(keepingCapacity: true)
        }
        parseCache[directory.path] = entry
    }

    func cachedTexture(_ key: String) -> SceneMetalTextureSource? {
        sceneLock.lock()
        defer { sceneLock.unlock() }
        return buildTextures[key]
    }

    func cacheTexture(_ source: SceneMetalTextureSource, for key: String) -> SceneMetalTextureSource {
        sceneLock.lock()
        defer { sceneLock.unlock() }
        buildTextures[key] = source
        return source
    }

    /// Ends a build: the content now holds the only CPU copies, which the renderer drops once uploaded.
    func endBuildTextures() {
        sceneLock.lock()
        defer { sceneLock.unlock() }
        buildTextures.removeAll()
    }
    /// Registers the text objects' fonts (`textFontLoader`); dropped with the wallpaper.
    var fontLoader: SceneTextFontLoader?

    /// `effectTranslator` translates and caches every shader variant the scene needs; the app's
    /// shared one (`defaultEffectTranslator`) unless a caller keeps its own cache (shader prewarm, tests).
    /// `loadsInBackground` starts the load on the preparation pool and returns at once
    /// (`startLoad`); otherwise the scene is loaded when init returns.
    init(wallpaper: WEWallpaper, propertyScope: WallpaperPropertyScope = .shared,
         effectTranslator: ShaderVariantTranslator? = SceneContentLoader.defaultEffectTranslator,
         loadsInBackground: Bool = false, overlay: SceneEditOverlay? = nil) {
        self.currentWallpaper = wallpaper
        overlayOverride = overlay
        self.propertyScope = propertyScope
        self.effectTranslator = effectTranslator
        self.loadsInBackground = loadsInBackground
        Self.log("init: wallpaper=\(wallpaper.project.title) dir=\(wallpaper.wallpaperDirectory.path)")
        if loadsInBackground { startLoad(from: wallpaper) } else { loadScene(from: wallpaper) }
    }

    deinit {
        loadJob?.cancel()
        // The built layer hands a strong reference to the renderer, so releasing this view model
        // is not enough on its own to silence the soundtrack.
        videoStream?.stop()
    }

    /// Both local and remote videos render through the one-layer video scene.
    static func isVideoType(_ type: String) -> Bool {
        let value = type.lowercased()
        return value == "video" || value == "remote-video"
    }

    /// Reloads the scene: in the background when this model loads there (`startLoad`), whose
    /// commit then bumps the revision.
    func reloadCurrentScene() {
        if loadsInBackground {
            startLoad(from: currentWallpaper, prepareDefaults: false)
        } else {
            loadScene(from: currentWallpaper, prepareDefaults: false)
        }
    }

    /// Drops the memoised scene content so the next build re-reads user properties that are
    /// consumed at build time, such as an authored effect's enabled flag.
    func invalidateContent() {
        bumpRevision()
    }

    /// The user's quality settings; a change rebuilds the content, whose engine combos follow them.
    /// The next build takes them, so this never waits on a build in progress.
    func setRenderSettings(_ settings: SceneRenderSettings) {
        let rebuild: Bool? = stateLock.withLock {
            guard settings != pendingRenderSettings else { return nil }
            // A video's HDR follows display HDR itself (`videoDynamicRange(of:)`).
            let rebuild = settings.contentKey != pendingRenderSettings.contentKey
                || (Self.isVideoType(currentWallpaper.project.type)
                    && (settings.postProcessing == .displayhdr) != (pendingRenderSettings.postProcessing == .displayhdr))
            pendingRenderSettings = settings
            return rebuild
        }
        // Settings applied per frame (reflection, the bloom gate, …) keep the content.
        if rebuild == true { bumpRevision() }
    }

    /// The loaded scene's size as WE's automatic texture resolution weighs it
    /// (`TextureReduction.orthographicSize(of:)`); nil for a perspective scene or none.
    var textureReductionSceneSize: SIMD2<Float>? {
        stateLock.withLock { loadedTextureReductionSize }
    }

    /// Shared by every scene: translated variants are cached in memory and on disk.
    /// Optional only for its callers' `guard let`s; it always exists.
    static let defaultEffectTranslator: ShaderVariantTranslator? =
        ShaderVariantTranslator(compiler: ShaderCompilerFactory.makeIsolated(qos: .userInitiated))
    /// This scene's translator (`init`).
    let effectTranslator: ShaderVariantTranslator?

    /// Key of this wallpaper instance's user properties in the script engine's store.
    var propertyStoreKey: String {
        // A Workshop preset item's store is keyed by the preset, not the base it plays from.
        let loaded = loadedWallpaperDirectory ?? currentWallpaper.wallpaperDirectory
        return propertyScope.runtimeKey(directory: loaded == currentWallpaper.wallpaperDirectory
                                        ? currentWallpaper.settingsDirectory : loaded)
    }

    /// This wallpaper's current value of a user property.
    func userProperty(_ name: String) -> String? {
        WallpaperServices.shared.userPropertyString(name, wallpaper: propertyStoreKey)
    }
}
