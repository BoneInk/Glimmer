import XCTest
@testable import OpenWallpaperEngine

/// Scripts' writes to a text layer's `font`, `anchor`, `padding`, `maxwidth` / `limitwidth` and
/// `maxrows` / `limitrows` reach the drawn layout (`SceneMetalText.scripted(by:)`), and a bound
/// layout field keeps its authored value (`{"script": …, "value": 1200}`).
final class SceneTextScriptLayoutTests: XCTestCase {
    private var storage: URL!

    override func setUpWithError() throws {
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-text-layout-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let storage, FileManager.default.fileExists(atPath: storage.path) { try FileManager.default.removeItem(at: storage) }
    }

    private func authored(maxWidth: Float? = nil, maxRows: Int? = nil) -> SceneMetalText {
        var text = SceneMetalText(value: "Song", font: "fonts/a.ttf", pointSize: 32, horizontalAlignment: "right",
                                  verticalAlignment: "top", padding: SIMD2(repeating: 32), maxWidth: maxWidth,
                                  maxRows: maxRows, useEllipsis: false, anchor: "none", blockAlign: false)
        text.maxWidthValue = maxWidth ?? 500
        text.maxRowsValue = maxRows ?? 1
        return text
    }

    private func state(_ writes: [(SceneScriptObjectField, [Float])],
                       strings: [SceneScriptStringField: String] = [:]) -> SceneScriptObjectState {
        var state = SceneScriptObjectState(values: [Float](repeating: 0, count: SceneScriptObjectTable.Layout.stride))
        for (field, value) in writes {
            state.owned.insert(field)
            for (index, component) in value.enumerated() { state.values[field.offset + index] = component }
        }
        state.strings = strings
        return state
    }

    func testScriptWritesReplaceTheLayoutFields() {
        let text = authored().scripted(by: state([(.padding, [4]), (.limitwidth, [1]), (.maxwidth, [640]),
                                                  (.limitrows, [1]), (.maxrows, [2])],
                                                 strings: [.font: "fonts/b.ttf", .anchor: "topright"]))
        XCTAssertEqual(text.padding, SIMD2<Float>(4, 4), "padding is one number, for both axes")
        XCTAssertEqual(text.maxWidth, 640)
        XCTAssertEqual(text.maxRows, 2)
        XCTAssertEqual(text.font, "fonts/b.ttf")
        XCTAssertEqual(text.anchor, "topright")
        XCTAssertEqual(text.horizontalAlignment, "right", "not written: authored")
    }

    func testTurningALimitOnUsesTheAuthoredValueAndOffDropsIt() {
        let on = authored().scripted(by: state([(.limitwidth, [1]), (.limitrows, [1])]))
        XCTAssertEqual(on.maxWidth, 500, "the authored maxwidth, kept while limitwidth was off")
        XCTAssertEqual(on.maxRows, 1)
        let off = authored(maxWidth: 300, maxRows: 3).scripted(by: state([(.limitwidth, [0]), (.limitrows, [0])]))
        XCTAssertNil(off.maxWidth)
        XCTAssertNil(off.maxRows)
        let width = authored(maxWidth: 300).scripted(by: state([(.maxwidth, [120])]))
        XCTAssertEqual(width.maxWidth, 120, "a bound maxwidth with limitwidth authored on")
        XCTAssertNil(authored().scripted(by: state([(.maxwidth, [120])])).maxWidth, "limitwidth stays off")
    }

    func testLayoutKeyChangesWithEveryLayoutField() {
        let base = authored(maxWidth: 300)
        var keys: Set<String> = [base.layoutKey]
        for change in [{ (t: inout SceneMetalText) in t.font = "x" }, { $0.padding = .zero }, { $0.maxWidth = 301 },
                       { $0.maxRows = 4 }, { $0.useEllipsis = true }, { $0.blockAlign = true },
                       { $0.horizontalAlignment = "left" }, { $0.verticalAlignment = "bottom" }] {
            var text = base
            change(&text)
            keys.insert(text.layoutKey)
        }
        XCTAssertEqual(keys.count, 9)
    }

    func testBoundLayoutFieldsKeepTheirAuthoredValues() throws {
        let json = #"""
            {"id": 7, "name": "Artist Name", "text": "Artist", "limitwidth": true, "limitrows": {"user": "rows", "value": true},
             "maxwidth": {"script": "export function update(value) { return value; }", "value": 1200.0},
             "maxrows": {"user": "count", "value": 2}, "padding": {"user": "pad", "value": "0.00000 0.00000"},
             "font": {"user": "font", "value": "fonts/a.ttf"}, "anchor": "center"}
            """#
        let object = try JSONDecoder().decode(WESceneObject.self, from: Data(json.utf8))
        XCTAssertEqual(object.maxwidth, 1200)
        XCTAssertEqual(object.maxrows, 2)
        XCTAssertEqual(object.limitrows, true)
        XCTAssertEqual(object.padding, "0.00000 0.00000")
        XCTAssertEqual(object.font, "fonts/a.ttf")
        XCTAssertEqual(object.anchor, "center")
        let plain = try JSONDecoder().decode(WESceneObject.self, from: Data(#"{"id": 1, "text": "a", "padding": 8, "maxwidth": 90}"#.utf8))
        XCTAssertEqual(plain.padding, "8")
        XCTAssertEqual(plain.maxwidth, 90)
    }

    /// 3238423642 "Katana Girl" (Everyone) binds a script to `maxwidth` on its "Artist Name" and
    /// "Song Title" layers (limitwidth on, authored 1200): the decoded layer keeps 1200 and the
    /// scripts' value is what the text wraps at.
    func testKatanaGirlMaxWidthScriptsReachTheLayout() throws {
        let folder = URL(fileURLWithPath: "/Volumes/980Pro/OpenWallpaperStorage/3238423642")
        let sceneURL = folder.appending(path: "scene.json")
        guard FileManager.default.fileExists(atPath: sceneURL.path) else { throw XCTSkip("no local copy of 3238423642") }
        let data = try Data(contentsOf: sceneURL)
        let scene = try JSONDecoder().decode(WEScene.self, from: data)
        // The scene has a second "Song Title" (another widget's, without the script).
        let layers = scene.objects.filter {
            ($0.name == "Artist Name" || $0.name == "Song Title") && $0.maxwidth == 1200 && $0.limitwidth == true
        }
        XCTAssertEqual(layers.count, 2)

        let document = try SceneScriptSiteBuilder.document(from: data)
        let content = SceneScriptSceneContent(wallpaperID: "katana-\(UUID().uuidString.prefix(8))", document: document,
                                              documentSignature: "1", project: nil, userValues: { [:] },
                                              file: { _ in nil }, makeLayer: { _ in nil })
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                                           media: SceneScriptReplayMediaSource(), spectrum: { .silent })
        let wallpaper = try XCTUnwrap(try SceneScriptWallpaper(content: content, services: services, screenID: "test"))
        addTeardownBlock { wallpaper.tearDown(); wallpaper.waitUntilIdle() }
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 30
        var state: SceneScriptFrameState?
        for _ in 0..<2 {
            wallpaper.submit(input)
            wallpaper.waitUntilIdle()
            state = wallpaper.take().state ?? state
        }
        let frame = try XCTUnwrap(state)
        for layer in layers {
            let id = try XCTUnwrap(layer.id)
            let object = try XCTUnwrap(frame.objects[id], "\(layer.name ?? "")'s script ran")
            let width = try XCTUnwrap(object.scalar(.maxwidth), "the script owns maxwidth")
            XCTAssertTrue(width.isFinite)
            XCTAssertNotEqual(width, 1200, "the script's value, not the authored one")
            var text = authored(maxWidth: 1200)
            text.maxWidthValue = 1200
            XCTAssertEqual(text.scripted(by: object).maxWidth, width)
        }
    }
}
