import AppKit
import CoreGraphics
import CoreVideo
import CryptoKit
import Foundation
import IOSurface
import Observation

enum SceneManualFrameError: LocalizedError, Equatable, Sendable {
    case notInManualMode
    var errorDescription: String? { "Scene 未处于独立导出模式。" }
}

@MainActor @Observable
final class UniversalSceneBackendRuntime {
    enum State: String, Sendable { case idle, loading, ready, paused, failed, disposed }

    let projectURL: URL
    private(set) var state: State = .idle
    private(set) var lastError: String?
    /// The structured detail behind `lastError` for local diagnostics; the UI keeps the concise
    /// Chinese message alone.
    private(set) var lastFailureDetail: SceneBackendFailureDetail?
    private(set) var editablePropertyKeys = Set<String>()
    private(set) var frameCount = 0
    private(set) var activeRuntime: Double = 0
    private(set) var frameRateLimit = 30
    private(set) var screenResolution: SceneVector2?
    private(set) var posterImage: CGImage? = nil
    private(set) var processStatus: SceneBackendProcessStatus?
    /// The strict readiness evidence the helper returned at prepare (and after each property rebuild).
    private(set) var readiness: SceneBackendReadiness?
    @ObservationIgnored private(set) var sceneLoadTimingMilliseconds: [String: Double] = [:]
    @ObservationIgnored private(set) var shaderCacheRestoredFiles = 0
    var hostView: NSView { surface }

    private let surface: SceneBackendMetalHostView
    private let followsHostScreen: Bool
    private let manualFrameExport: Bool
    private let registry: SceneRuntimeAssetRegistry
    private let transportFactory: @MainActor (String) -> SceneBackendSessionTransport
    private let pool: SceneBackendServicePool
    private var context: Session?
    private var desiredPaused = false
    private var aspectFill = true
    /// The user's scene-music intent, default off; forwarded to the helper after every load.
    private(set) var soundEnabled = false
    private(set) var soundVolume: Double = 1
    private var frameLoop: Task<Void, Never>?
    private var frameLoopID: UUID?
    private var frameLoopSuspensions = 0
    private var lastTick: ContinuousClock.Instant?
    private var lastProperties = Data("{}".utf8)
    private var operationTicket = UUID()
    private var nextGeneration: UInt64 = 0
    private var propertyRevision: UInt64 = 0
    private var pauseRevision = UUID()
    private var fpsRevision = UUID()
    private var aspectRevision = UUID()
    private var fpsUpdateTask: Task<Void, Never>?
    private var aspectUpdateTask: Task<Void, Never>?
    private var screenReload: Task<Void, Never>?
    private let frameGate = SceneBackendFrameGate()

    private struct Session {
        let leaseIndex: Int
        let client: SceneBackendSessionTransport
        let sessionID: UUID
        let generation: UInt64
        let width: Int
        let height: Int
        let cacheURL: URL
        let helperPID: Int32
        let helperInstanceID: UUID
        var sequence: UInt64
    }

    convenience init(projectURL: URL, screenResolution: SceneVector2? = nil, followsHostScreen: Bool = false,
                     manualFrameExport: Bool = false) throws {
        try self.init(projectURL: projectURL, screenResolution: screenResolution,
                      followsHostScreen: followsHostScreen, manualFrameExport: manualFrameExport, registry: .production,
                      pool: .shared, transportFactory: { SceneBackendXPCClient(serviceName: $0) })
    }

    init(projectURL: URL, screenResolution: SceneVector2?, followsHostScreen: Bool,
         manualFrameExport: Bool = false,
         registry: SceneRuntimeAssetRegistry, pool: SceneBackendServicePool,
         transportFactory: @escaping @MainActor (String) -> SceneBackendSessionTransport) throws {
        let project = try AuthorPropertyProject.load(projectURL: projectURL,
                                                       allowedRoot: projectURL.deletingLastPathComponent())
        guard project.projectType.lowercased() == "scene" else { throw UniversalSceneBackendError.invalidProject }
        if let screenResolution { try Self.validateResolution(screenResolution) }
        self.projectURL = project.projectURL
        self.screenResolution = screenResolution
        self.followsHostScreen = followsHostScreen
        self.manualFrameExport = manualFrameExport
        self.registry = registry; self.pool = pool; self.transportFactory = transportFactory
        surface = try SceneBackendMetalHostView.make()
        if followsHostScreen {
            surface.onScreenChange = { [weak self] screen in self?.screenDidChange(screen) }
        }
    }

    func load(propertiesJSON: Data) async throws {
        try requireActive(); try Task.checkCancellation()
        let ticket = UUID(); operationTicket = ticket; state = .loading; lastError = nil
        lastFailureDetail = nil
        sceneLoadTimingMilliseconds = [:]
        shaderCacheRestoredFiles = 0
        let loadStart = ContinuousClock.now
        fpsUpdateTask?.cancel(); aspectUpdateTask?.cancel(); frameGate.cancelWaiters()
        lastProperties = propertiesJSON
        let retireStart = ContinuousClock.now
        await retireCurrentSession()
        recordLoadTiming("retireSession", since: retireStart, ticket: ticket)
        try requireTicket(ticket)
        do {
            let projectURL = projectURL, registry = registry
            let preparationTiming = SceneLoadPreparationTimingBox()
            let prepared: (AuthorPropertyProject, SceneRuntimeAssetRegistry.Resolved,
                           SceneBackendPropertyValues, String, [String: Double])
            let preparationStart = ContinuousClock.now
            do {
                prepared = try await Task.detached(priority: .userInitiated) {
                    let detachedStart = ContinuousClock.now
                    do {
                        let project: AuthorPropertyProject
                        do {
                            let start = ContinuousClock.now
                            defer { preparationTiming.record("projectLoad", since: start) }
                            project = try AuthorPropertyProject.load(
                                projectURL: projectURL,
                                allowedRoot: projectURL.deletingLastPathComponent())
                        }
                        guard project.projectType.lowercased() == "scene" else {
                            throw UniversalSceneBackendError.invalidProject
                        }
                        let bundle: SceneRuntimeAssetRegistry.Resolved
                        do {
                            let start = ContinuousClock.now
                            defer { preparationTiming.record("registryValidation", since: start) }
                            guard let loaded = try registry.loadRegisteredBundle() else {
                                throw UniversalSceneBackendError.unavailable
                            }
                            bundle = loaded
                        }
                        let properties: SceneBackendPropertyValues
                        do {
                            let start = ContinuousClock.now
                            defer { preparationTiming.record("propertyPreparation", since: start) }
                            properties = try SceneBackendPropertyValues.normalize(
                                propertiesJSON, project: project)
                        }
                        let digest: String
                        do {
                            let start = ContinuousClock.now
                            defer { preparationTiming.record("projectDigest", since: start) }
                            digest = SHA256.hash(data: project.sourceData)
                                .map { String(format: "%02x", $0) }.joined()
                        }
                        preparationTiming.record("preparationWork", since: detachedStart)
                        return (project, bundle, properties, digest, preparationTiming.snapshot)
                    } catch {
                        preparationTiming.record("preparationWork", since: detachedStart)
                        throw error
                    }
                }.value
            } catch {
                recordLoadTiming("projectPreparation", since: preparationStart, ticket: ticket)
                recordLoadTimings(preparationTiming.snapshot, ticket: ticket)
                throw error
            }
            recordLoadTiming("projectPreparation", since: preparationStart, ticket: ticket)
            recordLoadTimings(prepared.4, ticket: ticket)
            try Task.checkCancellation(); try requireTicket(ticket)
            let resolutionAndConnectStart = ContinuousClock.now
            let resolution: (Int, Int)
            do {
                let start = ContinuousClock.now
                defer { recordLoadTiming("resolution", since: start, ticket: ticket) }
                resolution = try await resolvedPixelSize(project: prepared.0, ticket: ticket)
            }
            screenResolution = .init(x: Double(resolution.0), y: Double(resolution.1))
            nextGeneration &+= 1
            guard nextGeneration > 0 else { throw UniversalSceneBackendError.invalidProject }
            let sessionID = UUID(), generation = nextGeneration
            let lease = try pool.acquire()
            var client: SceneBackendSessionTransport?
            do {
                do {
                    let start = ContinuousClock.now
                    defer { recordLoadTiming("connectService", since: start, ticket: ticket) }
                    client = try await connectOwnedService(name: lease.1, ticket: ticket)
                }
                guard let client else { throw UniversalSceneBackendError.unavailable }
                recordLoadTiming("resolutionAndConnect",
                                 since: resolutionAndConnectStart, ticket: ticket)
                let cache = try SceneBackendPrivateCache.create(registryRoot: registry.registryURL, sessionID: sessionID)
                let registryRoot = registry.registryURL, manifest = prepared.1.manifestFingerprint
                do {
                    let start = ContinuousClock.now
                    defer { recordLoadTiming("shaderCacheRestore", since: start, ticket: ticket) }
                    let restored = (try? await Task.detached(priority: .userInitiated) {
                        try SceneBackendShaderCache.restore(registryRoot: registryRoot, session: cache, manifest: manifest)
                    }.value) ?? 0
                    try Task.checkCancellation(); try requireTicket(ticket)
                    shaderCacheRestoredFiles = restored
                }
                let roots = SceneBackendRoots(projectRoot: projectURL.deletingLastPathComponent(),
                    assetsRoot: prepared.1.assetsRootURL, cacheRoot: cache,
                    projectDigest: prepared.3, assetsManifestDigest: prepared.1.manifestFingerprint)
                let configuration = SceneBackendConfiguration(protocolVersion: 1, sessionID: sessionID,
                    generation: generation, roots: roots, width: resolution.0, height: resolution.1,
                    framesPerSecond: frameRateLimit, properties: prepared.2.values)
                let readiness: SceneBackendReadiness
                do {
                    let start = ContinuousClock.now
                    defer { recordLoadTiming("prepareRPC", since: start, ticket: ticket) }
                    readiness = try await client.prepare(configuration)
                    self.readiness = readiness
                }
                try Task.checkCancellation(); try requireTicket(ticket)
                guard readiness.isStrictlyReady, readiness.sessionID == sessionID,
                      readiness.generation == generation, readiness.projectDigest == prepared.3,
                      readiness.assetsManifestDigest == prepared.1.manifestFingerprint else {
                    throw UniversalSceneBackendError.notReady
                }
                context = Session(leaseIndex: lease.0, client: client, sessionID: sessionID,
                                  generation: generation, width: resolution.0, height: resolution.1,
                                  cacheURL: cache, helperPID: processStatus!.helperPID,
                                  helperInstanceID: processStatus!.instanceID, sequence: 0)
                client.invalidationHandler = { [weak self, weak client] in
                    guard let self, let client, self.context?.client === client else { return }
                    self.fail(UniversalSceneBackendError.interrupted.localizedDescription)
                }
                editablePropertyKeys = prepared.2.editableKeys
                propertyRevision = 0; activeRuntime = 0; frameCount = 0; lastTick = nil
                let configureStart = ContinuousClock.now
                do {
                    defer { recordLoadTiming("configure", since: configureStart, ticket: ticket) }
                    try await client.setFrameRateLimit(frameRateLimit)
                    try await client.setAspectFill(aspectFill)
                    try await client.setPaused(desiredPaused)
                    try await client.setSceneSound(enabled: soundEnabled, volume: soundVolume)
                    let preparedStatus = try await client.status()
                    guard let owner = processStatus, preparedStatus.ownsSession,
                          preparedStatus.helperPID == owner.helperPID,
                          preparedStatus.instanceID == owner.instanceID,
                          preparedStatus.sessionID == sessionID,
                          preparedStatus.generation == generation,
                          preparedStatus.soundEnabled == soundEnabled,
                          preparedStatus.soundVolume == soundVolume else {
                        throw UniversalSceneBackendError.interrupted
                    }
                    processStatus = preparedStatus
                }
                let firstFrameStart = ContinuousClock.now
                do {
                    defer { recordLoadTiming("firstFrame", since: firstFrameStart, ticket: ticket) }
                    try await requestFrame(elapsed: 0, ticket: ticket)
                }
                recordLoadTiming("configureAndFirstFrame",
                                 since: configureStart, ticket: ticket)
                do {
                    let start = ContinuousClock.now
                    defer { recordLoadTiming("shaderCachePublish", since: start, ticket: ticket) }
                    _ = try? await Task.detached(priority: .utility) {
                        try SceneBackendShaderCache.publish(registryRoot: registryRoot, session: cache, manifest: manifest)
                    }.value
                    try Task.checkCancellation(); try requireTicket(ticket)
                }
                state = desiredPaused ? .paused : .ready
                if !desiredPaused { startFrameLoop() }
                if followsHostScreen,
                   let desired = screenResolution,
                   (Int(desired.x.rounded()) != resolution.0 || Int(desired.y.rounded()) != resolution.1) {
                    scheduleScreenReload(propertiesJSON: propertiesJSON)
                }
            } catch {
                if context?.client === client { context = nil }
                if let client {
                    let reusable = await Self.closeAndConfirmExit(client: client, sessionID: sessionID,
                        generation: generation, helperPID: processStatus?.helperPID)
                    pool.release(lease.0, reusable: reusable)
                } else {
                    pool.release(lease.0)
                }
                throw error
            }
            recordLoadTiming("total", since: loadStart, ticket: ticket)
        } catch {
            guard state != .disposed, operationTicket == ticket else { throw CancellationError() }
            recordLoadTiming("total", since: loadStart, ticket: ticket)
            fail(error is CancellationError ? "Scene 加载已取消。" : error.localizedDescription,
                 detail: (error as? SceneBackendWireFailure)?.detail)
            throw error
        }
    }

    func applyPropertiesAndWait(_ propertiesJSON: Data) async throws {
        try requireActive(); try Task.checkCancellation()
        if state == .failed { try await load(propertiesJSON: propertiesJSON); return }
        guard var session = context, state == .ready || state == .paused else {
            throw UniversalSceneBackendError.notReady
        }
        let projectURL = projectURL
        let values = try await Task.detached(priority: .userInitiated) {
            let project = try AuthorPropertyProject.load(projectURL: projectURL,
                                                           allowedRoot: projectURL.deletingLastPathComponent())
            return try SceneBackendPropertyValues.normalize(propertiesJSON, project: project)
        }.value
        frameLoopSuspensions += 1
        defer { frameLoopSuspensions -= 1; startFrameLoop() }
        stopFrameLoop(); await waitForFrameLoop()
        try Task.checkCancellation(); try requireActive()
        propertyRevision &+= 1
        guard propertyRevision > 0 else { throw UniversalSceneBackendError.invalidProperties }
        do {
            try await session.client.updateProperties(values.values, revision: propertyRevision)
            guard context?.sessionID == session.sessionID else { throw CancellationError() }
            // The helper ACKs only after applying; the reported revision proves it (no fake ACK).
            let status = try await session.client.status()
            guard status.instanceID == processStatus?.instanceID,
                  status.sessionID == session.sessionID, status.generation == session.generation,
                  status.propertyRevision == propertyRevision else {
                throw UniversalSceneBackendError.interrupted
            }
            editablePropertyKeys = values.editableKeys; lastProperties = propertiesJSON
            processStatus = status
            session = context ?? session
            // A property change must reach the GPU even while paused: one synchronous frame at the
            // frozen scene time, without resuming the automatic loop.
            try await requestFrame(elapsed: activeRuntime, ticket: operationTicket)
            if desiredPaused { state = .paused } else { state = .ready; startFrameLoop() }
        } catch {
            guard state != .disposed else { throw CancellationError() }
            fail(error.localizedDescription, detail: (error as? SceneBackendWireFailure)?.detail)
            throw error
        }
    }

    func setFrameRateLimit(_ value: Int) throws {
        try requireActive()
        guard (1...240).contains(value) else { throw UniversalSceneBackendError.invalidProperties }
        guard frameRateLimit != value else { return }
        frameRateLimit = value
        let revision = UUID(); fpsRevision = revision
        fpsUpdateTask?.cancel()
        guard let session = context else { return }
        fpsUpdateTask = Task { [weak self, weak client = session.client] in
            do {
                // Coalesce slider bursts while the local scheduler immediately
                // observes the newest bound on its next iteration.
                try await Task.sleep(for: .milliseconds(30))
                guard let self, let client, self.fpsRevision == revision,
                      self.context?.client === client else { return }
                try await client.setFrameRateLimit(value)
                guard self.fpsRevision == revision, self.context?.client === client else { return }
                let status = try await client.status()
                guard status.instanceID == self.processStatus?.instanceID,
                      status.sessionID == session.sessionID, status.generation == session.generation,
                      status.frameRateLimit == value else { throw UniversalSceneBackendError.interrupted }
                self.processStatus = status
            } catch is CancellationError { }
            catch { if let self, self.fpsRevision == revision, self.context?.client === client { self.fail(error.localizedDescription) } }
        }
    }

    func updateScreenResolutionAndWait(_ size: SceneVector2) async throws {
        try requireActive(); try Task.checkCancellation(); try Self.validateResolution(size)
        guard screenResolution != size else { return }
        screenResolution = size
        if state == .idle { return }
        try await load(propertiesJSON: lastProperties)
    }

    func setPaused(_ value: Bool) {
        guard state != .disposed else { return }
        desiredPaused = value
        let revision = UUID(); pauseRevision = revision
        if value { stopFrameLoop(); lastTick = nil; if state == .ready { state = .paused } }
        guard let session = context else { return }
        Task { [weak self, weak client = session.client] in
            guard let self, let client else { return }
            do {
                try await client.setPaused(value)
                guard self.context?.client === client, self.state != .disposed,
                      self.pauseRevision == revision, self.desiredPaused == value else { return }
                if value { self.state = .paused }
                else { self.state = .ready; self.lastTick = nil; self.startFrameLoop() }
            } catch { if self.context?.client === client { self.fail(error.localizedDescription) } }
        }
    }

    /// Forwards the user's scene-music intent to the real helper-side players and reads the state
    /// back, so a local flag change is never treated as proof that sound was applied.
    func setSceneSound(enabled: Bool, volume: Double) {
        guard state != .disposed else { return }
        // Round-trip through Float: the helper's layers use Float, so the read-back status must
        // compare equal instead of failing on a Double/Float rounding difference.
        let clamped = Double(Float(min(max(volume.isFinite ? volume : 1, 0), 1)))
        soundEnabled = enabled; soundVolume = clamped
        guard let session = context else { return }
        Task { [weak self, weak client = session.client] in
            guard let self, let client else { return }
            do {
                try await client.setSceneSound(enabled: enabled, volume: clamped)
                guard self.context?.client === client else { return }
                let status = try await client.status()
                guard status.sessionID == session.sessionID, status.generation == session.generation,
                      status.soundEnabled == enabled, status.soundVolume == clamped else {
                    throw UniversalSceneBackendError.interrupted
                }
                self.processStatus = status
                self.lastError = nil
            } catch is CancellationError {
            } catch {
                if self.context?.client === client { self.lastError = error.localizedDescription }
            }
        }
    }

    func setAspectFill(_ value: Bool) {
        aspectFill = value; surface.setAspectFill(value)
        let revision = UUID(); aspectRevision = revision
        aspectUpdateTask?.cancel()
        guard let session = context else { return }
        aspectUpdateTask = Task { [weak self, weak client = session.client] in
            guard let self, let client else { return }
            self.frameLoopSuspensions += 1
            defer { self.frameLoopSuspensions -= 1; self.startFrameLoop() }
            do {
                self.stopFrameLoop(); await self.waitForFrameLoop()
                try Task.checkCancellation()
                guard self.aspectRevision == revision, self.context?.client === client else { return }
                try await client.setAspectFill(value)
                try await self.requestFrame(elapsed: self.activeRuntime, ticket: self.operationTicket)
                guard self.aspectRevision == revision, self.context?.client === client else { return }
                let status = try await client.status()
                guard status.instanceID == self.processStatus?.instanceID,
                      status.sessionID == session.sessionID, status.generation == session.generation,
                      status.aspectFill == value else { throw UniversalSceneBackendError.interrupted }
                self.processStatus = status
                self.state = self.desiredPaused ? .paused : .ready
                if !self.desiredPaused { self.startFrameLoop() }
            } catch is CancellationError { }
            catch { if self.aspectRevision == revision, self.context?.client === client { self.fail(error.localizedDescription) } }
        }
    }

    func dispose() {
        guard state != .disposed else { return }
        state = .disposed; lastError = nil; operationTicket = UUID()
        stopFrameLoop(); screenReload?.cancel(); screenReload = nil
        fpsUpdateTask?.cancel(); aspectUpdateTask?.cancel(); frameGate.cancelWaiters()
        let session = context; context = nil
        guard let session else { return }
        Task { [pool] in
            let reusable = await Self.closeAndConfirmExit(client: session.client,
                sessionID: session.sessionID, generation: session.generation, helperPID: session.helperPID)
            pool.release(session.leaseIndex, reusable: reusable)
        }
    }

    private func connectOwnedService(name: String, ticket: UUID) async throws -> SceneBackendSessionTransport {
        for attempt in 0..<20 {
            try Task.checkCancellation(); try requireTicket(ticket)
            let client = transportFactory(name)
            let status: SceneBackendProcessStatus
            do { status = try await client.status() }
            catch { client.invalidate(); throw error }
            if status.ownsSession {
                processStatus = status; return client
            }
            client.invalidate()
            if attempt < 19 { try await Task.sleep(for: .milliseconds(100)) }
        }
        throw UniversalSceneBackendError.unavailable
    }

    private func requestFrame(elapsed: Double, ticket: UUID) async throws {
        try await frameGate.acquire()
        defer { frameGate.release() }
        try Task.checkCancellation(); try requireTicket(ticket)
        guard var session = context else { throw UniversalSceneBackendError.notReady }
        session.sequence &+= 1
        guard session.sequence > 0, elapsed.isFinite, elapsed >= 0 else { throw UniversalSceneBackendError.invalidFrame }
        context = session
        let cursor = cursorPosition(width: session.width, height: session.height)
        let input = SceneFrameInput(sessionID: session.sessionID, generation: session.generation,
            sequence: session.sequence, elapsedSeconds: elapsed, cursorX: cursor?.0, cursorY: cursor?.1,
            leftMouseDown: false)
        let (token, ioSurface) = try await session.client.render(input)
        guard context?.sessionID == session.sessionID, operationTicket == ticket,
              token.sessionID == session.sessionID, token.generation == session.generation,
              token.sequence == session.sequence, token.width == session.width, token.height == session.height else {
            throw UniversalSceneBackendError.invalidFrame
        }
        try await surface.consume(surface: ioSurface, token: token)
        try await session.client.acknowledge(token)
        guard context?.sessionID == session.sessionID, operationTicket == ticket else { throw CancellationError() }
        frameCount += 1
    }

    /// Finite export mode: one frame per explicit timestamp and no automatic
    /// loop. The helper clock advances from each supplied timestamp instead of
    /// being frozen by `setPaused(true)`. The token is acknowledged only after
    /// the display-equivalent GPU copy into the encoder pixel buffer completes.
    func renderManualFrame(elapsed: Double, into pixelBuffer: CVPixelBuffer) async throws {
        guard manualFrameExport else { throw SceneManualFrameError.notInManualMode }
        try await frameGate.acquire()
        defer { frameGate.release() }
        try Task.checkCancellation(); try requireActive()
        guard state == .ready || state == .paused, var session = context else {
            throw UniversalSceneBackendError.notReady
        }
        session.sequence &+= 1
        guard session.sequence > 0, elapsed.isFinite, elapsed >= 0 else {
            throw UniversalSceneBackendError.invalidFrame
        }
        context = session
        let ticket = operationTicket
        let input = SceneFrameInput(sessionID: session.sessionID, generation: session.generation,
            sequence: session.sequence, elapsedSeconds: elapsed,
            cursorX: nil, cursorY: nil, leftMouseDown: false)
        let (token, ioSurface) = try await session.client.render(input)
        guard context?.sessionID == session.sessionID, operationTicket == ticket,
              token.sessionID == session.sessionID, token.generation == session.generation,
              token.sequence == session.sequence, token.width == session.width,
              token.height == session.height else {
            throw UniversalSceneBackendError.invalidFrame
        }
        try await surface.copyFrame(surface: ioSurface, token: token, into: pixelBuffer)
        try await session.client.acknowledge(token)
        guard context?.sessionID == session.sessionID, operationTicket == ticket else {
            throw CancellationError()
        }
        frameCount += 1
        activeRuntime = elapsed
    }

    /// Reads the helper's real Scene clock (no inferred/fake ACK) so the export
    /// can prove its timestamps advanced Scene time.
    func currentHelperSceneSeconds() async throws -> Double? {
        try requireActive()
        guard let session = context else { throw UniversalSceneBackendError.notReady }
        let status = try await session.client.status()
        guard status.sessionID == session.sessionID, status.generation == session.generation else {
            throw UniversalSceneBackendError.interrupted
        }
        processStatus = status
        return status.sceneSeconds
    }

    private func startFrameLoop() {
        guard frameLoop == nil, frameLoopSuspensions == 0, !desiredPaused, !manualFrameExport, state == .ready else { return }
        let ticket = operationTicket
        let loopID = UUID(); frameLoopID = loopID
        if lastTick == nil { lastTick = .now }
        frameLoop = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.frameLoopID == loopID {
                    self.frameLoop = nil; self.frameLoopID = nil
                    // Resume may have arrived while this cancelled loop was
                    // still awaiting its GPU/XPC frame. Reconcile the latest
                    // intent after draining instead of losing that resume.
                    self.startFrameLoop()
                }
            }
            while !Task.isCancelled, self.state == .ready, self.operationTicket == ticket, !self.desiredPaused {
                let interval = Duration.seconds(1.0 / Double(self.frameRateLimit))
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, self.state == .ready, !self.desiredPaused else { break }
                let now = ContinuousClock.now
                let delta = self.lastTick.map { instant -> Double in
                    let duration = instant.duration(to: now).components
                    return max(0, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
                } ?? 0
                self.lastTick = now; self.activeRuntime += delta
                do { try await self.requestFrame(elapsed: self.activeRuntime, ticket: ticket) }
                catch is CancellationError { break }
                catch { self.fail(error.localizedDescription); break }
            }
        }
    }

    private func stopFrameLoop() { frameLoop?.cancel(); lastTick = nil }
    private func waitForFrameLoop() async {
        if let frameLoop {
            let id = frameLoopID
            await frameLoop.value
            if frameLoopID == id { self.frameLoop = nil; frameLoopID = nil }
        }
    }

    private func retireCurrentSession() async {
        stopFrameLoop(); await waitForFrameLoop()
        guard let session = context else { return }
        context = nil; processStatus = nil
        await session.client.close(sessionID: session.sessionID, generation: session.generation)
        session.client.invalidationHandler = nil; await session.client.invalidateAndWait()
        let reusable = await SceneBackendProcessExit.wait(pid: session.helperPID)
        pool.release(session.leaseIndex, reusable: reusable)
    }

    private func resolvedPixelSize(project: AuthorPropertyProject, ticket: UUID) async throws -> (Int, Int) {
        try Task.checkCancellation(); try requireTicket(ticket)
        if followsHostScreen && screenResolution == nil { screenDidChange(surface.window?.screen) }
        if let screenResolution {
            try Self.validateResolution(screenResolution)
            return (Int(screenResolution.x.rounded()), Int(screenResolution.y.rounded()))
        }
        if let raw = project.rawJSON.objectValue?["general"]?.objectValue,
           let projection = raw["orthogonalprojection"]?.objectValue,
           let width = projection["width"]?.numberValue, let height = projection["height"]?.numberValue {
            let value = SceneVector2(x: width, y: height); try Self.validateResolution(value)
            return (Int(width.rounded()), Int(height.rounded()))
        }
        return (1920, 1080)
    }

    private func screenDidChange(_ screen: NSScreen?) {
        guard followsHostScreen, let screen, let size = Self.physicalSize(screen) else { return }
        let next = SceneVector2(x: Double(size.width), y: Double(size.height))
        guard screenResolution != next else { return }
        screenResolution = next
        guard state == .ready || state == .paused else { return }
        scheduleScreenReload(propertiesJSON: lastProperties)
    }

    private func scheduleScreenReload(propertiesJSON: Data) {
        screenReload?.cancel()
        screenReload = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
                try await self?.load(propertiesJSON: propertiesJSON)
            }
            catch { }
        }
    }

    private func cursorPosition(width: Int, height: Int) -> (Float, Float)? {
        guard let window = surface.window, !window.isMiniaturized else { return nil }
        let point = surface.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard surface.bounds.contains(point), surface.bounds.width > 0, surface.bounds.height > 0 else { return nil }
        return (Float(point.x / surface.bounds.width * CGFloat(width)),
                Float(point.y / surface.bounds.height * CGFloat(height)))
    }

    private static func physicalSize(_ screen: NSScreen) -> CGSize? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let mode = CGDisplayCopyDisplayMode(CGDirectDisplayID(number.uint32Value)) else { return nil }
        let portrait = screen.frame.height > screen.frame.width
        let width = CGFloat(mode.pixelWidth), height = CGFloat(mode.pixelHeight)
        return portrait == (height > width) ? CGSize(width: width, height: height) : CGSize(width: height, height: width)
    }

    private static func validateResolution(_ value: SceneVector2) throws {
        guard value.x.isFinite, value.y.isFinite, value.x >= 1, value.y >= 1,
              value.x <= 8192, value.y <= 8192,
              value.x.rounded() == value.x, value.y.rounded() == value.y,
              value.x * value.y <= 16_777_216 else { throw UniversalSceneBackendError.invalidProject }
    }

    private func requireActive() throws { if state == .disposed { throw UniversalSceneBackendError.disposed } }
    private func requireTicket(_ ticket: UUID) throws {
        try requireActive(); guard operationTicket == ticket else { throw CancellationError() }
    }
    private func recordLoadTiming(_ phase: String, since start: ContinuousClock.Instant,
                                  ticket: UUID) {
        guard operationTicket == ticket, state != .disposed else { return }
        let elapsed = sceneLoadElapsedMilliseconds(since: start)
        guard elapsed.isFinite, elapsed >= 0 else { return }
        sceneLoadTimingMilliseconds[phase] = elapsed
    }
    private func recordLoadTimings(_ values: [String: Double], ticket: UUID) {
        guard operationTicket == ticket, state != .disposed, !values.isEmpty else { return }
        for (phase, elapsed) in values where elapsed.isFinite && elapsed >= 0 {
            sceneLoadTimingMilliseconds[phase] = elapsed
        }
    }
    private func fail(_ message: String, detail: SceneBackendFailureDetail? = nil) {
        stopFrameLoop(); fpsUpdateTask?.cancel(); aspectUpdateTask?.cancel(); frameGate.cancelWaiters()
        state = .failed; lastError = message; lastFailureDetail = detail
        guard let session = context else { return }
        context = nil; processStatus = nil
        Task { [pool] in
            let reusable = await Self.closeAndConfirmExit(client: session.client,
                sessionID: session.sessionID, generation: session.generation, helperPID: session.helperPID)
            pool.release(session.leaseIndex, reusable: reusable)
        }
    }

    private static func closeAndConfirmExit(client: SceneBackendSessionTransport, sessionID: UUID,
                                            generation: UInt64, helperPID: Int32?) async -> Bool {
        client.invalidationHandler = nil
        await client.close(sessionID: sessionID, generation: generation)
        await client.invalidateAndWait()
        guard let helperPID else { return false }
        return await SceneBackendProcessExit.wait(pid: helperPID)
    }

    isolated deinit {
        frameLoop?.cancel(); fpsUpdateTask?.cancel(); aspectUpdateTask?.cancel(); screenReload?.cancel()
        if let context {
            Task { @MainActor [pool] in
                let reusable = await Self.closeAndConfirmExit(client: context.client,
                    sessionID: context.sessionID, generation: context.generation, helperPID: context.helperPID)
                pool.release(context.leaseIndex, reusable: reusable)
            }
        }
    }
}

private final class SceneLoadPreparationTimingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Double] = [:]

    func record(_ phase: String, since start: ContinuousClock.Instant) {
        let elapsed = sceneLoadElapsedMilliseconds(since: start)
        guard elapsed.isFinite, elapsed >= 0 else { return }
        lock.lock()
        values[phase] = elapsed
        lock.unlock()
    }

    var snapshot: [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private func sceneLoadElapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
    let components = start.duration(to: ContinuousClock.now).components
    return max(0, Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000)
}

struct SceneBackendPropertyValues: Sendable {
    let values: [String: String]
    let editableKeys: Set<String>

    static func normalize(_ payload: Data, project: AuthorPropertyProject) throws -> Self {
        guard payload.count <= AuthorPropertyProject.maximumBytes,
              let supplied = try JSONDecoder().decode(GWJSONValue.self, from: payload).objectValue,
              supplied.count <= 2048 else { throw UniversalSceneBackendError.invalidProperties }
        let definitions = Dictionary(uniqueKeysWithValues: project.properties.map { ($0.key, $0) })
        guard supplied.keys.allSatisfy({ definitions[$0] != nil }) else { throw UniversalSceneBackendError.invalidProperties }
        var overrides = [String: GWJSONValue]()
        for (key, wrapper) in supplied {
            let value = wrapper.objectValue?["value"] ?? wrapper
            guard let definition = definitions[key] else { throw UniversalSceneBackendError.invalidProperties }
            if isSupported(definition) { try definition.validate(value); overrides[key] = value }
        }
        let resolved = project.resolve(overrides: overrides)
        var output = [String: String](), editable = Set<String>()
        for definition in project.properties where isSupported(definition) {
            guard let value = resolved.values[definition.key] else { continue }
            try definition.validate(value)
            guard let text = string(value), definition.key.utf8.count <= 256,
                  text.utf8.count <= 16_384 else { throw UniversalSceneBackendError.invalidProperties }
            output[definition.key] = text; editable.insert(definition.key)
        }
        guard output.count <= 256 else { throw UniversalSceneBackendError.invalidProperties }
        return .init(values: output, editableKeys: editable)
    }

    private static func isSupported(_ definition: AuthorPropertyDefinition) -> Bool {
        guard !["scenetexture", "filetexture", "texture", "usershortcut", "shortcut"].contains(definition.rawType.lowercased()) else { return false }
        return [.bool, .slider, .color, .combo, .textinput].contains(definition.kind)
    }

    private static func string(_ value: GWJSONValue) -> String? {
        switch value {
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            guard value.isFinite else { return nil }
            if value.rounded() == value, abs(value) < 1e15 { return String(Int(value)) }
            return String(value)
        case .string(let value): return value.contains("\0") ? nil : value
        default: return nil
        }
    }
}

@MainActor
private final class SceneBackendFrameGate {
    private var occupied = false
    private var waiters = [(UUID, CheckedContinuation<Bool, Never>)]()

    func acquire() async throws {
        try Task.checkCancellation()
        if !occupied { occupied = true; return }
        guard waiters.count < 32 else { throw UniversalSceneBackendError.capacity }
        let id = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { waiters.append((id, $0)) }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel(id) } }
        guard granted else { throw CancellationError() }
        if Task.isCancelled { release(); throw CancellationError() }
    }

    func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().1.resume(returning: true) }
    }

    func cancelWaiters() {
        let pending = waiters; waiters = []
        pending.forEach { $0.1.resume(returning: false) }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(returning: false)
    }
}
