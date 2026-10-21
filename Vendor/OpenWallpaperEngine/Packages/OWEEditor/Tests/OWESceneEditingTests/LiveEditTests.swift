import XCTest
@testable import OWESceneEditing

/// What a running wallpaper draws live (no reload) when the overlay changes, and what needs the
/// scene read again.
@MainActor
final class LiveEditTests: XCTestCase {
    private var base: SceneOutline!

    override func setUp() async throws {
        base = try SceneOutline(sceneData: Fixtures.sceneData)
    }

    func testTransformOpacityAndColourAreLive() throws {
        var current = SceneEditOverlay()
        current.setField("origin", to: .string("100 200 0"), of: 10)
        current.setField("scale", to: .string("2 2 1"), of: 10)
        current.setField("angles", to: .string("0 0 1"), of: 10)
        current.setField("alpha", to: .number(0.5), of: 10)
        current.setField("color", to: .string("1 0 0"), of: 10)
        let live = try XCTUnwrap(SceneEditLiveValues.make(built: SceneEditOverlay(), current: current, base: base))
        let layer = try XCTUnwrap(live.layers[10])
        XCTAssertEqual(layer.origin?.built, SIMD3(960, 540, 0), "from the scene's value")
        XCTAssertEqual(layer.origin?.now, SIMD3(100, 200, 0))
        XCTAssertEqual(layer.scale?.now, SIMD3(2, 2, 1))
        XCTAssertEqual(layer.angles?.now.z, 1)
        XCTAssertEqual(layer.alpha?.built, 1)
        XCTAssertEqual(layer.alpha?.now, 0.5)
        XCTAssertEqual(layer.color?.now, SIMD3(1, 0, 0))
    }

    func testMeasuredAgainstWhatTheWallpaperWasBuiltWith() throws {
        var built = SceneEditOverlay()
        built.setField("origin", to: .string("10 10 0"), of: 13)
        var current = built
        current.setField("origin", to: .string("30 10 0"), of: 13)
        let live = try XCTUnwrap(SceneEditLiveValues.make(built: built, current: current, base: base))
        XCTAssertEqual(live.layers[13]?.origin?.built, SIMD3(10, 10, 0))
        XCTAssertEqual(live.layers[13]?.origin?.now, SIMD3(30, 10, 0))
        // An undo back to the scene's value is live too.
        let undone = try XCTUnwrap(SceneEditLiveValues.make(built: built, current: SceneEditOverlay(), base: base))
        XCTAssertEqual(undone.layers[13]?.origin?.now, SIMD3(1700, 900, 0))
        XCTAssertTrue(try XCTUnwrap(SceneEditLiveValues.make(built: current, current: current, base: base)).isEmpty)
    }

    func testEffectVisibilityAndConstantsAreLive() throws {
        var current = SceneEditOverlay()
        current.setEffectVisible(false, effect: 0, of: 10)
        current.setEffectConstant("speed", to: .number(3), effect: 0, of: 10)
        current.setEffectConstant("color", to: .string("1 0.5 0"), effect: 0, of: 10)
        let live = try XCTUnwrap(SceneEditLiveValues.make(built: SceneEditOverlay(), current: current, base: base))
        let effect = try XCTUnwrap(live.effects[10]?[0])
        XCTAssertEqual(effect.visible, false)
        XCTAssertEqual(effect.constants["speed"], [3])
        XCTAssertEqual(effect.constants["color"], [1, 0.5, 0])
        // An edit dropped falls back to the scene's value.
        current.setEffectConstant("color", to: nil, effect: 0, of: 10)
        let back = try XCTUnwrap(SceneEditLiveValues.make(built: current, current: SceneEditOverlay(), base: base))
        XCTAssertEqual(back.effects[10]?[0]?.constants["speed"], [1.5])
        XCTAssertEqual(back.effects[10]?[0]?.visible, true)
    }

    func testWhatNeedsTheSceneReadAgain() {
        func needsReload(_ change: (inout SceneEditOverlay) -> Void, built: SceneEditOverlay = SceneEditOverlay()) -> Bool {
            var current = built
            change(&current)
            return SceneEditLiveValues.make(built: built, current: current, base: base) == nil
        }
        XCTAssertTrue(needsReload { $0.setField("visible", to: .bool(false), of: 10) })
        XCTAssertTrue(needsReload { $0.setField("text", to: .string("x"), of: 11) })
        XCTAssertTrue(needsReload { $0.setField("origin", to: .string("1 1 0"), of: 14) }, "a script drives it")
        XCTAssertTrue(needsReload { $0.addObject(.object(["image": .string("x")]), id: 20) })
        XCTAssertTrue(needsReload { $0.updateEffect(key: "0", of: 10) { $0.combos = ["A": 1] } })
        XCTAssertTrue(needsReload { $0.updateEffect(key: "0", of: 10) { $0.textures = ["1": .string("m")] } })
        XCTAssertTrue(needsReload { $0.setEffectVisible(false, effect: 1, of: 10) }, "a user property sets it")
        XCTAssertTrue(needsReload { $0.setEffectConstant("strength", to: .number(1), effect: 0, of: 10) }
                      == false, "a constant the scene doesn't set is live while edited")
        var withStrength = SceneEditOverlay()
        withStrength.setEffectConstant("strength", to: .number(1), effect: 0, of: 10)
        XCTAssertTrue(needsReload({ $0.setEffectConstant("strength", to: nil, effect: 0, of: 10) }, built: withStrength),
                      "back to the shader's default, which only a read knows")
    }
}
