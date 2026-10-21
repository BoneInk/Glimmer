import XCTest
import simd
import OWESceneEditing
@testable import OpenWallpaperEngine

/// The Wallpaper Editor's puppets as the player reads them: the editor's writer (`PuppetMDLWriter`)
/// is read field for field by the app's `MDLReader`, and the editor's preview poses, blends and
/// simulates as the player does (`SceneAnimationLayerStack`, `SceneBonePhysics`).
final class EditorPuppetMDLTests: XCTestCase {
    /// A vertical strip, two bones up its middle, a clip turning the upper bone, a second cut from
    /// it with root motion, the upper bone a spring under sideways gravity, a rest pose.
    static func document() -> PuppetDocument {
        var document = PuppetDocument.new(imageSize: SIMD2(20, 200), material: "materials/strip.json")
        document.bones = []
        var vertices: [PuppetVertex] = []
        for row in 0...10 {
            let y = -100 + 20 * Float(row)
            for x: Float in [-10, 10] {
                vertices.append(PuppetVertex(position: SIMD2(x, y), uv: document.textureCoordinate(of: SIMD2(x, y))))
            }
        }
        var triangles: [SIMD3<UInt32>] = []
        for row in 0..<10 {
            let a = UInt32(2 * row)
            triangles += [SIMD3(a, a + 1, a + 3), SIMD3(a, a + 3, a + 2)]
        }
        document.replaceMesh(PuppetMesh(vertices: vertices, triangles: triangles))
        document.addBone(named: "lower", parent: nil, head: SIMD2(0, -100), angle: .pi / 2)
        document.addBone(named: "upper", parent: 0, head: SIMD2(0, 0), angle: .pi / 2)
        document.weights = PuppetAutoWeights.compute(document, method: .heat)
        var physics = PuppetBonePhysics()
        physics.gravity = true
        physics.gravityDirection = SIMD3(1, 0, 0)
        document.bones[1].physics = physics
        let wave = document.addClip(named: "wave", fps: 30, frames: 20, mode: .mirror)
        var turned = document.bones[1].local
        turned.euler.z = 0.9
        document.clips[wave].tracks[1].keys = [0: document.bones[1].local, 20: turned]
        document.clips[wave].events = [PuppetClipEvent(frame: 10, name: "half")]
        let cut = document.addClip(named: "cut", fps: 30, frames: 10)
        document.clips[cut].tracks[0].keys = [0: document.bones[0].local]
        document.clips[cut].rootMotion = PuppetClip.RootMotion(sourceClip: wave, startFrame: 0, endFrame: 10, rootBone: 0,
                                                               matchLoop: true, positionX: true, rotationY: true)
        return document
    }

    func testTheAppReadsWhatTheEditorWrites() throws {
        let document = Self.document()
        let model = try MDLReader.read(try PuppetMDLWriter.write(document))
        XCTAssertEqual(model.tag, "MDLV0023")
        XCTAssertEqual(model.trailingByteCount, 0)
        XCTAssertEqual(model.sections.map(\.tag), ["MDLS0004", "MDLA0006"])
        XCTAssertTrue(model.sections.allSatisfy { $0.parsedEnd == $0.end && !$0.skipped })
        let mesh = try XCTUnwrap(model.meshes.first)
        XCTAssertEqual(model.meshes.count, 1)
        XCTAssertEqual(mesh.materials, ["materials/strip.json"])
        XCTAssertEqual(mesh.format.rawValue, 0x1800009)
        XCTAssertTrue(mesh.isSkinned)
        XCTAssertEqual(mesh.vertexCount, document.mesh.vertices.count)
        XCTAssertEqual(mesh.indices, document.mesh.triangles.flatMap { [$0.x, $0.y, $0.z] })
        let positions = try XCTUnwrap(mesh.floatValues(.position))
        let uvs = try XCTUnwrap(mesh.floatValues(.texCoord))
        let bones = try XCTUnwrap(mesh.unsignedValues(.blendIndices))
        let weights = try XCTUnwrap(mesh.floatValues(.blendWeights))
        for (index, vertex) in document.mesh.vertices.enumerated() {
            XCTAssertEqual(Array(positions[(3 * index)..<(3 * index + 3)]), [vertex.position.x, vertex.position.y, 0])
            XCTAssertEqual(Array(uvs[(2 * index)..<(2 * index + 2)]), [vertex.uv.x, vertex.uv.y])
            let entries = document.weights[index]
            for slot in 0..<4 {
                XCTAssertEqual(bones[4 * index + slot], slot < entries.count ? UInt32(entries[slot].bone) : 0)
                XCTAssertEqual(weights[4 * index + slot], slot < entries.count ? entries[slot].weight : 0)
            }
            XCTAssertEqual(weights[(4 * index)..<(4 * index + 4)].reduce(0, +), 1, accuracy: 1e-5, "the player's weights sum to 1")
        }
        let skeleton = try XCTUnwrap(model.skeleton)
        XCTAssertEqual(skeleton.version, 4)
        XCTAssertEqual(skeleton.bones.map(\.name), ["lower", "upper"])
        XCTAssertEqual(skeleton.bones.map(\.parentIndex), [nil, 0])
        for (bone, edited) in zip(skeleton.bones, document.bones) {
            XCTAssertEqual(bone.flags, 1)
            XCTAssertTrue(simd_almost_equal_elements(bone.matrix, edited.local.matrix, 1e-5), bone.name)
        }
        XCTAssertTrue(simd_almost_equal_elements(skeleton.bindPoseWorldMatrices[1], document.bindWorlds[1], 1e-4))
        XCTAssertNil(MDLBonePhysics(properties: skeleton.bones[0].properties))
        let physics = try XCTUnwrap(MDLBonePhysics(properties: skeleton.bones[1].properties))
        XCTAssertTrue(physics.isSimulated)
        XCTAssertEqual(physics.flags, [.spring, .rotation, .gravity, .lockRotationX, .lockRotationY])
        XCTAssertEqual(physics.rotationStiffness, 200)
        XCTAssertEqual(physics.rotationInertia, 0.7, accuracy: 1e-6)
        XCTAssertEqual(physics.gravityDirection, SIMD3(1, 0, 0))
        XCTAssertEqual(physics.mass, 20)
        XCTAssertEqual(physics.tip, SIMD3(100, 0, 0), "a leaf's tip: 100 along x, as WE's compiler makes it")
        let clips = try XCTUnwrap(model.animations)
        XCTAssertEqual(model.animationsVersion, 6)
        XCTAssertEqual(clips.map(\.id), document.clips.map(\.id))
        XCTAssertEqual(clips.map(\.name), ["wave", "cut"])
        XCTAssertEqual(clips.map(\.mode), [.mirror, .loop])
        XCTAssertEqual(clips.map(\.fps), [30, 30])
        XCTAssertEqual(clips.map(\.frames), [20, 10])
        XCTAssertEqual(clips[0].events, [MDLAnimation.Event(frame: 10, name: "half")])
        XCTAssertEqual(clips[1].flags, MDLAnimation.Flag.reference | MDLAnimation.Flag.matchLoop | MDLAnimation.Flag.rootPositionX
                       | MDLAnimation.Flag.rootRotationY)
        XCTAssertEqual(clips[1].reference, MDLAnimation.Reference(animation: 0, startFrame: 0, endFrame: 10, frameOffset: 0, rootBone: 0))
        XCTAssertEqual(clips[0].boneTracks.map(\.isDisabled), [true, false], "a bone without keys keeps the pose below")
        XCTAssertEqual(clips[1].boneTracks.map(\.isDisabled), [false, true])
        let rest = document.restLocals
        for (clipIndex, clip) in clips.enumerated() {
            for (bone, track) in clip.boneTracks.enumerated() where !track.isDisabled {
                XCTAssertEqual(track.samples.count, 9 * (Int(clip.frames) + 1))
                for frame in 0...Int(clip.frames) {
                    let expected = document.clips[clipIndex].transform(of: bone, at: Float(frame), rest: rest[bone]).samples
                    let pose = track.pose(at: frame)
                    let read = [pose.position.x, pose.position.y, pose.position.z, pose.euler.x, pose.euler.y, pose.euler.z,
                                pose.scale.x, pose.scale.y, pose.scale.z]
                    for (a, b) in zip(read, expected) { XCTAssertEqual(a, b, accuracy: 1e-6) }
                }
            }
        }
    }

    /// The editor's preview of the layers is the player's pose.
    func testThePreviewPosesAsThePlayerDoes() throws {
        let document = Self.document()
        let model = try MDLReader.read(try PuppetMDLWriter.write(document))
        let skeleton = SceneSkeleton(try XCTUnwrap(model.skeleton))
        let clips = try XCTUnwrap(model.animations)
        let layers = [PuppetAnimationLayer(id: 1, name: "wave", clipID: clips[0].id, blendIn: true, blendTime: 0.2),
                      PuppetAnimationLayer(id: 2, name: "add", clipID: clips[0].id, additive: true, rate: 0.5, blend: 0.4)]
        var stack = SceneAnimationLayerStack(skeleton: skeleton, clips: clips)
        for (index, layer) in layers.enumerated() {
            stack.insert(SceneAnimationLayer(key: layer.id, name: layer.name, clip: 0, animation: clips[0], additive: layer.additive,
                                             blendIn: layer.blendIn, blendOut: layer.blendOut, blendTime: layer.blendTime,
                                             rate: layer.rate, blend: layer.blend))
            XCTAssertEqual(stack.layers.count, index + 1)
        }
        var preview = PuppetLayerPlayer(rig: PuppetRig(document), layers: layers)
        var update = SceneAnimationLayerUpdate()
        for _ in 0..<50 {
            let player = stack.evaluate(delta: 1 / 30, update: &update)
            let edited = preview.evaluate(delta: 1 / 30)
            for (a, b) in zip(player, edited) {
                XCTAssertEqual(simd_distance(a.translation, b.translation), 0, accuracy: 1e-3)
                XCTAssertEqual(abs(simd_dot(a.rotation.vector, b.rotation.vector)), 1, accuracy: 1e-5)
                XCTAssertEqual(simd_distance(a.scale, b.scale), 0, accuracy: 1e-5)
            }
            // The skinned mesh too: the palette is the player's `world · inverseBind`.
            let palette = skeleton.palette(worlds: skeleton.worlds(locals: player.map(\.matrix)))
            let rig = PuppetRig(document)
            let editedPalette = rig.palette(worlds: rig.worlds(edited))
            for (a, b) in zip(palette, editedPalette) { XCTAssertTrue(simd_almost_equal_elements(a, b, 1e-3)) }
        }
    }

    /// The editor's live physics preview steps as the player's bone physics.
    func testThePhysicsPreviewStepsAsThePlayerDoes() throws {
        let document = Self.document()
        let model = try MDLReader.read(try PuppetMDLWriter.write(document))
        let mdlSkeleton = try XCTUnwrap(model.skeleton)
        let skeleton = SceneSkeleton(mdlSkeleton)
        var player = try XCTUnwrap(SceneBonePhysics(mdlSkeleton))
        var preview = try XCTUnwrap(PuppetPhysicsSimulation(document))
        let locals = skeleton.restLocal
        var previous: [simd_float4x4]?
        for step in 0..<180 {
            // Moved 40 px right at frame 30, as a drag in the preview does.
            let x: Float = step < 30 ? 0 : 40
            let world = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(x, 0, 0, 1)))
            let frame = previous.map { SceneBonePhysics.Frame(delta: 1 / 60, objectWorld: world, previousWorlds: $0) }
            let models = player.worlds(locals: locals, skeleton: skeleton, frame: frame)
            previous = models.map { world * $0 }
            let edited = preview.step(locals: locals, parents: document.bones.map(\.parent), delta: 1 / 60, objectWorld: world)
            for (a, b) in zip(models, edited) { XCTAssertTrue(simd_almost_equal_elements(a, b, 1e-3), "frame \(step)") }
        }
        XCTAssertNotEqual(PuppetMath.angle(of: previous![1]), .pi / 2, accuracy: 1e-3, "gravity bent the upper bone")
    }

    /// Rigs that came with wallpapers open in the editor and save to what the player reads the
    /// same: the mesh, bones and clips of each fixture, written back by the editor.
    func testExistingRigsSaveBackAsThePlayerReadsThem() throws {
        for name in ["BonePhysics/rope-A.mdl", "v13-puppet.mdl", "mg5-puppet-blendshape.mdl", "v21-skeleton.mdl"] {
            let data = try Fixtures.data("Models/\(name)")
            let original = try MDLReader.read(data)
            let document = try PuppetMDLReader.read(data, imageSize: SIMD2(512, 512))
            guard document.problems.isEmpty else { continue }
            let saved = try MDLReader.read(try PuppetMDLWriter.write(document))
            let a = try XCTUnwrap(original.meshes.first), b = try XCTUnwrap(saved.meshes.first)
            XCTAssertEqual(a.vertexCount, b.vertexCount, name)
            XCTAssertEqual(a.indices, b.indices, name)
            let positionsA = a.floatValues(.position) ?? a.floatValues(.positionVec4).map { values in
                stride(from: 0, to: values.count, by: 4).flatMap { values[$0..<($0 + 3)] }
            }
            let positionsB = b.floatValues(.position) ?? b.floatValues(.positionVec4).map { values in
                stride(from: 0, to: values.count, by: 4).flatMap { values[$0..<($0 + 3)] }
            }
            XCTAssertEqual(positionsA?.count, positionsB?.count, name)
            for (p, q) in zip(positionsA ?? [], positionsB ?? []) where p.isFinite { XCTAssertEqual(p, q, accuracy: 1e-4, name) }
            let skeletonA = try XCTUnwrap(original.skeleton), skeletonB = try XCTUnwrap(saved.skeleton)
            XCTAssertEqual(skeletonA.bones.map(\.name), skeletonB.bones.map(\.name), name)
            XCTAssertEqual(skeletonA.bones.map(\.parentIndex), skeletonB.bones.map(\.parentIndex), name)
            for (p, q) in zip(SceneSkeleton(skeletonA).restWorld, SceneSkeleton(skeletonB).restWorld) {
                XCTAssertTrue(simd_almost_equal_elements(p, q, 1e-3), name)
            }
            XCTAssertEqual(skeletonA.bones.map { MDLBonePhysics(properties: $0.properties) },
                           skeletonB.bones.map { MDLBonePhysics(properties: $0.properties) }, name)
            XCTAssertEqual(original.attachments, saved.attachments, name)
            let clipsA = original.animations ?? [], clipsB = saved.animations ?? []
            XCTAssertEqual(clipsA.map(\.id), clipsB.map(\.id), name)
            XCTAssertEqual(clipsA.map(\.frames), clipsB.map(\.frames), name)
            for (clipA, clipB) in zip(clipsA, clipsB) {
                XCTAssertEqual(clipA.boneTracks.map(\.isDisabled), clipB.boneTracks.map(\.isDisabled), name)
                for (trackA, trackB) in zip(clipA.boneTracks, clipB.boneTracks) where !trackA.isDisabled {
                    for (p, q) in zip(trackA.samples, trackB.samples) { XCTAssertEqual(p, q, accuracy: 1e-3 * max(1, abs(p)), name) }
                }
            }
        }
    }

    /// WE's clipping masks (capture 532) saved by the editor give the player the same masks and
    /// the same draws.
    func testClippingMasksSaveBackAsThePlayerReadsThem() throws {
        for name in ["g_mask", "g_mask_hide", "g_mask_invert", "c_mask_noclip"] {
            let data = try Fixtures.data("Models/PuppetGroundTruth532/\(name).mdl")
            let original = try MDLReader.read(data)
            let document = try PuppetMDLReader.read(data, imageSize: SIMD2(512, 256))
            let saved = try MDLReader.read(try PuppetMDLWriter.write(document))
            let a = try XCTUnwrap(original.meshes.first), b = try XCTUnwrap(saved.meshes.first)
            XCTAssertEqual(MDLClippingMask.masks(of: b), MDLClippingMask.masks(of: a), name)
            let bones = original.skeleton?.bones.count ?? 0
            let before = try XCTUnwrap(ScenePuppetClipping(mesh: a, boneCount: bones), name)
            let after = try XCTUnwrap(ScenePuppetClipping(mesh: b, boneCount: bones), name)
            XCTAssertEqual(after.steps(order: after.order(nil)), before.steps(order: before.order(nil)), name)
        }
    }
}
