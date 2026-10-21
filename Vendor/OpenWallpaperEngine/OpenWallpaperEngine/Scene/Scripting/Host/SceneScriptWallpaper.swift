import Foundation

/// One wallpaper instance's scripts (docs/scenescript-plan.md §4.1, WP11): a `SceneScriptRuntime`
/// with every extension on a `SceneScriptThread` of its own, fed and read by the renderer that owns
/// it. Two displays get two of these and share nothing but the app-wide services.
///
/// The renderer calls `submit(_:)` at the start of every draw with the frame's inputs; the scripts
/// run on their thread (`asyncFrame`, so a hung script only drops script frames) and leave a
/// `SceneScriptFrameState` that `take()` hands back. The renderer waits for it a little
/// (`waitForSubmittedFrame`, `Timing.frameWait`), so what scripts did is drawn in the same frame,
/// as in WE. Everything else here runs on the script thread.
final class SceneScriptWallpaper {
    struct CreationError: Error, CustomStringConvertible {
        var description: String
    }

    /// Per-frame cost of the scripts, for measurements: CPU time of the script thread for a whole
    /// script frame (the renderer's values into the table, the cursor pass, the scripts, the read-back).
    struct Timing {
        var frames = 0
        var totalMilliseconds = 0.0
        var lastMilliseconds = 0.0
        /// Every frame's time, oldest first (bounded), for percentiles.
        var recentMilliseconds: [Double] = []

        static let recentLimit = 4096
        /// How long a draw waits for the script frame it started before drawing without it (its
        /// results then show from the next draw on). WE runs scripts inside the frame; ours take
        /// 0.1–0.5 ms, so the wait normally ends well before this, and a hung script is waited for
        /// once (later frames are skipped while it runs, §4.5).
        static let frameWait: TimeInterval = 0.004
    }

    let identity: SceneScriptIdentity
    let documentSignature: String
    let thread: SceneScriptThread
    /// Called on the main thread once, when the watchdog stopped this wallpaper's scripts.
    var onHalt: ((SceneScriptError?) -> Void)?
    /// Builds what `createLayer` made into the renderer's drawable form (textures uploaded), on the
    /// script thread before the frame is published, so the renderer draws it in the same frame as
    /// WE does (`takePrepared`). Nil when it can't be built here; the renderer then builds it itself.
    typealias PrepareCreated = (SceneScriptCreatedObject, _ id: Int) -> Any?
    private let prepareCreated: PrepareCreated?
    /// What `prepareCreated` built, by object id, until the renderer takes it (under `lock`).
    private var prepared: [Int: Any] = [:]

    private let content: SceneScriptSceneContent
    private let services: SceneScriptServices
    private let scriptHost: ScriptHost
    // Script thread.
    private var runtime: SceneScriptRuntime?
    private var engine: SceneScriptEngineExtension?
    private var cursor: SceneScriptCursorExtension?
    private var mirror: SceneScriptSceneMirror?
    private var environment: SceneScriptEngineEnvironment?
    /// Whether any script exports a cursor callback; the cursor pass runs only then (its events
    /// would reach no one otherwise).
    private var usesCursor = true

    /// Guards `input`, `published`, `pendingEvents`, `timing`, `haltReported` and the frame
    /// counts; signalled when a frame finishes.
    private let lock = NSCondition()
    /// Script frames started and finished (run or skipped by the runtime's state).
    private var submittedFrames = 0
    private var finishedFrames = 0
    private var input = SceneScriptFrameInput()
    private var published: SceneScriptFrameState?
    private var pendingEvents: [SceneScriptRenderEvent] = []
    private var timing = Timing()
    private var haltReported = false
    /// The user property values the scripts last got (main thread).
    private var lastUserValues: [String: SceneJSON] = [:]
    /// The language `applyGeneralSettings` last sent (main thread), and the observer that sends a
    /// new one when the user's preferred languages change.
    private var lastLanguage = SceneScriptGeneralSettings.defaultLanguage
    private var localeObserver: NSObjectProtocol?
    /// Each `usershortcut` property's binding as stored: set on the main thread, read by
    /// `engine.openUserShortcut` on the script thread (under `shortcutLock`).
    private var shortcutBindings: [String: String] = [:]
    private let shortcutLock = NSLock()

    /// Creates the runtime on its thread and starts loading the scripts there. Nil (logged) when
    /// the scene has no scripts.
    init?(content: SceneScriptSceneContent, services: SceneScriptServices, screenID: String,
          prepareCreated: PrepareCreated? = nil) throws {
        self.prepareCreated = prepareCreated
        identity = SceneScriptIdentity(wallpaperID: content.wallpaperID, screenID: screenID)
        documentSignature = content.documentSignature
        self.content = content
        self.services = services
        thread = SceneScriptThread(label: "\(content.wallpaperID) \(screenID)")
        scriptHost = ScriptHost(identity: identity, prelude: services.prelude)
        let properties = content.userProperties()
        guard !SceneScriptSiteBuilder(wallpaperID: content.wallpaperID).sites(in: content.document).isEmpty else { return nil }
        if let legacyStorageID = content.legacyStorageID {
            services.storage.adoptLegacyStore(from: legacyStorageID, to: content.wallpaperID)
        }
        for (name, property) in properties.properties { lastUserValues[name] = property.value }
        shortcutBindings = properties.userShortcutBindings
        try thread.sync { try create(properties: properties) }
        let generalSettings = SceneScriptGeneralSettings.current()
        lastLanguage = generalSettings["language"] as? String ?? SceneScriptGeneralSettings.defaultLanguage
        thread.async { [self] in
            guard let runtime else { return }
            runtime.load(userProperties: properties.payload(), generalSettings: generalSettings)
            usesCursor = Self.exportsCursorCallbacks(runtime)
            finish(runtime, frameStart: nil)
        }
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.generalSettingsDidChange(SceneScriptGeneralSettings.current())
            }
    }

    /// On the script thread: the runtime with its extensions, the scene placed, the sites added.
    private func create(properties: SceneScriptUserProperties) throws {
        let describer = SceneScriptSceneDescriber(userProperties: properties, file: content.file)
        let mirror = SceneScriptSceneMirror(document: content.document, describer: describer)
        let engine = SceneScriptEngineExtension(storage: services.storage)
        if let launcher = services.userShortcuts {
            engine.userShortcutHandler = { [weak self] name in
                guard let self else { return false }
                let binding = self.shortcutLock.withLock { self.shortcutBindings[name] }
                return binding.map(launcher.open) ?? false
            }
        }
        let cursor = SceneScriptCursorExtension()
        let model = SceneScriptObjectModel(host: mirror, modelData: content.modelData)
        let binding = SceneScriptBindingExtension()
        let runtime: SceneScriptRuntime
        do {
            runtime = try SceneScriptRuntime(
                host: scriptHost, compiler: SceneScriptModuleTransformer(),
                extensions: [engine, SceneScriptAudioBuffersExtension(spectrum: services.spectrum),
                             SceneScriptMediaExtension(source: services.media), model, binding, cursor],
                configuration: services.configuration, thread: thread)
        } catch {
            throw CreationError(description: "\(identity.wallpaperID): the SceneScript runtime could not start: \(error)")
        }
        mirror.attach(to: model)
        // WP8's sites, bound to the slots the object model gave the scene's objects.
        let slotted = SceneScriptSiteBuilder(wallpaperID: content.wallpaperID, userProperties: properties,
                                             slot: { mirror.slot(forObjectID: $0) })
        binding.add(slotted.sites(in: content.document), to: runtime)
        self.runtime = runtime
        self.engine = engine
        self.cursor = cursor
        self.mirror = mirror
    }

    deinit {
        if let localeObserver { NotificationCenter.default.removeObserver(localeObserver) }
        thread.async { [runtime] in runtime?.tearDown() }
    }

    // MARK: - Main thread

    /// This frame's inputs; runs a script frame on the script thread unless one is still running
    /// (false then).
    @discardableResult
    func submit(_ frameInput: SceneScriptFrameInput) -> Bool {
        lock.lock()
        input = frameInput
        lock.unlock()
        let started = thread.asyncFrame { [weak self] in
            self?.runFrame()
            self?.frameDidFinish()
        }
        if started {
            lock.lock()
            submittedFrames += 1
            lock.unlock()
        }
        return started
    }

    /// Waits until every script frame `submit` started has finished, or `timeout` seconds passed;
    /// whether they finished.
    @discardableResult
    func waitForSubmittedFrame(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        lock.lock()
        defer { lock.unlock() }
        while finishedFrames < submittedFrames {
            if !lock.wait(until: deadline) { return finishedFrames >= submittedFrames }
        }
        return true
    }

    /// The state the last finished script frame left (nil when nothing new) and the structural
    /// events since the last call. Reports a halt once through `onHalt`.
    func take() -> (state: SceneScriptFrameState?, events: [SceneScriptRenderEvent]) {
        lock.lock()
        let state = published
        published = nil
        let events = pendingEvents
        pendingEvents.removeAll()
        let newlyHalted = state?.halted == true && !haltReported
        if newlyHalted { haltReported = true }
        lock.unlock()
        if newlyHalted { onHalt?(scriptHost.lastTermination) }
        return (state, events)
    }

    /// What the script thread built for created object `id` (see `prepareCreated`), once.
    func takePrepared(_ id: Int) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return prepared.removeValue(forKey: id)
    }

    /// Script CPU time per frame so far.
    var frameTiming: Timing {
        lock.lock()
        defer { lock.unlock() }
        return timing
    }

    /// `applyUserProperties(changed)` for the properties of `names` the wallpaper declares whose
    /// value changed since the scripts last got it, with their current values in WE's raw form.
    /// (The app's change notification names every wallpaper's keys; two wallpapers may share a
    /// name.) Main thread.
    func userPropertiesDidChange(_ names: Set<String>) {
        let properties = content.userProperties()
        let bindings = properties.userShortcutBindings
        shortcutLock.withLock { shortcutBindings = bindings }
        let changed = names.filter { name in
            guard let value = properties.value(of: name), lastUserValues[name] != value else { return false }
            lastUserValues[name] = value
            return true
        }
        guard !changed.isEmpty else { return }
        withRuntime({ $0.userPropertiesDidChange(properties.payload(only: changed)) })
    }

    /// `applyGeneralSettings` with the settings that changed, at the start of the next script frame
    /// (the docs: "called once initially", then on every change). Main thread.
    func generalSettingsDidChange(_ settings: [String: Any]) {
        guard let language = settings["language"] as? String, language != lastLanguage else { return }
        lastLanguage = language
        withRuntime({ $0.generalSettingsDidChange(["language": language]) })
    }

    /// `resizeScreen` at the start of the next script frame; never for the first size.
    func screenDidResize(width: Double, height: Double) {
        withRuntime({ $0.screenDidResize(width: width, height: height) })
    }

    /// The inbox is thread-safe; the runtime reference is the script thread's, so hop there.
    private func withRuntime(_ body: @escaping (SceneScriptRuntime) -> Void) {
        thread.async { [weak self] in
            guard let runtime = self?.runtime else { return }
            body(runtime)
        }
    }

    /// The runtime itself; only on `thread` (tests and diagnostics read scripts' state through it).
    var scriptRuntime: SceneScriptRuntime? {
        dispatchPrecondition(condition: .onQueue(thread.queue))
        return runtime
    }

    /// Waits until the script thread has finished what was posted so far (tests, teardown).
    func waitUntilIdle() {
        thread.sync {}
    }

    /// Runs every script's `destroy()` on the script thread; the scripts never run again.
    func tearDown() {
        thread.async { [runtime] in runtime?.tearDown() }
    }

    // MARK: - Script thread

    private func frameDidFinish() {
        lock.lock()
        finishedFrames += 1
        lock.broadcast()
        lock.unlock()
    }

    private func runFrame() {
        guard let runtime, runtime.state == .loaded, let mirror, let engine else { return }
        lock.lock()
        let frameInput = input
        lock.unlock()
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        if environment != frameInput.environment {
            engine.environment = frameInput.environment
            environment = frameInput.environment
        }
        var scriptInput = frameInput.input
        scriptInput.shakeOffset = SIMD2(Double(frameInput.shakeOffset.x), Double(frameInput.shakeOffset.y))
        if engine.input != scriptInput { engine.input = scriptInput }
        mirror.prepare(frameInput, cursor: usesCursor ? cursor : nil)
        // After the clocks advanced, before `__rt.frame` drains the inbox (§1.9 P1).
        for event in mirror.rigAnimationEvents(frameInput.rigs) { runtime.inbox.post(event) }
        for event in mirror.animationEvents(frameInput.animationEvents) { runtime.inbox.post(event) }
        runtime.frame(deltaTime: frameInput.deltaTime)
        finish(runtime, frameStart: start)
    }

    /// Whether a loaded script exports one of the cursor callbacks (read between entries, where
    /// `__rt` is reachable; a throwing export getter counts as one, `invoke` reports it).
    private static func exportsCursorCallbacks(_ runtime: SceneScriptRuntime) -> Bool {
        let check = """
            __rt.records.some(function (record) {
                return ['cursorEnter', 'cursorLeave', 'cursorMove', 'cursorDown', 'cursorUp', 'cursorClick']
                    .some(function (name) {
                        try { return typeof __rt.exports(record, name) === 'function'; } catch (error) { return true; }
                    });
            })
            """
        guard let result = runtime.context.evaluateScript(check), result.isBoolean else { return true }
        return result.toBool()
    }

    /// After a load or frame: reads the tables back and publishes the state for the renderer.
    /// `frameStart` is the frame's start in thread CPU time (nil for the load).
    private func finish(_ runtime: SceneScriptRuntime, frameStart: UInt64?) {
        guard let mirror else { return }
        if runtime.state == .halted { mirror.markHalted() }
        let result = mirror.readBack()
        var built: [Int: Any] = [:]
        if let prepareCreated {
            for case let .create(id, object) in result.events {
                if let created = content.makeLayer(object), let value = prepareCreated(created, id) { built[id] = value }
            }
        }
        let milliseconds = frameStart.map { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - $0) / 1_000_000 }
        lock.lock()
        published = result.state
        pendingEvents.append(contentsOf: result.events)
        prepared.merge(built) { _, new in new }
        if let milliseconds {
            timing.frames += 1
            timing.totalMilliseconds += milliseconds
            timing.lastMilliseconds = milliseconds
            if timing.recentMilliseconds.count >= Timing.recentLimit { timing.recentMilliseconds.removeFirst() }
            timing.recentMilliseconds.append(milliseconds)
        }
        lock.unlock()
    }
}

/// The runtime's host: WE's prelude and the error channel. Remembers the watchdog's stop for the
/// renderer's notice.
private final class ScriptHost: SceneScriptHost {
    let identity: SceneScriptIdentity
    let prelude: SceneScriptPrelude
    private let lock = NSLock()
    private var termination: SceneScriptError?

    init(identity: SceneScriptIdentity, prelude: SceneScriptPrelude) {
        self.identity = identity
        self.prelude = prelude
    }

    var lastTermination: SceneScriptError? {
        lock.lock()
        defer { lock.unlock() }
        return termination
    }

    func runtime(_ runtime: SceneScriptRuntime, didReport error: SceneScriptError) {
        // The Wallpaper Editor's console shows it at the script's line.
        SceneScriptConsoleTap.post(.init(wallpaperID: identity.wallpaperID, scriptID: error.scriptID, isError: true,
                                         message: error.message, line: error.line))
        guard error.kind == .terminated else { return }
        lock.lock()
        termination = error
        lock.unlock()
    }
}
