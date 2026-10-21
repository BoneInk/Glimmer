import Foundation
import JavaScriptCore

/// The SceneScript runtime of one wallpaper instance (docs/scenescript-plan.md §4): its own
/// `JSVirtualMachine` and one `JSContext`, WE's prelude, every script of the scene as a record in
/// `runtime.js`, and the load and frame drivers. Two displays get two runtimes that share nothing.
///
/// Threading (S19): confined to one `SceneScriptThread`, a serial queue off the main thread, so a
/// script that hangs until the watchdog fires stalls only its wallpaper's scripts, never the UI.
/// The owner creates the runtime inside `thread.sync` and calls it only on that queue (frames via
/// `thread.asyncFrame`); every entry checks this. Other threads talk to it only through `inbox`
/// (`userPropertiesDidChange`, `screenDidResize`, and the events extensions post). Without a
/// thread (tests) the caller's thread is the runtime's; on the main thread that logs once.
/// Releasing the last reference on another thread still runs `destroy()` on the runtime's thread.
///
/// Each native→JS entry (`load`, `frame`, `tearDown`) is one call into `runtime.js` under the
/// watchdog. Script errors are isolated per callback in JS and reach Swift through one error
/// channel; each distinct error is logged once, by script id and line, never with source. A
/// callback that throws is not called again for that script (WE; plan §1.9 P4).
final class SceneScriptRuntime {
    struct Configuration {
        /// Watchdog limit for loading (module bodies, `init`, the first `applyUserProperties`).
        /// WE allows 15 s per outermost script call (scenescript64.dll; plan §1.9 P5).
        var loadTimeLimit: TimeInterval = 15
        /// Watchdog limit for one frame (every `update` plus events and timers).
        var frameTimeLimit: TimeInterval = 15
        var commandCapacity = 4096
        var commandNumberCapacity = 16384

        static let standard = Configuration()
    }

    enum State {
        case created, loaded
        /// The watchdog stopped script code. Like WE, no script code runs again until the wallpaper
        /// is reloaded (a new runtime).
        case halted
        case tornDown
    }

    struct CreationError: Error, CustomStringConvertible {
        var description: String
    }

    let identity: SceneScriptIdentity
    let virtualMachine: JSVirtualMachine
    let context: JSContext
    /// The `__rt` object of `runtime.js`.
    let rt: JSValue
    let inbox = SceneScriptInbox()
    let commandRing: SceneScriptCommandRing
    private(set) var state = State.created
    /// The most recent distinct errors, oldest first (bounded).
    private(set) var recentErrors: [SceneScriptError] = []

    private weak var host: SceneScriptHost?
    private let compiler: SceneScriptModuleCompiling
    private let extensions: [SceneScriptRuntimeExtension]
    private let configuration: Configuration
    private let watchdog: SceneScriptWatchdog?
    private let uncaught: UncaughtException
    private var errorLog: SceneScriptErrorLog
    private var pending: [SceneScriptInstance] = []
    private var instanceIDs = Set<String>()
    /// The shared buffers scripts can reach; a detached one halts the runtime (SF3).
    private var watched: [SceneScriptDetachable] = []
    /// The queue this runtime is confined to, or nil for the creating thread.
    let thread: SceneScriptThread?

    private static let recentErrorLimit = 256

    init(host: SceneScriptHost, compiler: SceneScriptModuleCompiling,
         extensions: [SceneScriptRuntimeExtension] = [], configuration: Configuration = .standard,
         thread: SceneScriptThread? = nil) throws {
        if let thread { dispatchPrecondition(condition: .onQueue(thread.queue)) }
        guard let virtualMachine = JSVirtualMachine(),
              let context = JSContext(virtualMachine: virtualMachine) else {
            throw CreationError(description: "JavaScriptCore could not create a context")
        }
        let identity = host.identity
        context.name = "SceneScript \(identity.wallpaperID) \(identity.screenID)"
        let uncaught = UncaughtException()
        context.exceptionHandler = { _, exception in uncaught.value = exception }

        let prelude = host.prelude
        if let baseClasses = prelude.baseClasses {
            context.evaluateScript(baseClasses, withSourceURL: URL(string: "owe://we/scripts/jsclasses/baseclasses.js"))
            if let exception = uncaught.take() {
                throw CreationError(description: "WE baseclasses.js failed: \(Self.message(of: exception))")
            }
        }
        let runtimeSource: String
        do {
            runtimeSource = try SceneScriptResources.source(named: "runtime")
        } catch {
            throw CreationError(description: "\(error)")
        }
        context.evaluateScript(runtimeSource, withSourceURL: URL(string: "owe://runtime/runtime.js"))
        if let exception = uncaught.take() {
            throw CreationError(description: "runtime.js failed: \(Self.message(of: exception))")
        }
        guard let rt = context.objectForKeyedSubscript("__rt"), rt.isObject else {
            throw CreationError(description: "runtime.js did not define __rt")
        }
        guard let ring = SceneScriptCommandRing(capacity: configuration.commandCapacity,
                                                numberCapacity: configuration.commandNumberCapacity, rt: rt) else {
            throw CreationError(description: "the command ring could not be allocated")
        }

        self.identity = identity
        self.virtualMachine = virtualMachine
        self.context = context
        self.rt = rt
        self.commandRing = ring
        self.host = host
        self.compiler = compiler
        self.extensions = extensions
        self.configuration = configuration
        self.uncaught = uncaught
        self.watchdog = SceneScriptWatchdog(context: context)
        self.errorLog = SceneScriptErrorLog(prefix: identity.wallpaperID)
        self.thread = thread
        watched = ring.sharedBuffers

        if thread == nil && Thread.isMainThread {
            OWELog.info(.script, "\(identity.wallpaperID): SceneScript runs on the main thread; a hung script freezes the app")
        }

        if watchdog == nil {
            OWELog.info(.script, "JavaScriptCore has no execution time limit; a hung script stalls its wallpaper")
        }
        for scriptExtension in extensions {
            try scriptExtension.install(into: self)
            for name in scriptExtension.scriptResources {
                try evaluateResource(named: name)
            }
        }
        registerPreludeModules(prelude.modules)
        // Every extension has set its hooks: from now on nothing can replace them (S28).
        rt.invokeMethod("seal", withArguments: [])
    }

    /// `destroy()` callbacks run on the runtime's thread even when the last reference goes away
    /// elsewhere (the owner should call `tearDown()` there first; this is the safety net).
    deinit {
        guard state != .tornDown else { return }
        if let thread, !thread.isCurrent {
            thread.sync { tearDown() }
        } else {
            tearDown()
        }
    }

    /// Checks that a buffer scripts can reach is still attached after every entry (SF3). Call
    /// from `install` for each `SceneScriptSharedBuffer` an extension hands to JavaScript.
    func watch(_ buffer: SceneScriptDetachable) {
        watched.append(buffer)
    }

    private func assertConfined() {
        if let thread { dispatchPrecondition(condition: .onQueue(thread.queue)) }
    }

    // MARK: - Instances and loading

    /// Queues a script for the next `load`. Ids must be unique within the runtime.
    func add(_ instance: SceneScriptInstance) {
        assertConfined()
        guard state != .tornDown else { return }
        guard instanceIDs.insert(instance.id).inserted else {
            report(SceneScriptError(kind: .internal, scriptID: instance.id, callback: "add",
                                    message: "duplicate script id", line: nil))
            return
        }
        pending.append(instance)
    }

    /// Compiles the queued scripts and runs the load phase for them: module bodies, script
    /// properties, `init`, then `applyUserProperties(userProperties)` and
    /// `applyGeneralSettings(generalSettings)`. Callable again for scripts added later; those get
    /// no `applyUserProperties` (P8's best guess for runtime-created scripts). Commands issued
    /// while loading (`createLayer`, `sortLayer`, `play` in `init`) run before it returns, so they
    /// take effect before the first frame (SF5).
    func load(userProperties: [String: Any] = [:], generalSettings: [String: Any] = SceneScriptGeneralSettings.current()) {
        assertConfined()
        guard state == .created || state == .loaded else { return }
        compilePending()
        let entry = enter(limit: configuration.loadTimeLimit, label: "load") {
            rt.invokeMethod("load", withArguments: [userProperties, generalSettings])
        }
        guard !entry.terminated, state != .halted else { return }
        state = .loaded
        commandRing.drain()
    }

    /// Runs one frame: extension buffers, then `__rt.frame` (events, timers, every `update`,
    /// deferred structure changes, `destroy`), then the command ring and extension read-back.
    func frame(deltaTime: Double) {
        assertConfined()
        guard state == .loaded else { return }
        for scriptExtension in extensions { scriptExtension.willRunFrame(self, deltaTime: deltaTime) }
        let events = inbox.drain().map { $0.javaScriptObject }
        enter(limit: configuration.frameTimeLimit, label: "frame") {
            rt.invokeMethod("frame", withArguments: [deltaTime, events])
        }
        guard state == .loaded else { return }
        commandRing.drain()
        for scriptExtension in extensions { scriptExtension.didRunFrame(self) }
    }

    /// Calls `destroy()` on every loaded script, in order, executes the commands they issued,
    /// tells every extension (`tearDown(_:)`), and stops the runtime. A halted runtime calls no
    /// script, but its extensions still clean up.
    func tearDown() {
        assertConfined()
        guard state != .tornDown else { return }
        if state == .loaded {
            enter(limit: configuration.loadTimeLimit, label: "teardown") {
                rt.invokeMethod("teardown", withArguments: [])
            }
            if state == .loaded { commandRing.drain() }
        }
        state = .tornDown
        pending.removeAll()
        instanceIDs.removeAll()
        for scriptExtension in extensions { scriptExtension.tearDown(self) }
    }

    /// Removes a script after the next frame's updates, calling its `destroy()`. Its id is free
    /// again once that `destroy()` ran.
    func remove(scriptID: String) {
        assertConfined()
        guard instanceIDs.contains(scriptID) else { return }
        if let index = pending.firstIndex(where: { $0.id == scriptID }) {
            pending.remove(at: index)
            instanceIDs.remove(scriptID)
            return
        }
        // A script that never reached JS (a compile error) has nothing to destroy.
        if rt.invokeMethod("remove", withArguments: [scriptID])?.toBool() != true {
            instanceIDs.remove(scriptID)
        }
    }

    // MARK: - Inbox shortcuts (any thread)

    /// `applyUserProperties` with only the changed properties, at the start of the next frame.
    func userPropertiesDidChange(_ changed: [String: Any]) {
        inbox.post(SceneScriptEvent(kind: .userProperties, payload: changed))
    }

    /// `applyGeneralSettings` with only the changed settings, at the start of the next frame.
    func generalSettingsDidChange(_ changed: [String: Any]) {
        inbox.post(SceneScriptEvent(kind: .generalSettings, payload: changed))
    }

    /// `resizeScreen(size)` at the start of the next frame. Never call it for the initial size.
    func screenDidResize(width: Double, height: Double) {
        inbox.post(SceneScriptEvent(kind: .resize, payload: ["x": width, "y": height]))
    }

    // MARK: - Reads

    /// The value a script's `init`/`update` last produced (its bound field's value).
    func value(of scriptID: String) -> JSValue? {
        rt.invokeMethod("valueOf", withArguments: [scriptID])
    }

    /// False once a script failed to compile or threw at global scope. A throwing callback disables
    /// only that callback.
    func isEnabled(_ scriptID: String) -> Bool {
        rt.invokeMethod("isEnabled", withArguments: [scriptID])?.toBool() ?? false
    }

    // MARK: - Entries

    private struct Entry {
        var value: JSValue?
        var terminated: Bool
    }

    /// One native→JS entry under the watchdog. Afterwards: a termination halts the runtime and names
    /// the script that was running; queued script errors are drained and logged; an exception that
    /// escaped `runtime.js` is reported as an internal error.
    @discardableResult
    private func enter(limit: TimeInterval, label: String, _ body: () -> JSValue?) -> Entry {
        watchdog?.arm(limit: limit)
        _ = uncaught.take()
        let value = body()
        let terminated = watchdog?.fired == true
        let exception = uncaught.take()
        if terminated {
            handleTermination(label: label)
        } else if let exception {
            report(SceneScriptError(kind: .internal, scriptID: "", callback: label,
                                    message: Self.message(of: exception), line: nil))
        }
        let pendingErrors = rt.forProperty("errors")?.forProperty("length")?.toInt32() ?? 0
        if pendingErrors > 0 { drainErrors() }
        if (rt.forProperty("removed")?.forProperty("length")?.toInt32() ?? 0) > 0 { drainRemoved() }
        if !terminated, state != .halted, watched.contains(where: { $0.isDetached }) { handleDetachment(label: label) }
        return Entry(value: value, terminated: terminated)
    }

    /// Scripts removed from JS (`destroyLayer`, a `destroy()` removing another script) free their
    /// ids here, so a re-created object's scripts can use them again (SF12).
    private func drainRemoved() {
        guard let removed = rt.invokeMethod("drainRemoved", withArguments: [])?.toArray() else { return }
        for case let id as String in removed { instanceIDs.remove(id) }
    }

    /// A script detached a buffer the runtime shares with scripts (`buffer.transfer()`): the
    /// memory is still safe (Swift owns it), but JavaScript no longer sees it, so scripts and
    /// renderer would silently disagree from now on. Stop every script, like the watchdog does.
    private func handleDetachment(label: String) {
        state = .halted
        let current = rt.invokeMethod("halt", withArguments: [])
        report(SceneScriptError(kind: .internal, scriptID: current?.isString == true ? current?.toString() ?? "" : "",
                                callback: label,
                                message: "a script detached a buffer shared with the engine; scripts are stopped",
                                line: nil))
    }

    /// WE stops every script of the wallpaper after its watchdog fired, not only the one that hung
    /// (scenescript64.dll; plan §1.9 P5).
    private func handleTermination(label: String) {
        state = .halted
        let current = rt.invokeMethod("halt", withArguments: [])
        var scriptID = ""
        if let current, current.isString, let id = current.toString() { scriptID = id }
        report(SceneScriptError(kind: .terminated, scriptID: scriptID, callback: label,
                                message: SceneScriptError.terminationMessage, line: nil))
    }

    private func drainErrors() {
        guard let drained = rt.invokeMethod("drainErrors", withArguments: [])?.toArray() else { return }
        for case let entry as [String: Any] in drained {
            let scriptID = entry["id"] as? String ?? ""
            let name = entry["name"] as? String ?? "Error"
            let message = entry["message"] as? String ?? ""
            let line = (entry["line"] as? NSNumber).flatMap { SceneScriptNumber.index($0.doubleValue, in: 1...Int(Int32.max)) } ?? -1
            report(SceneScriptError(kind: scriptID.isEmpty ? .internal : .runtime, scriptID: scriptID,
                                    callback: entry["callback"] as? String ?? "",
                                    message: "\(name): \(message)", line: line > 0 ? line : nil))
        }
    }

    private func report(_ error: SceneScriptError) {
        guard errorLog.record(error) else { return }
        if recentErrors.count >= Self.recentErrorLimit { recentErrors.removeFirst() }
        recentErrors.append(error)
        host?.runtime(self, didReport: error)
    }

    // MARK: - Compiling

    /// Compiles and defines the queued scripts; returns how many were defined.
    @discardableResult
    private func compilePending() -> Int {
        let instances = pending
        pending.removeAll()
        var defined = 0
        for instance in instances {
            guard let factory = compileFactory(instance.source, scriptID: instance.id, sourceURL: instance.sourceURL) else {
                continue
            }
            let properties: Any
            if let json = instance.scriptPropertiesJSON { properties = json } else { properties = NSNull() }
            _ = uncaught.take()
            let binding: Any = instance.binding?.javaScriptObject ?? NSNull()
            rt.invokeMethod("define", withArguments: [instance.id, factory, instance.initialValue, properties,
                                                      instance.objectSlot ?? -1,
                                                      instance.sourceURL?.absoluteString ?? "", binding])
            if let exception = uncaught.take() {
                report(SceneScriptError(kind: .internal, scriptID: instance.id, callback: "define",
                                        message: Self.message(of: exception), line: nil))
                continue
            }
            defined += 1
        }
        return defined
    }

    /// The module factory for `source`, or nil after reporting a compile error. Evaluating the
    /// factory expression runs none of the script's code.
    private func compileFactory(_ source: String, scriptID: String, sourceURL: URL?) -> JSValue? {
        let module: SceneScriptCompiledModule
        do {
            module = try compiler.compile(source)
        } catch let error as SceneScriptCompileError {
            report(SceneScriptError(kind: .compile, scriptID: scriptID, callback: "<compile>",
                                    message: error.message, line: error.line))
            return nil
        } catch {
            report(SceneScriptError(kind: .compile, scriptID: scriptID, callback: "<compile>",
                                    message: "\(error)", line: nil))
            return nil
        }
        _ = uncaught.take()
        let factory = context.evaluateScript(module.factorySource, withSourceURL: sourceURL)
        if let exception = uncaught.take() {
            let line = exception.forProperty("line")?.toInt32() ?? 0
            report(SceneScriptError(kind: .compile, scriptID: scriptID, callback: "<compile>",
                                    message: exception.toString() ?? "SyntaxError", line: line > 0 ? Int(line) : nil))
            return nil
        }
        guard let factory, factory.isObject else {
            report(SceneScriptError(kind: .compile, scriptID: scriptID, callback: "<compile>",
                                    message: "the compiled module is not a function", line: nil))
            return nil
        }
        return factory
    }

    private func registerPreludeModules(_ modules: [SceneScriptPrelude.Module]) {
        for module in modules {
            let scriptID = "we/jsmodules/\(module.name)"
            let url = URL(string: "owe://we/scripts/jsmodules/\(module.name).js")
            guard let factory = compileFactory(module.source, scriptID: scriptID, sourceURL: url) else { continue }
            rt.invokeMethod("registerModule", withArguments: [module.name, factory])
        }
    }

    private func evaluateResource(named name: String) throws {
        let source: String
        do {
            source = try SceneScriptResources.source(named: name)
        } catch {
            throw CreationError(description: "\(error)")
        }
        _ = uncaught.take()
        context.evaluateScript(source, withSourceURL: URL(string: "owe://runtime/\(name).js"))
        if let exception = uncaught.take() {
            throw CreationError(description: "\(name).js failed: \(Self.message(of: exception))")
        }
    }

    /// An exception's message and line, without any source text.
    private static func message(of exception: JSValue) -> String {
        let text = exception.toString() ?? "unknown JavaScript error"
        let line = exception.forProperty("line")?.toInt32() ?? 0
        return line > 0 ? "\(text) (line \(line))" : text
    }
}

/// The last exception JavaScriptCore reported outside `runtime.js`'s own error isolation. A class
/// so the context's exception handler can capture it without capturing the runtime.
private final class UncaughtException {
    var value: JSValue?

    func take() -> JSValue? {
        let taken = value
        value = nil
        return taken
    }
}
