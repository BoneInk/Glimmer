import XCTest
import simd
@testable import OWESceneEditing

/// Existing rigs (the repository's `.mdl` fixtures: a rope puppet WE's own editor made, the
/// generated per-version models) open in the editor and save back to what they were.
final class PuppetFixtureRigTests: XCTestCase {
    static let models = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Tests/Fixtures/Models")

    static let rigs = ["BonePhysics/rope-A.mdl", "BonePhysics/rope-B.mdl", "v13-puppet.mdl", "v19-skeleton.mdl",
                       "v21-skeleton.mdl", "v23-full.mdl", "mg4-rootmotion-all-on.mdl", "mg5-puppet-blendshape.mdl",
                       "PuppetGroundTruth509/base.mdl", "PuppetGroundTruth509/b_clip_keyed_order.mdl",
                       "PuppetGroundTruth509/c_refpose.mdl", "PuppetGroundTruth509/f_alpha.mdl"]

    func testRigsOpenAndSaveBack() throws {
        for name in Self.rigs {
            let data = try Data(contentsOf: Self.models.appending(path: name))
            let opened = try PuppetMDLReader.read(data, imageSize: SIMD2(512, 512), sourcePath: name)
            XCTAssertFalse(opened.bones.isEmpty, name)
            XCTAssertFalse(opened.mesh.vertices.isEmpty, name)
            for (index, bone) in opened.bones.enumerated() {
                if let parent = bone.parent { XCTAssertLessThan(parent, index, name) }
            }
            for entries in opened.weights where !entries.isEmpty {
                XCTAssertEqual(entries.reduce(0) { $0 + $1.weight }, 1, accuracy: 1e-5, name)
            }
            guard opened.problems.isEmpty else {
                // A static mesh in a fixture has vertices without weights: the editor asks for them first.
                XCTAssertEqual(opened.problems.count, 1, "\(name): \(opened.problems)")
                continue
            }
            let saved = try PuppetMDLWriter.write(opened)
            let reopened = try PuppetMDLReader.read(saved, imageSize: SIMD2(512, 512), sourcePath: name)
            XCTAssertEqual(reopened.mesh, opened.mesh, name)
            XCTAssertEqual(reopened.weights, opened.weights, name)
            XCTAssertEqual(reopened.bones.map(\.name), opened.bones.map(\.name), name)
            XCTAssertEqual(reopened.bones.map(\.parent), opened.bones.map(\.parent), name)
            XCTAssertEqual(reopened.bones.map(\.physics), opened.bones.map(\.physics), name)
            XCTAssertEqual(reopened.bones.map(\.otherProperties), opened.bones.map(\.otherProperties), name)
            for (a, b) in zip(reopened.bones, opened.bones) {
                XCTAssertTrue(a.local.isClose(to: b.local, tolerance: 1e-5), "\(name) \(a.name)")
            }
            XCTAssertEqual(reopened.clips.map(\.id), opened.clips.map(\.id), name)
            XCTAssertEqual(reopened.clips.map(\.flags), opened.clips.map(\.flags), name)
            XCTAssertEqual(reopened.clips.map(\.events), opened.clips.map(\.events), name)
            XCTAssertEqual(reopened.preserved, opened.preserved, name)
            let a = PuppetRig(reopened), b = PuppetRig(opened)
            for clip in opened.clips.indices {
                for frame in 0...opened.clips[clip].frames {
                    for (p, q) in zip(a.pose(clip: clip, frame: Float(frame)), b.pose(clip: clip, frame: Float(frame))) {
                        XCTAssertEqual(simd_distance(p.translation, q.translation), 0, accuracy: 1e-3, "\(name) clip \(clip)")
                        XCTAssertEqual(abs(simd_dot(p.rotation.vector, q.rotation.vector)), 1, accuracy: 1e-4, "\(name) clip \(clip)")
                    }
                }
            }
            // Saving what was saved changes nothing.
            XCTAssertEqual(try PuppetMDLWriter.write(reopened), saved, name)
        }
    }

    /// WE's editor's keyed per-bone Opacity and Depth offset (capture 509 F and B: `MDLA`'s second
    /// and third scalar lists) and the parts' index ranges survive opening and saving, and follow
    /// the bones; a new bone gets rest tracks, and the ranges go with it.
    func testWEsKeyedOpacityDepthAndPartRangesAreKept() throws {
        let folder = Self.models.appending(path: "PuppetGroundTruth509")
        let alpha = try PuppetMDLReader.read(try Data(contentsOf: folder.appending(path: "f_alpha.mdl")), imageSize: SIMD2(512, 256))
        let fade = try XCTUnwrap(alpha.clips.first?.boneAlphaTracks)
        XCTAssertEqual(fade.map(\.samples.count), [61, 61])
        XCTAssertEqual(fade[1].samples[0], 1)
        XCTAssertEqual(fade[1].samples[30], 0, accuracy: 1e-3)
        XCTAssertNil(alpha.clips.first?.boneDepthTracks)

        var keyed = try PuppetMDLReader.read(try Data(contentsOf: folder.appending(path: "b_clip_keyed_order.mdl")),
                                             imageSize: SIMD2(512, 256))
        XCTAssertEqual(keyed.preserved.boneRanges, [SIMD4(0, 0, 0, 594), SIMD4(1, 0, 594, 486)])
        let depth = try XCTUnwrap(keyed.clips.first?.boneDepthTracks)
        XCTAssertEqual(depth[1].samples[0], -200)
        XCTAssertEqual(depth[1].samples[30], 0)
        let saved = try PuppetMDLReader.read(try PuppetMDLWriter.write(keyed), imageSize: SIMD2(512, 256))
        XCTAssertEqual(saved.clips.first?.boneDepthTracks, depth)
        XCTAssertEqual(saved.preserved.boneRanges, keyed.preserved.boneRanges)

        keyed.addBone(named: "extra", parent: 0, head: SIMD2(0, 0))
        XCTAssertNil(keyed.preserved.boneRanges, "the parts' split no longer covers every bone")
        XCTAssertEqual(keyed.clips.first?.boneDepthTracks?.count, 3)
        XCTAssertEqual(keyed.clips.first?.boneDepthTracks?.last?.samples, [0])
        let grown = try PuppetMDLReader.read(try PuppetMDLWriter.write(keyed), imageSize: SIMD2(512, 256))
        XCTAssertEqual(grown.clips.first?.boneDepthTracks?.last?.samples, Array(repeating: 0, count: 61))
        XCTAssertEqual(grown.clips.first?.boneDepthTracks?[1].samples, depth[1].samples)
    }

    /// The rope WE's editor made: two bones, the tail a spring under gravity.
    func testWEsRopeReadsItsPhysics() throws {
        let data = try Data(contentsOf: Self.models.appending(path: "BonePhysics/rope-A.mdl"))
        let rope = try PuppetMDLReader.read(data, imageSize: SIMD2(512, 512))
        XCTAssertEqual(rope.bones.map(\.name), ["root", "tail"])
        XCTAssertEqual(rope.material, "materials/rope.json")
        XCTAssertNil(rope.bones[0].physics, "the root isn't simulated")
        let tail = try XCTUnwrap(rope.bones[1].physics)
        XCTAssertEqual(tail.kind, .spring)
        XCTAssertTrue(tail.rotation)
        XCTAssertTrue(tail.gravity)
        XCTAssertEqual(tail.rotationStiffness, 200)
        XCTAssertEqual(tail.compiledTip, SIMD3(100, 0, 0))
        XCTAssertEqual(rope.bones[1].otherProperties["ikd"], .number(2), "IK keys are kept")
        XCTAssertEqual(rope.preserved.bonePriorities, [0, 100])
        XCTAssertNotNil(PuppetPhysicsSimulation(rope))
    }
}
