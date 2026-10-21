import AppKit
import Foundation
import ImageIO
import Observation

/// Static scenes allocate no worker or frame loop. Scripted scenes serialize
/// helper updates and cached-texture composition with real pixel acknowledgements.
@MainActor @Observable
final class LegacySceneWallpaperRuntime {
    enum State: String, Sendable { case idle, loading, ready, paused, failed, disposed }
    let projectURL: URL
    private let surface = SceneRuntimeImageView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    var hostView: NSView { surface }
    private(set) var state: State = .idle
    private(set) var lastError: String?
    private(set) var posterImage: CGImage?
    private(set) var inspection: SceneWallpaperInspection?
    private(set) var editablePropertyKeys: Set<String> = []
    private(set) var isAnimated = false
    private(set) var frameCount = 0
    private(set) var activeRuntime: Double = 0
    private(set) var frameRateLimit = 30
    private let inspectionBarrier: (@Sendable () async throws -> Void)?
    private let workerExecutableURL: URL?
    private let engineAssets: SceneEngineAssetBundle?
    private var paused = false
    private var generation = UUID()
    private var work: Task<ScenePreparedResult, Never>?
    private var prepared: ScenePreparedRuntime?
    private var worker: SceneScriptWorkerClient?
    private var mutation: Task<ScenePublishedFrame, Error>?
    private var frameOperation: Task<Void, Error>?
    private var frameLoop: Task<Void, Never>?
    private var loopGeneration = UUID()
    private var lastTick: ContinuousClock.Instant?
    private(set) var screenResolution: SceneVector2?
    private(set) var lastFrameInput = SceneScriptInputSnapshot()
    private var appliedEnvironment: SceneScriptEnvironment?
    private let followsHostScreen: Bool
    private var screenUpdateTask: Task<Void, Never>?
    private var desiredNativeResolution: SceneVector2?
    private var scheduledNativeResolution: SceneVector2?
    /// The legacy renderer has no audio player; the intent is remembered for source compatibility
    /// only and is never reported as an applied capability.
    private(set) var soundEnabled = false
    private(set) var soundVolume = 1.0
    private var screenTaskTicket = UUID()
    private let mutationGate = SceneRuntimeMutationGate()
    private var loadingTicket: UUID?
    private var loadWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]


    init(projectURL: URL, inspectionBarrier: (@Sendable () async throws -> Void)? = nil,
         workerExecutableURL: URL? = nil, screenResolution: SceneVector2? = nil, followsHostScreen: Bool = false,
         engineAssets: SceneEngineAssetBundle? = nil) throws {
        let project = try AuthorPropertyProject.load(projectURL: projectURL, allowedRoot: projectURL.deletingLastPathComponent())
        guard project.projectType.lowercased() == "scene" else { throw SceneWallpaperFailure(message: "项目不是 Scene 壁纸。") }
        guard let entry = project.rawJSON.objectValue?["file"]?.stringValue else { throw SceneWallpaperFailure(message: "Scene 项目缺少入口。") }
        _ = try ScenePackageArchive.normalizedPath(entry)
        self.projectURL = projectURL.standardizedFileURL
        if let screenResolution { try SceneScriptEnvironment.validateScreen(screenResolution) }
        self.inspectionBarrier = inspectionBarrier; self.workerExecutableURL = workerExecutableURL; self.engineAssets = engineAssets
        self.screenResolution = screenResolution; self.followsHostScreen = followsHostScreen
        if followsHostScreen { surface.onScreenChange = { [weak self] screen in self?.hostScreenDidChange(screen) } }

    }

    func load(propertiesJSON: Data) async throws {
        try requireActive(); try Task.checkCancellation()
        mutationGate.cancelWaiters()
        let ticket = UUID(); generation = ticket; loadingTicket = ticket
        defer { finishLoading(ticket) }
        let previousError = lastError
        stopFrameLoop(); work?.cancel(); mutation?.cancel(); frameOperation?.cancel()
        if let old = worker { Task { await old.dispose() } }; worker = nil
        prepared = nil; appliedEnvironment = nil; lastFrameInput = .init(); isAnimated = false; state = .loading; lastError = nil
        let url = projectURL, barrier = inspectionBarrier, engineAssets = engineAssets
        let task = Task.detached(priority: .userInitiated) { () -> ScenePreparedResult in
            var keys: Set<String> = []
            do {
                try await barrier?(); try Task.checkCancellation()
                let project = try AuthorPropertyProject.load(projectURL: url, allowedRoot: url.deletingLastPathComponent())
                guard project.projectType.lowercased() == "scene" else { throw SceneWallpaperFailure(message: "项目不再是 Scene 壁纸。") }
                let resolution = try SceneEngineAssetResolver.production.resolve(projectURL: url, engineAssets: engineAssets)
                let defaults = resolution.inspection
                if defaults.isRenderableSubset { keys = try SceneAuthorPropertySupport.editableKeys(project: project, inspection: defaults) }
                let values = try SceneAuthorPropertySupport.validatedPayload(propertiesJSON, project: project)
                try Task.checkCancellation()
                let inspected = try SceneWallpaperInspector.inspect(projectURL: url, propertiesJSON: values, engineAssets: resolution.engineAssets)
                guard inspected.isRenderableSubset else {
                    throw SceneWallpaperFailure(message: inspected.diagnostics.map { "\($0.path)：\($0.message)" }.joined(separator: "\n"))
                }
                keys = try SceneAuthorPropertySupport.editableKeys(project: project, inspection: inspected)
                try SceneAuthorPropertySupport.validateBindingOverrides(values, project: project, inspection: inspected, editableKeys: keys)
                let cached = try SceneRuntimeTextureCache.prepare(inspected)
                let size = cached.canvasSize
                let factor = min(1, 4096 / max(size.x, size.y), sqrt(Double(16 * 1024 * 1024) / (size.x * size.y)))
                let pixels = CGSize(width: max(1, floor(size.x * factor)), height: max(1, floor(size.y * factor)))
                return .success(ScenePreparedRuntime(project: project, inspection: cached, pixelSize: pixels,
                    payload: try SceneAuthorPropertySupport.fullWorkerPayload(values, project: project), directKeys: keys))
            } catch is CancellationError { return .cancelled }
            catch { return .failure(error.localizedDescription, keys) }
        }
        work = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard generation == ticket, state != .disposed else { throw CancellationError() }
        work = nil
        if Task.isCancelled { restoreCancellation(previousError); throw CancellationError() }
        switch result {
        case .cancelled: restoreCancellation(previousError); throw CancellationError()
        case .failure(let message, let keys):
            editablePropertyKeys.formUnion(keys); fail(message); throw SceneWallpaperFailure(message: message)
        case .success(let context):
            editablePropertyKeys = context.directKeys
            let client = context.inspection.scriptProgram == nil ? nil : SceneScriptWorkerClient(executableURL: workerExecutableURL)
            worker = client
            do {
                var inspected = context.inspection
                var updateHandlers = false, propertyCallback = false
                if let client, let program = inspected.scriptProgram {
                    if followsHostScreen && screenResolution == nil {
                        // SwiftUI attaches the actual NSView on its next transaction.
                        // Never substitute the render buffer or an unrelated main screen.
                        for _ in 0..<100 {
                            try Task.checkCancellation(); try checkGeneration(ticket)
                            hostScreenDidChange(surface.window?.screen)
                            if screenResolution != nil { break }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        guard screenResolution != nil else { throw SceneWallpaperFailure(message: "Scene 预览尚未连接真实显示器，请重试。") }
                    }
                    let environment = scriptEnvironment(canvas: inspected.canvasSize)
                    var frame = try await client.configure(program: program, userProperties: context.payload, environment: environment)
                    try Task.checkCancellation(); try checkGeneration(ticket)
                    appliedEnvironment = environment
                    // configure has genuinely discovered/executed the callback.
                    // Keep that observed capability even if its first update fails,
                    // so an invalid saved scalar can be repaired without guessing.
                    editablePropertyKeys = context.directKeys.union(Self.scriptEditableKeys(context.project,
                        program: inspected.scriptProgram, hasCallback: frame.canApplyUserProperties, hasUpdates: frame.hasUpdateHandlers))
                    if frame.hasUpdateHandlers {
                        let input = paused ? lastFrameInput : cursorInputSnapshot(for: context)
                        lastFrameInput = input
                        frame = try await client.step(runtime: 0, frameTime: 0, input: input)
                        try Task.checkCancellation(); try checkGeneration(ticket)
                    }
                    inspected = try inspected.applyingScriptFrame(frame)
                    updateHandlers = frame.hasUpdateHandlers; propertyCallback = frame.canApplyUserProperties
                }
                let image = try await compose(inspected, size: context.pixelSize)
                try Task.checkCancellation(); try checkGeneration(ticket)
                prepared = context; activeRuntime = 0; frameCount = 0
                if let applied = appliedEnvironment?.screenResolution { screenResolution = applied }
                isAnimated = updateHandlers || inspected.parallax != nil || inspected.layers.contains(where:{$0.particleSystem != nil || $0.lightShaft != nil})
                editablePropertyKeys = context.directKeys.union(Self.scriptEditableKeys(context.project, program: context.inspection.scriptProgram, hasCallback: propertyCallback, hasUpdates: updateHandlers))
                publish(inspected, image: image)
                startFrameLoop()
            } catch {
                if let client { await client.dispose() }
                guard generation == ticket, state != .disposed else { throw CancellationError() }
                worker = nil; isAnimated = false
                if error is CancellationError { restoreCancellation(previousError) }
                else { fail(error.localizedDescription) }
                throw error
            }
        }
    }

    func applyPropertiesAndWait(_ payload: Data) async throws {
        try requireActive(); try Task.checkCancellation()
        try await mutationGate.acquire()
        defer { mutationGate.release() }
        try requireActive(); try Task.checkCancellation()
        // Static updates keep their established inspection path. A failed helper
        // requires a fresh isolated worker; its previous successful pixels stay visible.
        guard let context = prepared, context.inspection.scriptProgram != nil,
              let client = worker, state != .failed else { try await load(propertiesJSON: payload); return }
        try requireActive(); try Task.checkCancellation()
        let previous = mutation, frame = frameOperation
        let ticket = UUID(); generation = ticket
        stopFrameLoop(); state = .loading; lastError = nil
        let task = Task { () throws -> ScenePublishedFrame in
            if let previous { _ = await previous.result }
            if let frame { _ = await frame.result }
            try Task.checkCancellation(); try self.checkGeneration(ticket)
            let values = try SceneAuthorPropertySupport.validatedPayload(payload, project: context.project)
            try SceneAuthorPropertySupport.validateBindingOverrides(values, project: context.project,
                inspection: context.inspection, editableKeys: self.editablePropertyKeys)
            let supplied = try JSONDecoder().decode(GWJSONValue.self, from: values).objectValue ?? [:]
            let mappedKeys = Set(context.inspection.scriptProgram?.bindings.flatMap { $0.scriptPropertyBindings.values } ?? [])
            for key in mappedKeys.subtracting(self.editablePropertyKeys) {
                if let value = supplied[key], value != context.project.definition(for: key)?.defaultValue {
                    throw SceneWallpaperFailure(message: "此脚本仅在初始化时使用该属性，后续修改尚不支持：\(key)")
                }
            }
            let full = try SceneAuthorPropertySupport.fullWorkerPayload(values, project: context.project)
            var next = try await client.applyUserProperties(full, runtime: self.activeRuntime)
            try Task.checkCancellation(); try self.checkGeneration(ticket)
            // Callback/mapped values often affect update() through closure state.
            // Evaluate that current-time frame before ACK, including while paused;
            // this does not advance engine.runtime or accumulate frame time.
            if next.hasUpdateHandlers {
                next = try await client.step(runtime: self.activeRuntime, frameTime: 0, input: self.lastFrameInput)
                try Task.checkCancellation(); try self.checkGeneration(ticket)
            }
            let inspected = try context.inspection.applyingScriptFrame(next)
            let image = try await self.compose(inspected, size: context.pixelSize)
            try Task.checkCancellation(); try self.checkGeneration(ticket)
            return ScenePublishedFrame(inspection: inspected, image: image, scriptFrame: next)
        }
        mutation = task
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try checkGeneration(ticket); mutation = nil
            isAnimated = result.scriptFrame.hasUpdateHandlers || result.inspection.layers.contains(where:{$0.particleSystem != nil || $0.lightShaft != nil})
            editablePropertyKeys = context.directKeys.union(Self.scriptEditableKeys(context.project, program: context.inspection.scriptProgram, hasCallback: result.scriptFrame.canApplyUserProperties, hasUpdates: result.scriptFrame.hasUpdateHandlers))
            publish(result.inspection, image: result.image); startFrameLoop()
        } catch {
            guard generation == ticket, state != .disposed else { throw CancellationError() }
            mutation = nil; isAnimated = false
            // A cancellation during RPC may have terminated its helper. Always
            // retire it rather than let ready imply a live script engine.
            await client.dispose(); worker = nil
            if error is CancellationError { fail("Scene 更新已取消，可重新加载。") }
            else { fail(error.localizedDescription) }
            throw error
        }
    }

    /// Host-resolution changes are serialized with property RPCs and frames.
    /// Does not advance time and still renders/ACKs while paused. Startup only
    /// configures the environment; no synthetic resizeScreen event is emitted.
    func updateScreenResolutionAndWait(_ size: SceneVector2) async throws {
        try requireActive(); try Task.checkCancellation(); try SceneScriptEnvironment.validateScreen(size)
        try await mutationGate.acquire()
        defer { mutationGate.release() }
        try requireActive(); try Task.checkCancellation()
        // Each explicit call owns its fixed parameter and FIFO ACK. Native events
        // may coalesce before entering this method; queued calls never lie about size.
        screenResolution = size
        try await waitForCurrentLoad()
        try requireActive(); try Task.checkCancellation()
        screenResolution = size
        guard let context = prepared else {
            throw SceneWallpaperFailure(message: lastError ?? "Scene 尚未完成加载，未确认尺寸应用。")
        }
        guard context.inspection.scriptProgram != nil else { return }
        guard let client = worker, state != .failed else { throw SceneWallpaperFailure(message: lastError ?? "SceneScript 需要重新加载。") }
        let environment = scriptEnvironment(canvas: context.inspection.canvasSize)
        if appliedEnvironment == environment { return }
        let previous = mutation, frame = frameOperation
        let ticket = UUID(); generation = ticket
        stopFrameLoop(); state = .loading; lastError = nil
        let task = Task { () throws -> ScenePublishedFrame in
            if let previous { _ = await previous.result }
            if let frame { _ = await frame.result }
            try Task.checkCancellation(); try self.checkGeneration(ticket)
            var next = try await client.resizeScreen(environment, runtime: self.activeRuntime)
            try Task.checkCancellation(); try self.checkGeneration(ticket)
            if next.hasUpdateHandlers {
                next = try await client.step(runtime: self.activeRuntime, frameTime: 0, input: self.lastFrameInput)
                try Task.checkCancellation(); try self.checkGeneration(ticket)
            }
            let inspected = try context.inspection.applyingScriptFrame(next)
            let image = try await self.compose(inspected, size: context.pixelSize)
            try Task.checkCancellation(); try self.checkGeneration(ticket)
            return .init(inspection: inspected, image: image, scriptFrame: next)
        }
        mutation = task
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try checkGeneration(ticket); mutation = nil; appliedEnvironment = environment
            isAnimated = result.scriptFrame.hasUpdateHandlers || result.inspection.layers.contains(where:{$0.particleSystem != nil || $0.lightShaft != nil})
            publish(result.inspection, image: result.image); startFrameLoop()
        } catch {
            guard generation == ticket, state != .disposed else { throw CancellationError() }
            mutation = nil; isAnimated = false; await client.dispose(); worker = nil
            fail(error is CancellationError ? "Scene 尺寸更新已取消，可重新加载。" : error.localizedDescription)
            throw error
        }
    }
    private func waitForCurrentLoad() async throws {
        while loadingTicket != nil {
            let ticket = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { pending in
                    if loadingTicket == nil { pending.resume() }
                    else { loadWaiters[ticket] = pending }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.loadWaiters.removeValue(forKey: ticket)?.resume() }
            }
            try Task.checkCancellation(); try requireActive()
        }
    }
    private func finishLoading(_ ticket: UUID? = nil) {
        guard ticket == nil || loadingTicket == ticket else { return }
        loadingTicket = nil
        let waiters = loadWaiters; loadWaiters = [:]
        waiters.values.forEach { $0.resume() }
    }
    private func scriptEnvironment(canvas: SceneVector2) -> SceneScriptEnvironment {
        .init(canvasSize: canvas, screenResolution: screenResolution, presentation: .wallpaper)
    }
    /// CGDisplayPixelsWide returns logical mode width on this Retina Mac.
    /// Use CGDisplayMode's backing-pixel dimensions, oriented to display bounds.
    static func physicalScreenResolution(displayID: UInt32) -> SceneVector2? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        var width = Double(mode.pixelWidth), height = Double(mode.pixelHeight)
        let bounds = CGDisplayBounds(displayID)
        if bounds.width != bounds.height, (bounds.width < bounds.height) != (width < height) { swap(&width, &height) }
        let size = SceneVector2(x: width, y: height)
        return (try? SceneScriptEnvironment.validateScreen(size)) == nil ? nil : size
    }
    private func hostScreenDidChange(_ screen: NSScreen?) {
        guard followsHostScreen, state != .disposed, let screen,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        guard let size = Self.physicalScreenResolution(displayID: displayID.uint32Value), size != desiredNativeResolution else { return }
        desiredNativeResolution = size
        if prepared == nil { screenResolution = size }
        schedulePendingScreenUpdate()
    }
    private func schedulePendingScreenUpdate() {
        guard followsHostScreen, state != .disposed, state != .failed,
              let size = desiredNativeResolution, prepared != nil, worker != nil,
              size != appliedEnvironment?.screenResolution, size != scheduledNativeResolution else { return }
        let previous = screenUpdateTask, ticket = UUID()
        screenTaskTicket = ticket; scheduledNativeResolution = size
        screenUpdateTask = Task { [weak self] in
            if let previous { await previous.value }
            guard !Task.isCancelled, let self, self.state != .disposed else { return }
            // Coalesce native changes not yet enqueued. Explicit API calls retain
            // their parameter; no later event cancels an active properties RPC.
            do { try await self.updateScreenResolutionAndWait(self.desiredNativeResolution ?? size) }
            catch is CancellationError {} catch { /* Runtime retains the diagnostic and last successful pixels. */ }
            if self.screenTaskTicket == ticket {
                self.scheduledNativeResolution = nil
                self.schedulePendingScreenUpdate()
            }
        }
    }

    func setAspectFill(_ value: Bool) { guard state != .disposed else { return }; surface.setAspectFill(value) }
    func setFrameRateLimit(_ fps: Int) throws {
        try requireActive()
        guard (1...240).contains(fps) else {
            throw SceneWallpaperFailure(message: "Scene 壁纸帧率必须在 1...240 之间。")
        }
        guard frameRateLimit != fps else { return }
        frameRateLimit = fps
        stopFrameLoop()
        startFrameLoop()
    }
    func setPaused(_ value: Bool) {
        guard state != .disposed else { return }
        paused = value
        if value { stopFrameLoop() }
        if state == .ready || state == .paused { state = value ? .paused : .ready }
        if !value { startFrameLoop() }
    }
    /// No-op: scene sound is provided by the universal backend only. The legacy fallback never
    /// claims it applied the intent.
    func setSceneSound(enabled: Bool, volume: Double) {
        soundEnabled = enabled
        soundVolume = volume.isFinite ? min(max(volume, 0), 1) : 1
    }
    func dispose() {
        guard state != .disposed else { return }
        generation = UUID(); stopFrameLoop(); work?.cancel(); work = nil
        mutation?.cancel(); mutation = nil; frameOperation?.cancel(); frameOperation = nil
        if let client = worker { Task { await client.dispose() } }; worker = nil
        finishLoading(); mutationGate.cancelWaiters(); screenTaskTicket = UUID(); scheduledNativeResolution = nil
        screenUpdateTask?.cancel(); screenUpdateTask = nil; surface.stopScreenObservation(); surface.onScreenChange = nil
        prepared = nil; appliedEnvironment = nil; lastFrameInput = .init(); posterImage = nil; inspection = nil; editablePropertyKeys = []
        isAnimated = false; surface.publish(nil); state = .disposed; lastError = nil
    }
    private func requireActive() throws {
        guard state != .disposed else { throw SceneWallpaperFailure(message: "Scene 预览已关闭。") }
    }
    private func checkGeneration(_ ticket: UUID) throws {
        guard generation == ticket, state != .disposed else { throw CancellationError() }
    }
    private func restoreCancellation(_ error: String?) {
        lastError = error
        state = error != nil ? .failed : (posterImage == nil ? .idle : (paused ? .paused : .ready))
    }
    private func fail(_ message: String) { stopFrameLoop(); lastError = message; state = .failed; isAnimated = false }
    private func publish(_ inspected: SceneWallpaperInspection, image: CGImage) {
        inspection = inspected; posterImage = image; frameCount += 1
        surface.publish(image); state = paused ? .paused : .ready; lastError = nil
        schedulePendingScreenUpdate()
    }
    private func compose(_ inspected: SceneWallpaperInspection, size: CGSize, runtime: Double? = nil) async throws -> CGImage {
        let time=runtime ?? activeRuntime, cursor=lastFrameInput.cursorWorldPosition
        let render = Task.detached(priority: .userInitiated) { try SceneWallpaperRenderer.render(inspection: inspected, pixelSize: size, runtime:time,cursorWorldPosition:cursor) }
        return try await withTaskCancellationHandler { try await render.value } onCancel: { render.cancel() }
    }
    private func cursorInputSnapshot(for context: ScenePreparedRuntime) -> SceneScriptInputSnapshot {
        SceneScriptInputSnapshot(cursorWorldPosition: surface.cursorWorldPosition(
            mouseLocation: NSEvent.mouseLocation, imageSize: context.pixelSize,
            canvasSize: context.inspection.canvasSize, camera: context.inspection.camera
        ))
    }
    private func stopFrameLoop() { loopGeneration = UUID(); frameLoop?.cancel(); frameLoop = nil; lastTick = nil }
    private func startFrameLoop() {
        guard isAnimated, !paused, state == .ready, frameLoop == nil, let context = prepared else { return }
        let client=worker
        guard context.inspection.scriptProgram == nil || client != nil else {return}
        let token = UUID(); loopGeneration = token
        lastTick = ContinuousClock.now
        let interval = Duration.nanoseconds(Int64(1_000_000_000 / frameRateLimit))
        frameLoop = Task { [weak self] in
            var deadline = ContinuousClock.now + interval
            while !Task.isCancelled {
                do { try await ContinuousClock().sleep(until: deadline) } catch { break }
                guard let self, self.loopGeneration == token, !self.paused, self.state == .ready else { break }
                if let prior = self.frameOperation { _ = await prior.result }
                guard !Task.isCancelled, self.loopGeneration == token, !self.paused, self.state == .ready else { break }
                let now = ContinuousClock.now
                let elapsed = self.lastTick.map { $0.duration(to: now) } ?? .zero
                self.lastTick = now
                let delta = max(0, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                self.activeRuntime += delta
                let time = self.activeRuntime, ticket = self.generation
                let input = self.cursorInputSnapshot(for: context)
                self.lastFrameInput = input
                let operation = Task {
                    var inspected=context.inspection
                    if let client {
                        let frame = try await client.step(runtime: time, frameTime: delta, input: input)
                        try Task.checkCancellation(); try self.checkGeneration(ticket)
                        inspected = try inspected.applyingScriptFrame(frame)
                    }
                    guard self.loopGeneration == token, !self.paused else { throw CancellationError() }
                    let image = try await self.compose(inspected, size: context.pixelSize,runtime:time)
                    try Task.checkCancellation(); try self.checkGeneration(ticket)
                    guard self.loopGeneration == token, !self.paused else { throw CancellationError() }
                    self.publish(inspected, image: image)
                }
                self.frameOperation = operation
                do { try await operation.value }
                catch {
                    if self.loopGeneration == token, self.generation == ticket, self.state != .disposed, !(error is CancellationError) {
                        self.fail(error.localizedDescription); self.worker = nil; await client?.dispose()
                    }
                }
                if self.loopGeneration == token { self.frameOperation = nil }
                // At most one step+render in flight. Slow frames are dropped,
                // never replayed as accumulated timer work.
                deadline = max(now + interval, ContinuousClock.now)
            }
        }
    }
    private static func scriptEditableKeys(_ project: AuthorPropertyProject, program: SceneScriptProgram?, hasCallback: Bool, hasUpdates: Bool) -> Set<String> {
        let defaults = project.resolve(overrides: [:]).values
        let mapped = Set(program?.bindings.flatMap { $0.scriptPropertyBindings.values } ?? [])
        return Set(project.properties.filter { definition in
            guard hasCallback || (hasUpdates && mapped.contains(definition.key)) else { return false }
            guard [.bool,.color,.slider,.combo,.textinput].contains(definition.kind), let value = definition.defaultValue,
                  (try? definition.validate(value)) != nil else { return false }
            if case .unsupported = project.visibility(for: definition.key, values: defaults) { return false }
            return true
        }.map(\.key))
    }
    isolated deinit {
        finishLoading(); mutationGate.cancelWaiters()
        work?.cancel(); mutation?.cancel(); frameOperation?.cancel(); frameLoop?.cancel(); screenUpdateTask?.cancel()
        if let client = worker { Task { await client.dispose() } }
    }
}

#if !GW_UNIVERSAL_SCENE_BACKEND
typealias SceneWallpaperRuntime = LegacySceneWallpaperRuntime
#endif

/// Main-actor FIFO for property/environment transactions. Cancellation removes a
/// waiter; a cancelled newly granted lease is released before throwing. Reload
/// and dispose wake every pending caller rather than stranding a continuation.
@MainActor private final class SceneRuntimeMutationGate {
    private var occupied = false
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []
    func acquire() async throws {
        try Task.checkCancellation()
        if !occupied { occupied = true; return }
        guard waiters.count < 128 else { throw SceneWallpaperFailure(message: "Scene 更新队列已满，请稍后重试。") }
        let ticket = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { pending in waiters.append((ticket, pending)) }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(ticket) }
        }
        guard granted else { throw CancellationError() }
        if Task.isCancelled { release(); throw CancellationError() }
    }
    func release() {
        if !waiters.isEmpty { waiters.removeFirst().1.resume(returning: true) }
        else { occupied = false }
    }
    private func cancel(_ ticket: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == ticket }) { waiters.remove(at: index).1.resume(returning: false) }
    }
    func cancelWaiters() {
        let pending = waiters; waiters = []
        pending.forEach { $0.1.resume(returning: false) }
    }
}

private struct ScenePreparedRuntime: @unchecked Sendable {
    let project: AuthorPropertyProject
    let inspection: SceneWallpaperInspection
    let pixelSize: CGSize
    let payload: Data
    let directKeys: Set<String>
}
private enum ScenePreparedResult: @unchecked Sendable {
    case success(ScenePreparedRuntime)
    case failure(String, Set<String>)
    case cancelled
}
private struct ScenePublishedFrame: @unchecked Sendable {
    let inspection: SceneWallpaperInspection
    let image: CGImage
    let scriptFrame: SceneScriptFrame
}

/// ImageIO is used once per load. Dynamic frames retain bounded straight RGBA
/// buffers and never reopen files or decompress PNG/JPEG in the frame loop.
private enum SceneRuntimeTextureCache {
    static func prepare(_ inspection: SceneWallpaperInspection) throws -> SceneWallpaperInspection {
        var textures: [String: SceneTextureAsset] = [:], total = 0
        let maximum = SceneReadLimits().maximumTextureBytes
        for (key, texture) in inspection.textures {
            try Task.checkCancellation()
            let bytes = texture.storageWidth * texture.storageHeight * 4
            guard bytes <= maximum - total else { throw SceneWallpaperFailure(message: "Scene 解码纹理缓存超出预算。") }
            total += bytes
            if texture.video != nil || texture.format == .rgba8888 { textures[key] = texture; continue }
            guard let source = CGImageSourceCreateWithData(texture.data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width == texture.storageWidth, image.height == texture.storageHeight else { throw SceneWallpaperFailure(message: "Scene 纹理缓存解码失败。") }
            var data = Data(count: bytes)
            try data.withUnsafeMutableBytes { raw in
                guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SceneWallpaperFailure(message: "Scene 纹理缓存分配失败。") }
                context.setBlendMode(.copy); context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                let pixels = raw.bindMemory(to: UInt8.self)
                for row in 0..<image.height {
                    try Task.checkCancellation()
                    for offset in stride(from: row * image.width * 4, to: (row + 1) * image.width * 4, by: 4) {
                        let alpha = Int(pixels[offset + 3])
                        for channel in 0..<3 { pixels[offset + channel] = alpha == 0 ? 0 : UInt8(min(255, (Int(pixels[offset + channel]) * 255 + alpha / 2) / alpha)) }
                    }
                }
            }
            textures[key] = SceneTextureAsset(path: texture.path, format: .rgba8888, flags: texture.flags, channelCount:texture.channelCount,animation:texture.animation,verifiedStorageVariant:texture.verifiedStorageVariant,video:texture.video, data: data,
                storageWidth: texture.storageWidth, storageHeight: texture.storageHeight, imageWidth: texture.imageWidth, imageHeight: texture.imageHeight)
        }
        return SceneWallpaperInspection(canvasSize: inspection.canvasSize, clearColor: inspection.clearColor, camera: inspection.camera,
            layers: inspection.layers, textures: textures, diagnostics: inspection.diagnostics, scriptProgram: inspection.scriptProgram,bloom:inspection.bloom,fidelityNotes:inspection.fidelityNotes,renderIdentity:inspection.renderIdentity,parallax:inspection.parallax)
    }
}

/// Maps the native presentation viewport back through the same aspect and
/// orthographic camera transforms used by the CPU renderer.
enum SceneCursorMapper {
    static func worldPosition(hostPoint: CGPoint, hostBounds: CGRect, imageSize: CGSize,
                              aspectFill: Bool, canvasSize: SceneVector2,
                              camera: SceneCamera2D) -> SceneVector3? {
        guard [hostPoint.x,hostPoint.y,hostBounds.minX,hostBounds.minY,hostBounds.width,hostBounds.height,
               imageSize.width,imageSize.height].allSatisfy(\.isFinite),
              hostBounds.width > 0, hostBounds.height > 0, imageSize.width > 0, imageSize.height > 0,
              canvasSize.x.isFinite, canvasSize.y.isFinite, canvasSize.x > 0, canvasSize.y > 0,
              hostBounds.contains(hostPoint) else { return nil }
        let hostScale = aspectFill
            ? max(hostBounds.width / imageSize.width, hostBounds.height / imageSize.height)
            : min(hostBounds.width / imageSize.width, hostBounds.height / imageSize.height)
        guard hostScale.isFinite, hostScale > 0 else { return nil }
        let imageRect = CGRect(
            x: hostBounds.midX - imageSize.width * hostScale / 2,
            y: hostBounds.midY - imageSize.height * hostScale / 2,
            width: imageSize.width * hostScale, height: imageSize.height * hostScale
        )
        guard imageRect.contains(hostPoint) else { return nil }
        let imagePoint = CGPoint(x: (hostPoint.x - imageRect.minX) / hostScale,
                                 y: (hostPoint.y - imageRect.minY) / hostScale)
        let canvasWidth = CGFloat(canvasSize.x), canvasHeight = CGFloat(canvasSize.y)
        let renderScale = min(imageSize.width / canvasWidth, imageSize.height / canvasHeight)
        guard renderScale.isFinite, renderScale > 0 else { return nil }
        let canvasRect = CGRect(
            x: (imageSize.width - canvasWidth * renderScale) / 2,
            y: (imageSize.height - canvasHeight * renderScale) / 2,
            width: canvasWidth * renderScale, height: canvasHeight * renderScale
        )
        guard canvasRect.contains(imagePoint) else { return nil }
        let canvasX = Double((imagePoint.x - canvasRect.minX) / renderScale)
        let canvasY = Double((imagePoint.y - canvasRect.minY) / renderScale)
        guard let transform = try? camera.validatedTransform() else { return nil }
        let determinant = transform.a * transform.d - transform.b * transform.c
        guard determinant.isFinite, abs(determinant) >= 1e-12 else { return nil }
        let x = canvasX - transform.tx, y = canvasY - transform.ty
        let world = SceneVector3(x: (transform.d * x - transform.c * y) / determinant,
                                 y: (-transform.b * x + transform.a * y) / determinant, z: 0)
        return [world.x,world.y].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000_000_000 }) ? world : nil
    }
}

@MainActor private final class SceneRuntimeImageView: NSView {
    private var image: CGImage?
    private var aspectFill = false
    var onScreenChange: ((NSScreen?) -> Void)?
    private var screenTokens: [NSObjectProtocol] = []
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); stopScreenObservation()
        guard let window, onScreenChange != nil else { return }
        for (name, object) in [(NSWindow.didChangeScreenNotification, window as AnyObject?), (NSApplication.didChangeScreenParametersNotification, nil)] {
            screenTokens.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onScreenChange?(self?.window?.screen) }
            })
        }
        onScreenChange?(window.screen)
    }
    func stopScreenObservation() {
        screenTokens.forEach { NotificationCenter.default.removeObserver($0) }; screenTokens = []
    }
    isolated deinit { screenTokens.forEach { NotificationCenter.default.removeObserver($0) } }

    func setAspectFill(_ value: Bool) {
        guard aspectFill != value else { return }
        aspectFill = value; needsDisplay = true
    }
    func cursorWorldPosition(mouseLocation: CGPoint, imageSize: CGSize,
                             canvasSize: SceneVector2, camera: SceneCamera2D) -> SceneVector3? {
        guard let window, let contentView = window.contentView, !window.isMiniaturized else { return nil }
        let windowPoint = window.convertPoint(fromScreen: mouseLocation)
        let contentPoint = contentView.convert(windowPoint, from: nil)
        guard contentView.bounds.contains(contentPoint) else { return nil }
        let localPoint = convert(windowPoint, from: nil)
        guard visibleRect.contains(localPoint) else { return nil }
        return SceneCursorMapper.worldPosition(hostPoint: localPoint, hostBounds: bounds,
            imageSize: imageSize, aspectFill: aspectFill, canvasSize: canvasSize, camera: camera)
    }
    override var isOpaque: Bool { true }
    func publish(_ image: CGImage?) { self.image = image; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext, bounds.width > 0, bounds.height > 0 else { return }
        let xScale = bounds.width / CGFloat(image.width), yScale = bounds.height / CGFloat(image.height)
        let scale = aspectFill ? max(xScale, yScale) : min(xScale, yScale)
        context.clip(to: bounds)
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.draw(image, in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
    }
}

/// No saved value is a capability. Only recognized, type-compatible direct
/// bindings in a fully renderable inspection can enable a native editor.
struct SceneAuthorPropertySupport {
    static func editableKeys(project: AuthorPropertyProject, inspection: SceneWallpaperInspection) throws -> Set<String> {
        guard inspection.isRenderableSubset else { return [] }
        let bindings = Dictionary(grouping: inspection.layers.flatMap(\.bindings), by: \.propertyKey)
        var result: Set<String> = []
        for (key, uses) in bindings {
            guard let definition = project.definition(for: key), let value = definition.defaultValue else {
                throw SceneWallpaperFailure(message: "Scene 绑定缺少作者默认值：\(key)")
            }
            guard definition.isEditableSchema else { continue }
            try definition.validate(value)
            let supports = uses.allSatisfy { binding in
                switch binding.target {
                case "visible": return definition.kind == .bool || compatibleCombo(definition, target: binding.target)
                case "color": return definition.kind == .color || compatibleCombo(definition, target: binding.target)
                case "alpha": return definition.kind == .slider || compatibleCombo(definition, target: binding.target)
                case "origin", "angles", "scale", "size": return definition.kind == .textinput || compatibleCombo(definition, target: binding.target)
                default: return false
                }
            }
            guard supports else { continue }
            if case .unsupported = project.visibility(for: key, values: project.resolve(overrides: [:]).values) { continue }
            result.insert(key)
        }
        return result
    }
    private static func compatibleCombo(_ definition: AuthorPropertyDefinition, target: String) -> Bool {
        guard definition.kind == .combo, !definition.options.isEmpty else { return false }
        return definition.options.allSatisfy { option in
            guard let value = option.value else { return false }
            switch target {
            case "visible": return value.boolValue != nil
            case "alpha": return value.numberValue.map { (0...1).contains($0) } == true
            default:
                guard let string = value.stringValue else { return false }
                let components = string.split(whereSeparator: \.isWhitespace)
                let numbers = components.compactMap { Double($0) }
                guard components.count == numbers.count, (2...3).contains(numbers.count), numbers.allSatisfy(\.isFinite) else { return false }
                if target == "color" { return numbers.count == 3 && numbers.allSatisfy { (0...1).contains($0) } }
                return true
            }
        }
    }
    static func validateBindingOverrides(_ payload: Data, project: AuthorPropertyProject,
                                         inspection: SceneWallpaperInspection, editableKeys: Set<String>) throws {
        let values = try JSONDecoder().decode(GWJSONValue.self, from: payload).objectValue ?? [:]
        for key in Set(inspection.layers.flatMap(\.bindings).map(\.propertyKey)).subtracting(editableKeys) {
            if let value = values[key], value != project.definition(for: key)?.defaultValue {
                throw SceneWallpaperFailure(message: "Scene 绑定尚不支持编辑，未应用覆盖值：\(key)")
            }
        }
    }
    static func fullWorkerPayload(_ payload: Data, project: AuthorPropertyProject) throws -> Data {
        let overrides = try JSONDecoder().decode(GWJSONValue.self, from: payload).objectValue ?? [:]
        let values = project.resolve(overrides: overrides).values
        var result: [String: GWJSONValue] = [:]
        for definition in project.properties {
            guard let value = values[definition.key] else { continue }
            var metadata = definition.raw; metadata["value"] = value
            result[definition.key] = .object(metadata)
        }
        // The isolated helper unwraps metadata to raw Scene callback values;
        // carrying type here distinguishes color Vec3 from numeric text strings.
        return try JSONEncoder().encode(GWJSONValue.object(result))
    }
    static func validatedPayload(_ payload: Data, project: AuthorPropertyProject) throws -> Data {
        guard payload.count <= SceneReadLimits().maximumJSONBytes,
              let values = try JSONDecoder().decode(GWJSONValue.self, from: payload).objectValue else {
            throw SceneWallpaperFailure(message: "Scene 作者设置必须是有界 JSON 对象。")
        }
        var result: [String: GWJSONValue] = [:]
        for (key, wrapper) in values {
            guard let definition = project.definition(for: key) else { throw SceneWallpaperFailure(message: "未知 Scene 作者属性：\(key)") }
            let value = wrapper.objectValue?["value"] ?? wrapper
            if definition.isEditableSchema { try definition.validate(value) }
            else if value != definition.defaultValue { throw SceneWallpaperFailure(message: "Scene 作者属性只读：\(key)") }
            result[key] = value
        }
        return try JSONEncoder().encode(GWJSONValue.object(result))
    }
}
