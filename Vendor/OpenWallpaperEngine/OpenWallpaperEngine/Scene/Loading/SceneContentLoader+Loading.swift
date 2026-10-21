//
//  SceneContentLoader+Loading.swift
//  Open Wallpaper Engine
//
//  Reading a wallpaper's scene and building its render content (`metalContent`).
//

import SwiftUI
import CoreText
import CryptoKit
import OWESceneEditing

extension SceneContentLoader {
    // MARK: - Scene Loading

    /// What reading a wallpaper's scene yields, before it becomes the loaded scene (`commit`).
    private struct SceneRead {
        let wallpaper: WEWallpaper
        /// The parse's identity: the scene cache key's name (the files, edits, properties,
        /// displays and settings it was read for).
        let signature: String
        let hasPackage: Bool
        var parser: PKGParser?
        var scene: WEScene?
        var document: SceneJSON?
        var project: SceneJSON?
        var source = "parsed"
        var bindingTable = UserPropertyBindingTable()
        var hasScriptSites = false
        /// The editor overlay the scene was read with.
        var overlay: SceneEditOverlay?
        /// The editor overlay's documents the load was read with.
        var editorAssets: [String: Data] = [:]
    }

    /// Loads `wallpaper` on the calling thread; the scene is loaded when it returns. The app loads
    /// through `startLoad` instead, off the main thread.
    func loadScene(from wallpaper: WEWallpaper, prepareDefaults: Bool = true) {
        let generation = supersedeLoads()
        guard let read = readScene(wallpaper, isCurrent: { true }) else { return }
        commit(read, generation: generation, prepareDefaults: prepareDefaults)
    }

    /// Starts loading `wallpaper` on the preparation pool and returns at once: the key, the cache
    /// read or the parse, and the commit all run there, and the main thread only sees the new
    /// revision (`objectWillChange`). A newer load (a quick switch, a reload) cancels this one.
    func startLoad(from wallpaper: WEWallpaper, prepareDefaults: Bool = true) {
        let generation = supersedeLoads()
        let job = Self.loadPool.submit(priority: .settingWallpaper, estimatedBytes: 64 << 20) { [weak self] job in
            guard let self else { return }
            defer { self.stateLock.withLock { if self.loadGeneration == generation { self.loadJob = nil } } }
            let isCurrent = { !job.isCancelled && self.isCurrentLoad(generation) }
            guard isCurrent(), let read = self.readScene(wallpaper, isCurrent: isCurrent) else { return }
            self.commit(read, generation: generation, prepareDefaults: prepareDefaults)
        }
        stateLock.withLock { if loadGeneration == generation, !job.isCancelled { loadJob = job } }
    }

    /// The pool background loads run on (tests swap it).
    nonisolated(unsafe) static var loadPool = PreparationPool.shared

    /// A load started by `startLoad` has not committed yet.
    var isLoading: Bool { stateLock.withLock { loadJob != nil } }

    /// Starts a new load generation, cancelling the load in flight; returns the new generation.
    private func supersedeLoads() -> Int {
        stateLock.withLock {
            loadGeneration &+= 1
            loadJob?.cancel()
            loadJob = nil
            return loadGeneration
        }
    }

    private func isCurrentLoad(_ generation: Int) -> Bool {
        stateLock.withLock { loadGeneration == generation }
    }

    /// Reads `wallpaper`'s scene: the in-memory parse, else the scene file itself. Touches no loaded state, so
    /// it runs without the scene lock; nil when `isCurrent` says a newer load took over.
    private func readScene(_ wallpaper: WEWallpaper, isCurrent: () -> Bool) -> SceneRead? {
        OWEPhaseTiming.measure(.sceneLoad) { readSceneUntimed(wallpaper, isCurrent: isCurrent) }
    }

    private func readSceneUntimed(_ wallpaper: WEWallpaper, isCurrent: () -> Bool) -> SceneRead? {
        let signpost = OWESignpost.begin(OWESignpost.scene, "loadScene")
        defer { signpost.end() }
        OWEFrameMetrics.countSceneReload()
        // Symlink in any already-installed cross-workshop-item asset dependencies before parsing,
        // so paths like "effects/workshop/<id>/name/effect.json" resolve as ordinary loose files.
        WorkshopDependencyResolver.linkInstalledDependencies(for: wallpaper)
        let dir = wallpaper.wallpaperDirectory
        cacheLeases.hold(SceneLoadingSnapshotStore.current.folder(for: dir), scope: dir)
        let sceneFile = wallpaper.project.file  // e.g. "scene.json" or "gifscene.json"
        let settingsKey = settingsIdentity(for: dir, settingsDirectory: wallpaper.settingsDirectory)
            .key(.userProperties, scope: propertyScope)

        // Derive PKG name from scene file: "scene.json" → "scene.pkg", "gifscene.json" → "gifscene.pkg"
        let pkgURL = dir.appending(path: (sceneFile as NSString).deletingPathExtension + ".pkg")
        let looseSceneURL = dir.appending(path: sceneFile)
        let hasPackage = FileManager.default.fileExists(atPath: pkgURL.path(percentEncoded: false))

        // The in-memory parse's key: it covers every file of the wallpaper, the scene file the
        // project names, the edits baked into the parse, and what it is built for.
        let request = preparationRequest(for: wallpaper, settingsKey: settingsKey)
        let key = request.key
        guard isCurrent() else { return nil }
        var read = SceneRead(wallpaper: wallpaper, signature: key.name + "|" + sceneFile, hasPackage: hasPackage)
        read.overlay = request.overlay
        read.editorAssets = request.overlay?.editorFileData() ?? [:]
        if let cached = Self.cachedParse(for: dir, signature: read.signature) {
            read.parser = cached.parser
            read.scene = cached.scene
            read.document = cached.document
            read.source = "shared parse"
        } else if hasPackage {
            do {
                let parser = try PKGParser(url: pkgURL)
                read.parser = parser
                if let data = parser.extractFile(named: sceneFile) {
                    (read.scene, read.document) = try decodeScene(data, request: request)
                }
            } catch {
                Self.log("Failed to parse PKG: \(error)")
            }
        } else if FileManager.default.fileExists(atPath: looseSceneURL.path(percentEncoded: false)) {
            // Loose files (no .pkg)
            do {
                if let data = try AssetPathResolver.data(sceneFile, in: dir) {
                    (read.scene, read.document) = try decodeScene(data, request: request)
                } else {
                    Self.log("Loose \(sceneFile) is not a usable file inside the wallpaper folder")
                }
            } catch {
                Self.log("Failed to parse loose \(sceneFile): \(error)")
            }
        }
        guard isCurrent() else { return nil }
        if let scene = read.scene {
            Self.storeParse(ParsedScene(parser: read.parser, scene: scene, signature: read.signature,
                                        document: read.document), for: dir)
        }
        if let document = read.document {
            read.bindingTable.record(.scene, json: document)
            read.hasScriptSites = !SceneScriptSiteBuilder(wallpaperID: "").sites(in: document).isEmpty
        }
        read.project = Self.project(in: dir)
        return read
    }

    /// Makes `read` the loaded scene, unless a newer load superseded it; short, under the scene lock.
    private func commit(_ read: SceneRead, generation: Int, prepareDefaults: Bool) {
        sceneLock.lock()
        defer { sceneLock.unlock() }
        guard isCurrentLoad(generation) else { return }
        let wallpaper = read.wallpaper
        let dir = wallpaper.wallpaperDirectory

        // Re-parsing the same wallpaper (a settings change) must keep decoded textures and fonts;
        // only a different wallpaper invalidates them. Textures are shared process-wide and keyed
        // per wallpaper, so they survive switches and are reclaimed by NSCache under pressure.
        if loadedWallpaperDirectory != dir {
            assetDataCache.removeAll(keepingCapacity: true)
            fontLoader = nil
            // Otherwise a stale stream either keeps playing the previous video's audio after
            // switching to a non-video wallpaper, or gets reused verbatim for a different video.
            videoStream?.stop()
            videoStream = nil
            builtVideoFrameSize = nil
            workshopAssets = WorkshopAssetResolver(roots: WorkshopAssetResolver.defaultRoots())
            shaderCompat = SceneShaderCompat(assetsDirectory: WallpaperEngineAssets.directory)
            loadedProjectId = Self.workshopId(of: wallpaper)
        }
        pkgParser = read.parser
        pkgURL = dir.appending(path: (wallpaper.project.file as NSString).deletingPathExtension + ".pkg")

        guard let scene = read.scene else {
            // A video or web wallpaper legitimately has no scene; only a scene wallpaper missing
            // one is a real failure, and treating both as errors buries the genuine case.
            let type = wallpaper.project.type.lowercased()
            if type.isEmpty || type == "scene" {
                OWELog.error(.scene, "No scene data found")
            } else {
                Self.logDetail("No scene data for \(type) wallpaper; handled by its own renderer")
                // Otherwise metalContent()'s memoization still sees the old revision and keeps
                // serving the previous wallpaper's content until something else bumps it.
                loadedWallpaperDirectory = dir
                bumpRevision()
            }
            return
        }
        if prepareDefaults {
            prepareSceneUserPropertyDefaults(for: wallpaper, scene: scene)
        }
        Self.log("Scene loaded: \(scene.objects.count) objects from \(wallpaper.project.file) [\(read.source)]")
        if !read.hasPackage {
            WallpaperPackageConverter.markVerified(wallpaperDirectory: dir, objectCount: scene.objects.count)
        }
        setEditorAssets(read.editorAssets)
        loadedScene = scene
        loadedDocument = read.document.map { ($0, "\(dir.path)|\(read.signature)") }
        loadedProject = read.project
        hasScriptSites = read.hasScriptSites
        loadedWallpaperDirectory = dir
        stateLock.withLock {
            loadedBindingTable = read.bindingTable
            _loadedEditOverlay = read.overlay
            loadedTextureReductionSize = TextureReduction.orthographicSize(of: scene)
        }
        bumpRevision()
    }

    /// What preparing `wallpaper` reads, as the scene cache key covers it.
    private func preparationRequest(for wallpaper: WEWallpaper, settingsKey: String) -> ScenePreparation.Request {
        let stored = UserDefaults.app.dictionary(forKey: settingsKey) as? [String: String] ?? [:]
        let split = ScenePreparation.split(storedValues: stored)
        let dir = wallpaper.wallpaperDirectory
        let settings = stateLock.withLock { pendingRenderSettings }
        return ScenePreparation.Request(directory: dir, sceneFile: wallpaper.project.file,
                                        edits: split.edits, userProperties: split.properties,
                                        settings: String(describing: settings.contentKey),
                                        displays: SceneCacheKey.Display.connected(),
                                        overlay: overlayOverride ?? editOverlay(for: settingsIdentity(for: dir)))
    }

    /// The Wallpaper Editor's overlay the scene is read with: its draft for the editor's canvas
    /// (`WallpaperPropertyScope.editorDraft`), the saved one anywhere else.
    private func editOverlay(for identity: WallpaperSettingsIdentity) -> SceneEditOverlay? {
        if SceneBackendRuntimeContext.isActive { return nil }
        return propertyScope == .editorDraft ? SceneEditOverlayFiles.editedOverlay(for: identity) : SceneEditOverlayFiles.overlay(for: identity)
    }

    /// The scene and the document it was decoded from (for the scripts; nil when it isn't JSON the
    /// tolerant reader takes).
    private func decodeScene(_ data: Data, request: ScenePreparation.Request) throws -> (WEScene, SceneJSON?) {
        let resolved = try ScenePreparation.resolvedScene(data, edits: request.edits, overlay: request.overlay)
        return (try JSONDecoder().decode(WEScene.self, from: resolved), Self.document(resolved))
    }

    private static func document(_ data: Data) -> SceneJSON? {
        do {
            return try SceneScriptSiteBuilder.document(from: data)
        } catch {
            OWELog.error(.script, "scene.json can't be read for its scripts: \(error)")
            return nil
        }
    }

    /// project.json as JSON; nil (logged) when it can't be read.
    private static func project(in directory: URL) -> SceneJSON? {
        let url = WEProject.url(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try decodeTolerant(SceneJSON.self, from: Data(contentsOf: url))
        } catch {
            OWELog.error(.scene, "Can't read \(url.path): \(error)")
            return nil
        }
    }

    /// What changing user properties `keys` needs (`SceneBindingUpdate`), from the bindings the
    /// loaded scene and the documents its build read declare.
    func bindingUpdate(for keys: [String]) -> SceneBindingUpdate {
        SceneBindingUpdate(keys: keys, table: bindingTable)
    }

    /// How much of the whole scene a change of `keys` invalidates: only the app's own keys and
    /// scene-wide structural bindings rebuild it (`bindingUpdate(for:)`).
    func impact(of keys: [String]) -> SceneChangeImpact {
        bindingUpdate(for: keys).impact
    }

    /// The settings identity of the wallpaper played from `directory`, resolved (and old path keys
    /// moved) once per load. A Workshop preset item plays from its base's folder but keeps its
    /// settings under its own (`settingsDirectory`); later calls with only `directory` get the same.
    func settingsIdentity(for directory: URL, settingsDirectory: URL? = nil) -> WallpaperSettingsIdentity {
        identityLock.lock()
        defer { identityLock.unlock() }
        if let settings, settings.directory == directory,
           settingsDirectory == nil || settings.settingsDirectory == settingsDirectory { return settings.identity }
        let identity = WallpaperSettingsIdentity.resolve(directory: settingsDirectory ?? directory)
        identity.seed(propertyScope)
        settings = (directory, settingsDirectory ?? directory, identity)
        return identity
    }

    private func prepareSceneUserPropertyDefaults(for wallpaper: WEWallpaper, scene: WEScene) {
        guard wallpaper.project.type.caseInsensitiveCompare("scene") == .orderedSame else { return }
        let identity = settingsIdentity(for: wallpaper.wallpaperDirectory, settingsDirectory: wallpaper.settingsDirectory)
        let key = identity.key(.userProperties, scope: propertyScope)
        let defaults = UserDefaults.app
        var stored = identity.userSetValues(scope: propertyScope, defaults: defaults)
        // A Workshop preset item's values are its defaults: the user's own edits still win.
        stored.merge(WorkshopPresetItem.defaultValues(for: wallpaper)) { user, _ in user }
        // Text layers' fonts and sizes that earlier versions stored from the layers themselves.
        if stored.keys.contains(where: SceneTextLayerSettings.isLayerSetting) {
            var layerValues: [[String: String]] = [SceneTextLayerSettings.layerValues(in: scene)]
            if let authored = authoredScene(of: wallpaper) { layerValues.append(SceneTextLayerSettings.layerValues(in: authored)) }
            stored = SceneTextLayerSettings.removingLayerValues(from: stored, matching: layerValues)
        }
        let values = Self.userPropertyValues(stored: stored,
                                             declared: Self.declaredUserProperties(in: wallpaper.wallpaperDirectory),
                                             scene: scene)
        // A display's own store keeps what the user saved, so displays whose properties are equal
        // stay equal (`WallpaperPropertyGroups` compares the stores) whichever of them loaded.
        // Text layers' own fonts and sizes run but aren't saved (`SceneTextLayerSettings`).
        if propertyScope == .shared {
            let saved: [String: String] = values.filter { stored[$0.key] != nil || !SceneTextLayerSettings.isLayerSetting($0.key) }
            defaults.set(saved, forKey: key)
        }
        WallpaperServices.shared.setUserProperties(values, wallpaper: propertyScope.runtimeKey(directory: wallpaper.settingsDirectory),
                                                           replacing: true)
    }

    /// The scene file as authored, without the Wallpaper Editor's and Scene Edit / Export's edits;
    /// nil, logged, when it can't be read.
    private func authoredScene(of wallpaper: WEWallpaper) -> WEScene? {
        let sceneFile = wallpaper.project.file
        do {
            let data: Data? = try pkgParser?.extractFile(named: sceneFile)
                ?? AssetPathResolver.data(sceneFile, in: wallpaper.wallpaperDirectory)
            guard let data else { return nil }
            return try JSONDecoder().decode(WEScene.self, from: data)
        } catch {
            OWELog.error(.scene, "\(wallpaper.project.title): \(sceneFile) can't be read for its text layers: \(error)")
            return nil
        }
    }

    /// The wallpaper's property values: what the user stored, else project.json's defaults (the
    /// first option for a combo without one). Nothing else is invented: WE shows exactly what the
    /// properties say, even when that selects no variant of a conditional layer.
    static func userPropertyValues(stored: [String: String], declared: [String: [String: Any]],
                                   scene: WEScene) -> [String: String] {
        var values = stored
        for (name, property) in declared where values[name] == nil {
            if let value = property["value"] {
                values[name] = sceneUserPropertyString(value)
            } else if property["type"] as? String == "combo",
                      let option = (property["options"] as? [[String: Any]])?.first?["value"] {
                values[name] = sceneUserPropertyString(option)
            }
        }
        values.merge(SceneTextLayerSettings.layerValues(in: scene)) { stored, _ in stored }
        return values
    }

    /// `general.properties` of project.json; empty when the wallpaper declares none.
    private static func declaredUserProperties(in directory: URL) -> [String: [String: Any]] {
        let url = WEProject.url(in: directory)
        do {
            let root = try WEProject.json(in: directory)
            let general = root?["general"] as? [String: Any]
            return general?["properties"] as? [String: [String: Any]] ?? [:]
        } catch {
            OWELog.error(.scene, "Can't read user properties from \(url.path): \(error)")
            return [:]
        }
    }

    /// project.json's `preview`, then the usual preview file names.
    private func loadPreviewImage(wallpaperDir: URL) -> NSImage? {
        let named = currentWallpaper.project.previewURL(in: wallpaperDir)
        let candidates = [named].compactMap { $0 } + ["preview.jpg", "preview.png", "preview.gif"].map { wallpaperDir.appending(path: $0) }
        for url in candidates {
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }

    func metalContent() -> SceneMetalContent? {
        OWEPhaseTiming.measure(.sceneLoad) { metalContentUntimed() }
    }

    private func metalContentUntimed() -> SceneMetalContent? {
        sceneLock.lock()
        defer { sceneLock.unlock() }
        let revision = metalRevision
        renderSettings = stateLock.withLock { pendingRenderSettings }
        // Rebuilding walks every object and re-resolves textures; the result only changes when
        // the scene or its user properties do.
        if cachedContentRevision == revision, let cachedContent {
            return cachedContent
        }
        if SceneContentLoader.isVideoType(currentWallpaper.project.type) {
            let content = videoContent()
            cachedContent = content
            cachedContentRevision = revision
            return content
        }
        let signpost = OWESignpost.begin(OWESignpost.scene, "metalContent")
        defer { signpost.end() }
        defer { endBuildTextures() }
        guard let authoredScene = loadedScene, let wallpaperDir = loadedWallpaperDirectory else { return nil }
        // Content is built from what the user properties say (`bindingTable`).
        let valueContext = userValueContext
        var scene = resolvedScene(authoredScene)
        scene.objects = SceneObjectIdentity.assigningFallbackIDs(scene.objects)
        let sceneSize = metalSceneSize(for: scene)
        if scene.general.projection == .orthographicAuto { Self.centreFirstImage(of: &scene, sceneSize: sceneSize) }
        let bloom = bloomSettings(for: scene.general)
        let lighting = SceneLightingSettings(scene.general, in: valueContext)
        modelPlans.removeAll()
        sceneEngineCombos = SceneEngineCombos(bloom: bloom, lighting: lighting,
                                              orthographic: !scene.general.projection.isPerspective,
                                              settings: renderSettings)
        // Hidden objects are built too: a script can show them (docs/scenescript-plan.md §4.3).
        let visibility = Dictionary(scene.objects.enumerated().map { (String(SceneObjectIdentity.id(of: $1, at: $0)), isObjectVisible($1, at: $0)) },
                                    uniquingKeysWith: { first, _ in first })
        let authoredTransforms = SceneTransformHierarchy(objects: scene.objects)
        // WE draws objects in scene.json order; both lists carry that index so the renderer can interleave them.
        let layers: [SceneMetalLayer] = scene.objects.enumerated().compactMap { index, object in
            let id = SceneObjectIdentity.id(of: object, at: index)
            var layer = bindingTable.building(.object(id)) {
                buildLayer(object, id: id, wallpaperDir: wallpaperDir, sceneSize: sceneSize, context: valueContext)
            }
            layer?.order = index
            return layer
        }
        var particleSystems: [SceneMetalParticleSystem] = []
        particleMaterialPlanTime = (0, 0)
        let memoBefore = effectTranslator?.sources.counts
        let particleCache = ParticleDefinitionCache(sharesParts: sharesParticleDefinitions)
        for (index, object) in scene.objects.enumerated() {
            let base = particleSystems.count
            let id = SceneObjectIdentity.id(of: object, at: index)
            let family = bindingTable.building(.object(id)) {
                buildParticleFamily(object, id: id, wallpaperDir: wallpaperDir, sceneSize: sceneSize,
                                    pixelUnits: Self.particlesUsePixelUnits(scene), transforms: authoredTransforms,
                                    cache: particleCache)
            }
            for var system in family {
                system.order = index
                system.link?.parentIndex += base
                particleSystems.append(system)
            }
        }
        logParticleMaterialPlanTime(wallpaperDir: wallpaperDir, memoBefore: memoBefore)
        logParticleBuildTiming(particleCache.timing, wallpaperDir: wallpaperDir)
        particleCapacities = Dictionary(particleSystems.map { system in
            (system.order < scene.objects.count ? scene.objects[system.order].id ?? system.order : system.order,
             ParticleBudget.capacity(of: system))
        }, uniquingKeysWith: +)
        applyParticleBudget(to: &particleSystems, wallpaperDir: wallpaperDir)
        // A scene of scripts alone (groups whose scripts create layers) runs too, and so does one
        // of models alone (the default project arsenal).
        if !layers.isEmpty || !particleSystems.isEmpty || hasScriptSites || scene.objects.contains(where: { $0.model != nil }) {
            var transforms = authoredTransforms
            for layer in layers where layer.fillsScene {
                transforms.makeRoot(layer.id, local: SceneLocalTransform(origin: layer.position, scale: layer.scale, angle: layer.rotation))
            }
            var content = SceneMetalContent(size: sceneSize, layers: layers, particleSystems: particleSystems,
                                            bloom: bloom,
                                            transforms: transforms,
                                            camera: SceneCameraEffects(scene.general, in: valueContext),
                                            clearColor: scene.general.clearColor(in: valueContext),
                                            wallpaperKey: propertyStoreKey)
            content.general = scene.general
            content.clearEnabled = scene.general.clearEnabled(in: valueContext)
            content.motions = objectMotions(scene.objects, besides: layers, context: valueContext)
            content.visibility = visibility
            content.userVisibility = SceneUserVisibility(objects: scene.objects)
            content.objectIDs = scene.objects.enumerated().map { SceneObjectIdentity.id(of: $1, at: $0) }
            content.spatial = SceneSpatialContentBuilder(
                readFile: { self.assetData(named: $0, wallpaperDir: wallpaperDir) },
                wallpaperName: wallpaperDir.lastPathComponent).build(scene, context: valueContext)
            content.spatial.models = buildModels(content.spatial.models, wallpaperDir: wallpaperDir)
            SceneAttachmentCheck.logUnresolved(in: scene.objects, models: content.spatial.models, layers: layers,
                                               wallpaperName: wallpaperDir.lastPathComponent)
            content.scripts = scriptContent(wallpaperDir: wallpaperDir, sceneSize: sceneSize)
            content.timelines = loadedDocument.map {
                SceneTimelineSource(wallpaperID: loadedProjectId ?? Self.localWallpaperID(wallpaperDir),
                                    document: $0.document, signature: $0.signature)
            }
            content.sounds = soundBuilder(wallpaperDir: wallpaperDir).sounds(in: scene.objects, context: valueContext)
            content.lighting = SceneLightingContent(settings: lighting, lights: Self.lights(in: scene.objects, context: valueContext))
            content.lighting.cookies = SceneLightCookie.load(content.lighting.lights) { name, materialPath in
                loadMetalTexture(named: name, materialDir: materialPath, wallpaperDir: wallpaperDir)
            }
            content.volumetrics = volumetricsPlan(content.lighting.lights, wallpaperDir: wallpaperDir)
            content.engineCombos = sceneEngineCombos
            // An HDR content blooms through the HDR chain only (its `combine_srgb` when bloom is off).
            if sceneEngineCombos.hdr {
                content.hdrChain = engineChain("WE's HDR bloom", wallpaperDir: wallpaperDir, SceneHDRChain.build)
            } else {
                content.bloomChain = engineChain("WE's bloom", wallpaperDir: wallpaperDir, SceneBloomChain.build)
            }
            content.colorCorrection = engineChain("WE's colour correction", wallpaperDir: wallpaperDir,
                                                  SceneColorCorrection.build)
            // WE makes the fade only for a scene with camera paths (0x140181bae).
            if !content.spatial.cameraPaths.isEmpty {
                content.cameraFade = engineChain("WE's camera fade", wallpaperDir: wallpaperDir, SceneCameraFade.build)
            }
            // Not kept: it holds every decoded image, which the renderer drops once uploaded. The
            // instance asks again only after the revision changed, which rebuilds it anyway.
            cachedContent = nil
            return content
        }
        guard let preview = loadPreviewImage(wallpaperDir: wallpaperDir) else { return nil }
        return SceneMetalContent(size: sceneSize, layers: [SceneMetalLayer(id: "preview", name: "preview", source: .image(preview),
            position: sceneSize / 2, size: sceneSize, scale: SIMD2<Float>(repeating: 1),
            opacity: 1,
            brightness: 1, color: SIMD4<Float>(repeating: 1), text: nil,
            parallaxDepth: .zero, perspective: false,
            rotation: 0,
            )], particleSystems: [],
            bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7, tint: SIMD3<Float>(repeating: 1)))
    }

    func bloomSettings(for general: WESceneGeneral) -> SceneBloomSettings {
        SceneBloomSettings(general, in: userValueContext)
    }

    /// The scene's light objects, in scene order. They draw nothing; their transforms are in the
    /// content's hierarchy and motions like any other object's.
    static func lights(in objects: [WESceneObject], context: SceneValueContext) -> [SceneLightObject] {
        objects.compactMap { object in
            guard let light = object.light, let id = object.id else { return nil }
            let animated: [SceneLightValueField] = [.intensity, .radius, .exponent, .innercone, .outercone, .controlpoint]
            let hasTimelines = animated.contains { field in
                if case .object(let bound)? = light.values[field] { return bound.animation != nil }
                return false
            }
            return SceneLightObject(id: String(id), authored: light, light: SceneLight(light, in: context),
                                    depth: SceneLightDepth(object: object), hasTimelines: hasTimelines)
        }
    }

    /// Resolves user-bound values against this wallpaper's properties.
    /// The loaded scene with its user bindings resolved (`UserPropertyBindingTable.resolvedScene`);
    /// the authored scene, logged, when the resolved document can't be decoded.
    func resolvedScene(_ authored: WEScene) -> WEScene {
        guard let document = loadedDocument?.document else { return authored }
        do {
            return try bindingTable.resolvedScene(authored, document: document, properties: userProperty)
        } catch {
            OWELog.error(.scene, "\(currentWallpaper.project.title): scene.json can't be decoded with its user properties: \(error)")
            return authored
        }
    }

    var userValueContext: LiveSceneValueContext {
        LiveSceneValueContext(wallpaper: propertyStoreKey)
    }

    /// The scene's size in scene units (`Self.sceneSize(of:)`).
    func metalSceneSize(for scene: WEScene) -> SIMD2<Float> {
        guard let directory = loadedWallpaperDirectory else { return Self.sceneSize(of: scene) }
        return Self.sceneSize(of: scene) { model in
            SceneImageSize.of(model: model) { self.rawAssetData(named: $0, wallpaperDir: directory) }
        }
    }

    /// The scene's size in scene units (`general.orthogonalprojection` as WE reads it,
    /// docs/models-plan.md §2.1): an orthographic scene's width and height; `{"auto": true}`'s
    /// first image's size (0x14018b2c0), which is its texture's when the object has no `size`
    /// (`imageSize`, `SceneImageSize`; WE's GIF template writes none); a perspective scene, whose
    /// objects are in world units, WE's default canvas. What the renderer draws the scene at, so
    /// anything framing the drawn scene (the iPhone & iPad Export's crop) measures it with this
    /// (`SceneDrawnSize`).
    static func sceneSize(of scene: WEScene, imageSize: ((String) -> SIMD2<Double>?)? = nil) -> SIMD2<Float> {
        switch scene.general.projection {
        case .orthographic(let width, let height):
            return SIMD2<Float>(Float(width), Float(height))
        case .orthographicAuto:
            guard let image = firstImage(of: scene) else { return defaultCanvas }
            if let size = image.size?.parseVector2(), size.0 != 0, size.1 != 0 {
                return SIMD2<Float>(Float(size.0), Float(size.1))
            }
            if let model = image.image, let size = imageSize?(model), size.x > 0, size.y > 0 {
                return SIMD2<Float>(size)
            }
            return defaultCanvas
        case .perspective:
            return defaultCanvas
        }
    }

    /// WE's default canvas: a perspective scene's, and `auto`'s when its image's size can't be read.
    static let defaultCanvas = SIMD2<Float>(1920, 1080)

    /// `{"auto": true}` sizes the scene from its first image object, which WE puts at the
    /// scene's centre (0x14018b2c0) once: a script that moves it afterwards wins (WE 2.8,
    /// docs/models-plan.md §5.21).
    private static func firstImage(of scene: WEScene) -> WESceneObject? {
        scene.objects.first { $0.image != nil }
    }

    static func centreFirstImage(of scene: inout WEScene, sceneSize: SIMD2<Float>) {
        guard let index = scene.objects.firstIndex(where: { $0.image != nil }) else { return }
        scene.objects[index].origin = "\(sceneSize.x / 2) \(sceneSize.y / 2) 0"
    }
}
