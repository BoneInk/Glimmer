import XCTest
@testable import OWESceneEditing

/// A text layer's text, its script (a clock) and the script's options.
@MainActor
final class TextLayerEditTests: XCTestCase {
    private var session: SceneEditSession!

    override func setUp() async throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        session = SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData), undoManager: undoManager)
    }

    private func text(of id: Int) throws -> Any? {
        try Fixtures.object(id, in: try session.overlay.applied(to: Fixtures.sceneData))["text"]
    }

    func testTypingInAScriptedLayerSetsWhereTheScriptStarts() throws {
        XCTAssertEqual(session.textContent(of: 11), "12:00")
        XCTAssertNotNil(session.textScript(of: 11))
        session.setText("09:30", of: 11, actionName: "Change Text")
        let field = try XCTUnwrap(try text(of: 11) as? [String: Any])
        XCTAssertEqual(field["value"] as? String, "09:30")
        XCTAssertNotNil(field["script"], "the script keeps writing it")
        XCTAssertEqual(session.textContent(of: 11), "09:30")
    }

    func testANewTextLayerGetsAClockAndLosesIt() throws {
        let id = session.addLayer(SceneLayerFactory.text(name: "T", value: "Hello", font: "systemfont_arial", pointSize: 32,
                                                         origin: SIMD2(10, 10)), actionName: "Add Text Layer")
        session.setText("Hi there", of: id, actionName: "Change Text")
        XCTAssertEqual(session.textContent(of: id), "Hi there")
        session.setTextScript(.clock, of: id, actionName: "Change Text Script")
        XCTAssertEqual(SceneLayerFactory.TextScript(source: session.textScript(of: id)), .clock)
        XCTAssertEqual(session.textScriptProperties(of: id)["use24hFormat"], .bool(true))
        session.setTextScriptProperty("showSeconds", to: .bool(true), of: id, actionName: "Change Text Script")
        let objects = try JSONSerialization.jsonObject(with: try session.overlay.applied(to: Fixtures.sceneData)) as? [String: Any]
        let added = try XCTUnwrap((objects?["objects"] as? [[String: Any]])?.first { ($0["id"] as? NSNumber)?.intValue == id })
        let field = try XCTUnwrap(added["text"] as? [String: Any])
        XCTAssertTrue((field["script"] as? String)?.contains("export function update") == true)
        XCTAssertEqual((field["scriptproperties"] as? [String: Any])?["showSeconds"] as? Bool, true)
        session.setTextScript(nil, of: id, actionName: "Change Text Script")
        XCTAssertNil(session.textScript(of: id))
        let plain = try JSONSerialization.jsonObject(with: try session.overlay.applied(to: Fixtures.sceneData)) as? [String: Any]
        let object = try XCTUnwrap((plain?["objects"] as? [[String: Any]])?.first { ($0["id"] as? NSNumber)?.intValue == id })
        let withoutScript = try XCTUnwrap(object["text"] as? [String: Any])
        XCTAssertNil(withoutScript["script"], "a null script is taken away")
        XCTAssertEqual(withoutScript["value"] as? String, SceneLayerFactory.TextScript.clock.placeholder)
    }

    func testFontSizeAndAlignmentAreFieldEdits() throws {
        session.setValue(.number(48), for: "pointsize", of: 11, actionName: "Change Text Size")
        session.setValue(.string("left"), for: "horizontalalign", of: 11, actionName: "Change Alignment")
        session.setValue(.string("fonts/editor/face-1.ttf"), for: "font", of: 11, actionName: "Change Font")
        let object = try Fixtures.object(11, in: try session.overlay.applied(to: Fixtures.sceneData))
        XCTAssertEqual((object["pointsize"] as? NSNumber)?.doubleValue, 48)
        XCTAssertEqual(object["horizontalalign"] as? String, "left")
        XCTAssertEqual(object["font"] as? String, "fonts/editor/face-1.ttf")
        XCTAssertGreaterThan(try XCTUnwrap(session.geometry(of: 11)).size.y, 56, "the canvas's box follows the size")
    }
}
