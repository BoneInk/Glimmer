import XCTest
import MetalKit
import simd
@testable import OpenWallpaperEngine

/// Broken and extreme 3D content (docs/models-plan.md §4.3 T), written by the tests (no Workshop
/// content): each wallpaper loads through the real loader and draws through the real renderer, and
/// must fail cleanly: what can't be drawn is logged, the rest draws, and no frame fails on the GPU,
/// takes longer than 5 s or leaves a NaN in a float target or a posed bone.
final class ModelAdversarialTests: XCTestCase {
    private var scratch: URL!
    private var storage: URL!

    override func setUpWithError() throws {
        let id = UUID().uuidString
        scratch = FileManager.default.temporaryDirectory.appending(path: "owe-model-adversarial-\(id)")
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-model-adversarial-storage-\(id)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for url in [scratch, storage].compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Support

    private static let size = SIMD2(320, 180)

    /// Loads and draws `wallpaper` (settled, then `frames` frames at 1/30 s) and checks the frames.
    private func draw(_ wallpaper: ModelFixtureWallpaper, settings: SceneRenderSettings = SceneRenderSettings(),
                      frames: Int = 20, file: StaticString = #filePath, line: UInt = #line) throws -> ModelSceneHarness {
        let harness = try ModelSceneHarness(directory: wallpaper.directory, settings: settings, size: Self.size,
                                            storage: storage, file: file, line: line)
        try harness.settle(seconds: 10)
        _ = harness.run(frames: frames)
        try check(harness, file: file, line: line)
        return harness
    }

    private func check(_ harness: ModelSceneHarness, file: StaticString = #filePath, line: UInt = #line) throws {
        let name = harness.directory.lastPathComponent
        XCTAssertEqual(harness.gpuErrors, [], "\(name): GPU errors", file: file, line: line)
        XCTAssertLessThan(harness.slowestFrame, 5, "\(name): a frame took \(harness.slowestFrame) s", file: file, line: line)
        XCTAssertEqual(harness.posesAreFinite(), [], "\(name): posed bones that aren't finite", file: file, line: line)
        for texture in [harness.renderer.lastSceneTarget, harness.renderer.planarReflection?.texture,
                        harness.renderer.shadowPass?.atlas.texture].compactMap({ $0 }) {
            if let bad = try ModelSceneHarness.nonFiniteCount(texture, device: harness.device) {
                XCTAssertEqual(bad, 0, "\(name): \(texture.label ?? "\(texture.pixelFormat)") has values that aren't finite",
                               file: file, line: line)
            }
        }
    }

    /// The last frame's pixels (RGBA).
    private func pixels(_ harness: ModelSceneHarness) throws -> [UInt8] {
        try TextureUploadTests.read(try XCTUnwrap(harness.renderer.sharedFrame), device: harness.device)
    }

    /// Pixels of the last frame in columns `columns` (fractions of the width) brighter than the
    /// black clear colour, and those where `channel` dominates.
    private func lit(_ harness: ModelSceneHarness, columns: ClosedRange<Float> = 0...1, dominant channel: Int? = nil) throws -> Int {
        let bytes = try pixels(harness)
        let width = harness.renderer.sharedFrame?.width ?? Self.size.x
        let height = bytes.count / 4 / max(width, 1)
        let low = Int(columns.lowerBound * Float(width)), high = min(width, Int(columns.upperBound * Float(width)))
        var count = 0
        bytes.withUnsafeBufferPointer { raw in
            for y in 0..<height {
                for x in low..<high {
                    let i = (y * width + x) * 4
                    let r = Int(raw[i]), g = Int(raw[i + 1]), b = Int(raw[i + 2])
                    guard max(r, g, b) > 24 else { continue }
                    switch channel {
                    case 0?: if r > max(g, b) + 40 { count += 1 }
                    case 1?: if g > max(r, b) + 40 { count += 1 }
                    case 2?: if b > max(r, g) + 40 { count += 1 }
                    default: count += 1
                    }
                }
            }
        }
        return count
    }

    private func model(_ name: String, _ mdl: FixtureMDL) -> [String: Data] { ["models/\(name).mdl": mdl.data] }

    private func object(_ id: Int, _ model: String, origin: String = "0 0 0", extra: String = "") -> String {
        #"{"id":\#(id),"name":"\#(model)","model":"models/\#(model).mdl","origin":"\#(origin)"\#(extra)}"#
    }

    // MARK: - Bones and indices

    /// WE's reader fast-fails past 128 bones (0x140262501); ours rejects the file, logged, and the
    /// 128-bone model draws with `BONECOUNT` 128.
    func testA128BoneModelDrawsAndA129BoneModelIsRejected() throws {
        let log = ModelLogWindow()
        var files = model("b128", .cubeModel(bones: 128, bone: 127))
        files.merge(model("b129", .cubeModel(bones: 129, bone: 128))) { $1 }
        let wallpaper = try ModelFixtureWallpaper(in: scratch, name: "bones", objects: [
            object(1, "b128", origin: "-2 0 0"), object(2, "b129", origin: "2 0 0"),
        ], files: files)
        let harness = try draw(wallpaper)
        defer { harness.close() }
        let models = harness.content.spatial.models
        let b128 = try XCTUnwrap(models.first { $0.id == "1" }?.plan)
        XCTAssertEqual(b128.skeleton?.bones.count, 128)
        XCTAssertEqual(b128.meshes.first?.material.pass.variant?.combos["BONECOUNT"], 128)
        XCTAssertEqual(b128.meshes.first?.material.pass.variant?.combos["SKINNING"], 1)
        XCTAssertNil(models.first { $0.id == "2" }?.plan, "129 bones don't load")
        XCTAssertGreaterThan(harness.models?.meshDraws["1"] ?? 0, 0, "the 128-bone cube draws")
        XCTAssertGreaterThan(try lit(harness, columns: 0...0.5), 100, "the 128-bone cube is on screen")
        XCTAssertEqual(try lit(harness, columns: 0.5...1), 0, "nothing stands in for the rejected one")
        XCTAssertFalse(log.lines(containing: "b129.mdl").filter { $0.contains("can't be loaded") }.isEmpty, "the rejection is logged")
    }

    /// A mesh with 32-bit indices (mesh flag 1) whose triangles use vertices past 65535.
    func testUInt32IndicesPastTheUInt16RangeDraw() throws {
        let padding = 70_000
        let cube = FixtureMDL.cube(material: "materials/facecolor.json", base: UInt32(padding))
        let mdl = FixtureMDL(format: FixtureMDL.positionNormal, materialsPerMesh: 1, meshes: [FixtureMDL.Mesh(
            materials: ["materials/facecolor.json"], vertices: [Float](repeating: 0, count: padding * 6) + cube.vertices,
            indices: cube.indices, uint32Indices: true)])
        let wallpaper = try ModelFixtureWallpaper(in: scratch, name: "u32", objects: [object(1, "u32")], files: model("u32", mdl))
        let harness = try draw(wallpaper)
        defer { harness.close() }
        let plan = try XCTUnwrap(harness.content.spatial.models.first?.plan)
        XCTAssertEqual(plan.meshes.first?.usesUInt32Indices, true)
        XCTAssertGreaterThan(harness.models?.meshDraws["1"] ?? 0, 0)
        XCTAssertGreaterThan(try lit(harness), 500, "the cube past index 65535 is on screen")
    }

    /// A `.mdl` whose meshes name no material (`materialsPerMesh` 0) and one that isn't there:
    /// both logged, neither drawn, the scene's other model drawn.
    func testAModelWithoutMaterialsAndAMissingModelAreLogged() throws {
        let log = ModelLogWindow()
        var bare = FixtureMDL.cubeModel()
        bare.materialsPerMesh = 0
        var files = model("bare", bare)
        files.merge(model("good", .cubeModel())) { $1 }
        let wallpaper = try ModelFixtureWallpaper(in: scratch, name: "materials", objects: [
            object(1, "bare", origin: "-2 0 0"), object(2, "missing", origin: "2 0 0"), object(3, "good"),
        ], files: files)
        let harness = try draw(wallpaper)
        defer { harness.close() }
        let models = harness.content.spatial.models
        XCTAssertNil(models.first { $0.id == "1" }?.plan)
        XCTAssertNil(models.first { $0.id == "2" }?.plan)
        XCTAssertNotNil(models.first { $0.id == "3" }?.plan)
        XCTAssertGreaterThan(harness.models?.meshDraws["3"] ?? 0, 0)
        XCTAssertFalse(log.lines(containing: "bare.mdl has no mesh that draws").isEmpty, "the bare model is logged")
        XCTAssertFalse(log.lines(containing: "missing.mdl").filter { $0.contains("can't be loaded") }.isEmpty,
                       "the missing model is logged")
    }

    /// `skin` past the material list takes the last (0x140224dc4: `materials[min(skin, M − 1)]`);
    /// a negative one the first.
    func testASkinPastTheListTakesTheLastMaterial() throws {
        let cube = FixtureMDL.cube(material: "materials/facecolor_red.json")
        let mdl = FixtureMDL(format: FixtureMDL.positionNormal, materialsPerMesh: 2, meshes: [FixtureMDL.Mesh(
            materials: ["materials/facecolor_red.json", "materials/facecolor_green.json"], vertices: cube.vertices,
            indices: cube.indices)])
        let wallpaper = try ModelFixtureWallpaper(in: scratch, name: "skins", objects: [
            object(1, "skins", origin: "-2 0 0", extra: #","skin":7"#),
            object(2, "skins", origin: "2 0 0", extra: #","skin":-3"#),
        ], files: model("skins", mdl))
        let harness = try draw(wallpaper)
        defer { harness.close() }
        XCTAssertGreaterThan(try lit(harness, columns: 0...0.5, dominant: 1), 100, "skin 7 of 2 is the last, green")
        XCTAssertGreaterThan(try lit(harness, columns: 0.5...1, dominant: 0), 100, "skin −3 is the first, red")
        XCTAssertEqual(try lit(harness, columns: 0...0.5, dominant: 0), 0)
    }

    // MARK: - Attachments

    /// An `attachment` the parent's `.mdl` doesn't have: logged at load; the object hangs from its
    /// parent as if it named none (world = parentWorld · local), and draws.
    func testAnUnknownAttachmentNameIsLoggedAndTheObjectStillDraws() throws {
        let log = ModelLogWindow()
        var parent = FixtureMDL.cubeModel(bones: 1, bone: 0)
        parent.attachments = [.init(bone: 0, name: "hand")]
        var files = model("rig", parent)
        files.merge(model("prop", .cubeModel())) { $1 }
        let wallpaper = try ModelFixtureWallpaper(in: scratch, name: "attachment", objects: [
            object(1, "rig", origin: "-2 0 0"),
            object(2, "prop", origin: "4 0 0", extra: #","parent":1,"attachment":"no such point","scale":"0.5 0.5 0.5""#),
            object(3, "prop", origin: "0 2 0", extra: #","parent":1,"attachment":"hand","scale":"0.5 0.5 0.5""#),
        ], files: files)
        let harness = try draw(wallpaper)
        defer { harness.close() }
        XCTAssertGreaterThan(harness.models?.meshDraws["2"] ?? 0, 0, "the object with the unknown attachment draws")
        XCTAssertGreaterThan(harness.models?.meshDraws["3"] ?? 0, 0)
        XCTAssertFalse(log.lines(containing: "no such point").isEmpty, "the unknown attachment is logged")
        XCTAssertTrue(log.lines(containing: "names attachment \"hand\"").isEmpty, "a known attachment isn't")
    }

    // MARK: - Cameras and projection

    /// A camera layer looking away from the cube, hidden by its `visible` script after 0.5 s: the
    /// scene's own camera (which sees the cube) takes over.
    func testACameraLayerHiddenMidRunHandsBackToTheSceneCamera() throws {
        let wallpaper = try ModelFixtureWallpaper(in: scratch, name: "camera-hidden", objects: [
            object(1, "cube"),
            #"{"id":10,"name":"away","camera":"default","origin":"10 0 6","#
                + #""visible":{"script":"export function update(value) { return engine.runtime < 0.5; }","value":true}}"#,
        ], files: model("cube", .cubeModel()))
        let harness = try ModelSceneHarness(directory: wallpaper.directory, settings: SceneRenderSettings(), size: Self.size,
                                            storage: storage)
        defer { harness.close() }
        try harness.settle(seconds: 10)
        _ = harness.run(frames: 5)
        XCTAssertEqual(try lit(harness), 0, "the camera layer looks away from the cube")
        _ = harness.run(frames: 25)
        XCTAssertGreaterThan(try lit(harness), 500, "hidden, it hands the frame back to the scene camera")
        try check(harness)
    }

    /// Two camera layers, the later one visible every other half second: the last visible one in
    /// scene order is the camera, so the frame switches between them.
    func testTwoCameraLayersSwitch() throws {
        let wallpaper = try ModelFixtureWallpaper(in: scratch, name: "camera-switch", objects: [
            object(1, "cube"),
            #"{"id":10,"name":"sees","camera":"default","origin":"0 0 6"}"#,
            #"{"id":11,"name":"away","camera":"default","origin":"10 0 6","#
                + #""visible":{"script":"export function update(value) { return Math.floor(engine.runtime * 2) % 2 == 1; }","value":false}}"#,
        ], files: model("cube", .cubeModel()))
        let harness = try ModelSceneHarness(directory: wallpaper.directory, settings: SceneRenderSettings(), size: Self.size,
                                            storage: storage)
        defer { harness.close() }
        try harness.settle(seconds: 10)
        var states: [Bool] = []
        for frame in 0..<60 {
            harness.frame()
            // Every third frame: the camera switches every 15.
            if frame % 3 == 0 { states.append(try lit(harness) > 500) }
        }
        let switches = zip(states, states.dropFirst()).filter { $0 != $1 }.count
        XCTAssertGreaterThanOrEqual(switches, 3, "the camera switches every half second: \(states)")
        XCTAssertTrue(states.contains(true) && states.contains(false))
        try check(harness)
    }

    /// A scene of images alone without `orthogonalprojection` is perspective (§2.1: 1920×1080), and
    /// its image draws through the camera.
    func testAnImageOnlySceneWithoutOrthogonalProjectionDraws() throws {
        _ = try Fixtures.assets()
        let wallpaper = try ModelFixtureWallpaper(in: scratch, name: "image-perspective", objects: [
            #"{"id":1,"name":"red","image":"models/util/solidlayer.json","origin":"0 0 0","size":"2 2","color":"1 0 0"}"#,
        ])
        let harness = try draw(wallpaper)
        defer { harness.close() }
        XCTAssertTrue(harness.content.spatial.camera.projection.isPerspective, "missing orthogonalprojection is perspective")
        XCTAssertGreaterThan(try lit(harness, dominant: 0), 0, "the image draws")
    }

    // MARK: - Script model data

    /// `createModelData` with indices past its vertices, an `applyData` that grows the vertex
    /// buffer, a `replaceData` from `update`, one from a timer, and an `applyData` that shrinks the
    /// vertices under the indices: the script errors are logged, the geometry draws, the GPU never
    /// reads past a buffer (a fault ends the command buffer with an error).
    func testScriptModelDataAbuseFailsCleanly() throws {
        _ = try Fixtures.assets()
        let log = ModelLogWindow()
        let quad = "new Float32Array([-1,-1,0, 0,0,1,  1,-1,0, 0,0,1,  1,1,0, 0,0,1,  -1,1,0, 0,0,1])"
        func shape(_ indices: String) -> String {
            "{ vertexBuffer: \(quad), indexBuffer: \(indices), vertexFormat: ['position', 'normal'], "
                + "material: 'materials/facecolor.json', isVertexBufferDynamic: true, isIndexBufferDynamic: true }"
        }
        func host(_ id: Int, _ origin: String, init body: String, update: String) -> String {
            let script = """
                'use strict';
                let data;
                let frames = 0;
                export function init(value) {
                    data = thisScene.createModelData({ shapes: [\(shape("new Uint16Array([0, 1, 2, 0, 2, 3])"))] });
                    const layer = thisScene.createLayer({ name: 'geometry \(id)', model: data });
                    layer.origin = new Vec3(\(origin));
                    \(body)
                    return value;
                }
                export function update(value) {
                    frames += 1;
                    \(update)
                    return value;
                }
                """
            let text = String(data: try! JSONSerialization.data(withJSONObject: [script], options: [.fragmentsAllowed]), encoding: .utf8)!
            return #"{"id":\#(id),"name":"host \#(id)","origin":{"script":\#(text.dropFirst().dropLast()),"value":"0 0 0"}}"#
        }
        let wallpaper = try ModelFixtureWallpaper(in: scratch, name: "modeldata", objects: [
            // Indices past the four vertices, from the start.
            host(1, "-3, 1.5, 0", init: "data.replaceData({ shapes: [\(shape("new Uint16Array([0, 1, 2, 0, 2, 3, 0, 60000, 3])"))] });",
                 update: ""),
            // A larger vertex buffer (WE: "Vertex buffer size cannot increase").
            host(2, "0, 1.5, 0", init: "", update: "if (frames == 3) data.applyData({ shapes: [{ vertexBuffer: new Float32Array(48) }] });"),
            // `replaceData` from `update` (WE: "IModelData.replace cannot be called in update.").
            host(3, "3, 1.5, 0", init: "", update: "if (frames == 3) data.replaceData({ shapes: [\(shape("new Uint16Array([0, 1, 2])"))] });"),
            // `replaceData` from a timer, with other shapes and 32-bit indices.
            host(4, "-3, -1.5, 0", init: "engine.setTimeout(function () { data.replaceData({ shapes: [\(shape("new Uint32Array([0, 1, 2])")), \(shape("new Uint16Array([0, 2, 3])"))] }); }, 100);",
                 update: ""),
            // Fewer vertices than the indices reach.
            host(5, "0, -1.5, 0", init: "", update: "if (frames == 3) data.applyData({ shapes: [{ vertexBuffer: new Float32Array([-1,-1,0, 0,0,1]) }] });"),
        ], eye: "0 0 9")
        let harness = try draw(wallpaper, frames: 30)
        defer { harness.close() }
        XCTAssertFalse(log.lines(containing: "Vertex buffer size cannot increase").isEmpty, "the growing buffer is logged")
        XCTAssertFalse(log.lines(containing: "IModelData.replace cannot be called in update.").isEmpty,
                       "replaceData in update is logged")
        XCTAssertGreaterThan(try lit(harness), 500, "the script geometry draws")
    }

    // MARK: - Morph weights

    /// Morph weights that aren't finite or are out of range, from a clip's tracks (a model) and from
    /// `setBlendShapeWeight` (a puppet): the uniforms a draw gets stay finite.
    func testMorphWeightsThatArentFiniteOrAreOutOfRangeStayFinite() throws {
        let strip = SceneMorphTargetsTests.strip(count: 4)
        let clip = SceneMorphTargetsTests.Clip(name: "bad", frames: 4, fps: 4, tracks: [
            (0, [.nan, .nan, .nan, .nan, .nan]), (1, [5, 5, 5, 5, 5]), (2, [-.infinity, 1, .infinity, 1, -1]),
        ])
        let model = try SceneMorphTargetsTests.model(format: strip.format, vertexData: strip.vertices, indices: strip.indices,
                                                     flags: 0, targets: SceneMorphTargetsTests.targets(3, vertices: 4),
                                                     morphVertices: 4, clips: [clip])
        let morphs = try XCTUnwrap(SceneModelMorphs(model: model))
        let skeleton = try XCTUnwrap(model.skeleton)
        let clips = try XCTUnwrap(model.animations)
        for layer in [WEAnimationLayer(animation: 100), WEAnimationLayer(animation: 100, values: [.blend: .number(0.5)]),
                      WEAnimationLayer(animation: 100, values: [.additive: .bool(true)])] {
            let animator = ScenePuppetAnimator(skeleton: skeleton, clips: clips, layers: [layer], morphRig: .model(morphs))
            for _ in 0..<12 {
                animator.advance(delta: 0.1, values: EffectGraphTests.FixedValues())
                let uniforms = morphs.uniforms(mesh: 0, weights: animator.morphs)
                XCTAssertTrue(uniforms.weights.allSatisfy(\.isFinite), "\(layer): \(uniforms.weights)")
            }
        }
        let puppet = ScenePuppetAnimator(skeleton: skeleton, clips: [], layers: [],
                                         morphRig: SceneMorphRig.puppet(model.morphTargets?.first, meshFlags: 0))
        for (index, weight) in [(0, Float.nan), (1, .infinity), (2, 1e30), (99, 1), (-1, 1), (Int.max, 1)] as [(Int, Float)] {
            puppet.perform(.setBlendShape(index: index, weight: weight))
        }
        puppet.advance(delta: 1.0 / 30, values: EffectGraphTests.FixedValues())
        XCTAssertTrue(puppet.pose.morph?.weights.allSatisfy(\.isFinite) ?? true, "\(String(describing: puppet.pose.morph?.weights))")
    }

    // MARK: - Particles

    /// `collisionmodel` linked to an image without a rig, a hidden model and an object that doesn't
    /// exist: the image is logged once; the particles simulate and draw.
    func testCollisionModelLinksToNonModelsFailCleanly() throws {
        _ = try Fixtures.assets()
        let log = ModelLogWindow()
        let system = """
            {"emitter":[{"name":"sphererandom","rate":200,"distancemax":1,"speedmin":1,"speedmax":2}],
             "initializer":[{"name":"lifetimerandom","min":1,"max":1},{"name":"sizerandom","min":0.1,"max":0.1}],
             "operator":[{"name":"movement"},{"name":"collisionmodel"},{"name":"collisionmodel"},{"name":"collisionmodel"}],
             "material":"materials/dot.json","maxcount":400}
            """
        let dot = #"{"passes":[{"blending":"additive","shader":"genericparticle","textures":["particle/halo"]}]}"#
        let wallpaper = try ModelFixtureWallpaper(in: scratch, name: "collision", objects: [
            #"{"id":1,"name":"image","image":"models/util/solidlayer.json","origin":"-3 0 0","size":"1 1","color":"0 0 1"}"#,
            object(2, "cube", extra: #","visible":false"#),
            #"{"id":3,"name":"sparks","particle":"particles/sparks.json","origin":"0 0 0","#
                + #""dependencies":[{"id":1,"type":"collisionmodel","index":0},{"id":2,"type":"collisionmodel","index":1},"#
                + #"{"id":99,"type":"collisionmodel","index":2}]}"#,
        ], files: model("cube", .cubeModel()).merging(["particles/sparks.json": Data(system.utf8),
                                                         "materials/dot.json": Data(dot.utf8)]) { $1 })
        let harness = try draw(wallpaper, frames: 30)
        defer { harness.close() }
        XCTAssertEqual(harness.renderer.particleSystemCount, 1)
        XCTAssertEqual(log.lines(containing: "Particle collisionmodel: object 1 is neither a drawable model nor a Puppet Warp image").count, 1,
                       "logged once")
        XCTAssertEqual(harness.models?.meshDraws["2"] ?? 0, 0, "the hidden model isn't drawn")
    }

    // MARK: - Reflection and shadows

    /// A reflective model (`_rt_Reflection`) when every other model is `reflected: false`: the
    /// reflection pass clears and draws nothing; both models draw.
    func testAReflectiveModelWithNothingReflected() throws {
        _ = try Fixtures.assets()
        var floor = FixtureMDL.cubeModel(material: "materials/reflective.json")
        floor.meshes[0].materials = ["materials/reflective.json"]
        var files = model("floor", floor)
        files.merge(model("cube", .cubeModel())) { $1 }
        let wallpaper = try ModelFixtureWallpaper(in: scratch, name: "reflection", objects: [
            object(1, "floor", origin: "0 -2 0", extra: #","scale":"4 0.1 4""#),
            object(2, "cube", extra: #","reflected":false"#),
        ], files: files)
        let harness = try draw(wallpaper)
        defer { harness.close() }
        XCTAssertNotNil(harness.renderer.planarReflection?.texture, "the reflective model makes the target")
        XCTAssertEqual(harness.renderer.planarReflection?.drawnModels, [], "nothing is reflected")
        XCTAssertGreaterThan(harness.models?.meshDraws["1"] ?? 0, 0)
        XCTAssertGreaterThan(harness.models?.meshDraws["2"] ?? 0, 0)
    }

    /// A shadowed spot in the budget whose scene has no caster (the only model doesn't cast): the
    /// map is drawn empty, and the lit model reads it.
    func testAShadowedLightWithNoCasters() throws {
        _ = try Fixtures.assets()
        let wallpaper = try ModelFixtureWallpaper(in: scratch, name: "no-casters", objects: [
            object(1, "lit", origin: "0 -1 0", extra: #","castshadow":false,"scale":"3 0.2 3""#),
            #"{"id":2,"name":"spot","light":"lspot","origin":"0 4 0","angles":"-1.5708 0 0","castshadow":true,"#
                + #""color":"1 1 1","intensity":4,"radius":20}"#,
        ], general: #""clearcolor":"0 0 0","hdr":true,"lightconfig":{"spot":1,"spotshadow":1}"#,
           files: model("lit", .cubeModel(material: "materials/lit.json")))
        var settings = SceneRenderSettings()
        settings.shadows = .high
        settings.postProcessing = .ultra
        let harness = try draw(wallpaper, settings: settings)
        defer { harness.close() }
        XCTAssertGreaterThan(harness.models?.meshDraws["1"] ?? 0, 0, "the lit model draws")
        XCTAssertEqual(harness.renderer.shadowPass?.casterDraws ?? 0, 0, "nothing casts")
    }

    /// 256 lights of every kind, all casting shadows and volumetrics, against the largest budget:
    /// the budget takes what fits; frames stay finite and bounded.
    func testTwoHundredFiftySixLights() throws {
        _ = try Fixtures.assets()
        let kinds = ["lpoint", "lspot", "ltube", "ldirectional"]
        var objects = [object(1, "lit", origin: "0 -1 0", extra: #","scale":"3 0.2 3""#), object(2, "cube", origin: "0 0.5 0",
                                                                                           extra: #","scale":"0.4 0.4 0.4""#)]
        for index in 0..<256 {
            let angle = Float(index) / 256 * 2 * .pi
            let origin = String(format: "%.3f %.3f %.3f", 3 * cos(angle), 1 + Float(index % 4), 3 * sin(angle))
            objects.append(#"{"id":\#(100 + index),"name":"light \#(index)","light":"\#(kinds[index % 4])","origin":"\#(origin)","#
                + #""angles":"-1.2 \#(angle) 0","castshadow":true,"castvolumetrics":true,"color":"1 0.5 0.25","#
                + #""intensity":1,"radius":6,"controlpoint":"0 1 0"}"#)
        }
        var files = model("lit", .cubeModel(material: "materials/lit.json"))
        files.merge(model("cube", .cubeModel(material: "materials/lit.json"))) { $1 }
        let wallpaper = try ModelFixtureWallpaper(in: scratch, name: "lights", objects: objects, general: """
            "clearcolor":"0 0 0","hdr":true,"lightconfig":{"point":15,"spot":15,"tube":15,"directional":15,"spotshadow":3,\
            "pointshadow":3,"directionalshadow":3,"spotcookie":3,"spotshadowcookie":3}
            """, files: files)
        var settings = SceneRenderSettings()
        settings.shadows = .high
        settings.volumetrics = .high
        settings.postProcessing = .ultra
        let harness = try draw(wallpaper, settings: settings)
        defer { harness.close() }
        XCTAssertEqual(harness.content.lighting.lights.count, 256)
        XCTAssertGreaterThan(harness.models?.meshDraws["1"] ?? 0, 0)
        XCTAssertGreaterThan(harness.renderer.shadowPass?.casterDraws ?? 0, 0, "the budget's shadowed lights cast")
    }
}
