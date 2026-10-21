import Foundation
import OWEModelImport
import OWESceneEditing
import XCTest

/// WE 2.8.0.42's own FBX import (capture 546, `Fixtures/FBXImport546`): `skinned2.fbx` (made by
/// `make_skinned2_fbx.py` in Blender: a two-bone rig "Rig" › root › arm, a box skinned half to
/// each bone, a static "Plinth", takes "wave" and "walk") imported in WE's editor, then Configure
/// Model: a clip of Rig|walk with root motion on "root", an attachment "hand_tip" on arm, and the
/// Gravity rotation constraint on arm. `skinned2.json` and `skinned2.mdl` are what WE wrote.
final class FBXImport546Tests: XCTestCase {
    static func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/FBXImport546"))
    }

    static func weConfig() throws -> ModelImportConfig {
        try ModelImportConfig(json: Data(contentsOf: try fixture("skinned2.json")))
    }

    // MARK: models/<name>.json

    func testWEsConfigurationIsRead() throws {
        let config = try Self.weConfig()
        XCTAssertTrue(config.normals)
        XCTAssertTrue(config.tangentSpace)
        XCTAssertEqual(config.skinning, true)
        XCTAssertEqual(config.animationMapping, ["Rig|walk": 41, "Rig|wave": 42])
        XCTAssertEqual(config.clips, [ModelImportConfig.Clip(id: 26, name: "Rig|walk (Clip 0)", animation: 41, start: 0, end: 30,
                                                             frameOffset: 0, matchLoop: true, rootMotion: "root", motionFlags: 43008)])
        XCTAssertEqual(config.clips.first?.motionFlags, ModelImportConfig.Clip.defaultMotionFlags)
        XCTAssertEqual(config.attachments, [ModelImportConfig.Attachment(id: 27, name: "hand_tip", bone: "arm")])
        XCTAssertEqual(config.events, [])
        XCTAssertEqual(config.constraintSettings["arm"]?["preset"], .string("gravityrotation"))
        let arm = try XCTUnwrap(config.constraints["arm"])
        XCTAssertEqual(arm.kind, .rigid)
        XCTAssertTrue(arm.gravity)
        XCTAssertTrue(arm.limitAngles)
        XCTAssertEqual(arm.maxAngles.z, .pi / 2, accuracy: 1e-6)
        XCTAssertEqual(config.nextID(after: 2), 1001)
    }

    /// Written back, the configuration has WE's keys and shapes (and the same settings).
    func testTheConfigurationIsWrittenInWEsShape() throws {
        let config = try Self.weConfig()
        let written = try XCTUnwrap(try JSONSerialization.jsonObject(with: try config.jsonData()) as? [String: Any])
        let original = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: try Self.fixture("skinned2.json"))) as? [String: Any])
        XCTAssertEqual(Set(written.keys), Set(original.keys))
        let editor = try XCTUnwrap(written["editor"] as? [String: Any])
        let weEditor = try XCTUnwrap(original["editor"] as? [String: Any])
        XCTAssertEqual(Set(editor.keys), Set(weEditor.keys))
        XCTAssertEqual(editor["animationmapping"] as? [String: Int], ["Rig|walk": 41, "Rig|wave": 42])
        let clip = try XCTUnwrap((editor["clips"] as? [[String: Any]])?.first)
        let weClip = try XCTUnwrap((weEditor["clips"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(clip.keys), Set(weClip.keys))
        XCTAssertEqual(clip["animation"] as? String, "Rig|walk")
        XCTAssertEqual(clip["motionflags"] as? Int, 43008)
        XCTAssertEqual(clip["rootmotion"] as? String, "root")
        let attachment = try XCTUnwrap((editor["attachments"] as? [[String: Any]])?.first)
        XCTAssertEqual(attachment as NSDictionary, (weEditor["attachments"] as? [[String: Any]])?.first as NSDictionary?)
        let constraint = try XCTUnwrap((editor["constraints"] as? [[String: Any]])?.first)
        let weConstraint = try XCTUnwrap((weEditor["constraints"] as? [[String: Any]])?.first)
        XCTAssertEqual(constraint["bone"] as? String, "arm")
        let settings = try XCTUnwrap(constraint["config"] as? [String: Any])
        let weSettings = try XCTUnwrap(weConstraint["config"] as? [String: Any])
        XCTAssertEqual(Set(settings.keys), Set(weSettings.keys))
        for (key, value) in weSettings {
            XCTAssertTrue(ModelImportConfig.sameSetting(try XCTUnwrap(SceneJSONValue(any: value)), try XCTUnwrap(SceneJSONValue(any: settings[key]))),
                          "\(key): \(value) vs \(settings[key] ?? "nil")")
        }
        XCTAssertEqual(try ModelImportConfig(json: try config.jsonData()), try ModelImportConfig(json: try config.jsonData()))
    }

    /// This project's beta-7 shape (top-level records, clips naming their animation by id,
    /// `motionflags` as one byte) still reads, and is written in WE's.
    func testTheEarlierShapeStillReads() throws {
        let json = #"{"normals": true, "tangentspace": true, "clips": [{"id": 1001, "name": "Half", "animation": 1, "start": 0, "end": 5, "frameoffset": 0, "matchloop": true, "rootmotion": "Root", "motionflags": 168, "mode": "loop"}], "events": [{"id": 1002, "name": "step", "frame": 2, "animation": 1001}], "attachments": [{"id": 1003, "name": "hat", "bone": "Tip", "origin": "0.00000 1.00000 0.00000", "angles": "0.00000 0.00000 0.00000"}], "constraints": {"Tip": {"se": true, "r": true, "rs": 40, "rf": 5, "ri": 10}}}"#
        var config = try ModelImportConfig(json: Data(json.utf8))
        XCTAssertEqual(config.clips.first?.motionFlags, 0xA800)
        XCTAssertEqual(config.clips.first?.animation, 1)
        XCTAssertEqual(config.events.first?.animation, 1001)
        XCTAssertEqual(config.attachments.first?.origin, SIMD3(0, 1, 0))
        XCTAssertEqual(config.constraints["Tip"]?.rotationStiffness, 40)
        config.animationMapping = ["Wave": 1]
        let editor = try XCTUnwrap((try JSONSerialization.jsonObject(with: try config.jsonData()) as? [String: Any])?["editor"] as? [String: Any])
        XCTAssertEqual((editor["clips"] as? [[String: Any]])?.first?["animation"] as? String, "Wave")
        XCTAssertEqual((editor["events"] as? [[String: Any]])?.first?["clip"] as? Int, 1001)
        XCTAssertEqual((editor["constraints"] as? [[String: Any]])?.first?["bone"] as? String, "Tip")
    }

    // MARK: The .mdl

    func testSkinned2CompilesToWEsModel() throws {
        let source = try ModelFileLoader.load(contentsOf: try Self.fixture("skinned2.fbx"))
        let output = try ModelCompiler.compile(source, config: try Self.weConfig(), folder: "skinned2")
        let ours = try MDLTestReader.read(output.mdl)
        let theirs = try MDLTestReader.read(try Data(contentsOf: try Self.fixture("skinned2.mdl")))
        XCTAssertEqual(ours.tag, theirs.tag)
        XCTAssertEqual(ours.legacyFormat, theirs.legacyFormat)
        XCTAssertEqual(ours.sections, ["MDLS0004", "MDAT0001", "MDLA0006"])
        XCTAssertEqual(ours.sections, theirs.sections)

        // Meshes: the skinned box and the static Plinth, bound to its own node.
        XCTAssertEqual(ours.meshes.count, 2)
        XCTAssertEqual(ours.meshes.count, theirs.meshes.count)
        for (index, (a, b)) in zip(ours.meshes, theirs.meshes).enumerated() {
            XCTAssertEqual(a.materials, b.materials, "mesh \(index)")
            XCTAssertEqual(a.format, b.format, "mesh \(index)")
            XCTAssertEqual(a.indices, b.indices, "mesh \(index)")
            XCTAssertEqual(a.vertices.count, b.vertices.count, "mesh \(index)")
            let difference = WEDefaultProjectModelTests.largestDifference(a.vertices, b.vertices, stride: 80, format: a.format)
            XCTAssertLessThan(difference.value, 1e-4, "mesh \(index): \(difference.attribute)")
        }

        // Bones: RootNode, Rig (flag 0), Plinth, root, arm; the bind pose; the constraint as
        // WE compiles it.
        XCTAssertEqual(ours.bones.map(\.name), ["RootNode", "Rig", "Plinth", "root", "arm"])
        XCTAssertEqual(ours.bones.map(\.name), theirs.bones.map(\.name))
        XCTAssertEqual(ours.bones.map(\.flags), theirs.bones.map(\.flags))
        XCTAssertEqual(ours.bones.map(\.parent), theirs.bones.map(\.parent))
        for (a, b) in zip(ours.bones, theirs.bones) {
            for (x, y) in zip(a.matrix, b.matrix) { XCTAssertEqual(x, y, accuracy: 1e-4, a.name) }
            XCTAssertEqual(try Self.properties(a.properties), try Self.properties(b.properties), a.name)
        }
        XCTAssertEqual(ours.boneBoxes.count, theirs.boneBoxes.count)
        for (a, b) in zip(ours.boneBoxes, theirs.boneBoxes) {
            for (x, y) in zip(a.half + a.matrix, b.half + b.matrix) { XCTAssertEqual(x, y, accuracy: 1e-4) }
        }
        XCTAssertEqual(ours.attachments.map(\.bone), theirs.attachments.map(\.bone))
        XCTAssertEqual(ours.attachments.map(\.name), theirs.attachments.map(\.name))
        XCTAssertEqual(ours.attachments.map(\.matrix), theirs.attachments.map(\.matrix))

        // Animations: ids 41 and 42 from animationmapping, the clip 26 with 0xAC01, Assimp's keys
        // as WE samples them.
        XCTAssertEqual(ours.animations.map(\.id), [41, 42, 26])
        XCTAssertEqual(ours.animations.map(\.id), theirs.animations.map(\.id))
        XCTAssertEqual(ours.animations.map(\.name), theirs.animations.map(\.name))
        XCTAssertEqual(ours.animations.map(\.mode), theirs.animations.map(\.mode))
        XCTAssertEqual(ours.animations.map(\.fps), theirs.animations.map(\.fps))
        XCTAssertEqual(ours.animations.map(\.frames), theirs.animations.map(\.frames))
        XCTAssertEqual(ours.animations.map(\.flags), [0, 0, 0xAC01])
        XCTAssertEqual(ours.animations.map(\.flags), theirs.animations.map(\.flags))
        for (a, b) in zip(ours.animations, theirs.animations) {
            XCTAssertEqual(a.reference.map { [Int($0.source), Int($0.start), Int($0.end), Int($0.offset), Int($0.rootBone)] },
                           b.reference.map { [Int($0.source), Int($0.start), Int($0.end), Int($0.offset), Int($0.rootBone)] }, a.name)
            XCTAssertEqual(a.events.count, b.events.count, a.name)
            XCTAssertEqual(a.tracks.count, b.tracks.count, a.name)
            for (bone, (x, y)) in zip(a.tracks, b.tracks).enumerated() {
                for (index, (p, q)) in zip(x, y).enumerated() {
                    XCTAssertEqual(p, q, accuracy: 1e-3, "\(a.name) bone \(bone) frame \(index / 9) value \(index % 9)")
                }
            }
            for (x, y) in zip(a.bounds, b.bounds) { XCTAssertEqual(x, y, accuracy: 0.05, a.name) }
        }
        // The walk's root at frame 10 is the file's key 11: Blender wrote frame 11's time a tick
        // early, and WE truncates key times to frames.
        let walkRoot = ours.animations[0].tracks[3]
        XCTAssertEqual(walkRoot[10 * 9], theirs.animations[0].tracks[3][10 * 9], accuracy: 1e-5)
    }

    static func properties(_ json: String) throws -> [String: SceneJSONValue] {
        guard !json.isEmpty else { return [:] }
        guard case .object(let object)? = SceneJSONValue(any: try JSONSerialization.jsonObject(with: Data(json.utf8))) else { return [:] }
        return object.mapValues { value in
            if case .number(let n) = value { return .number(Double(Float(n))) }
            return value
        }
    }
}
