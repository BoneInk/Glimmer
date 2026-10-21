import WEFormat
import XCTest
import simd
@testable import OWESceneEditing

/// The writer and the editor's reader agree on every field the editor holds; the app's own
/// `MDLReader` reads the same bytes (OpenWallpaperEngineTests/EditorPuppetMDLTests).
final class PuppetMDLRoundTripTests: XCTestCase {
    /// A rig with everything the writer writes: two clips (one cut from the other with root
    /// motion), events, physics, kept properties, a rest pose, attachments and a reference pose.
    static func richDocument() -> PuppetDocument {
        var document = PuppetFixtures.twoBoneStrip()
        document.addBone(named: "tip", parent: 1, head: SIMD2(0, 90), angle: .pi / 2)
        document.weights[document.weights.count - 1] = [PuppetWeight(bone: 1, weight: 0.75), PuppetWeight(bone: 2, weight: 0.25)]
        var physics = PuppetBonePhysics(preset: .floppy)
        physics.limitAngles = true
        physics.minAngles = SIMD3(0, 0, -0.3)
        physics.maxAngles = SIMD3(0, 0, 0.3)
        document.bones[2].physics = physics
        document.bones[0].otherProperties = ["ik": .bool(false), "note": .string("kept")]
        var rest = document.bones[1].local
        rest.euler.z = 0.25
        document.bones[1].rest = rest
        let wave = document.addClip(named: "wave", fps: 24, frames: 12, mode: .mirror)
        var turned = document.bones[1].local
        turned.euler.z = 0.8
        turned.scale = SIMD3(1.1, 0.9, 1)
        document.clips[wave].tracks[1].keys = [0: document.bones[1].local, 6: turned, 12: document.bones[1].local]
        document.clips[wave].tracks[0].keys = [3: PuppetTransform(translation: SIMD3(5, -100, 0), euler: SIMD3(0, 0, .pi / 2),
                                                                  scale: SIMD3(repeating: 1))]
        document.clips[wave].events = [PuppetClipEvent(frame: 6, name: "peak")]
        let cut = document.addClip(named: "wave start", fps: 24, frames: 6, mode: .single)
        document.clips[cut].tracks[1].keys = [0: turned]
        document.clips[cut].rootMotion = PuppetClip.RootMotion(sourceClip: wave, startFrame: 0, endFrame: 6, frameOffset: 0,
                                                               rootBone: 0, matchLoop: false, positionX: true, rotationY: true)
        document.layers = [PuppetAnimationLayer(id: 1, name: "Wave", clipID: document.clips[wave].id)]
        let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        document.preserved.attachments = [.init(bone: 2, name: "hand", matrix: identity.enumerated().map { $0.offset == 12 ? 4 : $0.element })]
        document.preserved.referencePose = document.bones.map { _ in identity }
        document.preserved.bonePriorities = [0, 100, 200]
        return document
    }

    func testWriterAndReaderAgree() throws {
        let document = Self.richDocument()
        let data = try PuppetMDLWriter.write(document)
        let read = try PuppetMDLReader.read(data, imageSize: document.imageSize, sourcePath: "models/strip.mdl")
        XCTAssertEqual(read.material, document.material)
        XCTAssertEqual(read.mesh, document.mesh)
        XCTAssertEqual(read.weights.count, document.weights.count)
        for (a, b) in zip(read.weights, document.weights) {
            XCTAssertEqual(a.map(\.bone), b.map(\.bone))
            for (x, y) in zip(a, b) { XCTAssertEqual(x.weight, y.weight, accuracy: 1e-6) }
        }
        XCTAssertEqual(read.bones.map(\.name), ["lower", "upper", "tip"])
        XCTAssertEqual(read.bones.map(\.parent), [nil, 0, 1])
        for (a, b) in zip(read.bones, document.bones) {
            XCTAssertTrue(a.local.isClose(to: b.local, tolerance: 1e-5), "\(a.name): \(a.local) vs \(b.local)")
            XCTAssertEqual(a.rest == nil, b.rest == nil, a.name)
            if let ar = a.rest, let br = b.rest { XCTAssertTrue(ar.isClose(to: br, tolerance: 1e-5)) }
            XCTAssertEqual(a.flags, 1)
        }
        XCTAssertEqual(read.bones[0].otherProperties, ["ik": .bool(false), "note": .string("kept")])
        XCTAssertNil(read.bones[0].physics)
        var expectedPhysics = document.bones[2].physics!
        expectedPhysics.compiledTip = expectedPhysics.tip(childDistance: nil)
        XCTAssertEqual(read.bones[2].physics, expectedPhysics)
        XCTAssertEqual(read.clips.count, 2)
        let rig = PuppetRig(document), readRig = PuppetRig(read)
        for (index, (a, b)) in zip(read.clips, document.clips).enumerated() {
            XCTAssertEqual(a.id, b.id)
            XCTAssertEqual(a.name, b.name)
            XCTAssertEqual(a.mode, b.mode)
            XCTAssertEqual(a.fps, b.fps)
            XCTAssertEqual(a.frames, b.frames)
            XCTAssertEqual(a.events, b.events)
            XCTAssertEqual(a.flags, b.flags)
            XCTAssertEqual(a.tracks.map(\.isEmpty), b.tracks.map(\.isEmpty), "disabled tracks stay disabled")
            for frame in 0...a.frames {
                let p = readRig.pose(clip: index, frame: Float(frame)), q = rig.pose(clip: index, frame: Float(frame))
                for bone in p.indices {
                    XCTAssertEqual(simd_distance(p[bone].translation, q[bone].translation), 0, accuracy: 1e-3)
                    XCTAssertEqual(abs(simd_dot(p[bone].rotation.vector, q[bone].rotation.vector)), 1, accuracy: 1e-5)
                }
            }
        }
        XCTAssertEqual(read.clips[1].rootMotion, document.clips[1].rootMotion)
        XCTAssertEqual(read.clips[1].flags, 0x1 | 0x800 | 0x8000)
        XCTAssertEqual(read.preserved.attachments, document.preserved.attachments)
        XCTAssertEqual(read.preserved.referencePose, document.preserved.referencePose)
        XCTAssertEqual(read.preserved.bonePriorities, [0, 100, 200])
        XCTAssertTrue(read.layers.isEmpty, "layers live in scene.json, not the model")
        // Writing what was read gives the same bytes.
        var again = read
        again.layers = document.layers
        XCTAssertEqual(try PuppetMDLWriter.write(again), data)
    }

    func testTheBytesAreLaidOutAsWEReadsThem() throws {
        let document = PuppetFixtures.twoBoneStrip()
        let data = [UInt8](try PuppetMDLWriter.write(document))
        var r = MDLByteReader(data)
        XCTAssertEqual(try r.cstring(), "MDLV0023")
        XCTAssertEqual(try r.u32(), 0x1800009, "the legacy format")
        XCTAssertEqual(try r.u32(), 1, "one material a mesh")
        XCTAssertEqual(try r.u32(), 1, "one mesh")
        XCTAssertEqual(try r.cstring(), "materials/strip.json")
        XCTAssertEqual(try r.u32(), 0, "u16 indices, no extras")
        XCTAssertEqual(try r.f32s(6), [-10, -100, 0, 10, 100, 0], "the mesh's box")
        XCTAssertEqual(try r.u32(), 0x1800009, "position, blend indices, blend weights, texture coordinate")
        let vertices = try r.blob("vertices")
        XCTAssertEqual(vertices.count, 52 * document.mesh.vertices.count)
        let first = MDLReader.floats(vertices.prefix(52))
        XCTAssertEqual(Array(first[0..<3]), [-10, -100, 0])
        XCTAssertEqual(Array(first[7..<11]), [1, 0, 0, 0], "weights after the four indices")
        XCTAssertEqual(Array(first[11..<13]), [0, 1], "the bottom-left corner's texture coordinate (v down)")
        let indices = try r.blob("indices")
        XCTAssertEqual(indices.count, 2 * 3 * document.mesh.triangles.count)
        XCTAssertEqual(try r.u8(), 0)
        XCTAssertEqual(try r.u8(), 0)
        XCTAssertEqual(try r.u32(), 0, "no groups")
        XCTAssertEqual(try r.cstring(), "MDLS0004")
        let end = Int(try r.u32())
        XCTAssertEqual(try r.u32(), 2, "two bones")
        XCTAssertEqual(try r.cstring(), "lower")
        XCTAssertEqual(try r.u32(), 1)
        XCTAssertEqual(try r.u32(), 0xFFFF_FFFF)
        XCTAssertEqual(try r.u32(), 64)
        let matrix = try r.f32s(16)
        XCTAssertEqual(matrix[12], 0, accuracy: 1e-5)
        XCTAssertEqual(matrix[13], -100, accuracy: 1e-5, "translation in elements 12…14")
        XCTAssertEqual(try r.cstring(), "", "no properties")
        r.seek(to: end)
        XCTAssertEqual(try r.cstring(), "", "no clips: the empty tag ends the file")
        XCTAssertEqual(r.offset, data.count)
    }

    func testUnfinishedPuppetsAreNotWritten() {
        var document = PuppetFixtures.twoBoneStrip()
        document.weights[0] = []
        XCTAssertThrowsError(try PuppetMDLWriter.write(document)) { error in
            XCTAssertEqual(error as? PuppetMDLWriter.WriteError, .problems([.unweightedVertices(1)]))
        }
        XCTAssertThrowsError(try PuppetMDLWriter.write(PuppetDocument.new(imageSize: SIMD2(10, 10), material: "m")))
    }

    func testWideMeshesUse32BitIndices() throws {
        var document = PuppetFixtures.twoBoneStrip()
        let extra = 70_000
        document.mesh.vertices += Array(repeating: PuppetVertex(position: .zero, uv: SIMD2(0.5, 0.5)), count: extra)
        document.weights += Array(repeating: [PuppetWeight(bone: 0, weight: 1)], count: extra)
        let last = UInt32(document.mesh.vertices.count - 1)
        document.mesh.triangles.append(SIMD3(0, 1, last))
        let read = try PuppetMDLReader.read(try PuppetMDLWriter.write(document), imageSize: document.imageSize)
        XCTAssertEqual(read.mesh.triangles.last, SIMD3(0, 1, last))
    }

    // MARK: Overlay and bake

    func testPuppetsLiveInTheOverlayWithoutChangingTheScene() throws {
        var overlay = SceneEditOverlay()
        let digest = overlay.digest
        overlay.setPuppet(PuppetFixtures.twoBoneStrip(), of: 10)
        XCTAssertFalse(overlay.isEmpty)
        XCTAssertFalse(overlay.hasSceneEdits)
        XCTAssertEqual(overlay.digest, digest, "puppets don't reload the running scene")
        XCTAssertEqual(try overlay.applied(to: Fixtures.sceneData), Fixtures.sceneData)
        let decoded = try SceneEditOverlay.decoded(from: overlay.encoded())
        XCTAssertEqual(decoded.puppet(of: 10), overlay.puppet(of: 10))
        // An overlay from before puppets still reads.
        XCTAssertNil(try SceneEditOverlay.decoded(from: Data(#"{"version": 1, "objects": {}}"#.utf8)).puppets)
    }

    @MainActor
    func testPuppetEditsAreUndoable() {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let session = SceneEditSession(outline: try! SceneOutline(sceneData: Fixtures.sceneData), undoManager: undoManager)
        var changes = 0
        session.onChange = { _ in changes += 1 }
        let document = PuppetFixtures.twoBoneStrip()
        session.setPuppet(document, of: 10, actionName: "Create Puppet")
        var moved = document
        moved.moveVertex(0, to: SIMD2(-12, -100), textureLayout: true)
        session.setPuppet(moved, of: 10, actionName: "Move Vertices")
        XCTAssertEqual(session.puppet(of: 10), moved)
        session.undo()
        XCTAssertEqual(session.puppet(of: 10), document)
        session.undo()
        XCTAssertNil(session.puppet(of: 10))
        session.redo()
        XCTAssertEqual(session.puppet(of: 10), document)
        XCTAssertEqual(changes, 5)
        session.revert(to: SceneEditOverlay(), actionName: "Revert to Saved")
        XCTAssertNil(session.puppet(of: 10), "Revert drops the editor's puppets")
    }

    func testBakeWritesTheRigAModelAndTheLayerReferences() throws {
        var overlay = SceneEditOverlay()
        let document = Self.richDocument()
        overlay.setPuppet(document, of: 10)
        let existing = ["models/bg.json": Data(#"{"material": "materials/bg.json", "fullscreen": false}"#.utf8),
                        "models/bg_puppet_10.json": Data("{}".utf8)]
        let result = try PuppetSceneBake.bake(overlay, into: Fixtures.sceneData, readFile: { existing[$0] })
        XCTAssertEqual(Set(result.files.keys), ["models/bg_puppet_10_2.json", "models/bg_puppet_10_2.mdl"],
                       "a name the wallpaper already has isn't reused")
        let model = try XCTUnwrap(JSONSerialization.jsonObject(with: result.files["models/bg_puppet_10_2.json"]!) as? [String: Any])
        XCTAssertEqual(model["puppet"] as? String, "models/bg_puppet_10_2.mdl")
        XCTAssertEqual(model["material"] as? String, "materials/bg.json")
        XCTAssertEqual(model["fullscreen"] as? Bool, false, "the model's other keys stay")
        let read = try PuppetMDLReader.read(result.files["models/bg_puppet_10_2.mdl"]!, imageSize: document.imageSize)
        XCTAssertEqual(read.mesh, document.mesh)
        let object = try Fixtures.object(10, in: result.scene)
        XCTAssertEqual(object["image"] as? String, "models/bg_puppet_10_2.json")
        let layers = try XCTUnwrap(object["animationlayers"] as? [[String: Any]])
        XCTAssertEqual(layers.count, 1)
        XCTAssertEqual((layers[0]["animation"] as? NSNumber)?.uint64Value, document.clips[0].id)
        XCTAssertEqual(layers[0]["blend"] as? Double, 1)
        XCTAssertEqual(layers[0]["visible"] as? Bool, true)
        XCTAssertEqual(try Fixtures.object(13, in: result.scene)["image"] as? String, "models/logo.json", "other layers stay")
    }

    func testABoundLayerFieldKeepsItsBinding() throws {
        let authored = SceneJSONValue(any: ["animation": 7, "id": 3, "name": "Idle",
                                            "blend": ["user": "idleweight", "value": 0.5]] as [String: Any])!
        var layer = try XCTUnwrap(PuppetAnimationLayer(json: authored, fallbackID: 0))
        XCTAssertEqual(layer.blend, 0.5)
        XCTAssertEqual(layer.clipID, 7)
        layer.blend = 0.8
        let blend = try XCTUnwrap(layer.json["blend"] as? [String: Any])
        XCTAssertEqual(blend["user"] as? String, "idleweight")
        XCTAssertEqual(blend["value"] as? Double, 0.8)
    }
}
