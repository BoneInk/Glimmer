import XCTest
@testable import OpenWallpaperEngine

/// WE's transition settings: its keys and values, the Random pool as its toggles edit it, and the
/// transition a change picks.
final class WallpaperTransitionSettingsTests: XCTestCase {
    private func decode(_ json: String) throws -> WallpaperTransitionSettings {
        try JSONDecoder().decode(WallpaperTransitionSettings.self, from: Data(json.utf8))
    }

    func testReadsWEsValues() throws {
        let random = try decode(#"{"transition": "random", "transitionpool": ["3", "5", "99"], "transitiontime": 1500}"#)
        XCTAssertEqual(random.choice, .random)
        XCTAssertEqual(random.pool, [.horizontalSlide, .horizontalFade])
        XCTAssertEqual(random.milliseconds, 1500)
        XCTAssertEqual(try decode(#"{"transition": "18"}"#).choice, .kind(.fadeToBlack))
        XCTAssertEqual(try decode(#"{"transition": "none"}"#).choice, .none)
        // WE's dialog: `true` is a fade; no transition is "-2" over 1000 ms.
        XCTAssertEqual(try decode(#"{"transition": true}"#).choice, .kind(.fade))
        let empty = try decode("{}")
        XCTAssertEqual(empty.choice, .noneReducingFlicker)
        XCTAssertEqual(empty.milliseconds, 1000)
        XCTAssertNil(empty.pool)
    }

    func testWritesWEsValues() throws {
        let settings = WallpaperTransitionSettings(choice: .kind(.boilover), pool: [.ice], milliseconds: 2000)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        XCTAssertEqual(json["transition"] as? String, "26")
        XCTAssertEqual(json["transitionpool"] as? [String], ["25"])
        XCTAssertEqual(json["transitiontime"] as? Int, 2000)
        let all = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(WallpaperTransitionSettings.playlistDefault)) as? [String: Any])
        XCTAssertNil(all["transitionpool"], "every kind is no pool, as WE stores it")
        XCTAssertEqual(all["transition"] as? String, "0")
        XCTAssertEqual(all["transitiontime"] as? Int, 1500)
    }

    func testTheTimeSnapsToTheSlidersSteps() {
        XCTAssertEqual(WallpaperTransitionSettings.snapped(1234), 1250)
        XCTAssertEqual(WallpaperTransitionSettings.snapped(-5), 0)
        XCTAssertEqual(WallpaperTransitionSettings.snapped(9999), 3000)
    }

    func testThePoolTogglesAsWEs() {
        var settings = WallpaperTransitionSettings(choice: .random, milliseconds: 1000)
        settings.togglePool(.fade)
        XCTAssertEqual(settings.pool?.count, WallpaperTransitionKind.allCases.count - 1)
        XCTAssertFalse(settings.isInPool(.fade))
        settings.togglePool(.fade)
        XCTAssertNil(settings.pool, "adding the last missing kind is the whole pool again")
        settings.setWholePool(false)
        XCTAssertEqual(settings.pool, [])
        settings.togglePool(.zoom)
        XCTAssertEqual(settings.pool, [.zoom])
        settings.setWholePool(true)
        XCTAssertNil(settings.pool)
    }

    func testTheTransitionAChangeShows() {
        XCTAssertEqual(WallpaperTransitionSettings(choice: .kind(.door), milliseconds: 500).pick(), .door)
        XCTAssertNil(WallpaperTransitionSettings(choice: .kind(.door), milliseconds: 0).pick(), "no time, no transition")
        XCTAssertNil(WallpaperTransitionSettings(choice: .none, milliseconds: 500).pick())
        XCTAssertNil(WallpaperTransitionSettings(choice: .noneReducingFlicker, milliseconds: 500).pick())
        let random = WallpaperTransitionSettings(choice: .random, pool: [.lines, .ice], milliseconds: 500)
        XCTAssertEqual(random.pick(random: { _ in 1 }), .ice)
        XCTAssertNil(WallpaperTransitionSettings(choice: .random, pool: [], milliseconds: 500).pick())
        let everything = WallpaperTransitionSettings(choice: .random, milliseconds: 500)
        XCTAssertEqual(everything.pick(random: { $0.upperBound - 1 }), WallpaperTransitionKind.menuOrder.last)
    }

    func testEveryKindIsListedOnceInWEsOrder() {
        XCTAssertEqual(WallpaperTransitionKind.allCases.count, 27)
        XCTAssertEqual(Set(WallpaperTransitionKind.menuOrder), Set(WallpaperTransitionKind.allCases))
        XCTAssertEqual(WallpaperTransitionKind.menuOrder.count, WallpaperTransitionKind.allCases.count)
        XCTAssertEqual(WallpaperTransitionKind.menuOrder.prefix(2), [.fade, .fadeToBlack])
    }

    func testAChangeUsesTheTransitionItAsksFor() {
        let manual = WallpaperTransitionSettings(choice: .kind(.zoom), milliseconds: 500)
        let playlist = WallpaperTransitionSettings(choice: .kind(.door), milliseconds: 500)
        XCTAssertNil(WallpaperChangeTransition.none.settings(manual: manual))
        XCTAssertEqual(WallpaperChangeTransition.manual.settings(manual: manual), manual)
        XCTAssertEqual(WallpaperChangeTransition.playlist(playlist).settings(manual: manual), playlist)
    }
}
