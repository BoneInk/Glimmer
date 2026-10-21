import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// Puppets in motion (docs/models-plan.md §4.3 M6, P2): `ScenePuppetAnimator` plays an image's
/// authored animation layers and scripts' bone writes into the palette the mesh is drawn with,
/// and `ScenePuppetRenderer.warp` lays a lit puppet's other textures out like the posed mesh.
final class ScenePuppetAnimationTests: XCTestCase {
    // MARK: - The animator

    private static func rig(bones: Int = 2) -> MDLSkeleton {
        MDLSkeleton(version: 1, bones: (0..<bones).map {
            MDLBone(name: "b\($0)", flags: 1, parent: $0 == 0 ? 0xFFFF_FFFF : 0,
                    matrix: ScenePuppetTests.translation(SIMD3(Float($0) * 10, 0, 0)), properties: "")
        })
    }

    private static func layers(_ json: String) throws -> [WEAnimationLayer] {
        try JSONDecoder().decode([WEAnimationLayer].self, from: Data(json.utf8))
    }

    /// Authored layers make the pose; one naming no clip makes no layer and is reported.
    func testAuthoredLayersPoseTheRig() throws {
        let clip = SceneAnimationLayersTests.clip(id: 41, name: "idle", bones: 2,
                                                  pose: SceneAnimationLayersTests.still(SIMD3(100, 50, 0)))
        var missing: [WEAnimationLayer] = []
        let animator = ScenePuppetAnimator(
            skeleton: Self.rig(), clips: [clip],
            layers: try Self.layers(#"[{"animation": 41, "id": 47, "name": "idle"}, {"animation": 9, "name": "gone"}]"#)) {
            missing.append($0)
        }
        XCTAssertEqual(missing.map(\.name), ["gone"])
        XCTAssertEqual(animator.stack.layers.map(\.key), [47])
        XCTAssertEqual(animator.pose, .bind(boneCount: 2), "the bind pose until the first frame")
        animator.advance(delta: 0.1, values: EmptySceneValues())
        // Both bones at (100, 50) locally: bone 1 ends at its parent's (100, 50) + (100, 50).
        XCTAssertEqual(animator.worlds[1].columns.3, SIMD4(200, 100, 0, 1))
        // Its palette maps the bind position (10, 0) there.
        XCTAssertEqual(animator.pose.bones[1] * SIMD4(10, 0, 0, 1), SIMD4(200, 100, 0, 1))
    }

    /// `rate` and `blend` bound to user properties follow them every frame.
    func testBoundValuesFollowUserProperties() throws {
        struct Values: SceneValueContext {
            var properties: [String: String]
            func userProperty(_ name: String) -> String? { properties[name] }
        }
        let clip = SceneAnimationLayersTests.clip(id: 1, bones: 2, pose: SceneAnimationLayersTests.still(SIMD3(10, 0, 0)))
        let animator = ScenePuppetAnimator(skeleton: Self.rig(), clips: [clip], layers: try Self.layers(
            #"[{"animation": 1, "blend": {"user": "amount", "value": 1}, "rate": {"user": "speed", "value": 1}}]"#))
        animator.advance(delta: 0.5, values: Values(properties: ["amount": "0.25", "speed": "2"]))
        XCTAssertEqual(animator.stack.layers[0].blend, 0.25)
        XCTAssertEqual(animator.stack.layers[0].clock.time, 1, accuracy: 1e-6, "0.5 s at rate 2")
        XCTAssertEqual(animator.locals[0].columns.3.x, 2.5, accuracy: 1e-4, "a quarter of the way from 0 to 10")
    }

    /// A script's `setLocalBoneTransform` lasts on a rig without layers; a rig with layers is
    /// posed again each frame. `setBoneTransform` moves only that bone's palette entry. Scripts
    /// run after the frame's evaluation (WE's object loop 0x1401891a0 runs before the scripts'
    /// `update`), so a write lands on this frame's pose and the next evaluation replaces it.
    func testScriptBoneWrites() throws {
        let still = ScenePuppetAnimator(skeleton: Self.rig(), clips: [], layers: [])
        let moved = ScenePuppetTests.translation(SIMD3(0, 30, 0))
        still.perform(.setLocal(bone: 0, matrix: moved))
        still.advance(delta: 0.1, values: EmptySceneValues())
        still.advance(delta: 0.1, values: EmptySceneValues())
        XCTAssertEqual(still.locals[0], moved)
        XCTAssertEqual(still.worlds[1].columns.3, SIMD4(10, 30, 0, 1), "its child follows")

        let clip = SceneAnimationLayersTests.clip(id: 1, bones: 2, pose: SceneAnimationLayersTests.still(SIMD3(5, 0, 0)))
        let animated = ScenePuppetAnimator(skeleton: Self.rig(), clips: [clip], layers: try Self.layers(#"[{"animation": 1}]"#))
        animated.advance(delta: 0.1, values: EmptySceneValues())
        animated.perform(.setLocal(bone: 0, matrix: moved))
        XCTAssertEqual(animated.locals[0], moved, "on this frame's pose")
        XCTAssertEqual(animated.pose.bones[0] * SIMD4(0, 0, 0, 1), SIMD4(0, 30, 0, 1), "and drawn this frame")
        animated.advance(delta: 0.1, values: EmptySceneValues())
        XCTAssertEqual(animated.locals[0].columns.3, SIMD4(5, 0, 0, 1), "the layers pose it again")

        let world = ScenePuppetTests.translation(SIMD3(-7, -7, 0))
        animated.perform(.setWorld(bone: 0, matrix: world))
        XCTAssertEqual(animated.worlds[0], world)
        XCTAssertEqual(animated.worlds[1].columns.3, SIMD4(10, 0, 0, 1), "children keep their pose (0x14020f350)")
        XCTAssertEqual(animated.pose.bones[0] * SIMD4(0, 0, 0, 1), SIMD4(-7, -7, 0, 1))
    }

    /// Script layers: created by clip name, driven, destroyed.
    func testScriptLayers() throws {
        let clip = SceneAnimationLayersTests.clip(id: 1, name: "wave", mode: "single", bones: 2,
                                                  pose: SceneAnimationLayersTests.still(SIMD3(0, 8, 0)))
        let animator = ScenePuppetAnimator(skeleton: Self.rig(), clips: [clip], layers: [])
        animator.perform(.createLayer(key: 1_048_576, clip: "wave", config: .init(), singlePlay: true))
        animator.perform(.setLayer(key: 1_048_576, field: .rate, value: 4))
        animator.advance(delta: 0.25, values: EmptySceneValues())
        XCTAssertEqual(animator.layerStates.map(\.time), [1])
        XCTAssertEqual(animator.locals[0].columns.3.y, 8)
        animator.advance(delta: 0.5, values: EmptySceneValues())
        XCTAssertTrue(animator.stack.layers.isEmpty, "a single play goes when it finished")
        XCTAssertEqual(animator.lastUpdate.removed, [1_048_576])
        animator.perform(.createLayer(key: 1_048_577, clip: "nope", config: .init(), singlePlay: false))
        XCTAssertTrue(animator.stack.layers.isEmpty, "no clip of that name makes no layer")
    }

    // MARK: - The warp

    /// A texture warped through the posed mesh lands where the mesh pass puts the image: warping
    /// the image itself reproduces the albedo target texel for texel.
    func testAWarpedTextureFollowsTheMesh() throws {
        let setup = try PuppetSetup()
        let image = ScenePuppetTests.picture(width: 32, height: 16, opaque: true)
        let mesh = ScenePuppetTests.mesh(quads: [(SIMD4(-16, 8, 0, -8), SIMD4(0.5, 0, 1, 1)),
                                                 (SIMD4(0, 8, 16, -8), SIMD4(0, 0, 0.5, 1))], bones: [0, 1])
        let plan = try setup.plan(mesh, bones: 2, size: SIMD2(32, 16))
        XCTAssertTrue(setup.renderer.waitUntilReady(plan))
        var pose = ScenePuppetPose.bind(boneCount: 2)
        pose.bones[1] = ScenePuppetTests.translation(SIMD3(3, -2, 0))
        let texture = try ScenePuppetTests.texture(image, device: setup.device)
        let commands = try XCTUnwrap(setup.queue.makeCommandBuffer())
        let albedo = try XCTUnwrap(setup.renderer.albedo(plan, ScenePuppetRenderer.Draw(
            layerID: "p", source: texture, pose: pose, frame: BuiltinFrameContext(), values: EmptySceneValues(),
            assetTexture: { _, _ in nil }), commandBuffer: commands))
        let warped = try XCTUnwrap(setup.renderer.warp(plan, layerID: "p", key: "normal", texture: texture, contentSize: nil,
                                                       pose: pose, commandBuffer: commands))
        commands.commit()
        commands.waitUntilCompleted()
        let expected = try ScenePuppetTestSupport.rgba8(albedo, device: setup.device)
        let actual = try ScenePuppetTestSupport.rgba8(warped, device: setup.device)
        var worst = 0
        for index in expected.indices { worst = max(worst, abs(Int(expected[index]) - Int(actual[index]))) }
        XCTAssertLessThanOrEqual(worst, 1)
        XCTAssertTrue(setup.renderer.warp(plan, layerID: "p", key: "normal", texture: texture, contentSize: nil, pose: pose,
                                          commandBuffer: try XCTUnwrap(setup.queue.makeCommandBuffer())) === warped,
                      "kept until the pose changes")
    }

    // MARK: - The library

    /// The Knight (2515150033): its `idle` layer moves the root bone from the sheet's layout
    /// (−252, −813) to the clip's first frame at load.
    func testTheKnightIsAssembledByItsIdleLayer() throws {
        let directory = LibrarySweepTests.libraryRoot.appending(path: "2515150033", directoryHint: .isDirectory)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: directory.path), "wallpaper library not present")
        let model = try MDLModel.load(path: "models/centurion 1080p_sheet_puppet.mdl", package: nil, directory: directory)
        let skeleton = try XCTUnwrap(model.skeleton)
        let clips = try XCTUnwrap(model.animations)
        let animator = ScenePuppetAnimator(skeleton: skeleton, clips: clips,
                                           layers: try Self.layers(#"[{"animation": 41, "id": 47, "name": "idle", "rate": 1.0}]"#))
        XCTAssertEqual(animator.worlds[0].columns.3.x, skeleton.bones[0].matrix.columns.3.x)
        animator.advance(delta: 0, values: EmptySceneValues())
        let first = try XCTUnwrap(clips.first { $0.id == 41 }).boneTracks[0].pose(at: 0).position
        XCTAssertEqual(animator.worlds[0].columns.3.x, first.x, accuracy: 1e-3)
        XCTAssertEqual(animator.worlds[0].columns.3.y, first.y, accuracy: 1e-3)
        XCTAssertGreaterThan(simd_distance(first, SIMD3(skeleton.bones[0].matrix.columns.3.x, skeleton.bones[0].matrix.columns.3.y,
                                                        skeleton.bones[0].matrix.columns.3.z)), 100)
    }
}

/// `ScenePuppetTests`' renderer and material builder over the bundled shaders.
struct PuppetSetup {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let builder: ImageMaterialPlanBuilder
    let renderer: ScenePuppetRenderer

    init() throws {
        let assets = ShaderVariantTests.weAssets
        try XCTSkipUnless(FileManager.default.fileExists(atPath: assets.appending(path: "shaders/genericimage2.vert").path),
                          "bundled WE shaders missing")
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        let cache = FileManager.default.temporaryDirectory.appending(path: "owe-puppet-anim-\(UUID().uuidString)")
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache)
        let roots = [Fixtures.url("ImageMaterials"), assets]
        builder = ImageMaterialPlanBuilder(
            translator: translator,
            readFile: { path in
                for root in roots {
                    if let data = FileManager.default.contents(atPath: root.appending(path: path).path) { return data }
                }
                return nil
            },
            loadTexture: { _, _ in nil })
        renderer = try XCTUnwrap(ScenePuppetRenderer(device: device, archive: nil))
    }

    func plan(_ mesh: MDLMesh, bones: Int, size: SIMD2<Float>, material: String = "image4",
              model: MDLModel? = nil) throws -> ScenePuppetPlan {
        let source = SceneMetalTextureSource.dxt(TEXCompressedTexture(format: 0, width: Int(size.x), height: Int(size.y),
                                                                      data: [], contentWidth: Int(size.x), contentHeight: Int(size.y)))
        return try ScenePuppetPlan.make(model: model ?? ScenePuppetTests.model(mesh, bones: bones), rigPath: "rig.mdl",
                                        materialPath: "materials/\(material).json", source: source, imageSize: size,
                                        builder: builder)
    }
}
