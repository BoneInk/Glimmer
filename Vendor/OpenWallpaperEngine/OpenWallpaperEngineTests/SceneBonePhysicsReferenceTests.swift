import XCTest
import simd
@testable import OpenWallpaperEngine

/// WE's own bone physics (WE 2.8.0.42, captured in its editor preview; docs/models-plan.md
/// §2.14): a rope puppet built in the Puppet Warp editor, its `tail` a spring bone, variant A
/// rotating under gravity, B the "Bouncy position" preset. The origin script moves the layer
/// 200 px right at 2 s and back at 5 s, gives the tail a 45° angular impulse at 6 s and resets it
/// at 8 s, logging the tail's world matrix every frame. The rig is replayed with the logged
/// frame times: the script's move reaches the next frame's update, its calls land after the
/// frame's update (WE's object loop runs before the scripts).
final class SceneBonePhysicsReferenceTests: XCTestCase {
    struct Line {
        var time: Float
        var delta: Float
        var x: Float
        var axis: SIMD2<Float>
        var origin: SIMD2<Float>
        var localAngle: Float
    }

    static func log(_ variant: String) throws -> [Line] {
        let text = String(decoding: try Fixtures.data("Models/BonePhysics/rope-\(variant)-log.txt"), as: UTF8.self)
        return text.split(separator: "\n").compactMap { row in
            let f = row.split(separator: " ").dropFirst().compactMap { Float($0) }
            guard f.count == 10 else { return nil }
            return Line(time: f[0], delta: f[1], x: f[2], axis: SIMD2(f[3], f[4]), origin: SIMD2(f[7], f[8]), localAngle: f[9])
        }
    }

    /// The tail's world matrix per logged frame, replayed.
    static func replay(_ variant: String) throws -> (log: [Line], worlds: [simd_float4x4], locals: [simd_float4x4]) {
        let model = try MDLReader.read(Fixtures.data("Models/BonePhysics/rope-\(variant).mdl"))
        let animator = ScenePuppetAnimator(skeleton: try XCTUnwrap(model.skeleton), clips: [], layers: [])
        let tail = try XCTUnwrap(animator.skeleton.index(named: "tail"))
        let lines = try log(variant)
        var x: Float = 960
        var impulsed = false, reset = false
        var worlds: [simd_float4x4] = [], locals: [simd_float4x4] = []
        for line in lines {
            let object = ScenePuppetTests.translation(SIMD3(x, 540, 0))
            animator.advance(delta: line.delta, values: EmptySceneValues(), objectWorld: object)
            worlds.append(object * animator.worlds[tail])
            locals.append(animator.locals[tail])
            x = line.x
            if line.time >= 6, !impulsed {
                impulsed = true
                animator.perform(.physicsImpulse(bone: tail, linear: .zero, angularDegrees: SIMD3(0, 0, 45)))
            }
            if line.time >= 8, !reset {
                reset = true
                animator.perform(.resetPhysics(bone: tail))
            }
        }
        return (lines, worlds, locals)
    }

    /// Every logged frame of both variants: the tail's world axis and origin as WE's. A: gravity
    /// sags the 100-unit tip to about −30.7°, the move swings it to about −71.8°, the impulse adds
    /// 45° in a frame, the reset snaps it to its bind pose. B: 70 % of the move stays behind and
    /// the first frame's spring velocity already closes some of it (1033.6 of 1160). The local
    /// matrix never changes (`getLocalBoneAngles` logs 0): the physics is in the model matrix.
    func testReplayMatchesWEsLog() throws {
        for variant in ["A", "B"] {
            let (lines, worlds, locals) = try Self.replay(variant)
            XCTAssertGreaterThan(lines.count, 500, variant)
            let bind = try XCTUnwrap(locals.first)
            for (index, (line, world)) in zip(lines, worlds).enumerated() {
                let axis = SIMD2(world.columns.0.x, world.columns.0.y), origin = SIMD2(world.columns.3.x, world.columns.3.y)
                XCTAssertLessThan(simd_length(axis - line.axis), 3e-4, "\(variant) \(line.time): \(axis) vs \(line.axis)")
                XCTAssertLessThan(simd_length(origin - line.origin), 0.02, "\(variant) \(line.time): \(origin) vs \(line.origin)")
                XCTAssertEqual(line.localAngle, 0)
                XCTAssertEqual(locals[index], bind, "\(variant) \(line.time)")
            }
        }
        // Spot checks from the capture's README.
        let (a, aWorlds, _) = try Self.replay("A")
        let at = { (time: Float) in aWorlds[a.firstIndex { $0.time >= time }!] }
        XCTAssertEqual(atan2(at(1.9).columns.0.y, at(1.9).columns.0.x) * 180 / .pi, -30.7, accuracy: 0.1)
        XCTAssertEqual(at(2.067).columns.0.x, 0.3127, accuracy: 2e-4)
        let (b, bWorlds, _) = try Self.replay("B")
        XCTAssertEqual(bWorlds[b.firstIndex { $0.time >= 2.02 }!].columns.3.x, 1033.61, accuracy: 0.01)
    }
}
