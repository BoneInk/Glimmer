import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// `engine.setTimeout`/`setInterval` (docs/scenescript-plan.md §1.4, §1.9 P1): cancel functions,
/// global-scope rules, and when timers fire within a frame.
final class SceneScriptTimerTests: XCTestCase {
    private var fixture: SceneScriptEngineTestFixture!

    override func setUpWithError() throws {
        fixture = try SceneScriptEngineTestFixture()
    }

    override func tearDown() {
        fixture.removeStorage()
        fixture = nil
        super.tearDown()
    }

    func testTimersFireAfterEventsAndBeforeUpdatesInScriptOrder() throws {
        // Each script starts its timers in init; b's are started first but a is earlier in the list.
        fixture.add("a", """
            shared.log = shared.log || [];
            function init() {
                engine.setTimeout(function () { shared.log.push('a:timeout'); }, 10);
                engine.setInterval(function () { shared.log.push('a:interval'); }, 10);
            }
            function applyUserProperties(changed) { if (changed.p) shared.log.push('a:properties'); }
            function update() { shared.log.push('a:update'); }
            """)
        fixture.add("b", """
            shared.log = shared.log || [];
            function init() { engine.setTimeout(function () { shared.log.push('b:timeout'); }, 0); }
            function update() { shared.log.push('b:update'); }
            """)
        fixture.runtime.load()
        XCTAssertEqual(fixture.takeLog(), [], "nothing fires during load")

        fixture.runtime.userPropertiesDidChange(["p": ["type": "slider", "value": 1]])
        fixture.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(fixture.takeLog(), ["a:properties", "a:timeout", "a:interval", "b:timeout", "a:update", "b:update"])

        fixture.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(fixture.takeLog(), ["a:interval", "a:update", "b:update"], "timeouts fire once")
    }

    func testDelaysCountFrameTimeInMilliseconds() throws {
        fixture.add("delays", """
            shared.log = [];
            var started = false;
            function update() {
                if (started) return;
                started = true;
                engine.setTimeout(function () { shared.log.push('timeout@' + engine.runtime.toFixed(2)); }, 250);
                engine.setInterval(function () { shared.log.push('interval@' + engine.runtime.toFixed(2)); }, 200);
            }
            """)
        fixture.runtime.load()
        fixture.frames(7, deltaTime: 0.1)
        // Started during the first frame's update at 0.1 s; the first tick that counts is the next frame's.
        XCTAssertEqual(fixture.takeLog(), ["interval@0.30", "timeout@0.40", "interval@0.50", "interval@0.70"])
    }

    func testAnIntervalFiresAtMostOncePerFrameAndResetsToItsPeriod() throws {
        fixture.add("fast", """
            shared.count = 0;
            function init() { engine.setInterval(function () { shared.count += 1; }, 10); }
            """)
        fixture.runtime.load()
        fixture.frames(3, deltaTime: 1)
        XCTAssertEqual(fixture.evaluate("shared.count")?.toInt32(), 3, "a one-second frame fires a 10 ms interval once")
    }

    func testTheReturnedFunctionCancels() throws {
        _ = try Fixtures.assets()
        // The corpus pattern (3 scripts in 7 wallpapers): cancel the pending hide, start a new one.
        fixture.add("hide", """
            var lastHideEvent;
            shared.hidden = 0;
            function mediaThumbnailChanged(event) {
                if (lastHideEvent) {
                    lastHideEvent();
                    lastHideEvent = undefined;
                }
                if (event.hasThumbnail) {
                    lastHideEvent = engine.setTimeout(()=>{ shared.hidden += 1; }, 1000);
                }
            }
            """)
        fixture.runtime.load()
        XCTAssertEqual(fixture.evaluate("typeof engine.setTimeout(function () {}, 1)")?.toString(), "object",
                       "no script is running: nothing starts, null comes back")
        fixture.evaluate("__rt.broadcast('mediaThumbnailChanged', [{ hasThumbnail: true }])")
        fixture.frames(1, deltaTime: 0.6)
        fixture.evaluate("__rt.broadcast('mediaThumbnailChanged', [{ hasThumbnail: true }])")
        fixture.frames(1, deltaTime: 0.6)
        XCTAssertEqual(fixture.evaluate("shared.hidden")?.toInt32(), 0, "the first timeout was cancelled")
        fixture.frames(1, deltaTime: 0.6)
        XCTAssertEqual(fixture.evaluate("shared.hidden")?.toInt32(), 1)
        fixture.frames(3, deltaTime: 1)
        XCTAssertEqual(fixture.evaluate("shared.hidden")?.toInt32(), 1)
        XCTAssertTrue(fixture.host.errors.isEmpty, "\(fixture.host.errors)")
    }

    func testCancellingDuringTheTickStopsTimersNotYetRun() throws {
        fixture.add("cancel", """
            shared.log = [];
            var stopSelf, stopOther;
            function init() {
                stopSelf = engine.setInterval(function () { shared.log.push('self'); stopSelf(); stopOther(); }, 0);
                stopOther = engine.setInterval(function () { shared.log.push('other'); }, 0);
            }
            """)
        fixture.runtime.load()
        fixture.frames(3)
        XCTAssertEqual(fixture.takeLog(), ["self"])
    }

    func testTimersStartedInATimerWaitForTheNextFrame() throws {
        fixture.add("chain", """
            shared.log = [];
            function init() {
                engine.setTimeout(function () {
                    shared.log.push('first');
                    engine.setTimeout(function () { shared.log.push('second'); }, 0);
                }, 0);
            }
            """)
        fixture.runtime.load()
        fixture.frames(1)
        XCTAssertEqual(fixture.takeLog(), ["first"])
        fixture.frames(1)
        XCTAssertEqual(fixture.takeLog(), ["second"])
    }

    func testGlobalScopeRulesUseWEsMessages() throws {
        fixture.add("global", "engine.setTimeout(function () {}, 1);")
        fixture.add("globalInterval", "engine.setInterval(function () {}, 1);")
        fixture.add("fine", "function update(v) { return v + 1; }", initialValue: 0)
        fixture.runtime.load()
        fixture.frames(1)

        XCTAssertFalse(fixture.runtime.isEnabled("global"))
        XCTAssertEqual(fixture.host.errors.first { $0.scriptID == "global" }?.message,
                       "Error: setTimeout cannot be called from global scope.")
        XCTAssertEqual(fixture.host.errors.first { $0.scriptID == "globalInterval" }?.message,
                       "Error: setInterval cannot be called from global scope.")
        XCTAssertEqual(fixture.runtime.value(of: "fine")?.toInt32(), 1)
    }

    func testInvalidArgumentsStartNothing() throws {
        fixture.add("invalid", """
            shared.log = [];
            function init() {
                shared.log.push(String(engine.setTimeout()));
                shared.log.push(String(engine.setTimeout('not a function', 1)));
                engine.setTimeout(function () { shared.log.push('no delay'); });
                engine.setTimeout(function () { shared.log.push('NaN delay'); }, NaN);
                engine.setTimeout(function () { shared.log.push('string delay'); }, '5000');
            }
            """)
        fixture.runtime.load()
        XCTAssertEqual(fixture.takeLog(), ["null", "null"])
        fixture.frames(1)
        XCTAssertEqual(fixture.takeLog(), ["no delay", "NaN delay", "string delay"],
                       "a missing or non-number delay is 0; NaN is not above 0")
    }

    func testAThrowingTimerIsLoggedAndKeepsRunning() throws {
        fixture.add("thrower", """
            shared.count = 0;
            function init() { engine.setInterval(function () { shared.count += 1; throw new Error('tick'); }, 0); }
            function update() { shared.updated = true; }
            """)
        fixture.runtime.load()
        fixture.frames(3)
        XCTAssertEqual(fixture.evaluate("shared.count")?.toInt32(), 3, "WE never disables a timer callback (P4)")
        XCTAssertEqual(fixture.evaluate("shared.updated")?.toBool(), true)
        let errors = fixture.host.errors.filter { $0.scriptID == "thrower" }
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.callback, "setInterval")
        XCTAssertEqual(errors.first?.message, "Error: tick")
    }

    func testTimersOfARemovedScriptStop() throws {
        fixture.add("owner", """
            shared.count = 0;
            function init() { engine.setInterval(function () { shared.count += 1; }, 0); }
            """)
        fixture.runtime.load()
        fixture.frames(2)
        fixture.runtime.remove(scriptID: "owner")
        fixture.frames(3)
        XCTAssertEqual(fixture.evaluate("shared.count")?.toInt32(), 3, "it runs in the frame it is removed in, then stops")
    }
}
