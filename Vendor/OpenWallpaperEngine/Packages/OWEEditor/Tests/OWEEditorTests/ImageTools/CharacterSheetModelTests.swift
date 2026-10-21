import SwiftUI
import XCTest
@testable import OWEEditor
@testable import OWESceneEditing

/// Character Sheet Creation's hierarchy: limbs added under the selected one, removed with their
/// children moving up, and WE's tree lines.
@MainActor
final class CharacterSheetModelTests: XCTestCase {
    private func model() throws -> CharacterSheetModel {
        let scene = Data(#"{"general":{"orthogonalprojection":{"width":100,"height":100}},"objects":[{"id":1,"name":"Hero","image":"models/h.json","size":"8 8"}]}"#.utf8)
        let session = SceneEditSession(outline: try SceneOutline(sceneData: scene))
        var services = WallpaperEditorServices(makeCanvas: { AnyView(EmptyView()) }, blendModeTitle: "", blendModes: [],
                                               effectHelp: { _ in "" }, suggestedNewTitle: "", saveAsNewWallpaper: { $0 })
        let files = ["models/h.json": Data(#"{"material":"materials/h.json"}"#.utf8),
                     "materials/h.json": Data(#"{"passes":[{"textures":["h"]}]}"#.utf8)]
        services.readFile = { files[$0] }
        let picture = try XCTUnwrap(RGBAImage(width: 8, height: 8).cgImage)
        services.texture = { _ in picture }
        return CharacterSheetModel(session: session, layerID: 1, services: services, bodyName: "Body")
    }

    func testLimbsGoUnderTheSelectedOne() throws {
        let model = try model()
        model.addLimb(named: "Arm")
        model.addLimb(named: "Sword")
        model.selection = model.limbs[0].id
        model.addLimb(named: "Shield")
        model.selection = model.limbs[0].id
        model.addLimb(named: " ")
        XCTAssertEqual(model.limbs.map(\.name), ["Body", "Arm", "Sword", "Shield", "limb"])
        XCTAssertEqual(model.limbs.map(\.depth), [0, 1, 2, 1, 1])
        XCTAssertEqual((0..<5).map(model.treePrefix), ["", "├", "│└", "├", "└"])
        XCTAssertFalse(model.canFinish, "nothing separated yet")

        model.removeLimb(model.limbs[1].id)
        XCTAssertEqual(model.limbs.map(\.name), ["Body", "Sword", "Shield", "limb"])
        XCTAssertEqual(model.limbs.map(\.depth), [0, 1, 1, 1], "the Sword moves up under the Body")
        XCTAssertEqual(model.selection, model.limbs[0].id, "the removed limb's parent is selected")
        model.removeLimb(model.limbs[0].id)
        XCTAssertEqual(model.limbs.count, 4, "the Body always exists")
    }
}
