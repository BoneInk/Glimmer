import Foundation
import IOSurface
import Metal

private final class BackendSilentMedia: MediaSessionSource {
    func subscribe(_ update: @escaping (MediaSessionState) -> Void) -> Int { update(MediaSessionState()); return 1 }
    func unsubscribe(_ id: Int) {}
}
private final class BackendScriptErrors: @unchecked Sendable {
    private let lock = NSLock(); private var messages: [String] = []
    func append(_ value: String) { lock.withLock { if messages.count < 256 { messages.append(value) } } }
    func snapshot() -> [String] { lock.withLock { messages } }
}

/// Public Release API. Compile this facade inside the GPL module; the host/helper imports only
/// public DTOs and this class. No app entrypoint, @testable, NSApplication or desktop windows.
public final class SceneBackendFacade: @unchecked Sendable {
    public struct SurfaceFrame {
        public let token: SceneFrameToken
        public let surface: IOSurface
    }
    private let configuration: SceneBackendConfiguration
    private let context: SceneBackendRuntimeContext
    private let queue: DispatchQueue
    private let renderer: SceneMetalRenderer
    private let model: SceneContentLoader
    private var content: SceneMetalContent
    private var authoredObjects: [[String: Any]]
    private let propertyTypes: [String: String]
    private let pool: IOSurfaceFramePool
    private let scriptErrors: BackendScriptErrors
    private var consoleToken: UUID?
    private var closed = false
    private var paused = false
    /// A successful user-property update needs one real GPU frame even while paused.
    private var propertyFrameDirty = false
    /// The app's scene-music intent. Default off: a preload, export or any session that never
    /// forwards user intent stays silent, and the layers only play when this is enabled.
    private var soundEnabled = false
    private var soundVolume: Float = 1
    private var currentFPS: Int
    private var aspectFill = true
    private var time: Double = 1000
    private var lastElapsed: Double = 0
    private var propertyRevision: UInt64 = 0
    private var sequence: UInt64 = 0
    private var preparedRuntimeErrorRevision: UInt64 = 0
    public private(set) var readiness: SceneBackendReadiness

    public static func prepare(_ configuration: SceneBackendConfiguration) async throws -> SceneBackendFacade {
        guard configuration.protocolVersion == 1, configuration.framesPerSecond > 0,
              configuration.framesPerSecond <= 240, configuration.width > 0, configuration.height > 0,
              configuration.width <= 8192, configuration.height <= 8192,
              configuration.width * configuration.height <= 16_777_216,
              configuration.properties.count <= 256,
              configuration.properties.allSatisfy({ $0.key.utf8.count <= 256 && $0.value.utf8.count <= 16_384 })
        else { throw SceneBackendFailure.invalidConfiguration }
        let context = try SceneBackendRuntimeContext.install(configuration.roots)
        SceneScriptJIT.configurePollingTraps()
        let queue = DispatchQueue(label: "Glimmer.SceneBackend.owner", qos: .userInitiated)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try SceneBackendFacade(configuration: configuration, context: context, queue: queue)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private init(configuration: SceneBackendConfiguration, context: SceneBackendRuntimeContext, queue: DispatchQueue) throws {
        self.configuration = configuration; self.context = context; self.queue = queue; self.currentFPS = configuration.framesPerSecond
        let root = context.roots.projectRoot
        guard let projectData = try AssetPathResolver.data("project.json", in: root) else { throw SceneBackendFailure.invalidRoot }
        let project = try JSONDecoder().decode(WEProject.self, from: projectData)
        let projectObject = try JSONSerialization.jsonObject(with: projectData) as? [String: Any]
        let declared = (projectObject?["general"] as? [String: Any])?["properties"] as? [String: [String: Any]] ?? [:]
        propertyTypes = declared.mapValues { ($0["type"] as? String ?? "").lowercased() }
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(),
            cacheDirectory: context.roots.cacheRoot.appending(path: "shader-variants"),
            failureDirectory: context.roots.cacheRoot.appending(path: "shader-failures"))
        let identity = WallpaperSettingsIdentity.resolve(directory: root)
        UserDefaults.app.set(configuration.properties, forKey: identity.key(.userProperties))
        // The app supplied the resolved user intent; without this flag the loader re-derives
        // project.json defaults and the saved values never reach the binding table or scripts.
        UserDefaults.app.set(true, forKey: identity.key(.explicitUserProperties))
        model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: root), effectTranslator: translator)
        model.workshopAssets = WorkshopAssetResolver(roots: [])
        var settings = SceneRenderSettings(); settings.particleBudget = .unlimited
        model.setRenderSettings(settings)
        guard let built = model.metalContent() else { throw SceneBackendFailure.notReady }
        guard built.layers.count <= 4096, built.particleSystems.count <= 1024,
              built.particleSystems.allSatisfy({ $0.maximumParticleCount >= 0 && $0.maximumParticleCount <= 1_000_000 }),
              built.particleSystems.reduce(0, { $0 + $1.maximumParticleCount }) <= 1_000_000,
              built.layers.reduce(0, { $0 + $1.weEffects.reduce(0, { $0 + $1.passes.count }) }) <= 2048,
              built.sounds.count <= 64,
              built.sounds.allSatisfy({ $0.files.count <= 64 && $0.files.allSatisfy({ $0.duration.isFinite && $0.duration >= 0 }) })
        else { throw SceneBackendFailure.unsupported }
        content = built
        guard let document = model.loadedDocument?.document else { throw SceneBackendFailure.notReady }
        func foundation(_ value: SceneJSON) -> Any {
            switch value {
            case .null: return NSNull()
            case .bool(let b): return NSNumber(value: b)
            case .number(let n): return NSNumber(value: n)
            case .string(let text): return text
            case .array(let values): return values.map(foundation)
            case .object(let values): return values.mapValues(foundation)
            }
        }
        authoredObjects = ((foundation(document) as? [String: Any])?["objects"] as? [[String: Any]]) ?? []
        let prelude = SceneScriptPrelude.load(from: [context.roots.assetsRoot])
        guard prelude.baseClasses != nil else { throw SceneBackendFailure.notReady }
        let services = SceneScriptServices(prelude: prelude,
            storage: SceneScriptStorage(directory: context.roots.cacheRoot.appending(path: "script-storage"), notificationCenter: NotificationCenter()),
            media: BackendSilentMedia(), spectrum: { .silent }, clicks: nil, userShortcuts: nil)
        guard let engine = SceneMetalRenderer(pixelFormat: .bgra8Unorm, scriptServices: services,
            screenID: configuration.sessionID.uuidString, pipelineArchiveDirectory: context.roots.cacheRoot.appending(path: "pipelines"))
        else { throw SceneBackendFailure.notReady }
        renderer = engine; renderer.renderSettings = settings
        renderer.audioSpectrumFrame = { _ in .silent }
        renderer.setPlacement(.fill)
        scriptErrors = BackendScriptErrors()
        let errors = scriptErrors
        if let description = content.scripts {
            consoleToken = SceneScriptConsoleTap.listen(to: description.wallpaperID) { if $0.isError { errors.append($0.message) } }
        }
        pool = try IOSurfaceFramePool(device: renderer.device, sessionID: configuration.sessionID,
            generation: configuration.generation, width: configuration.width, height: configuration.height)
        // All stored properties must exist before the clock closure can capture this instance.
        readiness = SceneBackendReadiness(sessionID: configuration.sessionID, generation: configuration.generation,
            projectDigest: configuration.roots.projectDigest, assetsManifestDigest: configuration.roots.assetsManifestDigest,
            authoredDrawableIDs: [], accountedDrawableIDs: [], fallbackDrawableIDs: [], unresolvedResources: [],
            scriptErrors: [], pipelineFailureCount: 0, exactFontsResolved: false, requiredVideoStreamsReady: false,
            auditedSoundObjectIDs: [],
            gpuFrameCompleted: false, capabilityAuditCompleted: false, diagnostics: [])
        renderer.wallTime = { [weak self] in self?.time ?? 1000 }
        renderer.setContent(content)
        let deadline = Date().addingTimeInterval(90)
        while !renderer.hasContent && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        guard renderer.hasContent else { cleanup(); throw SceneBackendFailure.timeout }
        renderer.holdsClock = true
        waitForInitialFrame()
        for layer in content.layers {
            if let material = layer.imageMaterial,
               renderer.imageMaterials?.waitUntilReady(material, pixelFormat: renderer.lastSceneTarget?.pixelFormat ?? .rgba8Unorm, sampleCount: renderer.sceneSampleCount, depthFormat: renderer.sceneDepthFormat, timeout: 30) != true {
                context.recordError("image_material_not_ready")
            }
        }
        for system in content.particleSystems {
            if let material = system.material,
               renderer.particleMaterials?.waitUntilCompiled(material, pixelFormat: renderer.lastSceneTarget?.pixelFormat ?? .rgba8Unorm, timeout: 30) != true {
                context.recordError("particle_material_not_ready")
            }
        }
        let steadyBaseline = GlimmerStrictReadiness.captureBaseline(renderer: renderer)
        renderer.renderShared([viewport(cursor: nil)]); renderer.lastCommandBuffer?.waitUntilCompleted()
        renderer.scripts.wallpaper?.waitUntilIdle()
        renderer.holdsClock = false
        readiness = collectReadiness(steadyBaseline: steadyBaseline)
        // Diagnostic evidence stays in the explicitly granted private cache, including fail-closed preparation.
        try JSONEncoder().encode(readiness).write(to: context.roots.cacheRoot.appending(path: "readiness.json"), options: .atomic)
        applySoundTarget()
        guard readiness.isStrictlyReady else { cleanup(); throw readinessFailure(readiness, .notReady) }
        preparedRuntimeErrorRevision = context.errorRevision
    }

    private func viewport(cursor: SIMD2<Float>?) -> SceneViewport {
        let size = SIMD2(Float(configuration.width), Float(configuration.height))
        return SceneViewport(drawableSize: size, pointSize: size, cursor: cursor, frameRateLimit: currentFPS)
    }
    private func waitForInitialFrame() {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            renderer.renderShared([viewport(cursor: nil)])
            renderer.lastCommandBuffer?.waitUntilCompleted()
            // GPU completion alone can precede AVFoundation's first decoded
            // video texture. Do not finish preparation on that transient frame
            // and then fail the strict video audit immediately afterwards.
            let videosReady = renderer.layers.allSatisfy { entry in
                guard case .video(let stream) = entry.layer.source else { return true }
                return stream.currentTexture() != nil && stream.currentSeconds.isFinite && stream.player.isMuted
            }
            if renderer.hasCompleteFrame, renderer.effectGraph?.hasPendingPipelines != true, videosReady { return }
            Thread.sleep(forTimeInterval: 0.01)
        } while ContinuousClock.now < deadline
        // The unchanged strict audit still rejects unavailable video, invalid
        // shaders and missing resources; no poster or timeout counts as ready.
    }
    private func collectReadiness(steadyBaseline: GlimmerStrictReadiness.Baseline) -> SceneBackendReadiness {
        GlimmerStrictReadiness.collect(content: content, renderer: renderer,
            authoredObjects: authoredObjects, scriptConsoleErrors: scriptErrors.snapshot(), configuration: configuration,
            readOriginalResource: { [self] in model.rawAssetData(named: $0, wallpaperDir: context.roots.projectRoot) }, steadyBaseline: steadyBaseline)
    }
    private func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { do { continuation.resume(returning: try operation()) } catch { continuation.resume(throwing: error) } }
        }
    }
    public func render(_ input: SceneFrameInput) async throws -> SurfaceFrame {
        try await perform { [self] in
            guard !closed else { throw SceneBackendFailure.closed }
            guard input.sessionID == configuration.sessionID, input.generation == configuration.generation,
                  input.sequence > sequence, input.elapsedSeconds.isFinite, input.elapsedSeconds >= lastElapsed,
                  input.cursorX.map({ $0.isFinite }) ?? true, input.cursorY.map({ $0.isFinite }) ?? true
            else { throw SceneBackendFailure.stale }
            guard !input.leftMouseDown else { throw SceneBackendFailure.unsupported }
            time = 1000 + input.elapsedSeconds; lastElapsed = input.elapsedSeconds; sequence = input.sequence
            let cursor = input.cursorX.flatMap { x in input.cursorY.map { SIMD2(x, $0) } }
            if paused {
                renderer.clock.hold(at: time)
                if propertyFrameDirty {
                    // One real GPU frame at the frozen time: holdsClock suppresses the paused
                    // ease's minimum step so Scene time, timelines and particles do not advance.
                    let fallbackBaseline = GlimmerStrictReadiness.captureBaseline(renderer: renderer)
                    let wasHoldingClock = renderer.holdsClock
                    let wasSkippingIdleFrames = renderer.skipsIdleFrames
                    renderer.holdsClock = true
                    // A property edit is interactive demand: never let idle skipping drop this
                    // one frame and leave the old target behind.
                    renderer.skipsIdleFrames = false
                    renderer.renderShared([viewport(cursor: cursor)])
                    renderer.lastCommandBuffer?.waitUntilCompleted()
                    renderer.skipsIdleFrames = wasSkippingIdleFrames
                    renderer.holdsClock = wasHoldingClock
                    let fallbackAfter = GlimmerStrictReadiness.captureBaseline(renderer: renderer)
                    guard fallbackAfter.particleFallbacks == fallbackBaseline.particleFallbacks,
                          !fallbackAfter.imageFallbacks.contains(where: { $0.value > (fallbackBaseline.imageFallbacks[$0.key] ?? 0) }),
                          renderer.lastCommandBuffer?.status == .completed, !renderer.scripts.state.halted,
                          scriptErrors.snapshot().isEmpty, context.errorRevision == preparedRuntimeErrorRevision,
                          (renderer.effectGraph?.failedPipelineCount ?? 0) == 0 else { throw SceneBackendFailure.gpuFailure }
                    propertyFrameDirty = false
                }
            } else {
                let fallbackBaseline = GlimmerStrictReadiness.captureBaseline(renderer: renderer)
                renderer.renderShared([viewport(cursor: cursor)])
                renderer.lastCommandBuffer?.waitUntilCompleted()
                let fallbackAfter = GlimmerStrictReadiness.captureBaseline(renderer: renderer)
                guard fallbackAfter.particleFallbacks == fallbackBaseline.particleFallbacks,
                      !fallbackAfter.imageFallbacks.contains(where: { $0.value > (fallbackBaseline.imageFallbacks[$0.key] ?? 0) }),
                      renderer.lastCommandBuffer?.status == .completed, !renderer.scripts.state.halted,
                      scriptErrors.snapshot().isEmpty, context.errorRevision == preparedRuntimeErrorRevision, (renderer.effectGraph?.failedPipelineCount ?? 0) == 0 else { throw SceneBackendFailure.gpuFailure }
                propertyFrameDirty = false
            }
            let lease = try pool.acquire(sequence: input.sequence)
            guard let command = renderer.commandQueue.makeCommandBuffer(),
                  renderer.encodeSharedFrame(into: lease.texture, pixelsPerPoint: 1, commandBuffer: command) else {
                try pool.complete(lease.token, gpuSucceeded: false); throw SceneBackendFailure.gpuFailure
            }
            command.commit(); command.waitUntilCompleted()
            let ok = command.status == .completed
            try pool.complete(lease.token, gpuSucceeded: ok)
            guard ok else { throw SceneBackendFailure.gpuFailure }
            return SurfaceFrame(token: lease.token, surface: lease.surface)
        }
    }
    public func acknowledge(_ token: SceneFrameToken) async throws { try await perform { [self] in try pool.acknowledge(token) } }
    public func processStatus(helperPID: Int32, instanceID: UUID, ownsSession: Bool) async throws -> SceneBackendProcessStatus {
        try await perform { [self] in
            let soundIDs = renderer.sounds.ids
            return SceneBackendProcessStatus(helperPID: helperPID, instanceID: instanceID,
                sessionID: configuration.sessionID, generation: configuration.generation, ownsSession: ownsSession,
                frameRateLimit: currentFPS, aspectFill: aspectFill, sceneSeconds: renderer.clock.time, paused: paused,
                soundEnabled: soundEnabled, soundVolume: Double(soundVolume),
                soundsPrepared: soundIDs.count,
                soundPlaying: soundIDs.filter { renderer.sounds.isPlaying($0) == true }.count,
                propertyRevision: propertyRevision)
        }
    }
    public func setFrameRateLimit(_ fps: Int) async throws {
        try await perform { [self] in
            guard !closed else { throw SceneBackendFailure.closed }
            guard (1...240).contains(fps) else { throw SceneBackendFailure.invalidConfiguration }
            currentFPS = fps
        }
    }
    public func setAspectFill(_ fill: Bool) async throws {
        try await perform { [self] in
            guard !closed else { throw SceneBackendFailure.closed }
            aspectFill = fill; renderer.setPlacement(fill ? .fill : .fit)
        }
    }
    public func setPaused(_ value: Bool) async throws {
        try await perform { [self] in
            guard !closed else { throw SceneBackendFailure.closed }
            paused = value; renderer.pausesPlayback = value; renderer.clock.paused = value
            model.setEmbeddedVideoRate(value ? 0 : 1)
            applySoundTarget()
        }
    }
    /// The app's user intent for scene sound. Default is off; enabling creates the output-only
    /// device (no microphone input) and the layers follow the volume and the pause state.
    public func setSceneSound(enabled: Bool, volume: Float) async throws {
        try await perform { [self] in
            guard !closed else { throw SceneBackendFailure.closed }
            guard volume.isFinite, volume >= 0, volume <= 1 else { throw SceneBackendFailure.invalidConfiguration }
            if enabled && volume > 0 { WallpaperServices.shared.enableBackendSceneSoundOutput() }
            soundEnabled = enabled; soundVolume = volume
            applySoundTarget()
        }
    }
    public func updateProperties(_ values: [String: String], revision: UInt64) async throws {
        try await perform { [self] in
            guard !closed, revision > propertyRevision, values.count <= 256,
                  values.allSatisfy({ $0.key.utf8.count <= 256 && $0.value.utf8.count <= 16_384 }) else { throw SceneBackendFailure.stale }
            let unsupportedKeys = values.keys.filter {
                propertyTypes[$0] == nil || ["scenetexture", "usershortcut"].contains(propertyTypes[$0]!)
            }.sorted()
            guard unsupportedKeys.isEmpty else {
                throw SceneBackendDetailedFailure(failure: .unsupported, detail: SceneBackendFailureDetail(
                    code: SceneBackendFailure.unsupported.rawValue,
                    category: SceneBackendFailureDetail.categoryUnsupportedCapability,
                    userMessage: SceneBackendFailureDetail.message(for: SceneBackendFailureDetail.categoryUnsupportedCapability),
                    technicalDetail: "unsupported property types: "
                        + unsupportedKeys.prefix(16).map { "\($0)=\(propertyTypes[$0] ?? "undeclared")" }.joined(separator: ", "),
                    missingResources: []))
            }
            // Native live property store; no persistent domain, file path or command bridge.
            let identity = WallpaperSettingsIdentity.resolve(directory: context.roots.projectRoot)
            UserDefaults.app.set(values, forKey: identity.key(.userProperties))
            UserDefaults.app.set(true, forKey: identity.key(.explicitUserProperties))
            WallpaperServices.shared.setUserProperties(values, wallpaper: content.wallpaperKey, replacing: true)
            let keys = Array(values.keys)
            let update = model.bindingUpdate(for: keys)
            // Scripts and live uniform bindings get every change; structural bindings and the
            // app's own scene keys rebuild through the same loader the original app uses, so an
            // ACK is only returned after the rebuilt content passes the strict readiness audit.
            renderer.userPropertiesDidChange(Set(keys), owners: update.owners)
            if update.impact == .reloadScene {
                try rebuildContent(forceReload: true)
            } else if update.impact == .rebuildContent || !update.rebuild.isEmpty {
                try rebuildContent(forceReload: false)
            }
            propertyRevision = revision
            propertyFrameDirty = true
        }
    }
    public func close() async { _ = try? await perform { [self] in cleanup() } }
    private func cleanup() {
        guard !closed else { return }; closed = true
        soundEnabled = false
        model.setEmbeddedVideoRate(0); renderer.releaseContent(); pool.close()
        if let consoleToken { SceneScriptConsoleTap.stop(consoleToken); self.consoleToken = nil }
    }

    // MARK: - Content rebuild (user properties)

    /// Rebuilds the content the renderer draws after a structural or scene-wide property change,
    /// exactly as a fresh load would, and refuses to ACK unless the rebuilt content passes the
    /// same strict readiness audit as preparation.
    private func rebuildContent(forceReload: Bool) throws {
        // A paused property update rebuilds and audits without stepping the frozen scene.
        let wasHoldingClock = renderer.holdsClock
        let wasSkippingIdleFrames = renderer.skipsIdleFrames
        if paused {
            renderer.holdsClock = true
            renderer.skipsIdleFrames = false
        }
        defer {
            renderer.holdsClock = wasHoldingClock
            renderer.skipsIdleFrames = wasSkippingIdleFrames
        }
        if forceReload { model.reloadCurrentScene() } else { model.invalidateContent() }
        guard let built = model.metalContent() else { throw SceneBackendFailure.notReady }
        guard built.layers.count <= 4096, built.particleSystems.count <= 1024,
              built.particleSystems.allSatisfy({ $0.maximumParticleCount >= 0 && $0.maximumParticleCount <= 1_000_000 }),
              built.particleSystems.reduce(0, { $0 + $1.maximumParticleCount }) <= 1_000_000,
              built.layers.reduce(0, { $0 + $1.weEffects.reduce(0, { $0 + $1.passes.count }) }) <= 2048,
              built.sounds.count <= 64,
              built.sounds.allSatisfy({ $0.files.count <= 64 && $0.files.allSatisfy({ $0.duration.isFinite && $0.duration >= 0 }) })
        else { throw SceneBackendFailure.unsupported }
        content = built
        if let document = model.loadedDocument?.document {
            func foundation(_ value: SceneJSON) -> Any {
                switch value {
                case .null: return NSNull()
                case .bool(let b): return NSNumber(value: b)
                case .number(let n): return NSNumber(value: n)
                case .string(let text): return text
                case .array(let values): return values.map(foundation)
                case .object(let values): return values.mapValues(foundation)
                }
            }
            authoredObjects = ((foundation(document) as? [String: Any])?["objects"] as? [[String: Any]]) ?? []
        }
        renderer.setContent(built)
        let deadline = Date().addingTimeInterval(30)
        while !renderer.hasContent && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        guard renderer.hasContent else { throw SceneBackendFailure.timeout }
        applySoundTarget()
        waitForInitialFrame()
        for layer in built.layers {
            if let material = layer.imageMaterial,
               renderer.imageMaterials?.waitUntilReady(material, pixelFormat: renderer.lastSceneTarget?.pixelFormat ?? .rgba8Unorm, sampleCount: renderer.sceneSampleCount, depthFormat: renderer.sceneDepthFormat, timeout: 30) != true {
                context.recordError("image_material_not_ready")
            }
        }
        for system in built.particleSystems {
            if let material = system.material,
               renderer.particleMaterials?.waitUntilCompiled(material, pixelFormat: renderer.lastSceneTarget?.pixelFormat ?? .rgba8Unorm, timeout: 30) != true {
                context.recordError("particle_material_not_ready")
            }
        }
        let steadyBaseline = GlimmerStrictReadiness.captureBaseline(renderer: renderer)
        renderer.renderShared([viewport(cursor: nil)]); renderer.lastCommandBuffer?.waitUntilCompleted()
        renderer.scripts.wallpaper?.waitUntilIdle()
        let next = collectReadiness(steadyBaseline: steadyBaseline)
        readiness = next
        try JSONEncoder().encode(next).write(to: context.roots.cacheRoot.appending(path: "readiness.json"), options: .atomic)
        guard next.isStrictlyReady else { throw readinessFailure(next, .notReady) }
        preparedRuntimeErrorRevision = context.errorRevision
    }

    /// The scene's sound target: level is the app's volume and `audible` is the user's intent and
    /// the pause state. Muted or paused fades to silence exactly as the original renderer does.
    private func applySoundTarget() {
        let audible = soundEnabled && !paused && soundVolume > 0
        renderer.sounds.setTarget(level: soundVolume, audible: audible)
        // The isolated facade owns a DispatchQueue, not the upstream render
        // thread's running RunLoop. Once paused there are no frames to drive
        // its fade timer; settle silence here on the owner queue instead.
        if !audible { renderer.sounds.stepFade(1) }
    }

    /// Maps failed strict readiness onto the structured failure categories: a missing resource
    /// stays a missing resource instead of becoming "unsupported".
    private func readinessFailure(_ value: SceneBackendReadiness, _ failure: SceneBackendFailure) -> SceneBackendDetailedFailure {
        let missing = value.unresolvedResources
        let hasAudioRuntimeFailure = value.diagnostics.contains { $0.code.hasPrefix("runtime.audio_") }
        let hasUnsupported = value.diagnostics.contains { $0.code.hasPrefix("unsupported.") } || !value.capabilityAuditCompleted
        let category: String
        if !missing.isEmpty {
            category = SceneBackendFailureDetail.categoryMissingResources
        } else if hasAudioRuntimeFailure {
            category = SceneBackendFailureDetail.categoryRuntimeFailure
        } else if hasUnsupported {
            category = SceneBackendFailureDetail.categoryUnsupportedCapability
        } else if value.pipelineFailureCount > 0 {
            category = SceneBackendFailureDetail.categoryShaderFailure
        } else if !value.scriptErrors.isEmpty {
            category = SceneBackendFailureDetail.categoryScriptFailure
        } else {
            category = SceneBackendFailureDetail.categoryRuntimeFailure
        }
        let lines = value.diagnostics.prefix(16).map { diagnostic -> String in
            let resource = diagnostic.resource.map { " [\($0)]" } ?? ""
            return "\(diagnostic.code)\(resource): \(diagnostic.message)"
        }.joined(separator: "\n")
        return SceneBackendDetailedFailure(failure: failure, detail: SceneBackendFailureDetail(
            code: failure.rawValue, category: category,
            userMessage: SceneBackendFailureDetail.message(for: category),
            technicalDetail: lines.isEmpty ? nil : String(lines.prefix(8_192)),
            missingResources: Array(missing.prefix(64))))
    }
}
