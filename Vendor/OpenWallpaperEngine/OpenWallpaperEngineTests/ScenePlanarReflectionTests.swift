import XCTest
import Metal
import AppKit
import simd
@testable import OpenWallpaperEngine

/// The planar reflection, `_rt_Reflection` (docs/models-plan.md §2.11, §4.3 M9): a fixture cube
/// above a `generic2` plane that samples it (`Tests/Fixtures/ModelMaterials`), drawn headlessly
/// through `ScenePlanarReflection` and `SceneModelRenderer` with WE's camera matrices.
final class ScenePlanarReflectionTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var cache: URL?
    private var materials: ModelMaterialPlanBuilder!
    private var renderer: SceneModelRenderer!
    private var depthStates: SceneDepthStates!
    private var reflection: ScenePlanarReflection!
    /// What every asset texture draws with (the plane's albedo, tinted black by its material).
    private var white: MTLTexture!

    private static let size = 256
    /// The clear colour, and what the plane shows where the reflection holds it.
    private static let clear = SIMD3<Float>(0, 0, 0.4)
    private static let camera = ModelRenderTests.camera(eye: SIMD3(0, 3, 8))

    override func setUpWithError() throws {
        let assets = ShaderVariantTests.weAssets
        try XCTSkipUnless(FileManager.default.fileExists(atPath: assets.appending(path: "shaders/generic2.frag").path),
                          "bundled WE shaders missing")
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        let cache = FileManager.default.temporaryDirectory.appending(path: "owe-reflection-\(UUID().uuidString)")
        self.cache = cache
        let roots = [Fixtures.url("ModelMaterials"), assets]
        materials = ModelMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { path in
                for root in roots {
                    if let data = FileManager.default.contents(atPath: root.appending(path: path).path) { return data }
                }
                return nil
            },
            loadTexture: { _, _ in .image(NSImage(size: NSSize(width: 4, height: 4))) })
        renderer = try XCTUnwrap(SceneModelRenderer(device: device, archive: nil))
        depthStates = try XCTUnwrap(SceneDepthStates(device: device))
        reflection = ScenePlanarReflection(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        white = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 255, count: 4), bytesPerRow: 4)
    }

    override func tearDownWithError() throws {
        if let cache { try? FileManager.default.removeItem(at: cache) } // scratch cleanup
    }

    // MARK: - Fixtures

    /// A square of half-size 4 in the plane y = 0, facing +y (counter-clockwise seen from above).
    private static func plane() -> MDLMesh {
        let corners: [SIMD3<Float>] = [SIMD3(-4, 0, 4), SIMD3(4, 0, 4), SIMD3(4, 0, -4), SIMD3(-4, 0, -4)]
        let floats: [Float] = corners.flatMap { [$0.x, $0.y, $0.z, 0, 1, 0, 0, 0] }
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]
        return MDLMesh(materials: ["materials/reflective.json"], flags: 0, format: MDLVertexFormat(rawValue: 0xb),
                       vertexData: floats.withUnsafeBytes { Data($0) }, indexData: indices.withUnsafeBytes { Data($0) })
    }

    private func plan(_ mesh: MDLMesh, material: String, bounds: MDLBounds) throws -> SceneModelPlan {
        let built = try materials.build(materialPath: material, mesh: ModelMeshCombos(mesh: mesh, bones: 0, morphTargets: false))
        return SceneModelPlan(path: material, meshes: [SceneModelPlan.Mesh(
            index: 0, material: built, format: mesh.format, vertexData: mesh.vertexData, indexData: mesh.indexData,
            usesUInt32Indices: false, indexCount: mesh.indexCount)], bounds: bounds, skeleton: nil)
    }

    private func cube(_ material: String = "materials/facecolor.json") throws -> SceneModelPlan {
        try plan(ModelRenderTests.cube(), material: material, bounds: MDLBounds(min: SIMD3(repeating: -1), max: SIMD3(repeating: 1)))
    }

    private func mirrorPlane() throws -> SceneModelPlan {
        try plan(Self.plane(), material: "materials/reflective.json",
                 bounds: MDLBounds(min: SIMD3(-4, 0, -4), max: SIMD3(4, 0, 4)))
    }

    private func object(_ id: String, _ plan: SceneModelPlan, reflected: SceneRawValue? = nil) -> SceneModelObject {
        var object = SceneModelObject(id: id, name: id, order: 0, authored: WESceneModel(source: .path(plan.path)), plan: plan)
        if let reflected { object.renderValues[.reflected] = reflected }
        return object
    }

    /// A cube of half-size 0.5 centred at `centre`.
    private static func small(at centre: SIMD3<Float>) -> simd_float4x4 {
        SceneWorldMatrix.local(SceneLocalTransform3D(origin: centre, scale: SIMD3(repeating: 0.5), angles: .zero))
    }

    private func frame() -> BuiltinFrameContext {
        var frame = BuiltinFrameContext()
        frame.camera = Self.camera
        frame.eyePosition = Self.camera.eye
        frame.viewForward = Self.camera.forward
        frame.screenSize = SIMD2(repeating: Float(Self.size))
        return frame
    }

    private func setContent(_ objects: [SceneModelObject]) {
        renderer.setContent(objects, content: SceneMetalContent(size: SIMD2(256, 256), layers: [], particleSystems: [],
                                                                bloom: SceneBloomSettings(enabled: false, strength: 0,
                                                                                          threshold: 0.7, tint: SIMD3(repeating: 1))))
        reflection.setContent()
        for object in objects { XCTAssertTrue(renderer.waitUntilReady(object.plan!, pixelFormat: .bgra8Unorm)) }
    }

    /// The reflection pass over `models` (the reflected list, placed), and its target's RGBA bytes.
    private func reflect(_ models: [(SceneModelObject, simd_float4x4)], enabled: Bool = true) throws -> (MTLTexture, [UInt8]) {
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let pass = ScenePlanarReflection.Pass(
            width: Self.size, height: Self.size, pixelFormat: .bgra8Unorm, clearColor: Self.clear, enabled: enabled,
            objects: models.map { .model($0.0, world: $0.1) }, frame: frame(), values: EffectGraphTests.FixedValues(),
            mipMappedFrameBuffer: nil, shadowAtlas: nil, assetTexture: { [white] _, _ in white })
        let target = try XCTUnwrap(reflection.encode(pass, drawing: renderer, depthStates: depthStates, commandBuffer: buffer))
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        return (target, try TextureUploadTests.read(target, device: device))
    }

    /// The scene pass: `models` through the frame camera with `_rt_Reflection` bound; RGBA bytes.
    private func draw(_ models: [(SceneModelObject, simd_float4x4)], reflection texture: MTLTexture) throws -> [UInt8] {
        let target = try ModelRenderTests.target(device: device, size: Self.size)
        let depth = SceneDepthBuffer(device: device)
        XCTAssertTrue(depth.prepare(width: Self.size, height: Self.size, sampleCount: 1))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        depth.attach(to: pass, clear: true)
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
        for (object, world) in models {
            var draw = SceneModelDraw(world: world, camera: Self.camera, frame: frame(), values: EffectGraphTests.FixedValues(),
                                      pixelFormat: .bgra8Unorm, sampleCount: 1, depth: depthStates, mipMappedFrameBuffer: nil,
                                      assetTexture: { [white] _, _ in white })
            draw.planarReflection = texture
            renderer.draw(object, draw, encoder: encoder, commandBuffer: buffer)
        }
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        return try TextureUploadTests.read(target, device: device) // RGBA
    }

    /// Where a world point lands in the target (y down), through the frame camera.
    private static func pixel(_ point: SIMD3<Float>) -> SIMD2<Int> {
        let clip = camera.viewProjection * SIMD4(point, 1)
        let ndc = SIMD2(clip.x, clip.y) / clip.w
        return SIMD2(Int((ndc.x * 0.5 + 0.5) * Float(size)), Int((0.5 - ndc.y * 0.5) * Float(size)))
    }

    private static func color(_ bytes: [UInt8], _ pixel: SIMD2<Int>) -> SIMD3<Int> {
        let index = (pixel.y * size + pixel.x) * 4
        return SIMD3(Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
    }

    private static func near(_ a: SIMD3<Int>, _ b: SIMD3<Int>, _ tolerance: Int = 3) -> Bool {
        let d = a &- b
        return abs(d.x) <= tolerance && abs(d.y) <= tolerance && abs(d.z) <= tolerance
    }

    private static func byte(_ value: Float) -> Int { Int((value * 255).rounded()) }

    private static let clearBytes = SIMD3(byte(clear.x), byte(clear.y), byte(clear.z))

    // MARK: - Camera

    /// The mirrored camera sees the world mirrored across y = 0: its view-projection of a point
    /// is the frame camera's of the point's mirror; the eye and basis are mirrored.
    func testTheMirroredCameraSeesTheWorldMirroredAcrossYZero() {
        let mirrored = ScenePlanarReflection.mirrored(Self.camera)
        for point in [SIMD3<Float>(0.3, 1.7, -0.4), SIMD3(-2, -0.5, 1), SIMD3(1, 0, 0)] {
            let a = mirrored.viewProjection * SIMD4(point, 1)
            let b = Self.camera.viewProjection * SIMD4(point.x, -point.y, point.z, 1)
            XCTAssertLessThan(simd_length(a - b), 1e-4, "\(point)")
        }
        XCTAssertEqual(mirrored.eye, SIMD3(0, -3, 8))
        XCTAssertEqual(mirrored.forward.y, -Self.camera.forward.y, accuracy: 1e-6)
        XCTAssertEqual(mirrored.up, SIMD3(0, -1, 0))
        XCTAssertEqual(mirrored.projection, Self.camera.projection)
        let frame = ScenePlanarReflection.mirrored(frame())
        XCTAssertEqual(frame.eyePosition, SIMD3(0, -3, 8))
        XCTAssertEqual(frame.camera, mirrored)
    }

    // MARK: - Objects

    /// Only a variant that samples `_rt_Reflection` makes a model reflective: `generic2` with
    /// `REFLECTION` does, `generic2` without it (a dome) doesn't, although `g_Texture2` defaults
    /// to `_rt_Reflection` there.
    func testReflectiveModelsAreTheOnesWhoseVariantSamplesTheTarget() throws {
        let plane = try mirrorPlane()
        guard case .fbo(let name)? = plane.meshes[0].material.pass.textures[2] else {
            return XCTFail("g_Texture2: \(String(describing: plane.meshes[0].material.pass.textures[2]))")
        }
        XCTAssertEqual(name, ScenePlanarReflection.name)
        XCTAssertTrue(ScenePlanarReflection.isReflective(plane))
        let dome = try cube("materials/reflection.json")
        XCTAssertEqual(dome.meshes[0].material.pass.variant?.combos["REFLECTION"] ?? 0, 0)
        XCTAssertNil(dome.meshes[0].material.pass.textures[2], "not sampled without REFLECTION")
        XCTAssertFalse(ScenePlanarReflection.isReflective(dome))
        XCTAssertFalse(ScenePlanarReflection.isReflective(try cube()))
    }

    /// The reflected list: every model with `reflected` (only a literal `false` removes one) that
    /// isn't reflective; the target is needed while any model is reflective, hidden or not.
    func testTheReflectedListExcludesReflectiveAndUnreflectedModels() throws {
        let plane = object("plane", try mirrorPlane())
        let authoredTrue = object("true", try cube(), reflected: .bool(true))
        let byDefault = object("default", try cube())
        let off = object("off", try cube(), reflected: .bool(false))
        let bound = object("bound", try cube(), reflected: .object(.init(value: .bool(false), userName: "mirror")))
        let dome = object("dome", try cube("materials/reflection.json"), reflected: .bool(true))
        let reflectedPlane = object("plane2", try mirrorPlane(), reflected: .bool(true))
        let models = [plane, authoredTrue, byDefault, off, bound, dome, reflectedPlane]
        XCTAssertEqual(reflection.reflectedList(models).map { models[$0].id }, ["true", "default", "bound", "dome"])
        XCTAssertTrue(reflection.isNeeded(models))
        XCTAssertFalse(reflection.isNeeded([authoredTrue, byDefault, dome]), "no model samples the target")
    }

    // MARK: - The pass

    /// The mirrored image lies where the mirror of the cube projects through the frame camera,
    /// showing the faces a mirror shows (the cube's underside and front: the winding flips), and
    /// the plane adds 0.35 of it there (`generic2`), the clear colour elsewhere. With no clip
    /// plane, a cube below y = 0 appears above it in the target.
    func testTheMirroredImageLandsWhereTheMirrorOfTheCubeProjects() throws {
        let plane = object("plane", try mirrorPlane()), cube = object("cube", try cube())
        let below = object("below", try self.cube("materials/facecolor_red.json"))
        setContent([plane, cube, below])
        let above = Self.small(at: SIMD3(0, 2, 0)), under = Self.small(at: SIMD3(2.5, -1.5, 0))
        XCTAssertEqual(reflection.reflectedList([plane, cube, below]), [1, 2])
        let (texture, bytes) = try reflect([(cube, above), (below, under)])
        XCTAssertEqual(reflection.drawnModels, ["cube", "below"])
        // The mirrored cube spans y −2.5…−1.5; from above the eye sees its top, the real cube's
        // bottom (normal −y), and its front (+z).
        let underside = ModelRenderTestsFaces.color(SIMD3(0, -1, 0)), front = ModelRenderTestsFaces.color(SIMD3(0, 0, 1))
        XCTAssertTrue(Self.near(Self.color(bytes, Self.pixel(SIMD3(0, -1.5, 0.1))), underside),
                      "the mirrored top shows the underside: \(Self.color(bytes, Self.pixel(SIMD3(0, -1.5, 0.1))))")
        XCTAssertTrue(Self.near(Self.color(bytes, Self.pixel(SIMD3(0, -2, 0.5))), front),
                      "the mirrored front: \(Self.color(bytes, Self.pixel(SIMD3(0, -2, 0.5))))")
        XCTAssertEqual(Self.color(bytes, Self.pixel(SIMD3(0, 2, 0))), Self.clearBytes, "nothing where the cube itself is")
        XCTAssertEqual(Self.color(bytes, Self.pixel(SIMD3(-2.5, 0.5, 0))), Self.clearBytes)
        // No clip plane: the red cube below y = 0 is mirrored above it.
        XCTAssertEqual(Self.color(bytes, Self.pixel(SIMD3(2.5, 1.5, 0))), SIMD3(255, 0, 0), "mirrored from below")
        XCTAssertEqual(Self.color(bytes, Self.pixel(SIMD3(2.5, -1.5, 0))), Self.clearBytes)

        // The scene pass: the plane samples the target at its own screen position.
        let identity = matrix_identity_float4x4
        let scene = try draw([(plane, identity), (cube, above)], reflection: texture)
        // A point on the plane in front of the mirrored front face (the ray from the eye to it
        // meets y = 0 at z ≈ 3.6); the plane adds 0.35 of the face's colour there.
        let onPlane = Self.pixel(SIMD3(0, -2.1, 0.5))
        XCTAssertEqual(Self.color(bytes, onPlane), Self.color(bytes, onPlane &+ SIMD2(0, 3)), "a uniform patch of the reflection")
        let expected = SIMD3(Self.byte(Float(front.x) / 255 * 0.35), Self.byte(Float(front.y) / 255 * 0.35),
                             Self.byte(Float(front.z) / 255 * 0.35))
        XCTAssertTrue(Self.near(Self.color(scene, onPlane), expected, 3), "0.35 of the reflection: \(Self.color(scene, onPlane))")
        let bare = Self.pixel(SIMD3(-3, 0, 2))
        XCTAssertTrue(Self.near(Self.color(scene, bare), SIMD3(0, 0, Self.byte(Self.clear.z * 0.35)), 2),
                      "0.35 of the clear colour: \(Self.color(scene, bare))")
    }

    /// With the reflection setting off, nothing is drawn and the target holds the clear colour.
    func testTheSettingOffLeavesTheTargetCleared() throws {
        let cube = object("cube", try cube())
        setContent([cube])
        _ = try reflect([(cube, Self.small(at: SIMD3(0, 2, 0)))])
        XCTAssertEqual(reflection.drawnModels, ["cube"])
        let (_, bytes) = try reflect([(cube, Self.small(at: SIMD3(0, 2, 0)))], enabled: false)
        XCTAssertEqual(reflection.drawnModels, [])
        var other = 0
        for pixel in 0..<(Self.size * Self.size) {
            let c = SIMD3(Int(bytes[4 * pixel]), Int(bytes[4 * pixel + 1]), Int(bytes[4 * pixel + 2]))
            if c != Self.clearBytes { other += 1 }
        }
        XCTAssertEqual(other, 0, "every pixel the clear colour")
    }
}

/// The fixture shader's face colours (`facecolor.frag`: the normal as a colour).
enum ModelRenderTestsFaces {
    static func color(_ n: SIMD3<Float>) -> SIMD3<Int> {
        let c = (n * 0.5 + 0.5) * 255
        return SIMD3(Int(c.x.rounded()), Int(c.y.rounded()), Int(c.z.rounded()))
    }
}
