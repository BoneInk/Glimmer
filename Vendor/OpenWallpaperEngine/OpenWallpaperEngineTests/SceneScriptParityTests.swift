import Foundation
import XCTest
@testable import OpenWallpaperEngine

/// SceneScript parity with WE's documented API (lib.sceneScript.d.ts and the docs' reference):
/// every global, module and event outside the object model (SceneScriptObjectTypingsTests covers
/// that), the lifecycle order the docs give, and the library's scripts running without calling
/// anything the runtime lacks.
final class SceneScriptParityTests: XCTestCase {
    // MARK: - Globals, events and lifecycle (fixture)

    /// `Tests/Fixtures/SceneScript/replay/parity`: its scripts throw when a documented member is
    /// missing or an event comes out of order, and count what they saw in `shared`.
    func testParityFixtureSeesEveryDocumentedGlobalAndEventInOrder() throws {
        _ = try Fixtures.assets()
        let options = SceneScriptReplayHarness.Options()
        let wallpaper = try SceneScriptReplayWallpaper(directory: Fixtures.url("SceneScript/replay/parity"), id: "parity")
        let result = try SceneScriptReplayHarness(wallpaper: wallpaper, options: options).run(prelude: SceneScriptPrelude.load())
        XCTAssertEqual(wallpaper.sites.count, 5)
        XCTAssertTrue(result.errors.isEmpty, result.errors.map(\.description).joined(separator: "\n"))
        XCTAssertFalse(result.halted)

        let shared = result.sharedNumbers
        XCTAssertEqual(shared["probeOK"], 1)
        XCTAssertEqual(shared["lifecycleUpdates"], Double(options.frames))
        XCTAssertEqual(shared["intervalFires"], Double(options.frames), "a 0 ms interval fires once per frame")
        XCTAssertEqual(shared["timeoutUpdates"], 0, "timers run before the frame's updates")
        XCTAssertEqual(shared["generalSettingsCalls"], 1, "applyGeneralSettings once at load")
        XCTAssertEqual(shared["userPropertyCalls"], 3, "at load, then the two changes of the replay")
        XCTAssertEqual(shared["clicks"], Double(options.clickFrames.count))
        XCTAssertGreaterThanOrEqual(shared["cursorEnters"] ?? 0, Double(options.clickFrames.count))
        for event in ["mediaStatus", "mediaPlayback", "mediaProperties", "mediaThumbnail", "mediaTimeline"] {
            XCTAssertGreaterThan(shared[event] ?? 0, 0, "\(event)Changed never reached the script")
        }
        // destroyLayer: the layer's scripts still update in that frame, then destroy() runs once.
        XCTAssertEqual(shared["doomedDestroyCalls"], 1)
        let atDestroy = try XCTUnwrap(shared["updatesAtDestroyLayer"])
        XCTAssertEqual(shared["doomedUpdatesAtDestroy"], atDestroy + 1)
        XCTAssertEqual(shared["doomedUpdates"], atDestroy + 1, "no update after destroy()")
    }

    // MARK: - applyUserProperties, applyGeneralSettings and resizeScreen (runtime)

    func testChangesReachScriptsWithOnlyTheChangedKeysAtTheStartOfTheNextFrame() throws {
        let host = TestSceneScriptHost()
        let runtime = try SceneScriptRuntime(host: host, compiler: TestSceneScriptCompiler(), extensions: [])
        runtime.add(SceneScriptInstance(id: "log", source: """
            shared.log = [];
            function init(value) { shared.log.push('init'); return value; }
            function applyUserProperties(changed) { shared.log.push('props:' + Object.keys(changed).sort().join('+')); }
            function applyGeneralSettings(changed) { shared.log.push('general:' + Object.keys(changed).join('+') + '=' + changed.language); }
            function resizeScreen(size) { shared.log.push('resize:' + size.x + 'x' + size.y); }
            function update(value) { shared.log.push('update'); return value; }
            function destroy() { shared.log.push('destroy'); }
            """, initialValue: 0))
        runtime.load(userProperties: ["a": ["type": "bool", "value": true], "b": ["type": "slider", "value": 2]],
                     generalSettings: ["language": "de-de"])
        runtime.frame(deltaTime: 1.0 / 60)
        runtime.userPropertiesDidChange(["b": ["type": "slider", "value": 3]])
        runtime.generalSettingsDidChange(["language": "fr-fr"])
        runtime.screenDidResize(width: 2560, height: 1440)
        runtime.frame(deltaTime: 1.0 / 60)
        runtime.tearDown()
        XCTAssertTrue(host.errors.isEmpty, "\(host.errors)")
        // Where WE handles a resize within the frame is not known; the runtime puts it first.
        XCTAssertEqual(runtime.context.evaluateScript("shared.log.join(',')")?.toString(),
                       "init,props:a+b,general:language=de-de,update,"
                           + "resize:2560x1440,props:b,general:language=fr-fr,update,destroy")
    }

    func testGeneralSettingsLanguageIsWEsCodeForThePreferredLanguage() {
        let language = SceneScriptGeneralSettings.language(for:)
        XCTAssertEqual(language(["de-DE"]), "de-de")
        XCTAssertEqual(language(["de-AT"]), "de-de", "WE has one code per language")
        XCTAssertEqual(language(["en-GB"]), "en-us")
        XCTAssertEqual(language(["ja"]), "ja-jp")
        XCTAssertEqual(language(["zh-Hans-CN"]), "zh-chs")
        XCTAssertEqual(language(["zh-Hant-TW"]), "zh-cht")
        XCTAssertEqual(language(["zh-HK"]), "zh-cht")
        XCTAssertEqual(language(["pt-PT"]), "pt-pt")
        XCTAssertEqual(language(["pt-BR"]), "pt-br")
        XCTAssertEqual(language(["nb-NO"]), "nb-no")
        XCTAssertEqual(language(["es-419"]), "es-es")
        XCTAssertEqual(language(["gd-GB", "sv-SE"]), "sv-se", "the first language WE has")
        XCTAssertEqual(language(["gd-GB"]), "en-us", "WE's default")
        XCTAssertEqual(language([]), "en-us")
        XCTAssertTrue(SceneScriptGeneralSettings.languages.contains(SceneScriptGeneralSettings.current()["language"] as? String ?? ""))
    }

    func testConsoleHasV8sMembersAndRenderContextExists() throws {
        let fixture = try SceneScriptEngineTestFixture()
        fixture.runtime.add(SceneScriptInstance(id: "console", source: """
            function init(value) {
                console.warn('w'); console.info('i'); console.debug('d'); console.trace('t');
                console.group('g'); console.groupEnd(); console.time('x'); console.timeEnd('x');
                console.count(); console.assert(true); console.table([]); console.dir({});
                shared.renderContext = typeof renderContext === 'object' && renderContext !== null;
                return value;
            }
            """, initialValue: 0))
        fixture.runtime.load()
        XCTAssertTrue(fixture.host.errors.isEmpty, "\(fixture.host.errors)")
        XCTAssertEqual(fixture.runtime.context.evaluateScript("shared.renderContext")?.toBool(), true,
                       "renderContext missing or init threw: \(fixture.host.errors)")
        XCTAssertEqual(fixture.consoleLines.map(\.1).filter { ["w", "i", "d", "t"].contains(where: $0.hasSuffix) }.count, 4,
                       "\(fixture.consoleLines)")
    }

    // MARK: - The library

    /// Every scene of the library (`OWE_LIBRARY`) replayed as the corpus replay does it: no script
    /// may fail on a member the runtime lacks (a TypeError on `undefined`, a missing function, a
    /// global it can't find), and none may reach an explicit stub other than the six another
    /// change implements. Other errors (a script's own bugs, which WE shows too) are listed in the
    /// attachment, not failed.
    func testLibraryScriptsCallNoUnknownAPI() throws {
        _ = try Fixtures.assets()
        let library = LibrarySweepTests.libraryRoot
        try XCTSkipUnless(FileManager.default.fileExists(atPath: library.path), "wallpaper library not present")
        let prelude = SceneScriptPrelude.load()
        let knownScriptBugs = Set(SceneScriptCorpusReplayTests.expectedFailures.filter { $0.check == .exception }.map(\.key))
        let unknownAPI = try NSRegularExpression(
            pattern: "is not a function|is undefined|undefined is not an object|null is not an object|Can't find variable|is not a constructor|not supported",
            options: [.caseInsensitive])
        var report = "", failures: [String] = [], scenes = 0
        for id in try FileManager.default.contentsOfDirectory(atPath: library.path).sorted() {
            let directory = library.appending(path: id, directoryHint: .isDirectory)
            guard let data = FileManager.default.contents(atPath: directory.appending(path: "project.json").path),
                  let project = try? JSONDecoder().decode(WEProject.self, from: data), // not every folder is a wallpaper
                  project.type.lowercased() == "scene",
                  let wallpaper = try? SceneScriptReplayWallpaper(directory: directory, id: id),
                  !wallpaper.sites.isEmpty else { continue }
            scenes += 1
            let options = SceneScriptReplayHarness.Options()
            let result = try SceneScriptReplayHarness(wallpaper: wallpaper, options: options).run(prelude: prelude)
            let hashByID = Dictionary(result.sites.map { ($0.id, $0.site.hash) }, uniquingKeysWith: { first, _ in first })
            for error in result.errors {
                let line = "\(id) \(hashByID[error.scriptID] ?? "-") \(error.callback): \(error.message)"
                report += line + "\n"
                let range = NSRange(error.message.startIndex..., in: error.message)
                if unknownAPI.firstMatch(in: error.message, range: range) != nil,
                   !knownScriptBugs.contains(hashByID[error.scriptID] ?? "") {
                    failures.append(line)
                }
            }
        }
        XCTContext.runActivity(named: "SceneScript library errors (\(scenes) scenes)") { activity in
            activity.add(XCTAttachment(string: report.isEmpty ? "none" : report))
        }
        if let path = ProcessInfo.processInfo.environment["OWE_SCRIPT_PARITY_REPORT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
        XCTAssertGreaterThan(scenes, 0)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
