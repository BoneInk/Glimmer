import XCTest
@testable import OpenWallpaperEngine

/// A particle system's `instanceoverride` fields scripts own replace the authored ones; the rest,
/// and unusable numbers, stay (WP11).
final class SceneScriptInstanceOverridesTests: XCTestCase {
    private func state(_ writes: [(SceneScriptObjectField, [Float])]) -> SceneScriptObjectState {
        var state = SceneScriptObjectState(values: [Float](repeating: 0, count: SceneScriptObjectTable.Layout.stride))
        for (field, value) in writes {
            state.owned.insert(field)
            for (index, component) in value.enumerated() { state.values[field.offset + index] = component }
        }
        return state
    }

    func testOwnedFieldsReplaceTheAuthoredOnes() throws {
        var authored = SceneParticleOverrides()
        authored.alpha = 0.5
        authored.size = 2
        let scripted = try XCTUnwrap(SceneScriptInstanceOverrides(state([(.instanceRate, [3]), (.instanceColorn, [0.25]),
                                                                          (.controlpoint2, [1, 2, 3])])))
        let applied = scripted.applied(to: authored)
        XCTAssertEqual(applied.rate, 3)
        XCTAssertEqual(applied.tint, SIMD3(repeating: 0.25))
        XCTAssertEqual(applied.controlPoints[2], SIMD3(1, 2, 3))
        XCTAssertEqual(applied.alpha, 0.5, "not owned: authored")
        XCTAssertEqual(applied.size, 2)
    }

    func testNothingOwnedIsNil() {
        XCTAssertNil(SceneScriptInstanceOverrides(state([(.origin, [1, 2, 3])])))
    }

    func testNonFiniteNumbersKeepTheAuthoredValue() throws {
        let scripted = try XCTUnwrap(SceneScriptInstanceOverrides(state([(.instanceRate, [.nan]), (.instanceAlpha, [.infinity])])))
        let applied = scripted.applied(to: SceneParticleOverrides())
        XCTAssertEqual(applied.rate, 1)
        XCTAssertEqual(applied.alpha, 1)
    }
}
