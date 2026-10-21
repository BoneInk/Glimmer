import AppKit
import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// Regression tests for the runtime's findings in docs/test-risks.md (SF1–SF8, S19) and the WP2/
/// WP4 integration notes.
final class SceneScriptRuntimeHardeningTests: XCTestCase {
    private func makeRuntime(_ host: TestSceneScriptHost = TestSceneScriptHost(),
                             extensions: [SceneScriptRuntimeExtension] = [],
                             configuration: SceneScriptRuntime.Configuration = .standard) throws -> SceneScriptRuntime {
        try SceneScriptRuntime(host: host, compiler: TestSceneScriptCompiler(), extensions: extensions,
                               configuration: configuration)
    }

    private func evaluate(_ script: String, in runtime: SceneScriptRuntime) -> JSValue? {
        runtime.context.evaluateScript(script)
    }

    // MARK: - SF1: error lines

    func testHelperErrorsReportTheScriptsLine() throws {
        let host = TestSceneScriptHost()
        let runtime = try makeRuntime(host)
        runtime.add(SceneScriptInstance(id: "caller", source: """
            function helper() { return 1; }
            function update() {
                __rt.requireGlobalScope('registerAudioBuffers');
            }
            """))
        runtime.load()
        runtime.frame(deltaTime: 1.0 / 60)
        let error = host.errors.first { $0.scriptID == "caller" }
        XCTAssertEqual(error?.message, "Error: registerAudioBuffers can only be called from global scope.")
        XCTAssertEqual(error?.line, 3, "the script's line, not runtime.js's")
    }

    // MARK: - SF2, SF12: removals

    func testDestroyThatRemovesAnEarlierScriptDestroysBoth() throws {
        let runtime = try makeRuntime()
        runtime.add(SceneScriptInstance(id: "c", source: "function destroy() { shared.log.push('c'); }"))
        runtime.add(SceneScriptInstance(id: "b", source: """
            shared.log = [];
            function destroy() { shared.log.push('b'); __rt.remove('c'); }
            """))
        runtime.load()
        runtime.remove(scriptID: "b")
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(evaluate("shared.log.join()", in: runtime)?.toString(), "b,c")
        XCTAssertEqual(evaluate("__rt.byId.size + ',' + __rt.records.length", in: runtime)?.toString(), "0,0")
        XCTAssertFalse(runtime.isEnabled("c"))

        // Both ids are free again (the Swift side learned about 'c' from JS).
        runtime.add(SceneScriptInstance(id: "c", source: "function init() { shared.log.push('c again'); }"))
        runtime.add(SceneScriptInstance(id: "b", source: "function init() { shared.log.push('b again'); }"))
        runtime.load()
        XCTAssertEqual(evaluate("shared.log.join()", in: runtime)?.toString(), "b,c,c again,b again")
    }

    // MARK: - SF3: detachment

    func testADetachedSharedBufferStopsTheScripts() throws {
        let host = TestSceneScriptHost()
        let runtime = try makeRuntime(host)
        let probe = DetachableProbe()
        runtime.watch(probe)
        runtime.add(SceneScriptInstance(id: "n", source: "var n = 0; function update() { n += 1; return n; }", initialValue: 0))
        runtime.load()
        runtime.frame(deltaTime: 1.0 / 60)
        probe.isDetached = true
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(runtime.state, .halted)
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(runtime.value(of: "n")?.toInt32(), 2)
        XCTAssertEqual(host.errors.filter { $0.message.contains("detached") }.count, 1)
    }

    // MARK: - SF4, SF15: inbox

    func testAFullInboxCoalescesStateInsteadOfDroppingIt() {
        let inbox = SceneScriptInbox()
        let media = SceneScriptEvent.Kind(rawValue: "testMediaProperties")
        let timeline = SceneScriptEvent.Kind(rawValue: "testTimeline")
        let click = SceneScriptEvent.Kind(rawValue: "testClick")
        inbox.post(SceneScriptEvent(kind: .userProperties, payload: ["a": 1]))
        inbox.post(SceneScriptEvent(kind: media, payload: ["title": "new"]))
        inbox.post(SceneScriptEvent(kind: click, payload: 0, coalescing: .keep))
        inbox.post(SceneScriptEvent(kind: .userProperties, payload: ["b": 2]))
        inbox.post(SceneScriptEvent(kind: .userProperties, payload: ["a": 3]))
        for index in 0..<2000 { inbox.post(SceneScriptEvent(kind: timeline, payload: ["position": index])) }

        let events = inbox.drain()
        XCTAssertLessThanOrEqual(events.count, SceneScriptInbox.capacity)
        let properties = events.filter { $0.kind == .userProperties }
        XCTAssertEqual(properties.count, 1)
        XCTAssertEqual(properties.first?.payload as? [String: Int], ["a": 3, "b": 2])
        XCTAssertEqual(events.first { $0.kind == media }?.payload as? [String: String], ["title": "new"])
        XCTAssertEqual(events.filter { $0.kind == click }.count, 1)
        XCTAssertEqual(events.last { $0.kind == timeline }?.payload as? [String: Int], ["position": 1999])
    }

    func testAPausedRuntimeStillGetsThePropertyChange() throws {
        let runtime = try makeRuntime()
        runtime.add(SceneScriptInstance(id: "p", source: """
            function applyUserProperties(changed) { if (changed.color !== undefined) shared.color = changed.color; }
            """))
        runtime.load()
        runtime.userPropertiesDidChange(["color": "red"])
        for _ in 0..<2000 { runtime.screenDidResize(width: 100, height: 100) }
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(evaluate("shared.color", in: runtime)?.toString(), "red")
    }

    // MARK: - Teardown and threading (SF4, S10, S19)

    func testTeardownRunsDestroyThenTheirCommandsThenTheExtensions() throws {
        let recorder = TeardownRecorder()
        let runtime = try makeRuntime(extensions: [recorder])
        runtime.commandRing.register(SceneScriptCommandRing.Opcode(rawValue: 1001)) { _ in recorder.log.append("command") }
        runtime.add(SceneScriptInstance(id: "d", source: "function destroy() { __rt.push(1001, -1); }"))
        runtime.load()
        runtime.tearDown()
        runtime.tearDown()
        XCTAssertEqual(recorder.log, ["command", "tearDown"])
    }

    func testReleasingElsewhereRunsDestroyOnTheScriptThread() throws {
        let thread = SceneScriptThread(label: "test")
        let recorder = TeardownRecorder()
        var runtime: SceneScriptRuntime? = try thread.sync {
            try SceneScriptRuntime(host: TestSceneScriptHost(), compiler: TestSceneScriptCompiler(),
                                   extensions: [recorder], thread: thread)
        }
        let onThread: @convention(block) () -> Bool = { thread.isCurrent }
        thread.sync {
            runtime?.context.setObject(onThread, forKeyedSubscript: "onScriptThread" as NSString)
            runtime?.add(SceneScriptInstance(id: "d", source: "function destroy() { shared.destroyedOnThread = onScriptThread(); }"))
            runtime?.load()
        }
        let context = try XCTUnwrap(runtime?.context)
        runtime = nil // on the main thread
        XCTAssertEqual(thread.sync { context.evaluateScript("shared.destroyedOnThread")?.toBool() }, true)
        XCTAssertEqual(recorder.threads, [true])
    }

    func testAHungScriptOnItsThreadLeavesTheMainThreadFree() throws {
        try XCTSkipUnless(SceneScriptWatchdog.isAvailable, "JSContextGroupSetExecutionTimeLimit is unavailable")
        let thread = SceneScriptThread(label: "hang")
        var configuration = SceneScriptRuntime.Configuration.standard
        configuration.frameTimeLimit = 1
        let host = TestSceneScriptHost()
        let runtime = try thread.sync {
            try SceneScriptRuntime(host: host, compiler: TestSceneScriptCompiler(), configuration: configuration,
                                   thread: thread)
        }
        thread.sync {
            runtime.add(SceneScriptInstance(id: "hang", source: "function update() { while (true) {} }"))
            runtime.load()
        }
        XCTAssertTrue(thread.asyncFrame { runtime.frame(deltaTime: 1.0 / 60) })
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertFalse(thread.asyncFrame { runtime.frame(deltaTime: 1.0 / 60) }, "a frame is in flight: skipped")

        let responsive = expectation(description: "the main queue runs while the script hangs")
        let started = Date()
        DispatchQueue.main.async { responsive.fulfill() }
        wait(for: [responsive], timeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)

        XCTAssertEqual(thread.sync { runtime.state }, .halted)
        XCTAssertEqual(host.errors.first?.kind, .terminated)
        XCTAssertTrue(thread.asyncFrame { runtime.frame(deltaTime: 1.0 / 60) })
        thread.sync { runtime.tearDown() }
    }

    // MARK: - SF5: later loads

    func testScriptsAddedAfterTheFirstLoadGetNoApplyUserProperties() throws {
        let runtime = try makeRuntime()
        let source = "function applyUserProperties(c) { shared.log = (shared.log || []).concat(Object.keys(c)); }"
        runtime.add(SceneScriptInstance(id: "first", source: source))
        runtime.load(userProperties: ["p": 1])
        runtime.add(SceneScriptInstance(id: "later", source: "function init() {} " + source))
        runtime.load()
        XCTAssertEqual(evaluate("shared.log.join()", in: runtime)?.toString(), "p")
    }

    // MARK: - Integration: resizeScreen, callback

    func testResizeScreenGetsItsOwnVec2() throws {
        _ = try Fixtures.assets()
        let runtime = try makeRuntime()
        for id in ["a", "b"] {
            runtime.add(SceneScriptInstance(id: id, source: """
                function resizeScreen(size) {
                    shared.log = (shared.log || []).concat([(size instanceof Vec2) + ':' + size.x]);
                    size.x = 0;
                }
                """))
        }
        runtime.load()
        runtime.screenDidResize(width: 800, height: 600)
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(evaluate("shared.log.join()", in: runtime)?.toString(), "true:800,true:800")
    }

    func testTheRunningCallbackIsPublished() throws {
        let runtime = try makeRuntime()
        runtime.add(SceneScriptInstance(id: "a", source: """
            shared.atGlobal = __rt.callback;
            function update() { shared.inUpdate = __rt.callback; }
            """))
        runtime.load()
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(evaluate("String(shared.atGlobal) + ',' + shared.inUpdate + ',' + __rt.callback", in: runtime)?.toString(),
                       "null,update,null")
    }

    // MARK: - SF6, SF7, SF8: engine and storage

    func testStorageKeysCountTowardTheCap() throws {
        let directory = SceneScriptEngineTestFixture.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) } // cleanup of a temporary folder
        let storage = SceneScriptStorage(directory: directory, notificationCenter: NotificationCenter())
        let identity = SceneScriptIdentity(wallpaperID: "w", screenID: "s")
        var stored = 0
        for index in 0..<10_000 {
            let key = String(format: "%05d", index) + String(repeating: "k", count: 1019)
            if storage.setValue("1", forKey: key, in: .screen, of: identity) { stored += 1 }
        }
        XCTAssertEqual(stored, SceneScriptStorage.capacity / SceneScriptStorage.size(key: String(repeating: "k", count: 1024), json: "1"))
    }

    func testStorageFlushesWhenTheAppTerminates() throws {
        let directory = SceneScriptEngineTestFixture.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) } // cleanup of a temporary folder
        let center = NotificationCenter()
        let storage = SceneScriptStorage(directory: directory, notificationCenter: center)
        let identity = SceneScriptIdentity(wallpaperID: "w", screenID: "s")
        XCTAssertTrue(storage.setValue("1", forKey: "clicks", in: .global, of: identity))
        let file = storage.fileURL(for: .global, of: identity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testEngineRuntimeKeepsMillisecondsAfterDays() throws {
        let fixture = try SceneScriptEngineTestFixture()
        defer { fixture.removeStorage() }
        fixture.add("clock", "function update() { shared.log = (shared.log || []).concat([engine.runtime]); }")
        fixture.runtime.load()
        fixture.runtime.frame(deltaTime: 3 * 86_400)
        fixture.runtime.frame(deltaTime: 0.001)
        let log = fixture.evaluate("shared.log")?.toArray() as? [Double] ?? []
        XCTAssertEqual(log.count, 2)
        XCTAssertEqual((log.last ?? 0) - (log.first ?? 0), 0.001, accuracy: 1e-9)
    }

    func testDestroyWritesToStorageSurviveTeardown() throws {
        let fixture = try SceneScriptEngineTestFixture()
        defer { fixture.removeStorage() }
        fixture.add("saver", "function destroy() { localStorage.set('saved', 42, 'global'); }")
        fixture.runtime.load()
        fixture.runtime.tearDown()
        let file = fixture.storage.fileURL(for: .global, of: fixture.host.identity)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the teardown hook flushed it")
    }
}

private final class DetachableProbe: SceneScriptDetachable {
    var isDetached = false
}

private final class TeardownRecorder: SceneScriptRuntimeExtension {
    var log: [String] = []
    var threads: [Bool] = []

    func tearDown(_ runtime: SceneScriptRuntime) {
        log.append("tearDown")
        threads.append(runtime.thread?.isCurrent ?? true)
    }
}
