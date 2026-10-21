import CoreGraphics
import Foundation
import ImageIO
import OWEModelImport
import OWESceneEditing
import UniformTypeIdentifiers
import XCTest

/// The importer on the package's own fixtures (written by hand for these tests): an OBJ with
/// two materials and a texture beside it, and an ASCII FBX quad skinned to a two-bone chain
/// with one animation stack.
final class ModelImportTests: XCTestCase {
    static func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }

    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "OWEModelImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The OBJ and its `.mtl` copied beside a 2×2 `wall.png`.
    func objFolder() throws -> URL {
        let folder = directory.appending(path: "source")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["two-materials.obj", "two-materials.mtl"] {
            try FileManager.default.copyItem(at: try Self.fixture(name), to: folder.appending(path: name))
        }
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try XCTUnwrap(context.makeImage())
        try XCTUnwrap(EditorAssetStore.pngData(image)).write(to: folder.appending(path: "wall.png"))
        return folder
    }

    // MARK: OBJ

    func testObjMeshesFollowTheMaterialLibraryAndFlipV() throws {
        let source = try ModelFileLoader.load(contentsOf: try objFolder().appending(path: "two-materials.obj"))
        XCTAssertEqual(source.materials.map(\.name), ["Wall", "Floor"])
        XCTAssertEqual(source.materials[0].albedo.map { ($0.path as NSString).lastPathComponent }, "wall.png")
        let output = try ModelCompiler.compile(source, config: ModelImportConfig(), folder: "two")
        let model = try MDLTestReader.read(output.mdl)
        XCTAssertEqual(model.tag, "MDLV0023")
        XCTAssertEqual(model.sections, [])
        XCTAssertEqual(model.legacyFormat, 0xf)
        XCTAssertEqual(model.meshes.map(\.materials), [["materials/models/two/Wall.json"], ["materials/models/two/Floor.json"]])
        for mesh in model.meshes {
            XCTAssertEqual(mesh.format, 0xf)  // position, normal, tangent, uv: WE's default import
            XCTAssertEqual(mesh.vertices.count, 4 * 48)
            XCTAssertEqual(mesh.indices.count, 6 * 2)
            XCTAssertEqual(mesh.flags, 0)
        }
        let wall = model.meshes[0].vertices.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        // The first corner: (-1, 0, 0), normal +z, tangent +x (w the sign of (N × T) · B, B along
        // −y by Assimp's formula on the file's coordinates, as WE 2.8 computes it), uv (0, 1 - 0).
        XCTAssertEqual(Array(wall[0..<12]), [-1, 0, 0, 0, 0, 1, 1, 0, 0, -1, 0, 1])
        let indices = model.meshes[0].indices.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        XCTAssertEqual(indices, [0, 1, 2, 0, 2, 3])
    }

    func testAModelWithoutAConfigurationWritesPositionsAndCoordinatesOnly() throws {
        let source = try ModelFileLoader.load(contentsOf: try objFolder().appending(path: "two-materials.obj"))
        let model = try MDLTestReader.read(try ModelCompiler.compile(source, config: .missing, folder: "two").mdl)
        XCTAssertEqual(model.meshes.map(\.format), [0x9, 0x9])
        let second = try MDLTestReader.read(try ModelCompiler.compile(source, config: ModelImportConfig(secondUVChannel: true), folder: "two").mdl)
        XCTAssertEqual(second.meshes.map(\.format), [0x27, 0x27])  // the second set packed into a_TexCoordVec4
    }

    func testImportKeepsTheSourceConfigurationModelMaterialsAndTexture() throws {
        let folder = try objFolder()
        let store = EditorAssetStore(directory: directory.appending(path: "store"))
        let imported = try EditorModelImporter.importModel(from: folder.appending(path: "two-materials.obj"), into: store)
        let modelFolder = (imported.model as NSString).deletingLastPathComponent
        XCTAssertTrue(modelFolder.hasPrefix("models/two-materials-"))
        XCTAssertEqual(imported.model, "\(modelFolder)/two-materials.mdl")
        XCTAssertEqual(imported.config, "\(modelFolder)/two-materials.json")
        XCTAssertEqual(imported.source, "\(modelFolder)/two-materials.obj")
        XCTAssertEqual(imported.title, "two-materials")
        XCTAssertEqual(imported.missingTextures, ["missing.png"])
        let paths = Set(store.assets().map(\.path))
        let name = (modelFolder as NSString).lastPathComponent
        for path in [imported.model, imported.config, imported.source, "\(modelFolder)/two-materials.mtl",
                     "materials/models/\(name)/Wall.json", "materials/models/\(name)/Wall.png", "materials/models/\(name)/Floor.json"] {
            XCTAssertTrue(paths.contains(path), path)
        }
        let wall = try JSONSerialization.jsonObject(with: Data(contentsOf: try XCTUnwrap(store.url(for: "materials/models/\(name)/Wall.json"))))
        let pass = try XCTUnwrap(((wall as? [String: Any])?["passes"] as? [[String: Any]])?.first)
        XCTAssertEqual(pass["shader"] as? String, "generic4")
        XCTAssertEqual(pass["textures"] as? [String], ["models/\(name)/Wall"])
        XCTAssertEqual(pass["depthtest"] as? String, "enabled")
        XCTAssertEqual(pass["cullmode"] as? String, "normal")
        let floor = try JSONSerialization.jsonObject(with: Data(contentsOf: try XCTUnwrap(store.url(for: "materials/models/\(name)/Floor.json"))))
        XCTAssertEqual(((floor as? [String: Any])?["passes"] as? [[String: Any]])?.first?["textures"] as? [String], ["util/white"])
        XCTAssertEqual(store.modelConfig(for: imported.model), ModelImportConfig())
        XCTAssertEqual(store.modelSource(for: imported.model)?.lastPathComponent, "two-materials.obj")
        XCTAssertEqual(store.importedModels(), [imported.model])
        // Importing again writes nothing new.
        XCTAssertEqual(try EditorModelImporter.importModel(from: folder.appending(path: "two-materials.obj"), into: store).model, imported.model)
        XCTAssertEqual(Set(store.assets().map(\.path)), paths)
    }

    // MARK: FBX

    func testSkinnedFbxKeepsTheNodesTheSkinNeeds() throws {
        let source = try ModelFileLoader.load(contentsOf: try Self.fixture("skinned-quad.fbx"))
        XCTAssertEqual(source.nodes.map(\.name), ["", "Quad", "Root", "Tip"])
        XCTAssertEqual(source.nodes.map(\.isBone), [false, false, true, true])
        XCTAssertTrue(source.isSkinned)
        XCTAssertEqual(source.animations.map(\.name), ["Wave"])
        XCTAssertEqual(source.animations[0].fps, 30)
        XCTAssertEqual(source.animations[0].frames, 30)

        let output = try ModelCompiler.compile(source, config: ModelImportConfig(), folder: "quad")
        XCTAssertEqual(output.bones, ["RootNode", "Root", "Tip"])
        let model = try MDLTestReader.read(output.mdl)
        XCTAssertEqual(model.sections, ["MDLS0004", "MDLA0006"])
        XCTAssertEqual(model.meshes.map(\.format), [0x180000f])
        XCTAssertEqual(model.legacyFormat, 0x180000f)
        XCTAssertEqual(model.bones.map(\.flags), [0, 1, 1])
        XCTAssertEqual(model.bones.map(\.parent), [0xFFFF_FFFF, 0, 1])
        XCTAssertEqual(Array(model.bones[2].matrix[12..<15]), [0, 1, 0])
        // Root moves the lower edge (y 0), Tip the upper one (y 2, one unit above it).
        XCTAssertEqual(model.boneBoxes[0].half, [0, 0, 0])
        XCTAssertEqual(model.boneBoxes[1].half, [1, 0, 0])
        XCTAssertEqual(Array(model.boneBoxes[1].matrix[12..<15]), [0, 0, 0])
        XCTAssertEqual(model.boneBoxes[2].half, [1, 0, 0])
        XCTAssertEqual(Array(model.boneBoxes[2].matrix[12..<15]), [0, 1, 0])

        let vertices = model.meshes[0].vertices.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let indices = model.meshes[0].vertices.withUnsafeBytes { raw in
            (0..<4).map { vertex in raw.loadUnaligned(fromByteOffset: vertex * 80 + 40, as: UInt32.self) }
        }
        XCTAssertEqual(indices, [1, 1, 2, 2])  // each corner's first bone: Root, Root, Tip, Tip
        XCTAssertEqual(vertices[14], 1)  // its weight

        let wave = try XCTUnwrap(model.animations.first)
        XCTAssertEqual(wave.id, 1)
        XCTAssertEqual(wave.name, "Wave")
        XCTAssertEqual(wave.mode, "loop")
        XCTAssertEqual(wave.fps, 30)
        XCTAssertEqual(wave.frames, 30)
        XCTAssertEqual(wave.tracks.count, 3)
        // Tip's keys (0° at 0 s, 90° at 1 s) read linearly at each frame: frame 29 at 87°,
        // position (0, 1, 0); the last frame samples the first, as WE's tracks loop.
        let frame29 = Array(wave.tracks[2][(29 * 9)..<(30 * 9)])
        XCTAssertEqual(frame29[1], 1, accuracy: 1e-5)
        XCTAssertEqual(frame29[5], .pi / 2 * 29 / 30, accuracy: 1e-4)
        XCTAssertEqual(Array(wave.tracks[2].suffix(9)), Array(wave.tracks[2].prefix(9)))
        // The box over the clip: Tip's quarter turn swings the top corners, √2 from it, past
        // x = -√2 and y = 1 + √2 halfway.
        XCTAssertEqual(wave.bounds[0], -Float(2).squareRoot(), accuracy: 1e-4)
        XCTAssertEqual(wave.bounds[4], 1 + Float(2).squareRoot(), accuracy: 1e-4)
    }

    func testClipsEventsAttachmentsAndPhysicsCompileIntoTheModel() throws {
        let source = try ModelFileLoader.load(contentsOf: try Self.fixture("skinned-quad.fbx"))
        var config = ModelImportConfig()
        config.clips = [ModelImportConfig.Clip(id: 1001, name: "Half", animation: 1, start: 10, end: 20, frameOffset: 3, matchLoop: false,
                                               rootMotion: "Root", motionFlags: ModelImportConfig.Clip.positionX, mode: "mirror")]
        config.events = [ModelImportConfig.Event(id: 1002, name: "step", frame: 4, animation: 1001),
                         ModelImportConfig.Event(id: 1003, name: "start", frame: 0, animation: 1)]
        config.attachments = [ModelImportConfig.Attachment(id: 1004, name: "hand", bone: "Tip", origin: SIMD3(0, 0.5, 0))]
        config.constraints = ["Tip": PuppetBonePhysics(preset: .floppy)]
        let model = try MDLTestReader.read(try ModelCompiler.compile(source, config: config, folder: "quad").mdl)
        XCTAssertEqual(model.sections, ["MDLS0004", "MDAT0001", "MDLA0006"])
        XCTAssertEqual(model.animations.map(\.id), [1, 1001])
        let clip = model.animations[1]
        XCTAssertEqual(clip.name, "Half")
        XCTAssertEqual(clip.mode, "mirror")
        XCTAssertEqual(clip.frames, 10)
        XCTAssertEqual(clip.fps, 30)
        XCTAssertEqual(clip.flags, 0x1 | 0x800)
        XCTAssertEqual(clip.reference?.source, 0)
        XCTAssertEqual(clip.reference?.start, 10)
        XCTAssertEqual(clip.reference?.end, 20)
        XCTAssertEqual(clip.reference?.offset, 3)
        XCTAssertEqual(clip.reference?.rootBone, 1)
        XCTAssertEqual(clip.events.map(\.1), ["step"])
        XCTAssertEqual(model.animations[0].events.map(\.1), ["start"])
        // The clip's first frame is the source's frame 10.
        XCTAssertEqual(Array(clip.tracks[2].prefix(9)), Array(model.animations[0].tracks[2][90..<99]))
        XCTAssertEqual(model.attachments.map(\.name), ["hand"])
        XCTAssertEqual(model.attachments.first?.bone, 2)
        XCTAssertEqual(model.attachments.first.map { Array($0.matrix[12..<15]) }, [0, 0.5, 0])
        let properties = try JSONSerialization.jsonObject(with: Data(model.bones[2].properties.utf8)) as? [String: Any]
        XCTAssertEqual(properties?["ge"] as? Bool, true)  // the floppy preset's gravity
        XCTAssertEqual(properties?["rs"] as? Double, 40)
        XCTAssertEqual(model.bones[1].properties, "")
    }

    func testConfigurationJSONRoundTripsAndKeepsUnknownKeys() throws {
        let json = #"{"normals": true, "tangentspace": false, "skins": [{"a": "b"}], "clips": [{"id": 7, "name": "Walk", "animation": 1, "start": 2, "end": 9, "frameoffset": 1, "matchloop": false, "rootmotion": "Hips", "motionflags": 136, "mode": "single", "fps": 24}], "attachments": [{"id": 8, "name": "hat", "bone": "Head", "origin": "0.00000 1.00000 0.00000", "angles": "0.00000 0.00000 1.57080"}]}"#
        let config = try ModelImportConfig(json: Data(json.utf8))
        XCTAssertTrue(config.normals)
        XCTAssertFalse(config.tangentSpace)
        XCTAssertEqual(config.clips, [ModelImportConfig.Clip(id: 7, name: "Walk", animation: 1, start: 2, end: 9, frameOffset: 1, matchLoop: false,
                                                             rootMotion: "Hips", motionFlags: 0x8800, fps: 24, mode: "single")])
        XCTAssertEqual(config.attachments.first?.angles.z ?? 0, 1.5708, accuracy: 1e-4)
        XCTAssertNotNil(config.other["skins"])
        // Written in WE's shape (`editor`, the attachment as a transform) and read back.
        var again = try ModelImportConfig(json: try config.jsonData())
        XCTAssertEqual(again.attachments.first?.angles.z ?? 0, 1.5708, accuracy: 1e-4)
        XCTAssertEqual(again.attachments.first?.origin, SIMD3(0, 1, 0))
        again.attachments = config.attachments
        XCTAssertEqual(again, config)
        XCTAssertEqual(config.nextID(after: 3), 1001)
    }

    func testRecompileWritesARevisionNamedByTheConfiguration() throws {
        let store = EditorAssetStore(directory: directory.appending(path: "store"))
        let source = directory.appending(path: "skinned-quad.fbx")
        try FileManager.default.copyItem(at: try Self.fixture("skinned-quad.fbx"), to: source)
        let imported = try EditorModelImporter.importModel(from: source, into: store)
        XCTAssertEqual(imported.animations.map(\.name), ["Wave"])
        var config = try XCTUnwrap(store.modelConfig(for: imported.model))
        config.clips = [ModelImportConfig.Clip(id: 1001, name: "Start", animation: 1, start: 0, end: 5)]
        let revised = try EditorModelImporter.recompile(imported.model, config: config, in: store)
        XCTAssertNotEqual(revised.model, imported.model)
        XCTAssertEqual((revised.model as NSString).deletingLastPathComponent, (imported.model as NSString).deletingLastPathComponent)
        XCTAssertTrue((revised.model as NSString).lastPathComponent.hasPrefix("skinned-quad-"))
        XCTAssertEqual(revised.animations.map(\.name), ["Wave", "Start"])
        XCTAssertEqual(store.modelConfig(for: revised.model), config)
        XCTAssertEqual(store.modelSource(for: revised.model)?.lastPathComponent, "skinned-quad.fbx")
        // The import's own configuration compiles to the import's own model.
        XCTAssertEqual(try EditorModelImporter.recompile(revised.model, config: ModelImportConfig(), in: store).model, imported.model)
    }

    func testAnAnimationFileIsAddedBesideTheSource() throws {
        let store = EditorAssetStore(directory: directory.appending(path: "store"))
        let source = directory.appending(path: "skinned-quad.fbx")
        try FileManager.default.copyItem(at: try Self.fixture("skinned-quad.fbx"), to: source)
        let imported = try EditorModelImporter.importModel(from: source, into: store)
        let extra = directory.appending(path: "dance.fbx")
        try FileManager.default.copyItem(at: try Self.fixture("skinned-quad.fbx"), to: extra)
        let config = try EditorModelImporter.addAnimationFile(extra, to: imported.model, config: ModelImportConfig(), in: store)
        XCTAssertEqual(config.additionalFiles, ["dance.fbx"])
        let output = try EditorModelImporter.inspect(imported.model, config: config, in: store)
        XCTAssertEqual(output.animations.map(\.name), ["Wave", "Wave"])
        XCTAssertEqual(output.animations.map(\.id), [1, 2])
    }

    /// Clean Project keeps what a used model needs: its materials and textures, its
    /// configuration and its sources; an unused import goes.
    func testCleanProjectKeepsAUsedModelsFiles() throws {
        let store = EditorAssetStore(directory: directory.appending(path: "store"))
        let imported = try EditorModelImporter.importModel(from: try objFolder().appending(path: "two-materials.obj"), into: store)
        let scene = try JSONSerialization.data(withJSONObject: ["objects": [["id": 1, "model": imported.model]]])
        XCTAssertEqual(ProjectCleaner.unusedAssets(in: store, roots: [scene]).map(\.path), [])
        let unused = ProjectCleaner.unusedAssets(in: store, roots: [Data("{}".utf8)]).map(\.path)
        XCTAssertEqual(Set(unused), Set(store.assets().map(\.path)))
    }

    func testFilesThatArentModelsAreRefused() throws {
        let text = directory.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: text)
        XCTAssertThrowsError(try ModelFileLoader.load(contentsOf: text)) {
            XCTAssertEqual($0 as? ModelFileLoader.LoadError, .unsupported("notes.txt"))
        }
        let broken = directory.appending(path: "broken.fbx")
        try Data("not an fbx".utf8).write(to: broken)
        XCTAssertThrowsError(try ModelFileLoader.load(contentsOf: broken))
    }
}
