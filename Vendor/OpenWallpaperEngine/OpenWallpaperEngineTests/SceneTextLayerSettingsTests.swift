import XCTest
@testable import OpenWallpaperEngine

/// A text layer's Font and Size start at the layer's own, which aren't kept as the user's: a
/// stored copy would override the Wallpaper Editor's Font and Size.
final class SceneTextLayerSettingsTests: XCTestCase {
    private func scene(font: String, size: Int) throws -> WEScene {
        let json = #"{"camera": {}, "general": {}, "objects": [{"id": 7, "name": "clock", "text": {"value": "12:00"}, "font": "FONT", "pointsize": SIZE}]}"#
            .replacingOccurrences(of: "FONT", with: font)
            .replacingOccurrences(of: "SIZE", with: String(size))
        return try decodeTolerant(WEScene.self, from: Data(json.utf8))
    }

    func testTheLayerValuesAreItsFontAndSize() throws {
        XCTAssertEqual(SceneTextLayerSettings.layerValues(in: try scene(font: "a.ttf", size: 20)),
                       ["_owe_text_7_font": "a.ttf", "_owe_text_7_size": "20.0"])
    }

    func testStoredCopiesOfTheLayerValuesAreDropped() throws {
        let authored = SceneTextLayerSettings.layerValues(in: try scene(font: "a.ttf", size: 20))
        let edited = SceneTextLayerSettings.layerValues(in: try scene(font: "b.ttf", size: 40))
        // An earlier version stored the authored font and size; the editor has since changed them.
        let stored = ["_owe_text_7_font": "a.ttf", "_owe_text_7_size": "20", "_owe_text_7_bold": "true", "speed": "2"]
        let kept = SceneTextLayerSettings.removingLayerValues(from: stored, matching: [edited, authored])
        XCTAssertEqual(kept, ["_owe_text_7_bold": "true", "speed": "2"])
        // With them gone, the running values follow the edited layer.
        let values = SceneContentLoader.userPropertyValues(stored: kept, declared: [:], scene: try scene(font: "b.ttf", size: 40))
        XCTAssertEqual(values["_owe_text_7_font"], "b.ttf")
        XCTAssertEqual(values["_owe_text_7_size"], "40.0")
    }

    func testTheUsersOwnFontAndSizeAreKept() throws {
        let authored = SceneTextLayerSettings.layerValues(in: try scene(font: "a.ttf", size: 20))
        let stored = ["_owe_text_7_font": "c.ttf", "_owe_text_7_size": "64"]
        XCTAssertEqual(SceneTextLayerSettings.removingLayerValues(from: stored, matching: [authored]), stored)
    }

    func testOnlyFontAndSizeAreLayerSettings() {
        XCTAssertTrue(SceneTextLayerSettings.isLayerSetting("_owe_text_7_font"))
        XCTAssertTrue(SceneTextLayerSettings.isLayerSetting("_owe_text_7_size"))
        XCTAssertFalse(SceneTextLayerSettings.isLayerSetting("_owe_text_7_color"))
        XCTAssertFalse(SceneTextLayerSettings.isLayerSetting("font"))
    }
}
