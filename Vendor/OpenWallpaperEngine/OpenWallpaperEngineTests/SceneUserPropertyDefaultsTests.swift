import XCTest
@testable import OpenWallpaperEngine

final class SceneUserPropertyDefaultsTests: XCTestCase {
    private let variants = """
    {"camera":{},"general":{"orthogonalprojection":{"width":100,"height":100}},"objects":[
      {"id":1,"image":"models/a.json","visible":{"user":{"name":"variant","condition":"a"},"value":true}},
      {"id":2,"image":"models/b.json","visible":{"user":{"name":"variant","condition":"b"},"value":false}}
    ]}
    """

    /// WE shows exactly what the properties say: a value that selects no variant isn't replaced.
    func testNoVariantIsForcedVisible() throws {
        let scene = try JSONDecoder().decode(WEScene.self, from: Data(variants.utf8))
        let declared: [String: [String: Any]] = ["variant": ["type": "combo", "value": "none"]]
        XCTAssertEqual(SceneContentLoader.userPropertyValues(stored: [:], declared: declared, scene: scene),
                       ["variant": "none"])
        XCTAssertEqual(SceneContentLoader.userPropertyValues(stored: [:], declared: [:], scene: scene), [:])
    }

    func testStoredValuesWinAndComboFallsBackToFirstOption() throws {
        let scene = try JSONDecoder().decode(WEScene.self, from: Data(variants.utf8))
        let declared: [String: [String: Any]] = [
            "variant": ["type": "combo", "options": [["value": "b"], ["value": "a"]]],
            "speed": ["type": "slider", "value": 0.5]
        ]
        XCTAssertEqual(SceneContentLoader.userPropertyValues(stored: ["speed": "2"], declared: declared, scene: scene),
                       ["variant": "b", "speed": "2"])
    }
}
