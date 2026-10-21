import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// The replay harness (docs/scenescript-plan.md WP9) on synthetic wallpapers in
/// `Tests/Fixtures/SceneScript/replay`, so CI covers it without the corpus. Each fixture asserts
/// the §1.9 behaviour its scripts rely on and that the harness reports what it must.
final class SceneScriptReplayFixtureTests: XCTestCase {
    private func replay(_ name: String, options: SceneScriptReplayHarness.Options = .init()) throws
        -> (SceneScriptReplayWallpaper, SceneScriptReplayHarness.Result, [SceneScriptReplayChecks.Finding]) {
        let wallpaper = try SceneScriptReplayWallpaper(directory: Fixtures.url("SceneScript/replay/\(name)"), id: name)
        let result = try SceneScriptReplayHarness(wallpaper: wallpaper, options: options).run(prelude: SceneScriptPrelude.load())
        return (wallpaper, result, SceneScriptReplayChecks.findings(result, options: options))
    }

    private func samples(_ result: SceneScriptReplayHarness.Result, object: String, field: String,
                         file: StaticString = #filePath, line: UInt = #line) throws -> [Any] {
        let record = result.sites.first { $0.id.contains("/\(object)#") && $0.site.field == field }
        return try XCTUnwrap(record, "\(object) \(field)", file: file, line: line).samples
    }

    private func number(_ sample: Any) -> Double? { (sample as? NSNumber)?.doubleValue }

    private func vector(_ sample: Any) -> [Double] {
        (sample as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
    }

    // MARK: - Behaviour

    func testBehaviourFixtureMeetsEveryExpectation() throws {
        _ = try Fixtures.assets()
        let options = SceneScriptReplayHarness.Options()
        let (wallpaper, result, findings) = try replay("behaviour", options: options)
        XCTAssertEqual(wallpaper.sites.count, 12)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertFalse(result.halted)
        XCTAssertTrue(findings.isEmpty, findings.map(\.description).joined(separator: "\n"))
        XCTAssertEqual(result.frameMilliseconds.count, options.frames)

        // Clocks at the fixed clock: 23:59:52 on 31 December, midnight passes during the run.
        let clock = try samples(result, object: "Clock", field: "text")
        XCTAssertEqual(clock[0] as? String, Self.clockText(options.startDate.addingTimeInterval(options.deltaTime)))
        XCTAssertEqual(clock[599] as? String, Self.clockText(options.startDate.addingTimeInterval(600 * options.deltaTime)))
        XCTAssertEqual(clock[599] as? String, "00:00:02 2027")

        // Audio: flat under silence, moving under the tone.
        let bar = try samples(result, object: "Bar", field: "scale").map(vector)
        XCTAssertEqual(bar[100], [1, 1, 1])
        XCTAssertEqual(bar[500], [1, 1, 1])
        XCTAssertGreaterThan(Set(bar[150..<450].map { $0[1] }).count, 10)
        XCTAssertNotEqual(bar[200][1], 1)
        let rate = try samples(result, object: "Sparks", field: "instanceoverride.rate").compactMap(number)
        XCTAssertEqual(rate[100], 1, accuracy: 1e-6, "base 2 × (0.5 + silence)")
        XCTAssertGreaterThan(Set(rate[150..<450]).count, 10)

        // Media: the effect follows hasThumbnail, the text follows the track.
        let cover = try samples(result, object: "Cover", field: "effects.0.visible").compactMap(number)
        XCTAssertEqual(cover[100], 1)
        XCTAssertEqual(cover[375], 0)
        XCTAssertEqual(cover[500], 1)
        let title = try samples(result, object: "Title", field: "text")
        XCTAssertEqual(title[10] as? String, "", "no media yet")
        XCTAssertEqual(title[300] as? String, "Replay Song")
        XCTAssertEqual(title[400] as? String, "Second Song")
        XCTAssertEqual(title[550] as? String, "Third Song")

        // thisObject.getAnimation() on a material constant is the constant's timeline.
        let multiply = try samples(result, object: "Cover", field: "effects.0.passes.0.constantshadervalues.multiply")
        XCTAssertEqual(multiply.last.flatMap(number), 30)

        // Cursor: only Solid objects get clicks (§1.9 P7). From frame 300 the cursor clicks each
        // Solid layer with scripts in turn, four frames each.
        let button = try samples(result, object: "Button", field: "origin").map(vector)
        XCTAssertEqual(button[299].first, 0)
        XCTAssertEqual(button[360].first, 1)
        XCTAssertEqual(button[599].first, 2)
        let decoration = try samples(result, object: "Decoration", field: "origin").map(vector)
        XCTAssertEqual(decoration[599].first, 0)

        // `update(value)` receives the last applied value, so accumulators work (§1.9 P2).
        let fader = try samples(result, object: "Fader", field: "alpha").compactMap(number)
        XCTAssertEqual(fader[599], 10, accuracy: 0.01)

        // A scene-level script drives `thisScene.bloomstrength`.
        let bloom = try XCTUnwrap(result.sites.first { $0.site.field == "general.bloomstrength" }).samples.compactMap(number)
        XCTAssertEqual(bloom.count, 600)
        XCTAssertGreaterThan(Set(bloom).count, 100)

        // createLayer from the wallpaper's own asset.
        XCTAssertEqual(result.createdLayers, 1)
        XCTAssertEqual(try samples(result, object: "Spawner", field: "visible").last.flatMap(number), 1)

        // scriptproperties from the site, user properties at load and on change.
        let flagged = try samples(result, object: "Flagged", field: "visible").compactMap(number)
        XCTAssertEqual(flagged[400], 0)
        XCTAssertEqual(flagged[450], 1)
        XCTAssertEqual(flagged[560], 0)
    }

    func testReplayIsDeterministic() throws {
        let (_, first, _) = try replay("behaviour")
        let (_, second, _) = try replay("behaviour")
        for (a, b) in zip(first.sites, second.sites) {
            XCTAssertEqual(a.samples.map { "\($0)" }, b.samples.map { "\($0)" }, a.id)
        }
    }

    // MARK: - Failures

    func testFailuresFixtureIsReportedAndMatchesItsExpectations() throws {
        _ = try Fixtures.assets()
        let (wallpaper, result, findings) = try replay("failures")
        let hashes = Dictionary(uniqueKeysWithValues: wallpaper.sites.map {
            (wallpaper.objects[$0.objectIndex ?? 0].name, $0.hash)
        })
        let broken = try XCTUnwrap(hashes["Broken"])
        let thrower = try XCTUnwrap(hashes["Thrower"])
        let label = try XCTUnwrap(hashes["Label"])
        let lost = try XCTUnwrap(hashes["Lost"])

        XCTAssertTrue(findings.contains { $0.check == .exception && $0.key == broken && $0.message.contains("compile") })
        let thrown = try XCTUnwrap(findings.first { $0.check == .exception && $0.key == thrower })
        XCTAssertTrue(thrown.message.contains("update line 5"), thrown.message)
        XCTAssertTrue(thrown.message.contains("frame 9"), thrown.message)
        XCTAssertTrue(findings.contains { $0.check == .text && $0.key == label && $0.message.contains("Now: undefined") })
        XCTAssertTrue(findings.contains { $0.check == .finite && $0.key == lost })

        // §1.9 P4: the callback that threw is never called again; the script's others keep running.
        XCTAssertEqual(result.sharedNumbers["updateCalls"], 9)
        XCTAssertEqual(result.sharedNumbers["playbackEvents"], 4, "playing, paused, stopped, playing")

        let expected = [
            SceneScriptCorpusReplayTests.ExpectedFailure(key: broken, check: .exception, reason: "fixture: compile error"),
            SceneScriptCorpusReplayTests.ExpectedFailure(key: thrower, check: .exception, reason: "fixture: throws once"),
            SceneScriptCorpusReplayTests.ExpectedFailure(key: label, check: .text, reason: "fixture: undefined in text"),
            SceneScriptCorpusReplayTests.ExpectedFailure(key: lost, check: .finite, reason: "fixture: NaN origin"),
        ]
        SceneScriptCorpusReplayTests.assert(findings, expected: expected, scope: Set(hashes.values), label: "failures")
    }

    func testWatchdogTripIsReported() throws {
        let probe = try XCTUnwrap(JSContext())
        try XCTSkipIf(SceneScriptWatchdog(context: probe) == nil, "JavaScriptCore has no execution time limit here")
        var options = SceneScriptReplayHarness.Options()
        options.configuration.frameTimeLimit = 0.3
        let (wallpaper, result, findings) = try replay("watchdog", options: options)
        let hang = try XCTUnwrap(wallpaper.sites.first { wallpaper.objects[$0.objectIndex ?? 0].name == "Hang" }).hash
        XCTAssertTrue(result.halted)
        XCTAssertLessThan(result.frameMilliseconds.count, options.frames)
        XCTAssertTrue(findings.contains { $0.check == .watchdog && $0.key == hang }, "\(findings)")
    }

    // MARK: - Helpers

    private static func clockText(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d %d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, parts.year ?? 0)
    }
}
