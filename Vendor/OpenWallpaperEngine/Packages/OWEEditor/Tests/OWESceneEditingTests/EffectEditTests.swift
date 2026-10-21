import XCTest
@testable import OWESceneEditing

/// Effects added from the catalog, removed, reordered and toggled, and every kind of parameter
/// set: constants, combos, textures and masks, and constants bound to a user property. Each is
/// one undo step, kept in the overlay and written where the renderer reads it.
@MainActor
final class EffectEditTests: XCTestCase {
    private var session: SceneEditSession!

    override func setUp() async throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        session = SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData), undoManager: undoManager)
    }

    private static let shake = EffectCatalogEntry(file: "effects/shake/effect.json", title: "Shake", group: "animate", passCount: 2)

    private func effects(of id: Int) throws -> [[String: Any]] {
        let object = try Fixtures.object(id, in: try session.overlay.applied(to: Fixtures.sceneData))
        return object["effects"] as? [[String: Any]] ?? []
    }

    private func firstPass(_ effect: [String: Any]) -> [String: Any] {
        (effect["passes"] as? [[String: Any]])?.first ?? [:]
    }

    private func assertRoundTrips(file: StaticString = #filePath, line: UInt = #line) throws {
        let decoded = try SceneEditOverlay.decoded(from: try session.overlay.encoded())
        XCTAssertEqual(decoded, session.overlay, file: file, line: line)
        func parsed(_ overlay: SceneEditOverlay) throws -> NSDictionary? {
            try JSONSerialization.jsonObject(with: try overlay.applied(to: Fixtures.sceneData)) as? NSDictionary
        }
        XCTAssertEqual(try parsed(decoded), try parsed(session.overlay), file: file, line: line)
    }

    // MARK: Structure

    func testAddAnEffectToALayer() throws {
        let key = try XCTUnwrap(session.addEffect(Self.shake, to: 13, actionName: "Add Effect"))
        XCTAssertEqual(key, "+1")
        XCTAssertEqual(session.outline.layer(13)?.effects.map(\.key), ["+1"])
        XCTAssertEqual(session.outline.layer(13)?.effects.first?.title, "Shake")
        let added = try effects(of: 13)
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added[0]["file"] as? String, "effects/shake/effect.json")
        XCTAssertEqual((added[0]["passes"] as? [Any])?.count, 2, "one entry per pass, as WE writes")
        XCTAssertEqual(added[0]["visible"] as? Bool, true)
        XCTAssertNil(added[0][SceneEditOverlay.effectKeyMarker], "the outline's marker never reaches the renderer")
        let second = session.addEffect(Self.shake, to: 13, actionName: "Add Effect")
        XCTAssertEqual(second, "+2")
        try assertRoundTrips()
        session.undo(); session.undo()
        XCTAssertFalse(session.overlay.hasSceneEdits)
    }

    /// WE's Opacity effect with a mask in its slot, as Layer Opacity (Create Mask from Depth Map)
    /// adds it: the pass's `textures` name the mask at its slot, `MASK` is on, and it is one undo step.
    func testAddAnEffectWithAMaskIsOneUndoStep() throws {
        let key = try XCTUnwrap(session.addEffect(DepthMask.opacityEffect, to: 13, texture: "masks/opacity_mask_abc", slot: 1,
                                                  combo: "MASK", actionName: "Use Depth Map as Mask"))
        XCTAssertEqual(key, "+1")
        XCTAssertEqual(session.effectTexture(1, effect: key, of: 13), "masks/opacity_mask_abc")
        XCTAssertEqual(session.effectCombo("MASK", effect: key, of: 13, default: 0), 1)
        let added = try effects(of: 13)
        XCTAssertEqual(added.map { $0["file"] as? String }, ["effects/opacity/effect.json"])
        let pass = firstPass(added[0])
        let textures = try XCTUnwrap(pass["textures"] as? [Any])
        XCTAssertTrue(textures.first is NSNull, "the layer's own image, as WE writes it")
        XCTAssertEqual(textures[1] as? String, "masks/opacity_mask_abc")
        XCTAssertEqual((pass["combos"] as? [String: Any])?["MASK"] as? Int, 1)
        try assertRoundTrips()
        session.undo()
        XCTAssertFalse(session.overlay.hasSceneEdits, "the effect and its mask in one step")
        session.redo()
        XCTAssertEqual(session.effectTexture(1, effect: key, of: 13), "masks/opacity_mask_abc")
    }

    func testAddedEffectsGoAfterTheAuthoredOnes() throws {
        session.addEffect(Self.shake, to: 10, actionName: "Add Effect")
        XCTAssertEqual(session.outline.layer(10)?.effects.map(\.key), ["0", "1", "+1"])
        XCTAssertNil(session.overlay.objects["10"]?.effectOrder, "the scene's order, then the added")
        XCTAssertEqual(try effects(of: 10).map { $0["file"] as? String },
                       ["effects/waterripple/effect.json", "effects/blur/effect.json", "effects/shake/effect.json"])
    }

    func testReorderAndRemoveEffects() throws {
        session.addEffect(Self.shake, to: 10, actionName: "Add Effect")
        session.moveEffects(of: 10, from: IndexSet(integer: 2), to: 0, actionName: "Reorder Effects")
        XCTAssertEqual(session.outline.layer(10)?.effects.map(\.key), ["+1", "0", "1"])
        XCTAssertEqual(try effects(of: 10).map { $0["file"] as? String },
                       ["effects/shake/effect.json", "effects/waterripple/effect.json", "effects/blur/effect.json"])
        session.removeEffect("0", of: 10, actionName: "Remove Effect")
        XCTAssertEqual(session.outline.layer(10)?.effects.map(\.key), ["+1", "1"])
        XCTAssertEqual(try effects(of: 10).count, 2)
        try assertRoundTrips()
        session.removeEffect("+1", of: 10, actionName: "Remove Effect")
        XCTAssertNil(session.overlay.objects["10"]?.addedEffects, "a removed added effect leaves no trace")
        XCTAssertEqual(session.outline.layer(10)?.effects.map(\.key), ["1"])
        session.undo(); session.undo(); session.undo()
        XCTAssertEqual(session.outline.layer(10)?.effects.map(\.key), ["0", "1", "+1"])
    }

    func testMovingBackToTheScenesOrderIsNoEdit() {
        session.moveEffects(of: 10, from: IndexSet(integer: 1), to: 0, actionName: "Reorder")
        XCTAssertEqual(session.overlay.objects["10"]?.effectOrder, ["1", "0"])
        session.moveEffects(of: 10, from: IndexSet(integer: 1), to: 0, actionName: "Reorder")
        XCTAssertNil(session.overlay.objects["10"]?.effectOrder)
    }

    func testEditsFollowAnEffectThatMoved() throws {
        session.moveEffects(of: 10, from: IndexSet(integer: 1), to: 0, actionName: "Reorder")
        let ripple = try XCTUnwrap(session.outline.layer(10)?.effects.first { $0.key == "0" })
        session.setEffectVisible(false, effect: ripple, of: 10, actionName: "Off")
        let applied = try effects(of: 10)
        XCTAssertEqual(applied[1]["file"] as? String, "effects/waterripple/effect.json")
        XCTAssertEqual(applied[1]["visible"] as? Bool, false, "the edit is keyed by the effect, not its place")
    }

    // MARK: Values

    func testConstantEditsAreWrittenWhereTheRendererReadsThem() throws {
        session.setEffectConstant("speed", to: .number(3), effect: "0", of: 10, actionName: "Change Speed")
        session.setEffectConstant("ripplecolor", to: .string("1 0 0"), effect: "0", of: 10, defaultValue: .string("1 1 1"),
                                  actionName: "Change Color")
        let constants = try XCTUnwrap(firstPass(try effects(of: 10)[0])["constantshadervalues"] as? [String: Any])
        XCTAssertEqual((constants["Speed"] as? NSNumber)?.doubleValue, 3, "the scene's spelling of the key")
        XCTAssertEqual(constants["ripplecolor"] as? String, "1 0 0")
        XCTAssertEqual(session.effectConstantComponents("RIPPLECOLOR", effect: "0", of: 10, default: [1, 1, 1]), [1, 0, 0])
        session.setEffectConstant("ripplecolor", to: .string("1 1 1"), effect: "0", of: 10, defaultValue: .string("1 1 1"),
                                  actionName: "Change Color")
        XCTAssertNil(session.overlay.effectEdit("0", of: 10)?.constants["ripplecolor"], "the shader's default is no edit")
        session.setEffectConstant("speed", to: .number(1.5), effect: "0", of: 10, actionName: "Change Speed")
        XCTAssertFalse(session.overlay.hasSceneEdits, "the scene's own value is no edit")
    }

    func testASliderDragIsOneUndoStep() {
        for value in [0.2, 0.4, 0.6] {
            session.setEffectConstant("strength", to: .number(value), effect: "0", of: 10, actionName: "Change Strength",
                                      coalescing: true)
        }
        session.undo()
        XCTAssertFalse(session.overlay.hasSceneEdits)
    }

    func testCombosAndTextures() throws {
        session.setEffectCombo("PERSPECTIVE", to: 1, effect: "0", of: 10, defaultValue: 0, actionName: "Option")
        XCTAssertEqual(session.effectCombo("perspective", effect: "0", of: 10, default: 0), 1)
        session.setEffectTexture("masks/editor_ripple-abc", slot: 1, effect: "0", of: 10, combo: "MASK", actionName: "Paint Mask")
        let pass = firstPass(try effects(of: 10)[0])
        XCTAssertEqual((pass["combos"] as? [String: Any])?["PERSPECTIVE"] as? Int, 1)
        XCTAssertEqual((pass["combos"] as? [String: Any])?["MASK"] as? Int, 1, "a mask turns its combo on, as WE does")
        let textures = try XCTUnwrap(pass["textures"] as? [Any])
        XCTAssertTrue(textures[0] is NSNull, "the slots before it stay the shader's default")
        XCTAssertEqual(textures[1] as? String, "masks/editor_ripple-abc")
        XCTAssertEqual(session.effectTexture(1, effect: "0", of: 10), "masks/editor_ripple-abc")
        try assertRoundTrips()
        session.setEffectTexture(nil, slot: 1, effect: "0", of: 10, combo: "MASK", actionName: "Clear Mask")
        XCTAssertNil(session.overlay.effectEdit("0", of: 10)?.textures, "cleared back to the scene's (none)")
        XCTAssertNil(session.overlay.effectEdit("0", of: 10)?.combos?["MASK"])
        XCTAssertTrue(session.overlay.needsVersion2)
    }

    func testBindAConstantToAUserPropertyAndBack() throws {
        session.setEffectConstant("speed", to: .number(2), effect: "0", of: 10, actionName: "Change Speed")
        session.bindEffectConstant("speed", to: "ripplespeed", effect: "0", of: 10, actionName: "Bind to User Property")
        XCTAssertEqual(session.effectBinding("speed", effect: "0", of: 10), "ripplespeed")
        var constants = try XCTUnwrap(firstPass(try effects(of: 10)[0])["constantshadervalues"] as? [String: Any])
        let bound = try XCTUnwrap(constants["Speed"] as? [String: Any])
        XCTAssertEqual(bound["user"] as? String, "ripplespeed")
        XCTAssertEqual((bound["value"] as? NSNumber)?.doubleValue, 2, "the value it had is the binding's fallback")
        try assertRoundTrips()
        session.bindEffectConstant("speed", to: nil, effect: "0", of: 10, actionName: "Unbind Property")
        XCTAssertNil(session.effectBinding("speed", effect: "0", of: 10))
        constants = try XCTUnwrap(firstPass(try effects(of: 10)[0])["constantshadervalues"] as? [String: Any])
        XCTAssertEqual((constants["Speed"] as? NSNumber)?.doubleValue, 2)
    }

    func testAConstantTheSceneBindsCanBeSetFree() throws {
        let scene = Data(#"""
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "image": "a.json", "effects": [{"file": "effects/tint/effect.json",
            "passes": [{"constantshadervalues": {"color": {"user": "tint", "value": "1 0 0"}}}]}]}]}
        """#.utf8)
        let session = SceneEditSession(outline: try SceneOutline(sceneData: scene))
        XCTAssertEqual(session.effectBinding("color", effect: "0", of: 1), "tint")
        session.bindEffectConstant("color", to: nil, effect: "0", of: 1, actionName: "Unbind")
        XCTAssertEqual(session.overlay.effectEdit("0", of: 1)?.bindings, ["color": ""])
        let applied = try session.overlay.applied(to: scene)
        let object = try Fixtures.object(1, in: applied)
        let pass = ((object["effects"] as? [[String: Any]])?.first?["passes"] as? [[String: Any]])?.first
        XCTAssertEqual((pass?["constantshadervalues"] as? [String: Any])?["color"] as? String, "1 0 0")
        session.bindEffectConstant("color", to: "tint", effect: "0", of: 1, actionName: "Bind")
        XCTAssertNil(session.overlay.effectEdit("0", of: 1), "bound as the scene binds it: no edit")
    }

    // MARK: Catalog

    func testCatalogSearchAndGroups() {
        let entries = [
            EffectCatalogEntry(file: "effects/waterripple/effect.json", title: "Water Ripple", summary: "Adds a ripple animation.",
                               group: "animate", groupTitle: "Animate"),
            EffectCatalogEntry(file: "effects/blur/effect.json", title: "Blur", group: "blur", groupTitle: "Blur"),
            EffectCatalogEntry(file: "effects/workshop/1/glow/effect.json", title: "Glöw", group: "", groupTitle: "Workshop",
                               isWorkshop: true),
        ]
        XCTAssertEqual(EffectCatalog.filter(entries, query: "").map(\.title), ["Blur", "Glöw", "Water Ripple"])
        XCTAssertEqual(EffectCatalog.filter(entries, query: "RIPPLE anim").map(\.title), ["Water Ripple"])
        XCTAssertEqual(EffectCatalog.filter(entries, query: "glow").map(\.title), ["Glöw"], "accents ignored")
        XCTAssertEqual(EffectCatalog.filter(entries, query: "waterripple").count, 1, "the folder name matches")
        XCTAssertEqual(EffectCatalog.grouped(entries).map(\.title), ["Animate", "Blur", "Workshop"])
    }

    func testWorkshopEffectsTheSceneUsesAreOffered() throws {
        let scene = Data(#"""
        {"objects": [{"id": 1, "image": "a.json", "effects": [{"file": "effects/blur/effect.json"},
            {"file": "effects/workshop/123/glow/effect.json"}, {"file": "effects/mine/effect.json"}]},
                     {"id": 2, "image": "b.json", "effects": [{"file": "effects/workshop/123/glow/effect.json"}]}]}
        """#.utf8)
        let files = EffectCatalog.workshopEffects(in: try SceneOutline(sceneData: scene), builtIn: ["blur", "shake"])
        XCTAssertEqual(files, ["effects/workshop/123/glow/effect.json", "effects/mine/effect.json"])
    }

    func testSchemaControls() {
        XCTAssertEqual(EffectSchema.Parameter(key: "a", title: "A", defaultValue: [0], isInteger: true).control, .toggle)
        XCTAssertEqual(EffectSchema.Parameter(key: "a", title: "A", defaultValue: [0], maximum: 10).control, .slider)
        XCTAssertEqual(EffectSchema.Parameter(key: "a", title: "A", defaultValue: [1, 1, 1], isColor: true).control, .color)
        XCTAssertEqual(EffectSchema.Parameter(key: "a", title: "A", defaultValue: [1, 1]).control, .vector(2))
        let combo = EffectSchema.Combo(name: "B", title: "B", defaultValue: 0, requirements: ["A": 1])
        XCTAssertTrue(EffectSchema.requirementsHold(combo) { _ in 1 })
        XCTAssertFalse(EffectSchema.requirementsHold(combo) { _ in 0 })
    }

    /// A mask a later pass samples is named in that pass's `textures`, as WE's scenes name Blur's
    /// (`passes[3].textures[1]`), with no combo written: the bound texture switches it on.
    func testAMaskOfALaterPassGoesInThatPass() throws {
        let scene = Data("""
        {"objects": [{"id": 1, "image": "models/a.json", "effects": [
          {"file": "effects/blur/effect.json"},
          {"file": "effects/tint/effect.json", "passes": [{"textures": [null, "masks/tint_mask_old"]}]}
        ]}]}
        """.utf8)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let session = SceneEditSession(outline: try SceneOutline(sceneData: scene), undoManager: undoManager)
        session.setEffectTexture("masks/blur_combine_mask_abc", slot: 1, pass: 3, effect: "0", of: 1, combo: "MASK", actionName: "Mask")
        XCTAssertEqual(session.effectTexture(1, pass: 3, effect: "0", of: 1), "masks/blur_combine_mask_abc")
        XCTAssertNil(session.effectTexture(1, effect: "0", of: 1), "not the first pass's slot")
        session.setEffectTexture("masks/tint_mask_new", slot: 1, effect: "1", of: 1, combo: "MASK", actionName: "Mask")

        let applied = try XCTUnwrap(JSONSerialization.jsonObject(with: session.overlay.applied(to: scene)) as? [String: Any])
        let effects = try XCTUnwrap(((applied["objects"] as? [[String: Any]])?.first?["effects"]) as? [[String: Any]])
        let blurPasses = try XCTUnwrap(effects[0]["passes"] as? [[String: Any]])
        XCTAssertEqual(blurPasses.count, 4)
        let combine = try XCTUnwrap(blurPasses[3]["textures"] as? [Any])
        XCTAssertTrue(combine[0] is NSNull)
        XCTAssertEqual(combine[1] as? String, "masks/blur_combine_mask_abc")
        XCTAssertNil(blurPasses[0]["combos"], "a later pass's combo follows its texture")
        let tintPass = try XCTUnwrap((effects[1]["passes"] as? [[String: Any]])?.first)
        XCTAssertEqual((tintPass["textures"] as? [Any])?[1] as? String, "masks/tint_mask_new")
        XCTAssertNil(tintPass["combos"], "a mask replacing an authored one leaves the combo as authored")

        // Read back from the applied scene, as the next session sees it.
        let reread = SceneEditSession(outline: try SceneOutline(sceneData: try session.overlay.applied(to: scene)))
        XCTAssertEqual(reread.effectTexture(1, pass: 3, effect: "0", of: 1), "masks/blur_combine_mask_abc")

        session.undo()
        XCTAssertEqual(session.effectTexture(1, effect: "1", of: 1), "masks/tint_mask_old", "the replaced mask comes back")
        session.undo()
        XCTAssertNil(session.effectTexture(1, pass: 3, effect: "0", of: 1))
    }
}
