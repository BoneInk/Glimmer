import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// Operators and initializers address control points by index (`controlpoint`), and a child can
/// take its control points from its parent's particles (link flag 1).
final class ParticleControlPointTests: XCTestCase {
    private var texture: MTLTexture!

    override func setUpWithError() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
    }

    /// WE's control points (`wallpaper64.exe` 0x14022e3e0), by index, in the system's space: an
    /// offset from the emitter, the cursor (flag 1), a scene position (flag 2), the parent system's
    /// point (flag 4) or the object's `controlpoint<n>` override.
    func testControlPointsFollowTheirFlags() {
        var system = ParticleTestSystem()
        system.origin = SIMD2(500, 500)
        system.emitterLinear = simd_float2x2(diagonal: SIMD2(2, 2))
        system.controlPoints[1] = ParticleTestSystem.point(SIMD2(30, -40))
        system.controlPoints[2] = ParticleTestSystem.point(.zero, cursor: true)
        system.controlPoints[3] = ParticleControlPoint(offset: SIMD3(100, 50, 0), worldSpace: true)
        var configuration = system.configuration
        configuration.overrides.controlPoints[4] = SIMD3(10, 20, 0)
        let runtime = ParticleSystemRuntime(texture: texture, configuration: configuration, seed: 1)
        let cursor = SIMD2<Float>(700, 200)
        let inputs = ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: cursor)
        XCTAssertEqual(inputs.controlPoints[0], .zero, "control point 0 is the emitter")
        XCTAssertEqual(inputs.controlPoints[1], SIMD3(30, -40, 0), "an offset in the system's space")
        XCTAssertEqual(inputs.controlPoints[2], SIMD3(100, -150, 0), "the cursor, taken into the system's space")
        XCTAssertEqual(inputs.controlPoints[3], SIMD3(-200, -225, 0), "a scene position")
        XCTAssertEqual(inputs.controlPoints[4], SIMD3(10, 20, 0), "the object's override")
        XCTAssertEqual(runtime.lastControlPoints[1], SIMD3(560, 420, 0))
        XCTAssertEqual(inputs.absolutePoints, 0b1100)
        let moved = inputs.placed(at: SIMD2(100, 0), previous: SIMD2(100, 0))
        XCTAssertEqual(moved.controlPoints[2], SIMD3(50, -150, 0), "a cursor point stays put in the scene")
        XCTAssertEqual(moved.controlPoints[1], SIMD3(30, -40, 0), "an emitter point moves with the instance")
    }

    /// The json's control points by position, with their flags (0x1401d0530).
    func testTheBuilderReadsControlPointFlags() throws {
        let points = try JSONDecoder().decode([WEParticleControlPoint].self, from: Data(#"""
            [{"id": 0, "flags": 2, "offset": "5 5 0"}, {"id": 7, "flags": 1}, {"flags": 2, "offset": "1 2 3"},
             {"flags": 4, "parentcontrolpoint": 3}]
            """#.utf8))
        let parsed = ParticleSystemBuilder.controlPoints(points)
        XCTAssertEqual(parsed.count, 8)
        XCTAssertFalse(parsed[0].worldSpace, "control point 0 is never in the scene")
        XCTAssertTrue(parsed[1].followsCursor, "the id is ignored")
        XCTAssertTrue(parsed[2].worldSpace)
        XCTAssertEqual(parsed[2].offset, SIMD3(1, 2, 3), "z too (0x14022cdc0)")
        XCTAssertEqual(parsed[3].parentControlPoint, 3)
        XCTAssertFalse(parsed[3].parentRawValue)
    }

    /// Flag 4 copies the parent's control point into the child's space; with flag 8 ("raw value")
    /// the parent's point is copied as it is in the parent's space (0x14022e6b3). Flag 4 wins over
    /// flag 2 (0x14022e66e runs before the scene-position placement, 0x14022a070).
    func testAParentsPointCopiesRawWithFlagEight() throws {
        var parentSystem = ParticleTestSystem()
        parentSystem.origin = SIMD2(500, 500)
        parentSystem.controlPoints[1] = ParticleTestSystem.point(SIMD2(30, -40))
        let parent = ParticleSystemRuntime(texture: texture, configuration: parentSystem.configuration, seed: 1)
        _ = ParticleFrameInputs.advance(parent, deltaTime: 1 / 60, cursor: .zero)
        XCTAssertEqual(parent.lastControlPoints[1], SIMD3(530, 460, 0))

        var childSystem = ParticleTestSystem()
        childSystem.origin = SIMD2(600, 400)
        childSystem.controlPoints[1] = ParticleControlPoint(parentControlPoint: 1)
        childSystem.controlPoints[2] = ParticleControlPoint(parentControlPoint: 1, parentRawValue: true)
        childSystem.controlPoints[3] = ParticleControlPoint(offset: SIMD3(5, 5, 0), worldSpace: true, parentControlPoint: 1)
        let child = ParticleSystemRuntime(texture: texture, configuration: childSystem.configuration, seed: 2)
        child.parent = parent
        let inputs = ParticleFrameInputs.advance(child, deltaTime: 1 / 60, cursor: .zero)
        XCTAssertEqual(inputs.controlPoints[1], SIMD3(-70, 60, 0), "the parent's point, in the child's space")
        XCTAssertEqual(inputs.controlPoints[2], SIMD3(30, -40, 0), "the parent's own value")
        XCTAssertEqual(inputs.controlPoints[3], inputs.controlPoints[1], "flag 4 before flag 2")
    }

    /// Flag 16 changes nothing at run time: `wallpaper64.exe` reads a control point's flags only for
    /// 1, 2, 4, 8 and its own 0x10000 (0x14022e461, 0x14022a08c, 0x14022e66e, 0x14022a765), never 16.
    /// WE's dripping-water presets set it on the points their instance override drives.
    func testFlagSixteenIsAPlainPoint() throws {
        let points = try JSONDecoder().decode([WEParticleControlPoint].self, from: Data(#"""
            [{"id": 0}, {"id": 1, "flags": 16, "offset": "40 -10 0"}, {"id": 2, "offset": "40 -10 0"}]
            """#.utf8))
        let parsed = ParticleSystemBuilder.controlPoints(points)
        XCTAssertEqual(parsed[1], parsed[2])
    }
}
