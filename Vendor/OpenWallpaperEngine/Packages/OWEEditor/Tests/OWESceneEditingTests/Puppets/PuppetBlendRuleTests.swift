import XCTest
import simd
@testable import OWESceneEditing

/// Puppet Warp blend rules in the editor (docs/models-plan.md §2.15): read from and written to
/// the `.mdl`'s constraints and constraint tracks, edited on the document, and posed in the
/// preview as the player poses them. `br_rule` / `br_none` are WE 2.8.0.42's capture 533.
final class PuppetBlendRuleTests: XCTestCase {
    private static func rig(_ name: String) throws -> PuppetDocument {
        let data = try Data(contentsOf: PuppetFixtureRigTests.models.appending(path: "PuppetGroundTruth533/\(name).mdl"))
        return try PuppetMDLReader.read(data, imageSize: SIMD2(512, 256), sourcePath: "models/bars_puppet.mdl")
    }

    func testWEsRuleOpensAndSavesBack() throws {
        let opened = try Self.rig("br_rule")
        XCTAssertEqual(opened.bones.map(\.name), ["red", "blue", "anchor"])
        XCTAssertNil(opened.bones[0].blendRules)
        let rule = try XCTUnwrap(opened.bones[1].blendRules?.first)
        XCTAssertEqual(opened.bones[1].blendRules?.count, 1)
        XCTAssertEqual(rule.target, 2)
        XCTAssertEqual(rule.flags, 0)
        XCTAssertNil(rule.floats)
        let samples = rule.samples(clip: 28, frames: 60)
        XCTAssertEqual(samples[0], 1, accuracy: 1e-4)
        XCTAssertEqual(samples[30], 0, accuracy: 1e-4)
        XCTAssertEqual(samples[59], 1, accuracy: 1e-3)
        XCTAssertNil(try Self.rig("br_none").bones[1].blendRules, "the deleted rule's curve isn't in the .mdl")

        let reopened = try PuppetMDLReader.read(try PuppetMDLWriter.write(opened), imageSize: SIMD2(512, 256))
        let again = try XCTUnwrap(reopened.bones[1].blendRules?.first)
        XCTAssertEqual(again.target, 2)
        for (a, b) in zip(again.samples(clip: 28, frames: 60), samples) { XCTAssertEqual(a, b, accuracy: 2e-4) }
    }

    func testTheWriterLaysOutTheConstraintsAsWEReadsThem() throws {
        var document = PuppetFixtures.twoBoneStrip()
        document.bones.append(PuppetBone(name: "anchor", parent: nil, local: PuppetTransform(matrix: matrix_identity_float4x4)))
        _ = document.addClip(named: "clip", frames: 10)
        XCTAssertTrue(document.addBlendRule(bone: 1, target: 2))
        XCTAssertFalse(document.addBlendRule(bone: 1, target: 2), "one rule per target")
        XCTAssertFalse(document.addBlendRule(bone: 1, target: 1), "not toward itself")
        let id = document.clips[0].id
        document.setBlendRuleWeight(bone: 1, rule: 0, clip: id, frame: 0, to: 1)
        document.setBlendRuleWeight(bone: 1, rule: 0, clip: id, frame: 10, to: 3)
        XCTAssertEqual(document.bones[1].blendRules?[0].weights[id], [0: 1, 10: 1], "clamped to 0…1")
        document.setBlendRuleWeight(bone: 1, rule: 0, clip: id, frame: 10, to: 0)
        XCTAssertEqual(document.bones[1].blendRules?[0].weight(clip: id, at: 5), 0.5)
        let bytes = [UInt8](try PuppetMDLWriter.write(document))
        // MDLS: …, u32 1 constraint {bone 1, weight 0, target 2, flags 0}, then u16 0 maps.
        let constraint: [UInt8] = [1, 0, 0, 0] + [1, 0, 0, 0] + [0, 0, 0, 0] + [2, 0, 0, 0] + [0, 0, 0, 0] + [0, 0]
        XCTAssertNotNil(bytes.firstRange(of: constraint))
        let read = try PuppetMDLReader.read(Data(bytes), imageSize: document.imageSize)
        XCTAssertEqual(read.bones[1].blendRules?[0].samples(clip: id, frames: 10).map { ($0 * 10).rounded() / 10 },
                       [1, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1, 0])
    }

    func testRulesFollowTheirBones() {
        var document = PuppetFixtures.twoBoneStrip()
        document.bones.append(PuppetBone(name: "anchor", parent: nil, local: PuppetTransform(matrix: matrix_identity_float4x4)))
        _ = document.addClip(named: "clip")
        document.addBlendRule(bone: 2, target: 1)
        document.setBlendRuleWeight(bone: 2, rule: 0, clip: document.clips[0].id, frame: 0, to: 1)
        document.deleteBone(0)
        XCTAssertEqual(document.bones.map(\.name), ["upper", "anchor"])
        XCTAssertEqual(document.bones[1].blendRules?.map(\.target), [0], "the target renumbered")
        document.deleteBone(0)
        XCTAssertNil(document.bones[0].blendRules, "a rule toward a deleted bone goes")

        var other = PuppetFixtures.twoBoneStrip()
        _ = other.addClip(named: "clip")
        other.addBlendRule(bone: 1, target: 0)
        let id = other.clips[0].id
        other.setBlendRuleWeight(bone: 1, rule: 0, clip: id, frame: 3, to: 1)
        other.deleteClip(0)
        XCTAssertNil(other.bones[1].blendRules?[0].weights[id], "a deleted clip's keys go")
        other.removeBlendRule(bone: 1, at: 0)
        XCTAssertNil(other.bones[1].blendRules)
    }

    /// The preview poses as the player: at frame 0 the weight is 1, so blue's joint is on the
    /// anchor; at frame 30 it is 0 and blue rests.
    func testThePreviewPullsTheBoneTowardItsTarget() throws {
        let document = try Self.rig("br_rule")
        let rig = PuppetRig(document)
        let start = rig.worlds(clip: 0, frame: 0)
        XCTAssertEqual(simd_distance(start[1].columns.3, start[2].columns.3), 0, accuracy: 1e-3)
        let middle = rig.worlds(clip: 0, frame: 30)
        XCTAssertEqual(simd_distance(middle[1].columns.3, rig.bindWorld[1].columns.3), 0, accuracy: 1e-3)

        var player = PuppetLayerPlayer(rig: rig, layers: [PuppetAnimationLayer(id: 1, name: "clip", clipID: 28)])
        _ = player.evaluate(delta: 0)
        XCTAssertEqual(player.blendWeights.first ?? 0, 1, accuracy: 1e-4)

        let turned = PuppetMath.matrix(translation: SIMD3(4, 2, 0), euler: SIMD3(0.2, -0.3, 0.9), scale: SIMD3(2, 2, 2))
        let blended = PuppetBlendMath.blend(matrix_identity_float4x4, toward: turned, weight: 1)
        for column in 0..<4 { XCTAssertEqual(simd_distance(blended[column], turned[column]), 0, accuracy: 1e-4) }
    }
}
