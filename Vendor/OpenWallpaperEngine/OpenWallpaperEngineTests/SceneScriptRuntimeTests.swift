import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// The SceneScript runtime skeleton (docs/scenescript-plan.md WP2): lifecycle, per-instance
/// isolation, the watchdog, error isolation and the load and frame order.
final class SceneScriptRuntimeTests: XCTestCase {
    private func makeRuntime(_ host: TestSceneScriptHost = TestSceneScriptHost(),
                             extensions: [SceneScriptRuntimeExtension] = [],
                             configuration: SceneScriptRuntime.Configuration = .standard) throws -> SceneScriptRuntime {
        try SceneScriptRuntime(host: host, compiler: TestSceneScriptCompiler(), extensions: extensions,
                               configuration: configuration)
    }

    private func evaluate(_ script: String, in runtime: SceneScriptRuntime) -> JSValue? {
        runtime.context.evaluateScript(script)
    }

    // MARK: - Lifecycle

    func testLifecycleChainsValuesAndCallsDestroyOnce() throws {
        let runtime = try makeRuntime()
        runtime.add(SceneScriptInstance(id: "counter", source: """
            shared.calls = shared.calls || [];
            function init(value) { shared.calls.push('init'); return value + 1; }
            function update(value) { shared.calls.push('update'); return value + 1; }
            function destroy() { shared.calls.push('destroy'); }
            """, initialValue: 10))
        runtime.add(SceneScriptInstance(id: "silent", source: "function update(value) {}", initialValue: 5))
        XCTAssertEqual(runtime.state, .created)

        runtime.load()
        XCTAssertEqual(runtime.state, .loaded)
        XCTAssertEqual(runtime.value(of: "counter")?.toInt32(), 11)
        for _ in 0..<3 { runtime.frame(deltaTime: 1.0 / 60) }
        XCTAssertEqual(runtime.value(of: "counter")?.toInt32(), 14, "update receives the value it returned last frame")
        XCTAssertEqual(runtime.value(of: "silent")?.toInt32(), 5, "returning nothing keeps the value")

        runtime.tearDown()
        XCTAssertEqual(runtime.state, .tornDown)
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(evaluate("shared.calls.join(',')", in: runtime)?.toString(),
                       "init,update,update,update,destroy")
    }

    func testWEBaseClassesAreLoadedUnmodified() throws {
        _ = try Fixtures.assets()
        let runtime = try makeRuntime()
        // WE's `Vec2.perpendicular()` is `(y, -x)`; a look-alike would give `(-y, x)`.
        XCTAssertEqual(evaluate("new Vec2(3, 4).perpendicular().toString()", in: runtime)?.toString(), "4 -3")
        XCTAssertEqual(evaluate("typeof _Internal.updateScriptProperties", in: runtime)?.toString(), "function")
        XCTAssertEqual(evaluate("typeof createScriptProperties", in: runtime)?.toString(), "function")
    }

    // MARK: - Isolation

    func testTwoRuntimesShareNothing() throws {
        let first = try makeRuntime(TestSceneScriptHost(screenID: "screen-1"))
        let second = try makeRuntime(TestSceneScriptHost(screenID: "screen-2"))
        XCTAssertFalse(first.virtualMachine === second.virtualMachine)
        let source = """
            var count = 0;
            function update(value) { count += 1; shared.total = (shared.total || 0) + 1; return count; }
            """
        for runtime in [first, second] {
            runtime.add(SceneScriptInstance(id: "same-id", source: source, initialValue: 0))
            runtime.load()
        }
        for _ in 0..<3 { first.frame(deltaTime: 1.0 / 60) }
        second.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(first.value(of: "same-id")?.toInt32(), 3)
        XCTAssertEqual(second.value(of: "same-id")?.toInt32(), 1)
        XCTAssertEqual(evaluate("shared.total", in: first)?.toInt32(), 3)
        XCTAssertEqual(evaluate("shared.total", in: second)?.toInt32(), 1)

        evaluate("var onlyInFirst = 1;", in: first)
        XCTAssertEqual(evaluate("typeof onlyInFirst", in: second)?.toString(), "undefined")

        // Tearing one down (a display switching wallpaper) leaves the other running.
        first.tearDown()
        second.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(second.value(of: "same-id")?.toInt32(), 2)
    }

    // MARK: - Watchdog

    private var fastWatchdog: SceneScriptRuntime.Configuration {
        var configuration = SceneScriptRuntime.Configuration.standard
        configuration.loadTimeLimit = 0.3
        configuration.frameTimeLimit = 0.2
        return configuration
    }

    func testWatchdogStopsAnInfiniteUpdateAndHaltsTheRuntime() throws {
        try XCTSkipUnless(SceneScriptWatchdog.isAvailable, "JSContextGroupSetExecutionTimeLimit is unavailable")
        let host = TestSceneScriptHost()
        let runtime = try makeRuntime(host, configuration: fastWatchdog)
        runtime.add(SceneScriptInstance(id: "counter", source: "var n = 0; function update() { n += 1; return n; }",
                                        initialValue: 0))
        runtime.add(SceneScriptInstance(id: "hang", source: """
            var calls = 0;
            function update() { calls += 1; if (calls > 1) { while (true) {} } }
            """))
        runtime.load()
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(runtime.value(of: "counter")?.toInt32(), 1)

        let start = Date()
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(runtime.state, .halted)
        XCTAssertEqual(host.errors.filter { $0.kind == .terminated }.map(\.scriptID), ["hang"])
        XCTAssertEqual(host.errors.first { $0.kind == .terminated }?.message, SceneScriptError.terminationMessage)

        // Like WE, no script runs again until the wallpaper reloads.
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(runtime.value(of: "counter")?.toInt32(), 2, "counter ran before the hang in that frame, then never")
        XCTAssertEqual(evaluate("1 + 1", in: runtime)?.toInt32(), 2, "the context survives termination")
        runtime.tearDown()
        XCTAssertEqual(runtime.state, .tornDown)
    }

    func testWatchdogStopsAGlobalScopeLoopDuringLoad() throws {
        try XCTSkipUnless(SceneScriptWatchdog.isAvailable, "JSContextGroupSetExecutionTimeLimit is unavailable")
        let host = TestSceneScriptHost()
        let runtime = try makeRuntime(host, configuration: fastWatchdog)
        runtime.add(SceneScriptInstance(id: "before", source: "shared.before = true; function init() { return 'inited'; }"))
        runtime.add(SceneScriptInstance(id: "hang", source: "while (true) {}"))
        runtime.add(SceneScriptInstance(id: "after", source: "shared.after = true;"))
        runtime.load()

        XCTAssertEqual(runtime.state, .halted)
        XCTAssertEqual(host.errors.filter { $0.kind == .terminated }.map(\.scriptID), ["hang"])
        XCTAssertEqual(evaluate("shared.before", in: runtime)?.toBool(), true)
        XCTAssertTrue(evaluate("shared.after", in: runtime)?.isUndefined ?? false)
        XCTAssertNotEqual(runtime.value(of: "before")?.toString(), "inited", "no init runs after the watchdog fired")
    }

    // MARK: - Errors

    func testAThrowingCallbackIsDisabledAloneAndLoggedOnceWithoutSource() throws {
        let host = TestSceneScriptHost()
        let runtime = try makeRuntime(host)
        runtime.add(SceneScriptInstance(id: "thrower", source: """
            // secretSourceToken
            var n = 0;
            function update() {
                n += 1; shared.throwerCalls = n;
                throw new Error('boom');
            }
            function applyUserProperties() { shared.throwerProperties = (shared.throwerProperties || 0) + 1; }
            """))
        runtime.add(SceneScriptInstance(id: "counter", source: "var n = 0; function update() { n += 1; return n; }",
                                        initialValue: 0))
        runtime.load()
        for _ in 0..<3 { runtime.frame(deltaTime: 1.0 / 60) }
        runtime.userPropertiesDidChange(["p": 1])
        runtime.frame(deltaTime: 1.0 / 60)

        XCTAssertEqual(runtime.value(of: "counter")?.toInt32(), 4)
        XCTAssertTrue(runtime.isEnabled("thrower"))
        XCTAssertEqual(evaluate("shared.throwerCalls", in: runtime)?.toInt32(), 1, "WE never calls a callback again after it threw (P4)")
        XCTAssertEqual(evaluate("shared.throwerProperties", in: runtime)?.toInt32(), 2, "its other callbacks keep running")
        let errors = host.errors.filter { $0.scriptID == "thrower" }
        XCTAssertEqual(errors.count, 1, "each distinct error is reported once")
        XCTAssertEqual(errors.first?.kind, .runtime)
        XCTAssertEqual(errors.first?.callback, "update")
        XCTAssertEqual(errors.first?.line, 5)
        XCTAssertEqual(errors.first?.message, "Error: boom")
        XCTAssertFalse(errors.first?.description.contains("secretSourceToken") ?? true)
    }

    func testCompileAndGlobalScopeErrorsDisableOnlyTheirScript() throws {
        let host = TestSceneScriptHost()
        let runtime = try makeRuntime(host)
        runtime.add(SceneScriptInstance(id: "broken", source: "var a = 1;\nvar = ;"))
        runtime.add(SceneScriptInstance(id: "throwsAtLoad", source: "throw new Error('at load');"))
        runtime.add(SceneScriptInstance(id: "fine", source: "function update(v) { return v + 1; }", initialValue: 0))
        runtime.load()
        runtime.frame(deltaTime: 1.0 / 60)

        XCTAssertFalse(runtime.isEnabled("broken"))
        XCTAssertFalse(runtime.isEnabled("throwsAtLoad"))
        XCTAssertEqual(runtime.value(of: "fine")?.toInt32(), 1)
        let compile = host.errors.first { $0.scriptID == "broken" }
        XCTAssertEqual(compile?.kind, .compile)
        XCTAssertEqual(compile?.line, 2)
        XCTAssertEqual(host.errors.first { $0.scriptID == "throwsAtLoad" }?.kind, .runtime)
    }

    // MARK: - Order

    private func orderScript(_ name: String) -> String {
        """
        shared.log = shared.log || [];
        shared.log.push('eval:\(name):' + __rt.phase);
        function init(value) { shared.log.push('init:\(name):' + __rt.phase); }
        function applyUserProperties(changed) { shared.log.push('aup:\(name):' + Object.keys(changed).sort().join('+')); }
        function applyGeneralSettings(changed) { shared.log.push('ags:\(name):' + changed.language); }
        function resizeScreen(size) { shared.log.push('resize:\(name):' + size.x + 'x' + size.y); }
        function update(value) { shared.log.push('update:\(name)'); }
        function destroy() { shared.log.push('destroy:\(name)'); }
        """
    }

    private func takeLog(_ runtime: SceneScriptRuntime) -> [String] {
        let log = evaluate("shared.log.splice(0, shared.log.length)", in: runtime)?.toArray() as? [String]
        return log ?? []
    }

    func testLoadAndFrameCallbackOrder() throws {
        let runtime = try makeRuntime(extensions: [PhaseLoggingExtension()])
        runtime.add(SceneScriptInstance(id: "a", source: orderScript("a")))
        runtime.add(SceneScriptInstance(id: "b", source: orderScript("b")))

        runtime.load(userProperties: ["p": 1, "q": 2])
        XCTAssertEqual(takeLog(runtime), [
            "eval:a:global", "eval:b:global", "init:a:callback", "init:b:callback",
            "aup:a:p+q", "aup:b:p+q", "ags:a:en-us", "ags:b:en-us"
        ])

        // Posted media first: WE still handles property changes before media events (P1).
        runtime.inbox.post(SceneScriptEvent(kind: SceneScriptEvent.Kind(rawValue: "testMedia"), payload: ["state": 1]))
        runtime.userPropertiesDidChange(["p": 3])
        runtime.screenDidResize(width: 800, height: 600)
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(takeLog(runtime), [
            "frameGlobals", "resize:a:800x600", "resize:b:800x600", "aup:a:p", "aup:b:p", "media:1",
            "animations", "timers", "update:a", "update:b", "deferred"
        ])

        runtime.remove(scriptID: "a")
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(takeLog(runtime), ["frameGlobals", "animations", "timers", "update:b", "deferred", "destroy:a"])

        runtime.tearDown()
        XCTAssertEqual(takeLog(runtime), ["destroy:b"])
    }

    // MARK: - Shared memory

    func testCommandRingDeliversCommandsInOrderEachFrame() throws {
        let runtime = try makeRuntime()
        var received: [SceneScriptCommandRing.Command] = []
        runtime.commandRing.register(SceneScriptCommandRing.Opcode(rawValue: 1000)) { received.append($0) }
        runtime.add(SceneScriptInstance(id: "pusher", source: """
            function update() { __rt.push(1000, 7, [1.5, 2.5], ['hello']); __rt.push(1000, -1); }
            """))
        runtime.load()
        runtime.frame(deltaTime: 1.0 / 60)
        runtime.frame(deltaTime: 1.0 / 60)

        XCTAssertEqual(received.count, 4, "the ring is emptied after each frame")
        XCTAssertEqual(received.first?.target, 7)
        XCTAssertEqual(received.first?.numbers, [1.5, 2.5])
        XCTAssertEqual(received.first?.strings, ["hello"])
        XCTAssertEqual(received[1].target, -1)
        XCTAssertEqual(received[1].numbers, [])
        XCTAssertEqual(runtime.commandRing.pendingCount, 0)
    }

    func testObjectTableIsTheSameMemoryInSwiftAndJavaScript() throws {
        let runtime = try makeRuntime()
        let table = try XCTUnwrap(SceneScriptObjectTable(capacity: 2, in: runtime.context))
        table.install(on: runtime.rt)
        typealias Layout = SceneScriptObjectTable.Layout

        table.values[SceneScriptObjectTable.index(slot: 1, field: Layout.alpha)] = 0.5
        XCTAssertEqual(evaluate("__rt.table.values[1 * __rt.table.layout.stride + __rt.table.layout.alpha]",
                                in: runtime)?.toDouble(), 0.5)
        evaluate("__rt.table.values[__rt.table.layout.origin] = 3; __rt.table.dirty[0] = 1;", in: runtime)
        XCTAssertEqual(table.values[SceneScriptObjectTable.index(slot: 0, field: Layout.origin)], 3)
        XCTAssertEqual(table.dirty[0], 1)
    }
}

