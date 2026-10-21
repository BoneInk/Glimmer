import XCTest
import simd
@testable import OpenWallpaperEngine

/// WE 2.8.0.42's Puppet Warp blend rule from capture request 533
/// (`Tests/Fixtures/Models/PuppetGroundTruth533`; we-test-wp-images,
/// tools/peer/requests/owe-beta7/models-open/533-blend-rules). 509's bars (red root, blue child)
/// with a third root bone, `anchor`, unweighted; blue has a blend rule toward it, and clip 28 keys
/// the anchor's Origin y 0 → −150 → 0 (offsets from bind) and the rule's weight 1 → 0 → 1 over
/// frames 0, 30, 59. WE's stills of the running wallpaper give the blue bar's centroid on the
/// 1920 × 1080 frame (the layer at its centre, y up); `br_none` is the same clip with the rule
/// deleted, its weight curve orphaned in the editor's JSON (docs/models-plan.md §2.15).
final class PuppetBlendRules533Tests: XCTestCase {
    private static func model(_ name: String) throws -> MDLModel {
        try MDLReader.read(try Fixtures.data("Models/PuppetGroundTruth533/\(name).mdl"))
    }

    private static func animator(_ model: MDLModel, clip: UInt64?) throws -> ScenePuppetAnimator {
        let skeleton = try XCTUnwrap(model.skeleton)
        let layers = clip.map { [WEAnimationLayer(animation: $0)] } ?? []
        return ScenePuppetAnimator(skeleton: skeleton, clips: model.animations ?? [], layers: layers)
    }

    /// The blue bar's area-weighted centroid in frame pixels, skinned with the animator's palette:
    /// the triangles textured from the right half (blue), the layer's centre at (960, 540).
    private static func blueCentroid(_ mesh: MDLMesh, _ pose: ScenePuppetPose) throws -> SIMD2<Float> {
        let positions = try XCTUnwrap(mesh.floatValues(.position))
        let uvs = try XCTUnwrap(mesh.floatValues(.texCoord))
        let indices = try XCTUnwrap(mesh.unsignedValues(.blendIndices))
        let weights = try XCTUnwrap(mesh.floatValues(.blendWeights))
        let skinned: [SIMD2<Float>] = (0..<mesh.vertexCount).map { vertex in
            let point = SIMD4<Float>(positions[3 * vertex], positions[3 * vertex + 1], positions[3 * vertex + 2], 1)
            var sum = SIMD4<Float>.zero
            for slot in 0..<4 {
                let weight: Float = weights[4 * vertex + slot]
                guard weight != 0 else { continue }
                let bone = Int(indices[4 * vertex + slot])
                sum += weight * (pose.bones[bone] * point)
            }
            return SIMD2(960 + sum.x, 540 - sum.y)
        }
        let triangles = mesh.indices.map(Int.init)
        var area: Float = 0
        var moment = SIMD2<Float>.zero
        for start in stride(from: 0, to: triangles.count, by: 3) {
            let corners = triangles[start..<(start + 3)]
            guard corners.allSatisfy({ uvs[2 * $0] > 0.5 }) else { continue }
            let a = skinned[corners[start]], b = skinned[corners[start + 1]], c = skinned[corners[start + 2]]
            let piece: Float = abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) / 2
            area += piece
            moment += piece * (a + b + c) / 3
        }
        return moment / area
    }

    /// The centroid at `time` s, advanced in 60 Hz frames (a target posed after its bone lags a
    /// frame, as in WE).
    private static func centroids(_ name: String, clip: UInt64?, at times: [Float]) throws -> [SIMD2<Float>] {
        let model = try Self.model(name)
        let animator = try Self.animator(model, clip: clip)
        var clock: Float = 0
        var out: [SIMD2<Float>] = []
        for time in times {
            while clock < time - 1e-5 {
                let step = min(1 / 60, time - clock)
                animator.advance(delta: step, values: EmptySceneValues())
                clock += step
            }
            out.append(try blueCentroid(model.meshes[0], animator.pose))
        }
        return out
    }

    /// WE's stills (stills/, rd_timed_report.txt): the blue bar's centroid (blue pixels) at rest
    /// and at 0.25 / 0.5 / 0.75 / 1.0 / 1.5 s.
    private static let rest = SIMD2<Float>(1083.5, 539.5)
    private static let captured: [(time: Float, centroid: SIMD2<Float>)] = [
        (0.25, SIMD2(1180.7, 474.1)), (0.5, SIMD2(1137.8, 514.9)), (0.75, SIMD2(1101.5, 540.6)),
        (1.0, SIMD2(1084.6, 539.6)), (1.5, SIMD2(1110.1, 543.8)),
    ]
    /// The stills show the clip about 0.09 s before their timestamps: two frames of the capture's
    /// ~22 fps (frames 779…806 over 1.25 s), the jitter of docs/models-plan.md point 28. Fitted on
    /// each still alone the lag is 0.08–0.11 s; one lag fits all five.
    private static let stillLag: Float = 0.09

    /// The compiled rule: on blue (bone 1), weight 0, target anchor (bone 2), no floats (the
    /// editor's `amin` 0 / `amax` 5 aren't written); the clip's one constraint track is the keyed
    /// weight, eased 1 → 0 → 1. `br_none` has neither, though its JSON keeps the curve.
    func testTheCompiledRuleAndItsWeightTrack() throws {
        let rule = try Self.model("br_rule"), none = try Self.model("br_none")
        let skeleton = try XCTUnwrap(rule.skeleton)
        XCTAssertEqual(skeleton.bones.map(\.name), ["red", "blue", "anchor"])
        XCTAssertEqual(skeleton.constraints, [MDLSkeleton.Constraint(bone: 1, a: 0, b: 2, flags: 0, f0: nil, f1: nil)])
        let clip = try XCTUnwrap(rule.animation(id: 28))
        let track = try XCTUnwrap(clip.constraintTracks?.first)
        XCTAssertEqual(clip.constraintTracks?.count, 1)
        XCTAssertEqual(track.tag, 0)
        XCTAssertEqual(track.samples.count, 61)
        XCTAssertEqual(track.samples[0], 1, accuracy: 1e-4)
        XCTAssertEqual(track.samples[30], 0, accuracy: 1e-4)
        XCTAssertEqual(track.samples[59], 1, accuracy: 1e-3)
        XCTAssertEqual(none.skeleton?.constraints, [])
        XCTAssertEqual(none.animation(id: 28)?.constraintTracks?.count, 0)
        XCTAssertNil(SceneBlendRules(try XCTUnwrap(none.skeleton)))
        XCTAssertEqual(SceneBlendRules(skeleton)?.rules, [[], [.init(weight: 0, target: 2)], []])
        // No clip yet: the rule is there, its weight 0 until a layer keys it.
        XCTAssertEqual(try Self.model("br_static_rule").skeleton?.constraints, skeleton.constraints)
    }

    /// Blue is pulled toward the anchor by the keyed weight, its model matrix lerped toward the
    /// anchor's (translation here: no bone turns or scales), red's weights holding its near end:
    /// the centroid's move from rest matches WE's within 6 px at every still.
    func testTheRulePullsBlueTowardTheAnchorAsWEDraws() throws {
        let times = Self.captured.map { $0.time - Self.stillLag }
        let ours = try Self.centroids("br_rule", clip: 28, at: [0] + times)
        let oursRest = try Self.centroids("br_none", clip: 28, at: [0])[0]
        XCTAssertEqual(simd_distance(oursRest, Self.rest), 0, accuracy: 2.5, "the bar at rest")
        for (index, still) in Self.captured.enumerated() {
            let moved = ours[index + 1] - oursRest, theirs = still.centroid - Self.rest
            XCTAssertEqual(simd_distance(moved, theirs), 0, accuracy: 6,
                           "t = \(still.time) s: ours moved \(moved), WE's \(theirs)")
        }
        // At frame 0 the weight is 1: blue's head sits on the anchor (143.8, 98.2 at the clip's start).
        let animator = try Self.animator(try Self.model("br_rule"), clip: 28)
        animator.advance(delta: 1e-4, values: EmptySceneValues())
        animator.advance(delta: 1e-4, values: EmptySceneValues())
        XCTAssertEqual(animator.worlds[1].columns.3.x, animator.worlds[2].columns.3.x, accuracy: 0.05)
        XCTAssertEqual(animator.worlds[1].columns.3.y, animator.worlds[2].columns.3.y, accuracy: 0.05)
    }

    /// Without the rule nothing moves blue: the orphaned curve isn't in the `.mdl`.
    func testWithoutTheRuleBlueStaysAtRest() throws {
        let times = Self.captured.map(\.time)
        let ours = try Self.centroids("br_none", clip: 28, at: [0] + times)
        for centroid in ours { XCTAssertEqual(simd_distance(centroid, ours[0]), 0, accuracy: 1e-3) }
        let animator = try Self.animator(try Self.model("br_none"), clip: 28)
        animator.advance(delta: 0.25, values: EmptySceneValues())
        for column in 0..<4 {
            XCTAssertEqual(simd_distance(animator.pose.bones[1][column], matrix_identity_float4x4[column]), 0, accuracy: 1e-4)
        }
    }

    /// The decomposition WE blends: weight 0 and 1 give the bone's and the target's matrix back
    /// (rotation, scale and translation), ½ lerps the parts, children follow the blended bone.
    func testTheBlendLerpsTranslationAnglesAndScale() {
        let own = SceneBoneTransform(translation: SIMD3(1, 2, 3), rotation: simd_quatf(angle: 0.3, axis: SIMD3(0, 0, 1)),
                                     scale: SIMD3(1, 1, 1)).matrix
        let target = SceneBoneTransform(translation: SIMD3(11, -2, 5), rotation: simd_quatf(angle: 1.1, axis: SIMD3(0, 0, 1)),
                                        scale: SIMD3(2, 2, 2)).matrix
        for column in 0..<4 {
            XCTAssertEqual(simd_distance(SceneBlendRules.blend(own, toward: target, weight: 0)[column], own[column]), 0, accuracy: 1e-5)
            XCTAssertEqual(simd_distance(SceneBlendRules.blend(own, toward: target, weight: 1)[column], target[column]), 0, accuracy: 1e-5)
        }
        let half = SceneBlendRules.blend(own, toward: target, weight: 0.5)
        let expected = SceneBoneTransform(translation: SIMD3(6, 0, 4), rotation: simd_quatf(angle: 0.7, axis: SIMD3(0, 0, 1)),
                                          scale: SIMD3(1.5, 1.5, 1.5)).matrix
        for column in 0..<4 { XCTAssertEqual(simd_distance(half[column], expected[column]), 0, accuracy: 1e-5) }

        // A 3D turn reads back through WE's angles.
        let turned = SceneBoneTransform(translation: .zero, rotation: simd_quatf(angle: 0.8, axis: simd_normalize(SIMD3(1, 2, 3))),
                                        scale: SIMD3(1, 1, 1)).matrix
        let parts = SceneBlendRules.Parts(turned)
        let rebuilt = SceneBlendRules.rotation(parts.angles)
        for column in 0..<3 { XCTAssertEqual(simd_distance(rebuilt[column], turned[column]), 0, accuracy: 1e-5) }

        // WE brings a target angle more than π above the bone's down by π, never up.
        let low = SceneBoneTransform(translation: .zero, rotation: simd_quatf(angle: -3, axis: SIMD3(0, 0, 1)),
                                     scale: SIMD3(1, 1, 1)).matrix
        let high = SceneBoneTransform(translation: .zero, rotation: simd_quatf(angle: 3, axis: SIMD3(0, 0, 1)),
                                      scale: SIMD3(1, 1, 1)).matrix
        let pulled = SceneBlendRules.Parts(SceneBlendRules.blend(low, toward: high, weight: 1))
        XCTAssertEqual(pulled.angles.z, 3 - Float.pi, accuracy: 1e-4)
    }
}
