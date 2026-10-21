import XCTest
@testable import OpenWallpaperEngine

/// A layer is an alternative version when its `visible` is bound to a combo user property with a
/// condition, not because of its name.
final class SceneLayerVersionTests: XCTestCase {
    private let definitions: [String: UserPropertyDefinition] = [
        "style": UserPropertyDefinition(key: "style", raw: [
            "type": "combo", "text": "Style",
            "options": [["label": "Day", "value": "1"], ["label": "<b>Night</b>", "value": "2"]],
        ]),
        "rain": UserPropertyDefinition(key: "rain", raw: ["type": "bool", "text": "Rain", "value": true]),
    ]

    private func object(_ json: String) throws -> WESceneObject {
        try JSONDecoder().decode(WESceneObject.self, from: Data(json.utf8))
    }

    func testVisibleBoundToAComboWithAConditionIsAVersion() throws {
        let night = try XCTUnwrap(SceneLayerVersion(object: object(
            #"{"name":"background","visible":{"user":{"name":"style","condition":"2"},"value":false}}"#),
            definitions: definitions))
        XCTAssertEqual(night.property, "style")
        XCTAssertEqual(night.value, "2")
        XCTAssertEqual(night.title(labels: WallpaperEngineLabels()), "Night")
        let unlisted = try XCTUnwrap(SceneLayerVersion(object: object(
            #"{"name":"x","visible":{"user":{"name":"style","condition":"7"},"value":true}}"#), definitions: definitions))
        XCTAssertEqual(unlisted.label, "7", "a value no option has shows as itself")
    }

    func testNamesAndOtherBindingsAreNotVersions() throws {
        XCTAssertNil(SceneLayerVersion(object: try object(#"{"name":"background_2","visible":true}"#), definitions: definitions),
                     "a _N suffix says nothing")
        XCTAssertNil(SceneLayerVersion(object: try object(#"{"name":"drops","visible":{"user":"rain","value":true}}"#),
                                       definitions: definitions), "a bool binding is a toggle")
        XCTAssertNil(SceneLayerVersion(object: try object(
            #"{"name":"x","visible":{"user":{"name":"version","condition":"1"},"value":true}}"#), definitions: definitions),
                     "a property the project doesn't declare")
    }
}
