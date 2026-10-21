import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// `localStorage` (docs/scenescript-plan.md §1.5, §4.7): locations, isolation between screens
/// and wallpapers, WE's value semantics and messages, the 100000-byte cap, persistence.
final class SceneScriptLocalStorageTests: XCTestCase {
    private var directory: URL!
    private var storage: SceneScriptStorage!

    override func setUp() {
        super.setUp()
        directory = SceneScriptEngineTestFixture.makeStorageDirectory()
        storage = SceneScriptStorage(directory: directory)
    }

    override func tearDown() {
        storage = nil
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            XCTAssertNoThrow(try FileManager.default.removeItem(at: directory))
        }
        super.tearDown()
    }

    private func makeFixture(wallpaperID: String = "wallpaper-a", screenID: String = "screen-1") throws -> SceneScriptEngineTestFixture {
        try SceneScriptEngineTestFixture(wallpaperID: wallpaperID, screenID: screenID, storage: storage)
    }

    /// Runs `body` as the body of a script callback and returns what it returns, or the message it threw.
    private func run(_ body: String, in fixture: SceneScriptEngineTestFixture) -> JSValue? {
        let id = "probe\(UUID().uuidString)"
        fixture.add(id, "function init() { try { shared.result = (function () { \(body) })(); } catch (e) { shared.result = 'threw: ' + e.message; } }")
        fixture.runtime.load()
        return fixture.evaluate("shared.result")
    }

    func testSetGetDeleteAndClearWithTheScreenDefault() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(run("""
            localStorage.set('n', 5);
            localStorage.set('s', 'text', localStorage.LOCATION_GLOBAL);
            return [localStorage.get('n'), localStorage.get('n', 'screen'), localStorage.get('n', 'global'),
                    localStorage.get('s', 'global'), localStorage.get('s'), localStorage.get('missing'),
                    localStorage.LOCATION_GLOBAL, localStorage.LOCATION_SCREEN].map(String).join(',');
            """, in: fixture)?.toString(), "5,5,undefined,text,undefined,undefined,global,screen")
        XCTAssertEqual(run("""
            const first = localStorage.delete('n'), again = localStorage.delete('n');
            localStorage.set('x', 1); localStorage.set('y', 2, 'global');
            localStorage.clear();
            return [first, again, localStorage.get('x'), localStorage.get('y', 'global'), localStorage.get('s', 'global')].map(String).join(',');
            """, in: fixture)?.toString(), "true,false,undefined,2,text", "clear() empties only the screen store")
        XCTAssertEqual(run("localStorage.clear('global'); return String(localStorage.get('s', 'global'));", in: fixture)?.toString(),
                       "undefined")
    }

    func testValuesRoundTripThroughJSON() throws {
        _ = try Fixtures.assets()
        let fixture = try makeFixture()
        XCTAssertEqual(run("""
            localStorage.set('v', new Vec3(1, 2, 3));
            localStorage.set('o', { a: [1, 'b', null], nested: { t: true } });
            localStorage.set('f', function () {});
            const v = localStorage.get('v');
            return [v instanceof Vec3, v.x + ' ' + v.y + ' ' + v.z, new Vec3(v.x, v.y, v.z).toString(),
                    JSON.stringify(localStorage.get('o')), String(localStorage.get('f'))].join('|');
            """, in: fixture)?.toString(), #"false|1 2 3|1 2 3|{"a":[1,"b",null],"nested":{"t":true}}|null"#,
                       "a Vec3 comes back as a plain {x, y, z}; a function is stored as 'undefined', which reads back as null")
    }

    func testUndefinedOrUnserializableValuesDeleteTheScreenKey() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(run("""
            localStorage.set('k', 1); localStorage.set('k', 1, 'global');
            localStorage.set('k', undefined, 'global');
            const afterUndefined = [localStorage.get('k'), localStorage.get('k', 'global')].map(String).join(',');
            localStorage.set('k', 2);
            const cyclic = {}; cyclic.self = cyclic;
            let threw = false;
            try { localStorage.set('k', cyclic); } catch (e) { threw = e instanceof TypeError; }
            return afterUndefined + '|' + String(localStorage.get('k')) + ',' + threw;
            """, in: fixture)?.toString(), "undefined,1|undefined,true",
                       "WE deletes from 'screen' whatever location was passed, then rethrows")
    }

    func testWEsErrorMessages() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(run("localStorage.set(1, 2);", in: fixture)?.toString(), "threw: LocalStorageSet key not a string.")
        XCTAssertEqual(run("localStorage.get({});", in: fixture)?.toString(), "threw: LocalStorageSet key not a string.")
        XCTAssertEqual(run("localStorage.delete();", in: fixture)?.toString(), "threw: LocalStorageSet key not a string.")

        let global = try makeFixture(wallpaperID: "wallpaper-global")
        global.add("set", "localStorage.set('k', 1);")
        global.add("get", "localStorage.get('k');")
        global.add("delete", "localStorage.delete('k');")
        global.add("clear", "localStorage.clear();")
        global.runtime.load()
        let messages = ["set", "get", "delete", "clear"].map { id in
            global.host.errors.first { $0.scriptID == id }?.message ?? "no error"
        }
        XCTAssertEqual(messages, [
            "Error: LocalStorageSet cannot be cleared from global scope.",
            "Error: LocalStorageGet cannot be cleared from global scope.",
            "Error: LocalStorageDelete cannot be cleared from global scope.",
            "Error: LocalStorageClear cannot be cleared from global scope."
        ])
    }

    func testScreensShareGlobalAndWallpapersShareNothing() throws {
        let first = try makeFixture(screenID: "screen-1")
        let second = try makeFixture(screenID: "screen-2")
        let other = try makeFixture(wallpaperID: "wallpaper-b", screenID: "screen-1")
        _ = run("localStorage.set('where', 'one'); localStorage.set('score', 10, 'global');", in: first)
        XCTAssertEqual(run("return String(localStorage.get('where')) + ',' + localStorage.get('score', 'global');",
                           in: second)?.toString(), "undefined,10")
        XCTAssertEqual(run("return String(localStorage.get('where')) + ',' + String(localStorage.get('score', 'global'));",
                           in: other)?.toString(), "undefined,undefined")
    }

    func testTheCapCountsEveryOtherEntryAndRejectsTheWrite() throws {
        let fixture = try makeFixture()
        // Each entry is 8 header bytes, its key and its JSON: a 49_989-character string is 49_991
        // JSON bytes, so 'a' and 'b' take 50_000 bytes each.
        let result = run("""
            const big = 'x'.repeat(49989);
            localStorage.set('a', big);
            localStorage.set('a', big);
            localStorage.set('b', big);
            let message = 'stored';
            try { localStorage.set('c', 1); } catch (e) { message = e.message; }
            localStorage.set('c', 1, 'global');
            return [message, String(localStorage.get('c')), localStorage.get('c', 'global')].join('|');
            """, in: fixture)?.toString()
        XCTAssertEqual(result, "LocalStorageSet failed, possibly out of memory.|undefined|1",
                       "replacing a key doesn't count it twice; the full screen store refuses, the global one is separate")
        XCTAssertEqual(2 * SceneScriptStorage.size(key: "a", json: String(repeating: "x", count: 49_991)),
                       SceneScriptStorage.capacity)
    }

    func testValuesPersistUnderTheRuntimeIdentity() throws {
        let identity = SceneScriptIdentity(wallpaperID: "123/../456", screenID: "Display 1")
        XCTAssertTrue(storage.setValue("42", forKey: "answer", in: .screen, of: identity))
        XCTAssertTrue(storage.setValue(#""hi""#, forKey: "greeting", in: .global, of: identity))
        storage.flush()

        let screenFile = storage.fileURL(for: .screen, of: identity)
        XCTAssertTrue(screenFile.path.hasPrefix(directory.path), "ids can't escape the storage folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: screenFile.path))
        XCTAssertEqual(screenFile.deletingLastPathComponent(), storage.fileURL(for: .global, of: identity).deletingLastPathComponent())

        let reopened = SceneScriptStorage(directory: directory)
        XCTAssertEqual(reopened.value(forKey: "answer", in: .screen, of: identity), "42")
        XCTAssertEqual(reopened.value(forKey: "greeting", in: .global, of: identity), #""hi""#)
        XCTAssertNil(reopened.value(forKey: "answer", in: .screen,
                                    of: SceneScriptIdentity(wallpaperID: identity.wallpaperID, screenID: "Display 2")))

        reopened.removeAll(in: .screen, of: identity)
        reopened.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: screenFile.path), "an emptied store leaves no file")
    }

    func testTheExtensionFlushesWhenItGoesAway() throws {
        var fixture: SceneScriptEngineTestFixture? = try makeFixture()
        _ = run("localStorage.set('kept', true, 'global');", in: fixture!)
        let file = storage.fileURL(for: .global, of: SceneScriptIdentity(wallpaperID: "wallpaper-a", screenID: "screen-1"))
        fixture = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
