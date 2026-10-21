import XCTest
import simd
@testable import OpenWallpaperEngine

/// Puppet Warp's rope chain against WE 2.8.0.42's capture 536 (`Tests/Fixtures/Models/
/// PuppetRope536`; we-test-wp-images, tools/peer/requests/owe-beta7/models-open/536-rope): a
/// 5-bone chain (root at −224.58, joints 112.29 / 112.29 / 113.55 / 89.58 apart) whose tip has
/// "Rope with 4 elements" (gravity, mass 600, friction 5), played on an empty 2 s clip at the
/// image's place (960, 540). `rope_base` stretches with its end pinned, `rope_nostretch` doesn't,
/// `rope_nostretch_free` frees the end. WE's RenderDoc stills (about 25 frames a second) put the
/// middle joint's tick at y 584–585 on the 1080-line frame by 2–4 s in both pinned variants, 45 px
/// under the rest line at 540; the free rope swings under and past its root (docs/models-plan.md
/// §2.14). Every capture still is a slow frame, so the stills' early sag (the next frame's delta
/// is long) isn't matched frame by frame.
final class ScenePuppetRopeTests: XCTestCase {
    private static let world: simd_float4x4 = {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(960, 540, 0, 1)
        return m
    }()

    private static func animator(_ name: String, layered: Bool = true,
                                 physics: ScenePhysicsSettings = ScenePhysicsSettings()) throws -> ScenePuppetAnimator {
        let model = try MDLReader.read(try Fixtures.data("Models/PuppetRope536/\(name).mdl"))
        let animator = ScenePuppetAnimator(skeleton: try XCTUnwrap(model.skeleton), clips: model.animations ?? [],
                                           layers: layered ? [WEAnimationLayer(animation: 22)] : [])
        let rope = try XCTUnwrap(animator.rope)
        rope.environment = ScenePuppetRope.Environment(physics: physics, time: 0, projectionWidth: 1920)
        return animator
    }

    private static func point(_ animator: ScenePuppetAnimator, _ bone: Int) -> SIMD2<Float> {
        let t = animator.worlds[bone].columns.3
        return SIMD2(t.x, t.y)
    }

    /// The bones' positions after each frame of `seconds` at 25 frames a second.
    private static func run(_ animator: ScenePuppetAnimator, seconds: Float, time: Float = 0,
                            each: (Float, ScenePuppetAnimator) -> Void = { _, _ in }) {
        let delta: Float = 0.04
        var t: Float = 0
        for _ in 0..<Int((seconds / delta).rounded()) {
            t += delta
            animator.rope?.environment.time = time + t
            animator.advance(delta: delta, values: EmptySceneValues(), objectWorld: world)
            each(t, animator)
        }
    }

    func testAPinnedRopeSagsToWhereWEsSettles() throws {
        for name in ["rope_base", "rope_nostretch"] {
            let animator = try Self.animator(name)
            var lowest: Float = 0
            Self.run(animator, seconds: 4) { t, animator in
                // Both ends stay pinned: the root to its bone, the end to its IK target.
                XCTAssertEqual(Self.point(animator, 0).x, -224.5795, accuracy: 1e-3)
                XCTAssertEqual(Self.point(animator, 0).y, 0, accuracy: 1e-3)
                XCTAssertEqual(Self.point(animator, 4).x, 203.1309, accuracy: 1e-3)
                XCTAssertEqual(Self.point(animator, 4).y, 0, accuracy: 1e-3)
                if t > 0.1 { lowest = min(lowest, Self.point(animator, 2).y) }
            }
            // WE: 584–585 at 2 and 4 s, 44–45 px down.
            XCTAssertEqual(Self.point(animator, 2).y, -44.5, accuracy: 7, "\(name): the middle settles where WE's does")
            XCTAssertEqual(Self.point(animator, 2).x, 0, accuracy: 3, name)
            XCTAssertLessThan(lowest, -50, "\(name) sags past its rest, as WE's (627 at 0.5 s)")
        }
    }

    func testAFreeEndSwingsUnderAndPastItsRootKeepingItsLength() throws {
        let animator = try Self.animator("rope_nostretch_free")
        var passedLeft = false
        var lowest: Float = 0
        let lengths: [Float] = [112.29, 112.29, 113.55, 89.58]
        var stretch = [Float](repeating: 0, count: 4), longest = stretch
        var frames: Float = 0
        Self.run(animator, seconds: 4) { t, animator in
            XCTAssertEqual(Self.point(animator, 0), SIMD2(-224.5795, 0), accuracy: 1e-3, "the root stays")
            let tip = Self.point(animator, 4)
            lowest = min(lowest, tip.y)
            if t <= 2.2, tip.x < -224.5795 { passedLeft = true }
            for (index, length) in lengths.enumerated() {
                let ratio = simd_length(Self.point(animator, index + 1) - Self.point(animator, index)) / length
                stretch[index] += ratio
                longest[index] = max(longest[index], ratio)
            }
            frames += 1
        }
        // WE: hanging down at 1 s (y to 1025, 485 px under the rest line), past the root at 2 s.
        XCTAssertLessThan(lowest, -300, "the end falls")
        XCTAssertTrue(passedLeft, "the end swings past its root by 2 s, as WE's")
        // The bones show the step's points, before the sweeps: a fast rope stretches a little
        // (WE's hangs 7 % long at 1 s and is within 1 % at the end of its swing, 2 s).
        for index in 0..<4 {
            XCTAssertLessThan(stretch[index] / frames, 1.1, "segment \(index + 1) keeps its length on average")
            XCTAssertLessThan(longest[index], 1.25, "segment \(index + 1)")
        }
    }

    func testTheSceneWindMovesTheSag() throws {
        var physics = ScenePhysicsSettings()
        physics.windEnabled = true
        let still = try Self.animator("rope_base"), windy = try Self.animator("rope_base", physics: physics)
        var difference: Float = 0
        Self.run(still, seconds: 2)
        Self.run(windy, seconds: 2)
        Self.run(still, seconds: 2, time: 2) { _, _ in }
        Self.run(windy, seconds: 2, time: 2) { _, animator in
            difference = max(difference, abs(Self.point(animator, 2).y - Self.point(still, 2).y))
        }
        XCTAssertGreaterThan(difference, 1, "WE's sag changes with the wind (623, 613, 579, 611 against 602)")
    }

    /// WE simulates a rope only while an animation layer plays (capture 536's first run, and the
    /// update's only solver call, 0x1402037a6, on its layered path).
    func testWithoutALayerTheRopeStaysStraight() throws {
        let animator = try Self.animator("rope_base", layered: false)
        Self.run(animator, seconds: 4)
        for (bone, x) in zip(0...4, [-224.5795, -112.2897, 0, 113.5514, 203.1309] as [Float]) {
            XCTAssertEqual(Self.point(animator, bone), SIMD2(x, 0), accuracy: 1e-2)
        }
    }
}

private func XCTAssertEqual(_ a: SIMD2<Float>, _ b: SIMD2<Float>, accuracy: Float, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(simd_length(a - b), accuracy, "\(a) vs \(b) \(message)", file: file, line: line)
}
