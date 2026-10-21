import XCTest
import simd
import OWESceneEditing
@testable import OpenWallpaperEngine

/// The Wallpaper Editor's model import as the player reads it: what `ModelCompiler` writes for
/// an imported FBX or OBJ (docs/model-import.md) is read field for field by the app's
/// `MDLReader`, and its skeleton and clips pose as the player poses them.
final class EditorModelImportTests: XCTestCase {
    /// A quad skinned to a two-bone chain under a mesh node, as the importer reads an FBX: the
    /// root (unnamed), the mesh's node, "Root" and "Tip" one unit up; the lower corners on Root,
    /// the upper ones on Tip; one animation turning Tip a quarter turn over 30 frames.
    static func source() -> ModelSource {
        let identity = matrix_identity_float4x4
        var tip = identity
        tip.columns.3 = SIMD4(0, 1, 0, 1)
        let nodes = [ModelSource.Node(name: "", parent: nil, local: identity, isBone: false),
                     ModelSource.Node(name: "Quad", parent: 0, local: identity, isBone: false),
                     ModelSource.Node(name: "Root", parent: 0, local: identity, isBone: true),
                     ModelSource.Node(name: "Tip", parent: 2, local: tip, isBone: true)]
        let corners: [SIMD3<Float>] = [SIMD3(-1, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 2, 0), SIMD3(-1, 0, 0), SIMD3(1, 2, 0), SIMD3(-1, 2, 0)]
        let uvs: [SIMD2<Float>] = corners.map { SIMD2(($0.x + 1) / 2, $0.y / 2) }
        let influences = corners.map { corner in
            ModelSource.Influences(nodes: SIMD4(corner.y > 1 ? 3 : 2, 0, 0, 0), weights: SIMD4(1, 0, 0, 0))
        }
        let mesh = ModelSource.Mesh(name: "Quad", material: 0, positions: corners,
                                    normals: Array(repeating: SIMD3(0, 0, 1), count: 6), uvs: uvs, influences: influences)
        let frames = 30
        let samples: [[PuppetTransform]] = nodes.enumerated().map { index, node in
            (0...frames).map { frame in
                var transform = PuppetTransform(matrix: node.local)
                if index == 3 { transform.euler.z = .pi / 2 * Float(frame) / Float(frames) }
                return transform
            }
        }
        return ModelSource(nodes: nodes, meshes: [mesh], materials: [ModelSource.Material(name: "Skin")],
                           animations: [ModelSource.Animation(name: "Wave", fps: 30, frames: frames, samples: samples)])
    }

    static func config() -> ModelImportConfig {
        var config = ModelImportConfig()
        config.clips = [ModelImportConfig.Clip(id: 1001, name: "Half", animation: 1, start: 10, end: 20, frameOffset: 2, matchLoop: true,
                                               rootMotion: "Root", motionFlags: ModelImportConfig.Clip.positionX | ModelImportConfig.Clip.rotationY,
                                               mode: "single")]
        config.events = [ModelImportConfig.Event(id: 1002, name: "step", frame: 5, animation: 1001)]
        config.attachments = [ModelImportConfig.Attachment(id: 1003, name: "hand", bone: "Tip", origin: SIMD3(0, 0.5, 0),
                                                           angles: SIMD3(0, 0, .pi / 2))]
        config.constraints = ["Tip": PuppetBonePhysics(preset: .springy)]
        return config
    }

    func testTheAppReadsWhatTheImporterWrites() throws {
        let output = try ModelCompiler.compile(Self.source(), config: Self.config(), folder: "quad")
        let model = try MDLReader.read(output.mdl)
        XCTAssertEqual(model.tag, "MDLV0023")
        XCTAssertEqual(model.trailingByteCount, 0)
        XCTAssertEqual(model.sections.map(\.tag), ["MDLS0004", "MDAT0001", "MDLA0006"])
        XCTAssertTrue(model.sections.allSatisfy { $0.parsedEnd == $0.end && !$0.skipped })
        XCTAssertEqual(model.materialsPerMesh, 1)
        let mesh = try XCTUnwrap(model.meshes.first)
        XCTAssertEqual(mesh.materials, ["materials/models/quad/Skin.json"])
        XCTAssertEqual(mesh.format.rawValue, 0x180000f)
        XCTAssertEqual(mesh.vertexCount, 4)
        XCTAssertEqual(mesh.indices, [0, 1, 2, 0, 2, 3])
        let blendIndices: [UInt32] = try XCTUnwrap(mesh.unsignedValues(.blendIndices))
        let firstBones: [UInt32] = stride(from: 0, to: blendIndices.count, by: 4).map { blendIndices[$0] }
        XCTAssertEqual(firstBones, [1, 1, 2, 2])
        XCTAssertEqual(mesh.floatValues(.texCoord), [Float]([0, 1, 1, 1, 1, 0, 0, 0]))  // v flipped
        XCTAssertEqual(mesh.bounds?.min, SIMD3<Float>(-1, 0, 0))
        XCTAssertEqual(mesh.bounds?.max, SIMD3<Float>(1, 2, 0))
        XCTAssertEqual(mesh.groups, [])

        let skeleton = try XCTUnwrap(model.skeleton)
        XCTAssertEqual(skeleton.version, 4)
        XCTAssertEqual(skeleton.bones.map(\.name), ["RootNode", "Root", "Tip"])
        XCTAssertEqual(skeleton.bones.map(\.flags), [0, 1, 1])
        XCTAssertEqual(skeleton.bones.map(\.parent), [0xFFFF_FFFF, 0, 1])
        XCTAssertEqual(skeleton.bindPoseWorldMatrices[2].columns.3, SIMD4<Float>(0, 1, 0, 1))
        let boxes: [SIMD3<Float>] = try XCTUnwrap(skeleton.boneVectors?.map(\.vector))
        XCTAssertEqual(boxes, [SIMD3<Float>.zero, SIMD3<Float>(1, 0, 0), SIMD3<Float>(1, 0, 0)])
        XCTAssertEqual(skeleton.boneVectors?[2].matrix.columns.3, SIMD4<Float>(0, 1, 0, 1))
        XCTAssertNil(MDLBonePhysics(properties: skeleton.bones[1].properties))
        XCTAssertNotNil(MDLBonePhysics(properties: skeleton.bones[2].properties))

        let attachments: [MDLAttachment] = try XCTUnwrap(model.attachments)
        XCTAssertEqual(attachments.map(\.name), ["hand"])
        XCTAssertEqual(attachments.first?.bone, 2)
        XCTAssertEqual(attachments.first?.matrix.columns.3, SIMD4<Float>(0, 0.5, 0, 1))

        XCTAssertEqual(model.animationsVersion, 6)
        let animations = try XCTUnwrap(model.animations)
        XCTAssertEqual(animations.map(\.id), [1, 1001])
        XCTAssertEqual(animations.map(\.name), ["Wave", "Half"])
        XCTAssertEqual(animations.map(\.modeName), ["loop", "single"])
        XCTAssertEqual(animations.map(\.frames), [30, 10])
        XCTAssertEqual(animations[0].boneTracks.count, 3)
        XCTAssertEqual(animations[0].boneTracks[2].pose(at: 30).euler.z, .pi / 2, accuracy: 1e-5)
        let clip = animations[1]
        XCTAssertEqual(clip.flags, 0x1 | 0x400 | 0x800 | 0x8000)
        XCTAssertEqual(clip.reference, MDLAnimation.Reference(animation: 0, startFrame: 10, endFrame: 20, frameOffset: 2, rootBone: 1))
        XCTAssertEqual(clip.boneTracks[2].pose(at: 0), animations[0].boneTracks[2].pose(at: 10))
        XCTAssertEqual(clip.events, [MDLAnimation.Event(frame: 5, name: "step")])
        // The animated box: the top corners, √2 from Tip, swing out past x = -√2.
        XCTAssertEqual(animations[0].bounds?.min.x ?? 0, -Float(2).squareRoot(), accuracy: 1e-4)
    }

    /// The player's skeleton poses the imported rig: Tip's quarter turn moves the upper corners
    /// around Tip's origin, (1, 2) to (-1, 2).
    func testThePlayerPosesTheImportedRig() throws {
        let model = try MDLReader.read(try ModelCompiler.compile(Self.source(), config: ModelImportConfig(), folder: "quad").mdl)
        let skeleton = SceneSkeleton(try XCTUnwrap(model.skeleton))
        let clip = try XCTUnwrap(model.animations?.first)
        let locals = clip.boneTracks.map { SceneBoneTransform($0.pose(at: 30)).matrix }
        let palette = skeleton.palette(worlds: skeleton.worlds(locals: locals))
        let corner: SIMD4<Float> = palette[2] * SIMD4(1, 2, 0, 1)
        XCTAssertEqual(corner.x, -1, accuracy: 1e-5)
        XCTAssertEqual(corner.y, 2, accuracy: 1e-5)
    }
}
