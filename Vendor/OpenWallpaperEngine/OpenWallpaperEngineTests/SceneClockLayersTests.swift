import XCTest
@testable import OpenWallpaperEngine

final class SceneClockLayersTests: XCTestCase {
    func testScriptsThatReadTheDateAreClocks() {
        for source in ["var d = new Date(); return d.getHours();", "return Date.now()",
                       "let t = new Date();", "x.getUTCMinutes()", "return d.toLocaleTimeString()"] {
            XCTAssertTrue(SceneClockLayers.readsDate(source), source)
        }
        for source in ["return engine.runtime * 2;", "return value.toUpperCase();", "var updated = 1;"] {
            XCTAssertFalse(SceneClockLayers.readsDate(source), source)
        }
    }

    func testFindsTheTextLayersWhoseScriptReadsTheDate() throws {
        let json = #"""
        {"objects": [
          {"id": 5, "text": {"value": "", "script": "export function update() { return new Date().getHours(); }"}},
          {"id": 6, "text": {"value": "", "script": "export function update(v) { return v; }"}},
          {"id": 7, "text": "static"},
          {"id": 8, "image": "a.json", "visible": {"value": true, "script": "return new Date().getHours() > 6;"}}
        ]}
        """#
        let document = try JSONDecoder().decode(SceneJSON.self, from: Data(json.utf8))
        XCTAssertEqual(SceneClockLayers.ids(in: document), ["5"])
    }

    /// A still leaves out every text layer and the clock hands (a rotation script that reads the
    /// date); other date-reading scripts (tints, fades, day and night backgrounds) stay.
    func testAStillLeavesOutTheTextLayersAndTheClockHands() throws {
        let json = #"""
        {"objects": [
          {"id": 5, "text": {"value": "", "script": "export function update() { return new Date().getHours(); }"}},
          {"id": 6, "text": {"value": "Title"}},
          {"id": 7, "image": "hand.json", "angles": {"value": "0 0 0", "script": "export function update(v) { v.z = new Date().getMinutes() * 6; return v; }"}},
          {"id": 8, "image": "a.json", "visible": {"value": true, "script": "return new Date().getHours() > 6;"}},
          {"id": 9, "image": "b.json", "color": {"value": "1 1 1", "script": "return Date.now() % 2;"}},
          {"id": 10, "image": "c.json", "angles": {"value": "0 0 0", "script": "export function update(v) { v.z += 1; return v; }"}}
        ]}
        """#
        let document = try JSONDecoder().decode(SceneJSON.self, from: Data(json.utf8))
        XCTAssertEqual(SceneClockLayers.stillIDs(in: document), ["5", "6", "7"])
    }
}
