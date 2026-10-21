import XCTest
import Metal
import AppKit
import simd
@testable import OpenWallpaperEngine

/// Shadows on the GPU (docs/models-plan.md §4.3 M8): a cube over a plane, lit by one shadowed
/// spot, point or directional light. The plane draws through WE's `generic4` with the light
/// budget's shadow combos, reading the atlas `SceneShadowPass` drew the cube into through its
/// shadow variant (`shadowcaster`). The shadow on the plane, where the plane is darker with the
/// cube casting than without it, is compared with a CPU ray test from each pixel's point on the
/// plane to the light.
final class SceneShadowRenderTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var cache: URL?
    private var renderer: SceneModelRenderer!
    private var shadowPass: SceneShadowPass!
    private var depthStates: SceneDepthStates!
    private var white: MTLTexture!

    static let size = 256
    /// The plane's half-size, at y = 0, and the cube (half-size 1) above it.
    static let planeHalf: Float = 7
    static let cubeCentre = SIMD3<Float>(0, 2, 0)

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ShaderVariantTests.weAssets.appending(path: "shaders/generic4.frag").path),
                          "bundled WE shaders missing")
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-shadows-\(UUID().uuidString)")
        renderer = try XCTUnwrap(SceneModelRenderer(device: device, archive: nil))
        shadowPass = try XCTUnwrap(SceneShadowPass(device: device, archive: nil))
        depthStates = try XCTUnwrap(SceneDepthStates(device: device))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        white = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        white.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: [UInt8](repeating: 255, count: 64),
                      bytesPerRow: 16)
    }

    override func tearDownWithError() throws {
        if let cache { try? FileManager.default.removeItem(at: cache) } // scratch cleanup
    }

    // MARK: - Fixtures

    private func builder(_ budget: WELightConfig, quality: Int) -> ModelMaterialPlanBuilder {
        let roots = [Fixtures.url("ModelMaterials"), ShaderVariantTests.weAssets]
        return ModelMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { path in
                for root in roots {
                    if let data = FileManager.default.contents(atPath: root.appending(path: path).path) { return data }
                }
                return nil
            },
            loadTexture: { _, _ in .image(NSImage(size: NSSize(width: 4, height: 4))) },
            sceneEngineCombos: SceneEngineCombos(sceneOrtho: false, lightBudget: budget, shadowQuality: quality))
    }

    /// An upward plane of half-size `planeHalf` at y = 0, wound counter-clockwise about +Y.
    static func plane() -> MDLMesh {
        let u = SIMD3<Float>(planeHalf, 0, 0), v = SIMD3<Float>(0, 0, -planeHalf)
        var floats: [Float] = []
        for corner in [-u - v, u - v, u + v, -u + v] { floats += [corner.x, corner.y, corner.z, 0, 1, 0, 0, 0] }
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]
        return MDLMesh(materials: ["materials/lit.json"], flags: 0, format: MDLVertexFormat(rawValue: 0xb),
                       vertexData: floats.withUnsafeBytes { Data($0) }, indexData: indices.withUnsafeBytes { Data($0) })
    }

    private func plan(_ mesh: MDLMesh, material: String, builder: ModelMaterialPlanBuilder, half: Float) throws -> SceneModelPlan {
        let built = try builder.build(materialPath: material, mesh: ModelMeshCombos(mesh: mesh, bones: 0, morphTargets: false))
        return SceneModelPlan(path: "\(material).mdl", meshes: [SceneModelPlan.Mesh(
            index: 0, material: built, format: mesh.format, vertexData: mesh.vertexData, indexData: mesh.indexData,
            usesUInt32Indices: false, indexCount: mesh.indexCount)],
            bounds: MDLBounds(min: SIMD3(-half, -half, -half), max: SIMD3(half, half, half)), skeleton: nil)
    }

    /// Looking straight down at the plane.
    static let camera: SceneFrameCamera = {
        let eye = SIMD3<Float>(0, 17, 0)
        return SceneFrameCamera(view: SceneCamera.lookAt(eye: eye, center: .zero, up: SIMD3(0, 0, -1)),
                                projection: SceneCamera.perspective(fovDegrees: 50, aspect: 1, near: 0.1, far: 100),
                                eye: eye, forward: SIMD3(0, -1, 0), up: SIMD3(0, 0, -1), fieldOfView: 50)
    }()

    static func lightWorld(position: SIMD3<Float>, direction: SIMD3<Float>) -> simd_float4x4 {
        let x = simd_normalize(direction)
        let z = simd_normalize(simd_cross(x, abs(x.y) > 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)))
        let y = simd_cross(z, x)
        return simd_float4x4(columns: (SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(position, 1)))
    }

    // MARK: - Drawing

    /// The plane drawn with the light, once with the cube casting and once without; RGBA bytes of
    /// each, and the atlas drawn.
    private func render(light: SceneLight, world: simd_float4x4, budget: WELightConfig,
                        quality: Int = 3, cube custom: SceneModelPlan? = nil) throws -> (without: [UInt8], with: [UInt8]) {
        let builder = builder(budget, quality: quality)
        let cube = try custom ?? plan(ModelRenderTests.cube(), material: "materials/facecolor.json", builder: builder, half: 1)
        let plane = try plan(Self.plane(), material: "materials/lit.json", builder: builder, half: Self.planeHalf)
        XCTAssertNotNil(cube.meshes[0].material.shadowCaster, "an opaque material under a shadow budget casts")
        XCTAssertEqual(plane.meshes[0].material.pass.variant?.combos["LIGHTS_SHADOW_MAPPING"], 1)
        let cubeObject = SceneModelObject(id: "cube", name: "cube", order: 0, authored: WESceneModel(source: .path("cube.mdl")),
                                          plan: cube)
        let planeObject = SceneModelObject(id: "plane", name: "plane", order: 1, authored: WESceneModel(source: .path("plane.mdl")),
                                           plan: plane)
        renderer.setContent([cubeObject, planeObject], content: SceneMetalContent(
            size: SIMD2(256, 256), layers: [], particleSystems: [],
            bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7, tint: SIMD3(repeating: 1))))
        shadowPass.setContent()
        XCTAssertTrue(renderer.waitUntilReady(plane, pixelFormat: .bgra8Unorm))
        XCTAssertTrue(shadowPass.waitUntilReady(cube))

        let camera = Self.camera
        let packed = SceneLightPacker.lightingV1(
            [SceneLightPacker.Light(light: light, world: world, localOrigin: .zero, visible: true, id: "light")],
            budget: budget, shadows: true, viewForward: camera.forward,
            shadowContext: SceneLightPacker.ShadowContext(quality: quality, eye: camera.eye, forward: camera.forward,
                                                          orthographic: false, atlasExtent: shadowPass.atlas.extent))
        XCTAssertFalse(packed.shadows.maps.isEmpty)
        var frame = BuiltinFrameContext(time: 1)
        frame.camera = camera
        frame.eyePosition = camera.eye
        frame.viewForward = camera.forward
        frame.lighting = SceneFrameLighting(ambient: .zero, skylight: .zero, arrays: packed.arrays, shadows: packed.shadows)
        let values = EffectGraphTests.FixedValues()
        let caster = SceneShadowPass.Caster(model: cubeObject, world: simd_float4x4(translation: Self.cubeCentre))
        var images: [[UInt8]] = []
        for casters in [[], [caster]] {
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            let drawsBefore = shadowPass.casterDraws
            let atlas = try XCTUnwrap(shadowPass.encode(packed.shadows, casters: casters, models: renderer, frame: frame,
                                                        values: values, assetTexture: { [white] _, _ in white },
                                                        commandBuffer: buffer))
            XCTAssertEqual(shadowPass.casterDraws - drawsBefore, casters.isEmpty ? 0 : SceneShadowPass.batches(packed.shadows.maps).count,
                           "one instanced draw per batch")
            let target = try ModelRenderTests.target(device: device, size: Self.size)
            let depth = SceneDepthBuffer(device: device)
            XCTAssertTrue(depth.prepare(width: Self.size, height: Self.size, sampleCount: 1))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            depth.attach(to: pass, clear: true)
            let encoder = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
            renderer.draw(planeObject, SceneModelDraw(world: matrix_identity_float4x4, camera: camera, frame: frame, values: values,
                                                      pixelFormat: .bgra8Unorm, sampleCount: 1, depth: depthStates,
                                                      mipMappedFrameBuffer: nil, assetTexture: { [white] _, _ in white },
                                                      shadowAtlas: atlas),
                          encoder: encoder, commandBuffer: buffer)
            encoder.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            XCTAssertNil(buffer.error)
            XCTAssertEqual(renderer.meshDraws["plane"], images.count + 1, "the plane drew")
            images.append(try TextureUploadTests.read(target, device: device))
        }
        return (images[0], images[1])
    }

    // MARK: - The CPU reference

    /// Where pixel (x, y) of the target sees the plane; nil off it.
    private static func planePoint(x: Int, y: Int) -> SIMD3<Float>? {
        let ndc = SIMD2(Float(x) + 0.5, Float(y) + 0.5) / Float(size) * SIMD2(2, -2) + SIMD2(-1, 1)
        let inverse = camera.viewProjection.inverse
        func unproject(_ z: Float) -> SIMD3<Float> {
            let p = inverse * SIMD4(ndc.x, ndc.y, z, 1)
            return SIMD3(p.x, p.y, p.z) / p.w
        }
        let near = unproject(1), far = unproject(0.001)
        let t = near.y / (near.y - far.y)
        let point = near + (far - near) * t
        guard abs(point.x) < planeHalf - 0.05, abs(point.z) < planeHalf - 0.05 else { return nil }
        return point
    }

    /// Whether the segment from `origin` along `direction` for `length` crosses the cube.
    private static func hitsCube(_ origin: SIMD3<Float>, _ direction: SIMD3<Float>, length: Float) -> Bool {
        let low = cubeCentre - 1, high = cubeCentre + 1
        var enter: Float = 0, exit = length
        for axis in 0..<3 {
            if abs(direction[axis]) < 1e-9 {
                if origin[axis] < low[axis] || origin[axis] > high[axis] { return false }
                continue
            }
            let a = (low[axis] - origin[axis]) / direction[axis], b = (high[axis] - origin[axis]) / direction[axis]
            enter = max(enter, min(a, b))
            exit = min(exit, max(a, b))
        }
        return enter <= exit
    }

    /// The shadow's pixels on the GPU (darker than half the unshadowed plane) and by the ray test,
    /// over the pixels the light reaches.
    private func compare(_ images: (without: [UInt8], with: [UInt8]), towardLight: (SIMD3<Float>) -> (SIMD3<Float>, Float),
                         label: String, file: StaticString = #filePath, line: UInt = #line) {
        var gpu = 0, cpu = 0, both = 0, lit = 0
        for y in 0..<Self.size {
            for x in 0..<Self.size {
                guard let point = Self.planePoint(x: x, y: y) else { continue }
                let index = (y * Self.size + x) * 4
                let without = Float(images.without[index]), with = Float(images.with[index])
                guard without > 40 else { continue }
                lit += 1
                let (direction, length) = towardLight(point)
                let shadowedByRay = Self.hitsCube(point, direction, length: length)
                let shadowedOnGPU = with < without * 0.5
                if shadowedByRay { cpu += 1 }
                if shadowedOnGPU { gpu += 1 }
                if shadowedByRay && shadowedOnGPU { both += 1 }
            }
        }
        let union = gpu + cpu - both
        let message = "\(label): GPU \(gpu) px, ray test \(cpu) px, both \(both), lit \(lit)"
        print(message)
        XCTAssertGreaterThan(cpu, 500, "the fixture casts a sizeable shadow: \(message)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(Float(gpu - cpu)) / Float(cpu), 0.05, message, file: file, line: line)
        XCTAssertGreaterThanOrEqual(Float(both) / Float(max(union, 1)), 0.9, "overlap: \(message)", file: file, line: line)
    }

    // MARK: - Tests

    private static func light(_ kind: WELightKind) -> SceneLight {
        var light = SceneLight(kind: kind)
        light.color = SIMD3(repeating: 1)
        // Below the 8-bit target's white where it is lit, so a partly shadowed texel shows.
        light.intensity = 2.5
        light.radius = 30
        light.exponent = 1
        light.innerCone = 55
        light.outerCone = 60
        light.castShadow = true
        return light
    }

    func testASpotLightsShadowMatchesTheRayTest() throws {
        let position = SIMD3<Float>(1.2, 7, -0.8)
        let world = Self.lightWorld(position: position, direction: SIMD3(-0.1, -1, 0.05))
        let images = try render(light: Self.light(.spot), world: world, budget: WELightConfig(spot: 1, spotShadow: 1))
        compare(images, towardLight: { point in (simd_normalize(position - point), simd_distance(position, point)) }, label: "spot")
    }

    func testAPointLightsShadowMatchesTheRayTest() throws {
        let position = SIMD3<Float>(-1, 6, 0.7)
        let world = Self.lightWorld(position: position, direction: SIMD3(1, 0, 0))
        let images = try render(light: Self.light(.point), world: world, budget: WELightConfig(point: 1, pointShadow: 1))
        compare(images, towardLight: { point in (simd_normalize(position - point), simd_distance(position, point)) }, label: "point")
    }

    func testADirectionalLightsShadowMatchesTheRayTest() throws {
        let direction = simd_normalize(SIMD3<Float>(0.35, -1, 0.2))
        let world = Self.lightWorld(position: SIMD3(0, 10, 0), direction: direction)
        var light = Self.light(.directional)
        light.intensity = 1.5
        let images = try render(light: light, world: world, budget: WELightConfig(directional: 1, directionalShadow: 1))
        compare(images, towardLight: { _ in (-direction, 100) }, label: "directional")
    }

    /// A script's model data casts with the triangle list `applyData` left, not the one it was
    /// planned with (`SceneModelRenderer.indexCount(of:in:)`): the cube cut to its bottom face
    /// draws 6 indices into the atlas and still shadows the plane.
    func testAScriptMeshCastsWithItsCurrentTriangleList() throws {
        let budget = WELightConfig(spot: 1, spotShadow: 1)
        let mesh = ModelRenderTests.cube()
        let store = SceneScriptModelDataStore()
        let token = store.create(SceneScriptModelData(shapes: [SceneScriptModelData.Shape(
            format: mesh.format, materialPaths: ["materials/facecolor.json"], vertices: mesh.vertexData, indices: mesh.indexData,
            usesUInt32Indices: false, dynamicVertices: false, dynamicIndices: true)],
            bounds: MDLBounds(min: SIMD3(-1, -1, -1), max: SIMD3(1, 1, 1))))
        let cube = try XCTUnwrap(SceneScriptModelPlanBuilder(materials: builder(budget, quality: 3)).plan(
            try XCTUnwrap(store.snapshot(token)?.data), geometry: SceneScriptModelGeometry(store: store, token: token),
            objectName: "cube"))
        let position = SIMD3<Float>(1.2, 7, -0.8)
        let world = Self.lightWorld(position: position, direction: SIMD3(-0.1, -1, 0.05))
        func shadowed(_ images: (without: [UInt8], with: [UInt8])) -> Int {
            stride(from: 0, to: images.without.count, by: 4).filter {
                images.without[$0] > 40 && Float(images.with[$0]) < Float(images.without[$0]) * 0.5
            }.count
        }
        var before = shadowPass.casterIndices
        let whole = try render(light: Self.light(.spot), world: world, budget: budget, cube: cube)
        XCTAssertEqual(shadowPass.casterIndices - before, mesh.indexCount)
        let bottom = Array(mesh.indexData.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }[18..<24])
        try store.apply(token, [SceneScriptModelDataUpdate(indices: bottom.withUnsafeBytes { Data($0) })])
        before = shadowPass.casterIndices
        let face = try render(light: Self.light(.spot), world: world, budget: budget, cube: cube)
        XCTAssertEqual(shadowPass.casterIndices - before, 6, "the list applyData left")
        XCTAssertGreaterThan(shadowed(face), 300, "the bottom face still casts")
        XCTAssertLessThan(shadowed(face), shadowed(whole), "a face casts less than the cube")
    }

    /// A frame that would draw exactly what the atlas holds keeps it (`SceneShadowPass.Recording`):
    /// the second of two identical frames encodes nothing and the atlas reads the same as one
    /// drawn afresh; a moved caster, a moved light, or a frame whose command buffer was never
    /// committed draws again.
    func testAnUnchangedFrameKeepsTheAtlas() throws {
        let budget = WELightConfig(point: 1, pointShadow: 1)
        let builder = builder(budget, quality: 3)
        let cube = try plan(ModelRenderTests.cube(), material: "materials/facecolor.json", builder: builder, half: 1)
        let cubeObject = SceneModelObject(id: "cube", name: "cube", order: 0, authored: WESceneModel(source: .path("cube.mdl")),
                                          plan: cube)
        renderer.setContent([cubeObject], content: SceneMetalContent(
            size: SIMD2(256, 256), layers: [], particleSystems: [],
            bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7, tint: SIMD3(repeating: 1))))
        shadowPass.setContent()
        XCTAssertTrue(shadowPass.waitUntilReady(cube))
        let camera = Self.camera
        func shadows(_ position: SIMD3<Float>) -> SceneShadowFrame {
            SceneLightPacker.lightingV1(
                [SceneLightPacker.Light(light: Self.light(.point), world: Self.lightWorld(position: position, direction: SIMD3(1, 0, 0)),
                                        localOrigin: .zero, visible: true, id: "light")],
                budget: budget, shadows: true, viewForward: camera.forward,
                shadowContext: SceneLightPacker.ShadowContext(quality: 3, eye: camera.eye, forward: camera.forward,
                                                              orthographic: false, atlasExtent: shadowPass.atlas.extent)).shadows
        }
        var frame = BuiltinFrameContext(time: 1)
        frame.camera = camera
        frame.eyePosition = camera.eye
        frame.viewForward = camera.forward
        let values = EffectGraphTests.FixedValues()
        func draw(_ maps: SceneShadowFrame, at centre: SIMD3<Float>, commit: Bool = true) throws -> [UInt8] {
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            let atlas = try XCTUnwrap(shadowPass.encode(
                maps, casters: [SceneShadowPass.Caster(model: cubeObject, world: simd_float4x4(translation: centre))],
                models: renderer, frame: frame, values: values, assetTexture: { [white] _, _ in white }, commandBuffer: buffer))
            guard commit else { return [] }
            buffer.commit()
            buffer.waitUntilCompleted()
            XCTAssertNil(buffer.error)
            return try Self.depthBytes(atlas, device: device, queue: queue)
        }
        let light = SIMD3<Float>(-1, 6, 0.7)
        // The first frame makes the atlas, which the next frames' layout sees.
        _ = try draw(shadows(light), at: Self.cubeCentre)
        let first = try draw(shadows(light + SIMD3(0, 0.25, 0)), at: Self.cubeCentre)
        let drawn = shadowPass.casterDraws, reused = shadowPass.atlasesReused
        let second = try draw(shadows(light + SIMD3(0, 0.25, 0)), at: Self.cubeCentre)
        XCTAssertEqual(shadowPass.casterDraws, drawn, "the unchanged frame draws nothing")
        XCTAssertEqual(shadowPass.atlasesReused, reused + 1)
        XCTAssertEqual(second, first)
        XCTAssertTrue(first.contains { $0 != 0 }, "the cube cast into the atlas")

        _ = try draw(shadows(light), at: Self.cubeCentre + SIMD3(0.5, 0, 0))
        XCTAssertGreaterThan(shadowPass.casterDraws, drawn, "a moved caster draws")
        let afterCaster = shadowPass.casterDraws
        _ = try draw(shadows(light + SIMD3(0, 0.5, 0)), at: Self.cubeCentre + SIMD3(0.5, 0, 0))
        XCTAssertGreaterThan(shadowPass.casterDraws, afterCaster, "a moved light draws")

        // A frame given up before its commit drew nothing; the next frame draws again.
        _ = try draw(shadows(light + SIMD3(0, 0.25, 0)), at: Self.cubeCentre, commit: false)
        let abandoned = shadowPass.casterDraws
        let redrawn = try draw(shadows(light + SIMD3(0, 0.25, 0)), at: Self.cubeCentre)
        XCTAssertGreaterThan(shadowPass.casterDraws, abandoned, "the uncommitted frame's commands are drawn again")
        XCTAssertEqual(redrawn, first, "drawn afresh, the same depth")

        // A new content draws again.
        shadowPass.setContent()
        let afterContent = shadowPass.casterDraws
        _ = try draw(shadows(light), at: Self.cubeCentre)
        XCTAssertGreaterThan(shadowPass.casterDraws, afterContent)
    }

    /// A point light's caster draws only into the faces that hold it, and the atlas reads the same
    /// as when it's drawn into all six.
    func testACasterDrawsOnlyIntoTheFacesThatHoldIt() throws {
        let budget = WELightConfig(point: 1, pointShadow: 1)
        let builder = builder(budget, quality: 3)
        let cube = try plan(ModelRenderTests.cube(), material: "materials/facecolor.json", builder: builder, half: 1)
        let cubeObject = SceneModelObject(id: "cube", name: "cube", order: 0, authored: WESceneModel(source: .path("cube.mdl")),
                                          plan: cube)
        renderer.setContent([cubeObject], content: SceneMetalContent(
            size: SIMD2(256, 256), layers: [], particleSystems: [],
            bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7, tint: SIMD3(repeating: 1))))
        shadowPass.setContent()
        XCTAssertTrue(shadowPass.waitUntilReady(cube))
        let camera = Self.camera
        let light = SIMD3<Float>(-1, 6, 0.7)
        var frame = BuiltinFrameContext(time: 1)
        frame.camera = camera
        frame.eyePosition = camera.eye
        frame.viewForward = camera.forward
        let values = EffectGraphTests.FixedValues()
        func draw(culling: Bool) throws -> (bytes: [UInt8], instances: Int) {
            shadowPass.cullsViews = culling
            shadowPass.setContent()
            let shadows = SceneLightPacker.lightingV1(
                [SceneLightPacker.Light(light: Self.light(.point), world: Self.lightWorld(position: light, direction: SIMD3(1, 0, 0)),
                                        localOrigin: .zero, visible: true, id: "light")],
                budget: budget, shadows: true, viewForward: camera.forward,
                shadowContext: SceneLightPacker.ShadowContext(quality: 3, eye: camera.eye, forward: camera.forward,
                                                              orthographic: false, atlasExtent: shadowPass.atlas.extent)).shadows
            let before = shadowPass.casterInstances
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            let atlas = try XCTUnwrap(shadowPass.encode(
                shadows, casters: [SceneShadowPass.Caster(model: cubeObject, world: simd_float4x4(translation: Self.cubeCentre))],
                models: renderer, frame: frame, values: values, assetTexture: { [white] _, _ in white }, commandBuffer: buffer))
            buffer.commit()
            buffer.waitUntilCompleted()
            XCTAssertNil(buffer.error)
            let instances = shadowPass.casterInstances - before
            return (try Self.depthBytes(atlas, device: device, queue: queue), instances)
        }
        // The first frame makes the atlas at its size.
        _ = try draw(culling: false)
        let all = try draw(culling: false)
        let culled = try draw(culling: true)
        shadowPass.cullsViews = true
        XCTAssertTrue(all.bytes.contains { $0 != 0 }, "the cube cast into the atlas")
        XCTAssertEqual(culled.bytes, all.bytes, "the same depth")
        XCTAssertLessThan(culled.instances, all.instances, "fewer views drawn")
    }

    /// A depth32Float texture's bytes.
    static func depthBytes(_ texture: MTLTexture, device: MTLDevice, queue: MTLCommandQueue) throws -> [UInt8] {
        let rowBytes = texture.width * 4
        let buffer = try XCTUnwrap(device.makeBuffer(length: rowBytes * texture.height, options: .storageModeShared))
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(commands.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * texture.height)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return [UInt8](UnsafeRawBufferPointer(start: buffer.contents(), count: buffer.length))
    }

    /// Without casters the atlas is cleared and every lookup reads lit; a frame without maps binds
    /// the cleared stand-in.
    func testTheClearedAtlasReadsLit() throws {
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let atlas = try XCTUnwrap(shadowPass.encode(SceneShadowFrame(), casters: [], models: renderer, frame: BuiltinFrameContext(),
                                                    values: EffectGraphTests.FixedValues(), assetTexture: { _, _ in nil },
                                                    commandBuffer: buffer))
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertEqual(SIMD2(atlas.width, atlas.height), SIMD2(2, 2))
        XCTAssertEqual(atlas.pixelFormat, .depth32Float)
        XCTAssertEqual(shadowPass.atlas.extent, .zero, "no atlas until a frame has maps")
    }
}

private extension simd_float4x4 {
    init(translation: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(translation, 1)
    }
}
