import XCTest
@testable import OWESceneEditing

/// A custom effect's material options (WE's Blending, Culling, Depth test, Depth write): read
/// with WE's blank effect's values where the material sets none, written into every pass as WE
/// writes JSON, and kept in the edits as one undo step.
@MainActor
final class MaterialShaderOptionsTests: XCTestCase {
    private static let material = """
    {"passes": [{"shader": "effects/mine", "blending": "translucent", "culling": "normal", "depthtest": "enabled"}]}
    """

    func testOptionsAreReadWithWEsDefaults() throws {
        let options = try XCTUnwrap(MaterialShaderOptions(material: Self.material))
        XCTAssertEqual(options.blending, .translucent)
        XCTAssertEqual(options.culling, .normal, "the older culling key")
        XCTAssertTrue(options.depthTest)
        XCTAssertFalse(options.depthWrite)
        XCTAssertFalse(options.depthWriteApplies, "translucent drawing writes no depth")
        let blank = try XCTUnwrap(MaterialShaderOptions(material: #"{"passes": [{"shader": "x"}]}"#))
        XCTAssertEqual(blank, MaterialShaderOptions())
        XCTAssertNil(MaterialShaderOptions(material: "not a material"))
    }

    func testOptionsAreWrittenIntoEveryPass() throws {
        var options = try XCTUnwrap(MaterialShaderOptions(material: Self.material))
        options.blending = .normal
        options.depthWrite = true
        XCTAssertTrue(options.depthWriteApplies)
        let written = try XCTUnwrap(options.applied(to: Self.material))
        XCTAssertEqual(written, """
        {
        \t"passes" :\u{20}
        \t[
        \t\t{
        \t\t\t"blending" : "normal",
        \t\t\t"cullmode" : "normal",
        \t\t\t"depthtest" : "enabled",
        \t\t\t"depthwrite" : "enabled",
        \t\t\t"shader" : "effects/mine"
        \t\t}
        \t]
        }
        """)
    }

    func testAChangeIsOneUndoStep() throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let session = SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData), undoManager: undoManager)
        let path = "effects/mine/materials/effects/mine.json"
        var options = try XCTUnwrap(MaterialShaderOptions(material: Self.material))
        options.blending = .additive
        session.setMaterialOptions(options, material: path, text: Self.material, actionName: "Change Shader Option")
        XCTAssertEqual(MaterialShaderOptions(material: try XCTUnwrap(session.overlay.effectFile(path)))?.blending, .additive)
        session.undo()
        XCTAssertNil(session.overlay.effectFiles)
    }
}
