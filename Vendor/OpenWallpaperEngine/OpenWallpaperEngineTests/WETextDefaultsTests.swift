import XCTest
import AppKit
@testable import OpenWallpaperEngine

/// A text object's fields that scene.json leaves out take `wallpaper64.exe`'s constructor values
/// (`WETextDefaults`), in the renderer and in the scripts' object model.
final class WETextDefaultsTests: XCTestCase {
    private func textLayers() throws -> [String: SceneMetalText] {
        let directory = Fixtures.url("Scenes/text-defaults")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/text-defaults/project.json"))
        let wallpaper = WEWallpaper(using: project, where: directory)
        addTeardownBlock { Fixtures.removeStoredSettings(for: directory) }
        let content = try XCTUnwrap(SceneContentLoader(wallpaper: wallpaper).metalContent())
        return Dictionary(uniqueKeysWithValues: content.layers.compactMap { layer in layer.text.map { (layer.id, $0) } })
    }

    /// Absent: point size 32, padding 32, max width 500 and max rows 1 once limited; centred.
    func testAbsentFieldsTakeWEsConstructorValues() throws {
        let bare = try XCTUnwrap(try textLayers()["1"])
        XCTAssertEqual(bare.pointSize, 32)
        XCTAssertEqual(bare.padding, SIMD2(32, 32))
        XCTAssertEqual(bare.maxWidth, 500)
        XCTAssertEqual(bare.maxRows, 1)
        XCTAssertNil(bare.horizontalAlignment)
        XCTAssertNil(bare.verticalAlignment)
        let font = NSFont.systemFont(ofSize: 40)
        func origins(_ alignment: String?) -> [CGPoint] {
            SceneTextLayout(text: "Ab\nc", font: font, padding: SIMD2(32, 32), horizontalAlignment: alignment,
                            verticalAlignment: alignment, maxWidth: nil, maxRows: nil, useEllipsis: false).baselineOrigins()
        }
        XCTAssertEqual(origins(nil), origins(WETextDefaults.alignment))
    }

    /// Authored fields win.
    func testAuthoredFieldsWin() throws {
        let authored = try XCTUnwrap(try textLayers()["2"])
        XCTAssertEqual(authored.pointSize, 20)
        XCTAssertEqual(authored.padding, SIMD2(8, 8))
        XCTAssertEqual(authored.maxWidth, 301.5)
        XCTAssertEqual(authored.maxRows, 2)
    }

    /// Scripts read the same values for a text object that leaves them out.
    func testScriptsSeeWEsTextDefaults() throws {
        let describer = SceneScriptSceneDescriber(
            userProperties: SceneScriptUserProperties(project: try SceneScriptSiteBuilder.document(from: Data("{}".utf8))),
            file: { _ in nil })
        let text = describer.object(["text": .object(["value": .string("hi")])], id: 1)
        XCTAssertEqual(text.kind, .text)
        XCTAssertEqual(text.values[.pointsize], [32])
        XCTAssertEqual(text.values[.padding], [32])
        XCTAssertEqual(text.values[.maxwidth], [500])
        XCTAssertEqual(text.values[.maxrows], [1])
        let sized = describer.object(["text": .object(["value": .string("hi")]), "pointsize": .number(12)], id: 2)
        XCTAssertEqual(sized.values[.pointsize], [12])
        let image = describer.object(["image": .string("models/a.json")], id: 3)
        XCTAssertNil(image.values[.pointsize], "only text objects have them")
    }
}
