import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// WP4's `engine` object, user properties, `openUserShortcut` and `console`
/// (docs/scenescript-plan.md §1.4, §1.5).
final class SceneScriptEngineTests: XCTestCase {
    private var fixtures: [SceneScriptEngineTestFixture] = []

    override func tearDown() {
        fixtures.forEach { $0.removeStorage() }
        fixtures = []
        super.tearDown()
    }

    private func makeFixture(environment: SceneScriptEngineEnvironment = .standard,
                             now: @escaping () -> Date = Date.init,
                             calendar: Calendar = .current) throws -> SceneScriptEngineTestFixture {
        let fixture = try SceneScriptEngineTestFixture(environment: environment, now: now, calendar: calendar)
        fixtures.append(fixture)
        return fixture
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: - Frame numbers

    func testFrameTimeRuntimeAndTimeOfDay() throws {
        // 18:00:00 UTC is three quarters of the day.
        let sixPM = Date(timeIntervalSince1970: 18 * 3600)
        let fixture = try makeFixture(now: { sixPM }, calendar: utcCalendar())
        fixture.add("clock", """
            shared.log = [];
            function init() { shared.log.push('init ' + engine.frametime + ' ' + engine.runtime); }
            function update() { shared.log.push(engine.frametime.toFixed(4) + ' ' + engine.runtime.toFixed(4)); }
            """)
        fixture.runtime.load()
        fixture.runtime.frame(deltaTime: 0.25)
        fixture.runtime.frame(deltaTime: 0.5)
        fixture.runtime.frame(deltaTime: 0)
        XCTAssertEqual(fixture.takeLog(), ["init 0 0", "0.2500 0.2500", "0.5000 0.7500", "0.0000 0.7500"])
        XCTAssertEqual(fixture.evaluate("engine.timeOfDay")?.toDouble() ?? 0, 0.75, accuracy: 1e-6)
    }

    func testSizesAreFreshVec2sAndFollowTheEnvironment() throws {
        _ = try Fixtures.assets()
        let fixture = try makeFixture(environment: SceneScriptEngineEnvironment(screenResolution: SIMD2(2560, 1440),
                                                                                canvasSize: SIMD2(1920, 1080)))
        fixture.add("sizes", """
            function init() {
                shared.initSize = engine.canvasSize.x + 'x' + engine.canvasSize.y;
                shared.isVec2 = engine.screenResolution instanceof Vec2;
                const a = engine.screenResolution; a.x = 1;
                shared.copy = engine.screenResolution.x;
            }
            """)
        fixture.runtime.load()
        XCTAssertEqual(fixture.evaluate("shared.initSize")?.toString(), "1920x1080", "module bodies and init see the sizes")
        XCTAssertEqual(fixture.evaluate("shared.isVec2")?.toBool(), true)
        XCTAssertEqual(fixture.evaluate("shared.copy")?.toInt32(), 2560, "writing a returned vector changes nothing")

        fixture.engine.environment.screenResolution = SIMD2(1080, 1920)
        XCTAssertEqual(fixture.evaluate("engine.screenResolution.y")?.toInt32(), 1920)
        XCTAssertEqual(fixture.evaluate("engine.isPortrait()")?.toBool(), true)
        XCTAssertEqual(fixture.evaluate("engine.isLandscape()")?.toBool(), false)
    }

    func testDeviceFlagsAreFunctions() throws {
        let fixture = try makeFixture()
        let flags = fixture.evaluate("""
            [engine.isRunningInEditor(), engine.isPortrait(), engine.isLandscape(), engine.isDesktopDevice(),
             engine.isMobileDevice(), engine.isWallpaper(), engine.isScreensaver()].join(',')
            """)?.toString()
        XCTAssertEqual(flags, "false,false,true,true,false,true,false")
        XCTAssertEqual(fixture.evaluate("[engine.AUDIO_RESOLUTION_16, engine.AUDIO_RESOLUTION_32, engine.AUDIO_RESOLUTION_64].join()")?.toString(),
                       "16,32,64")
        XCTAssertEqual(fixture.evaluate("typeof engine.clearTimeout")?.toString(), "undefined",
                       "WE has no clearTimeout; the returned function cancels")

        fixture.engine.environment.isScreensaver = true
        XCTAssertEqual(fixture.evaluate("engine.isScreensaver() + ',' + engine.isWallpaper()")?.toString(), "true,false")
        fixture.engine.environment.isRunningInEditor = true
        XCTAssertEqual(fixture.evaluate("engine.isRunningInEditor()")?.toBool(), true, "the Wallpaper Editor's canvas")
    }

    // MARK: - User properties

    private let rawProperties: [String: Any] = [
        "tint": ["type": "color", "value": "1 0.5 0.25"],
        "speed": ["type": "slider", "value": 3],
        "show": ["type": "bool", "value": true],
        "launch": ["type": "usershortcut", "isbound": true, "commandtype": 1, "file": "app.lnk"],
    ]

    func testUserPropertiesAreConvertedByWEsOwnCode() throws {
        _ = try Fixtures.assets()
        let fixture = try makeFixture()
        fixture.add("props", """
            function applyUserProperties(changed) {
                shared.changed = Object.keys(changed).sort().join(',');
                shared.tintIsVec3 = changed.tint instanceof Vec3;
                shared.tint = changed.tint ? changed.tint.toString() : shared.tint;
                shared.launch = changed.launch ? JSON.stringify(changed.launch) : shared.launch;
                changed.speed = 99;
            }
            """)
        fixture.runtime.load(userProperties: rawProperties)
        XCTAssertEqual(fixture.evaluate("shared.changed")?.toString(), "launch,show,speed,tint")
        XCTAssertEqual(fixture.evaluate("shared.tintIsVec3")?.toBool(), true)
        XCTAssertEqual(fixture.evaluate("shared.tint")?.toString(), "1 0.5 0.25")
        XCTAssertEqual(fixture.evaluate("shared.launch")?.toString(), #"{"isbound":true,"commandtype":1,"file":"app.lnk"}"#)
        XCTAssertEqual(fixture.evaluate("engine.userProperties.speed")?.toInt32(), 3,
                       "the object a callback receives is not engine.userProperties")
        XCTAssertEqual(fixture.evaluate("engine.userProperties.tint instanceof Vec3")?.toBool(), true)

        // A change carries only the changed property; engine.userProperties keeps the rest.
        fixture.runtime.userPropertiesDidChange(["speed": ["type": "slider", "value": 5]])
        fixture.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(fixture.evaluate("shared.changed")?.toString(), "speed")
        XCTAssertEqual(fixture.evaluate("engine.userProperties.speed")?.toInt32(), 5)
        XCTAssertEqual(fixture.evaluate("engine.userProperties.show")?.toBool(), true)
    }

    // MARK: - openUserShortcut

    func testOpenUserShortcutOnlyInsideCursorCallbacks() throws {
        let fixture = try makeFixture()
        fixture.add("shortcut", """
            function tryOpen(label) {
                try { shared.log.push(label + ':' + engine.openUserShortcut('launch')); }
                catch (e) { shared.log.push(label + ':' + e.message); }
            }
            shared.log = [];
            function update() { tryOpen('update'); }
            function cursorClick() { tryOpen('click'); }
            function cursorDown() { tryOpen('down'); }
            function cursorMove() { tryOpen('move'); }
            """)
        fixture.runtime.load()
        fixture.runtime.frame(deltaTime: 1.0 / 60)
        fixture.evaluate("__rt.broadcast('cursorDown', [{}]); __rt.broadcast('cursorMove', [{}]); __rt.broadcast('cursorClick', [{}]);")
        XCTAssertEqual(fixture.takeLog(), [
            "update:Cannot execute user command outside of cursor callbacks.",
            "down:false", "move:Cannot execute user command outside of cursor callbacks.", "click:false"
        ])
    }

    func testOnlyOneUserShortcutRunsPerClick() throws {
        let fixture = try makeFixture()
        var opened: [String] = []
        fixture.engine.userShortcutHandler = { opened.append($0); return true }
        fixture.add("shortcut", """
            shared.log = [];
            function cursorClick() {
                shared.log.push(String(engine.openUserShortcut('first')));
                try { engine.openUserShortcut('second'); } catch (e) { shared.log.push(e.message); }
            }
            """)
        fixture.runtime.load()
        fixture.runtime.frame(deltaTime: 1.0 / 60)
        fixture.evaluate("__rt.broadcast('cursorClick', [{}])")
        fixture.runtime.frame(deltaTime: 1.0 / 60)
        fixture.evaluate("__rt.broadcast('cursorClick', [{}])")
        XCTAssertEqual(opened, ["first", "first"])
        XCTAssertEqual(fixture.takeLog(), [
            "true", "Cannot execute more than one user command per cursor click.",
            "true", "Cannot execute more than one user command per cursor click."
        ])
    }

    // MARK: - console

    func testConsoleNamesTheScriptAndIsRateLimited() throws {
        _ = try Fixtures.assets()
        let fixture = try makeFixture()
        fixture.add("talker", """
            function init() { console.log('hello', 1, new Vec2(1, 2)); console.error('bad', true); }
            function update() { for (let i = 0; i < 100; i++) console.log('spam ' + i); }
            """)
        fixture.runtime.load()
        XCTAssertEqual(fixture.consoleLines.count, 2)
        XCTAssertEqual(fixture.consoleLines.first?.0, .log)
        XCTAssertEqual(fixture.consoleLines.first?.1, "[test-wallpaper screen-1] talker Log: hello 1 1 2")
        XCTAssertEqual(fixture.consoleLines.last?.0, .error)
        XCTAssertEqual(fixture.consoleLines.last?.1, "[test-wallpaper screen-1] talker Error: bad true")

        fixture.runtime.frame(deltaTime: 0.1)
        XCTAssertEqual(fixture.consoleLines.count, SceneScriptConsole.linesPerSecond, "capped per second of scene time")
        fixture.runtime.frame(deltaTime: 1)
        XCTAssertTrue(fixture.consoleLines.contains { $0.1.hasSuffix("console lines suppressed (more than 20 per second)") })
    }
}
