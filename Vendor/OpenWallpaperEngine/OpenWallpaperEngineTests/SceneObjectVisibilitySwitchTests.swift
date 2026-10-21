import XCTest
import OWESceneEditing
@testable import OpenWallpaperEngine

/// Switching off an object whose `visible` a user property sets, in Scene Edit / Export's store
/// and in the Wallpaper Editor's overlay: hidden whatever the property says, and handed back to the
/// property when shown again, as the renderer resolves it.
final class SceneObjectVisibilitySwitchTests: XCTestCase {
    private static let objectsJSON = #"""
    [{"id": 1, "visible": {"user": {"name": "clocklocation", "condition": "1"}, "value": true}},
     {"id": 2, "visible": {"user": {"name": "clocklocation", "condition": "2"}, "value": false}},
     {"id": 3, "visible": false}]
    """#

    private func visibility(_ values: [String: String], objects json: String = objectsJSON) throws -> [String: Bool] {
        let objects = try JSONDecoder().decode([WESceneObject].self, from: Data(json.utf8))
        return SceneUserVisibility(objects: objects).resolve { values[$0] }.objects
    }

    func testTheSwitchHidesABoundObjectAndShowingHandsItBack() throws {
        let bound = SceneObjectVisibilitySwitch(objectID: 2, property: "clocklocation", authored: false)
        var values = ["clocklocation": "2"]
        XCTAssertTrue(bound.isOn(values), "on while the property decides, whatever its authored value")
        XCTAssertEqual(try visibility(values)["2"], true)

        values = bound.values(values, settingOn: false)
        XCTAssertEqual(values[bound.key], "false")
        XCTAssertFalse(bound.isOn(values))
        XCTAssertFalse(bound.isShown(values))
        XCTAssertEqual(try visibility(values)["2"], false, "hidden whatever the property says")

        values = bound.values(values, settingOn: true)
        XCTAssertNil(values[bound.key], "showing it drops the override")
        XCTAssertTrue(bound.isOn(values))
        XCTAssertEqual(try visibility(values)["2"], true, "the property shows it again")
        values["clocklocation"] = "1"
        XCTAssertEqual(try visibility(values)["2"], false, "and hides it again")
    }

    func testAnUnboundObjectStoresItsValue() throws {
        let plain = SceneObjectVisibilitySwitch(objectID: 3, property: nil, authored: false)
        XCTAssertFalse(plain.isOn([:]))
        let values = plain.values([:], settingOn: true)
        XCTAssertEqual(values[plain.key], "true")
        XCTAssertTrue(plain.isOn(values))
        XCTAssertEqual(try visibility(values)["3"], true)
    }

    /// The Wallpaper Editor's override, applied to scene.json as the desktop and both previews load
    /// it, hides the object for every value of its property.
    func testTheWallpaperEditorsOverrideHidesItForTheRenderer() throws {
        var overlay = SceneEditOverlay()
        overlay.setField("visible", to: .bool(false), of: 1)
        let scene = Data(#"{"objects": \#(Self.objectsJSON)}"#.utf8)
        let applied = try JSONSerialization.jsonObject(with: try overlay.applied(to: scene)) as! [String: Any]
        let objects = String(decoding: try JSONSerialization.data(withJSONObject: applied["objects"]!), as: UTF8.self)
        for option in ["1", "2"] {
            XCTAssertEqual(try visibility(["clocklocation": option], objects: objects)["1"], false)
        }
        XCTAssertEqual(try visibility(["clocklocation": "2"], objects: objects)["2"], true, "the others still follow it")
    }
}
