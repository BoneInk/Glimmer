import XCTest
import Metal
import AppKit
import simd
@testable import OpenWallpaperEngine

/// Models drawn headlessly (docs/models-plan.md §4.3 M5): a fixture cube through a fixture shader
/// that colours each face by its normal (`Tests/Fixtures/ModelMaterials`), placed and seen through
/// WE's camera matrices, in a pass with WE's reversed depth; and the planning rules (combos,
/// textures, draw-list order, culling) on WE's own shaders.
final class ModelRenderTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var cache: URL?
    private var materials: ModelMaterialPlanBuilder!
    private var renderer: SceneModelRenderer!
    private var depthStates: SceneDepthStates!

    static let size = 256

    override func setUpWithError() throws {
        let assets = ShaderVariantTests.weAssets
        try XCTSkipUnless(FileManager.default.fileExists(atPath: assets.appending(path: "shaders/generic4.frag").path),
                          "bundled WE shaders missing")
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        let cache = FileManager.default.temporaryDirectory.appending(path: "owe-models-\(UUID().uuidString)")
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
    }

    override func tearDownWithError() throws {
        if let cache { try? FileManager.default.removeItem(at: cache) } // scratch cleanup
    }

    // MARK: - Fixtures

    /// A cube of half-size 1 about the origin, one quad per face with its outward normal, wound
    /// counter-clockwise about it as WE's `.mdl`s are (right-handed); position and normal (0x3).
    static func cube() -> MDLMesh {
        let faces: [(normal: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>)] = [
            (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)), (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
            (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1)), (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)), (SIMD3(0, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, 1, 0)),
        ]
        var floats: [Float] = []
        var indices: [UInt16] = []
        for (face, (normal, u, v)) in faces.enumerated() {
            for corner in [-u - v, u - v, u + v, -u + v] {
                let position = normal + corner
                floats += [position.x, position.y, position.z, normal.x, normal.y, normal.z]
            }
            let base = UInt16(face * 4)
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        return MDLMesh(materials: ["materials/facecolor.json"], flags: 0, format: MDLVertexFormat(rawValue: 0x3),
                       vertexData: floats.withUnsafeBytes { Data($0) }, indexData: indices.withUnsafeBytes { Data($0) })
    }

    private func plan(_ material: String = "materials/facecolor.json") throws -> SceneModelPlan {
        let mesh = Self.cube()
        let built = try materials.build(materialPath: material, mesh: ModelMeshCombos(mesh: mesh, bones: 0, morphTargets: false))
        return SceneModelPlan(path: "cube.mdl", meshes: [SceneModelPlan.Mesh(
            index: 0, material: built, format: mesh.format, vertexData: mesh.vertexData, indexData: mesh.indexData,
            usesUInt32Indices: false, indexCount: mesh.indexCount)],
            bounds: MDLBounds(min: SIMD3(repeating: -1), max: SIMD3(repeating: 1)), skeleton: nil)
    }

    static func camera(eye: SIMD3<Float>, center: SIMD3<Float> = .zero) -> SceneFrameCamera {
        SceneFrameCamera(view: SceneCamera.lookAt(eye: eye, center: center, up: SIMD3(0, 1, 0)),
                         projection: SceneCamera.perspective(fovDegrees: 50, aspect: 1, near: 0.1, far: 100),
                         eye: eye, forward: simd_normalize(center - eye), up: SIMD3(0, 1, 0), fieldOfView: 50)
    }

    static func target(device: MTLDevice, size: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private struct Placed {
        var plan: SceneModelPlan
        var world: simd_float4x4
        var id: String
    }

    /// Draws `models` in order through `camera` into a target with WE's cleared depth; RGBA bytes.
    private func render(_ models: [Placed], camera: SceneFrameCamera) throws -> [UInt8] {
        let objects = models.map { SceneModelObject(id: $0.id, name: $0.id, order: 0, authored: WESceneModel(source: .path("cube.mdl")),
                                                    plan: $0.plan) }
        renderer.setContent(objects, content: SceneMetalContent(size: SIMD2(256, 256), layers: [], particleSystems: [],
                                                                bloom: SceneBloomSettings(enabled: false, strength: 0,
                                                                                          threshold: 0.7, tint: SIMD3(repeating: 1))))
        for model in models { XCTAssertTrue(renderer.waitUntilReady(model.plan, pixelFormat: .bgra8Unorm)) }
        let target = try Self.target(device: device, size: Self.size)
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
        var frame = BuiltinFrameContext()
        frame.camera = camera
        frame.eyePosition = camera.eye
        for (model, object) in zip(models, objects) {
            renderer.draw(object, SceneModelDraw(world: model.world, camera: camera, frame: frame,
                                                 values: EffectGraphTests.FixedValues(), pixelFormat: .bgra8Unorm, sampleCount: 1,
                                                 depth: depthStates, mipMappedFrameBuffer: nil, assetTexture: { _, _ in nil }),
                          encoder: encoder, commandBuffer: buffer)
        }
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        return try TextureUploadTests.read(target, device: device) // RGBA
    }

    private func color(_ bytes: [UInt8], _ pixel: SIMD2<Float>) -> SIMD3<Int> {
        let x = Int(pixel.x), y = Int(pixel.y)
        let index = (y * Self.size + x) * 4
        return SIMD3(Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
    }

    /// Where a world point lands in the target (y down), through WE's view-projection.
    private func pixel(_ point: SIMD3<Float>, _ camera: SceneFrameCamera) -> SIMD2<Float> {
        let clip = camera.viewProjection * SIMD4(point, 1)
        let ndc = SIMD2(clip.x, clip.y) / clip.w
        return SIMD2((ndc.x * 0.5 + 0.5) * Float(Self.size), (0.5 - ndc.y * 0.5) * Float(Self.size))
    }

    private static func near(_ a: SIMD3<Int>, _ b: SIMD3<Int>, _ tolerance: Int = 3) -> Bool {
        let d = a &- b
        return abs(d.x) <= tolerance && abs(d.y) <= tolerance && abs(d.z) <= tolerance
    }

    /// The colour the fixture shader gives a face with outward normal `n`.
    private static func faceColor(_ n: SIMD3<Float>) -> SIMD3<Int> {
        let c = (n * 0.5 + 0.5) * 255
        return SIMD3(Int(c.x.rounded()), Int(c.y.rounded()), Int(c.z.rounded()))
    }

    // MARK: - Placement, depth and culling

    /// The cube's corners land where WE's camera matrices put them (just inside each silhouette
    /// corner is the cube, just outside is the clear colour), and the faces WE draws are the ones
    /// turned to the camera: its outward faces, wound counter-clockwise.
    func testTheCubesCornersAndFacesLandWhereTheCameraPutsThem() throws {
        let camera = Self.camera(eye: SIMD3(3, 2.5, 4))
        let world = SceneWorldMatrix.local(SceneLocalTransform3D(origin: SIMD3(0.2, -0.1, 0.3), scale: SIMD3(1, 0.8, 1.2),
                                                                 angles: SIMD3(0.1, 0.4, -0.2)))
        let bytes = try render([Placed(plan: try plan(), world: world, id: "cube")], camera: camera)
        var corners: [SIMD3<Float>] = []
        for x: Float in [-1, 1] { for y: Float in [-1, 1] { for z: Float in [-1, 1] { corners.append(SIMD3(x, y, z)) } } }
        let projected = corners.map { corner -> SIMD2<Float> in
            let p = world * SIMD4(corner, 1)
            return pixel(SIMD3(p.x, p.y, p.z), camera)
        }
        let centre = projected.reduce(.zero, +) / Float(projected.count)
        // The silhouette's corners: the projected points on the hull (none lies inside the others' triangle fan).
        for point in Self.hull(projected) {
            let outward = simd_normalize(point - centre)
            XCTAssertNotEqual(color(bytes, point - outward * 3), SIMD3(0, 0, 0), "inside corner \(point)")
            XCTAssertEqual(color(bytes, point + outward * 3), SIMD3(0, 0, 0), "outside corner \(point)")
        }
        // Faces: the centre of each face turned to the eye shows its colour.
        let rotation = simd_float3x3(SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z),
                                     SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z),
                                     SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z))
        var seen = 0
        for normal in [SIMD3<Float>(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)] {
            let centreWorld = world * SIMD4(normal, 1)
            let outward = simd_normalize(simd_inverse(rotation).transpose * normal)
            let toEye = camera.eye - SIMD3(centreWorld.x, centreWorld.y, centreWorld.z)
            let shown = color(bytes, pixel(SIMD3(centreWorld.x, centreWorld.y, centreWorld.z), camera))
            let facing = simd_dot(simd_normalize(outward), simd_normalize(toEye))
            if facing > 0.2 {
                seen += 1
                XCTAssertTrue(Self.near(shown, Self.faceColor(normal)), "face \(normal) turned to the eye")
            } else if facing < -0.2 {
                XCTAssertFalse(Self.near(shown, Self.faceColor(normal), 20), "face \(normal) turned away is hidden")
            }
        }
        XCTAssertGreaterThanOrEqual(seen, 2, "faces turned to the camera")
    }

    /// The nearer cube hides the farther one whichever is drawn first (WE's reversed depth, GREATER).
    func testDepthHidesTheFartherCubeWhateverTheOrder() throws {
        let camera = Self.camera(eye: SIMD3(0, 0, 6))
        let red = try plan("materials/facecolor_red.json"), green = try plan("materials/facecolor_green.json")
        let near = Placed(plan: red, world: matrix_identity_float4x4, id: "near")
        let far = Placed(plan: green, world: SceneWorldMatrix.local(SceneLocalTransform3D(origin: SIMD3(0.5, 0.3, -3),
                                                                                          scale: SIMD3(repeating: 2),
                                                                                          angles: .zero)), id: "far")
        let centre = SIMD2<Float>(repeating: Float(Self.size) / 2)
        XCTAssertEqual(color(try render([near, far], camera: camera), centre), SIMD3(255, 0, 0), "drawn later but behind")
        XCTAssertEqual(color(try render([far, near], camera: camera), centre), SIMD3(255, 0, 0), "drawn later and in front")
        let bytes = try render([far, near], camera: camera)
        XCTAssertEqual(color(bytes, SIMD2(Float(Self.size) * 0.75, Float(Self.size) / 2)), SIMD3(0, 255, 0), "the far cube beside")
    }

    /// From inside a cube every face is a back face: WE's default cull mode draws nothing, `nocull`
    /// draws the inner side of the face ahead.
    func testBackFacesAreCulledUnlessNocull() throws {
        let camera = Self.camera(eye: .zero, center: SIMD3(0, 0, -1))
        let big = SceneWorldMatrix.local(SceneLocalTransform3D(origin: .zero, scale: SIMD3(repeating: 5), angles: .zero))
        let centre = SIMD2<Float>(repeating: Float(Self.size) / 2)
        XCTAssertEqual(color(try render([Placed(plan: try plan(), world: big, id: "culled")], camera: camera), centre),
                       SIMD3(0, 0, 0), "all back faces")
        let bytes = try render([Placed(plan: try plan("materials/facecolor_nocull.json"), world: big, id: "nocull")], camera: camera)
        XCTAssertTrue(Self.near(color(bytes, centre), Self.faceColor(SIMD3(0, 0, -1))), "the -z face from inside")
    }

    /// A model wholly outside the frustum isn't drawn (0x1401e5a10); one straddling it is.
    func testModelsOutsideTheFrustumAreCulled() throws {
        let camera = Self.camera(eye: SIMD3(0, 0, 6))
        let box = MDLBounds(min: SIMD3(repeating: -1), max: SIMD3(repeating: 1))
        func inside(_ origin: SIMD3<Float>, scale: Float = 1) -> Bool {
            let world = SceneWorldMatrix.local(SceneLocalTransform3D(origin: origin, scale: SIMD3(repeating: scale), angles: .zero))
            return SceneModelRenderer.isInsideFrustum(box, world: world, viewProjection: camera.viewProjection)
        }
        XCTAssertTrue(inside(.zero))
        XCTAssertTrue(inside(SIMD3(3.5, 0, 0)), "straddling the right plane")
        XCTAssertFalse(inside(SIMD3(20, 0, 0)), "far to the right")
        XCTAssertFalse(inside(SIMD3(0, 0, 10)), "behind the eye")
        XCTAssertFalse(inside(SIMD3(0, 0, -200)), "past the far plane")
        XCTAssertTrue(inside(SIMD3(0, 0, 0), scale: 1000), "around the eye")
        XCTAssertTrue(SceneModelRenderer.isInsideFrustum(.unbounded, world: matrix_identity_float4x4,
                                                         viewProjection: camera.viewProjection), "a model without bounds")
        _ = try render([Placed(plan: try plan(), world: SceneWorldMatrix.local(SceneLocalTransform3D(
            origin: SIMD3(30, 0, 0), scale: SIMD3(repeating: 1), angles: .zero)), id: "away")], camera: camera)
        XCTAssertEqual(renderer.culledModels, ["away"])
        XCTAssertNil(renderer.meshDraws["away"])
    }

    /// The shadow pass's split cull test (a caster's sphere once, each view's planes once) keeps
    /// what the one-pair test keeps.
    func testSplitCullingMatchesTheOnePairTest() {
        let box = MDLBounds(min: SIMD3(-1, -2, -0.5), max: SIMD3(1, 2, 0.5))
        let cameras = [Self.camera(eye: SIMD3(0, 0, 6)), Self.camera(eye: SIMD3(7, 3, -2), center: SIMD3(1, 0, 0))]
        for camera in cameras {
            let frustum = SceneModelCulling.Frustum(camera.viewProjection)
            for x in stride(from: Float(-12), through: 12, by: 1.5) {
                for z in stride(from: Float(-40), through: 12, by: 2.5) {
                    let world = SceneWorldMatrix.local(SceneLocalTransform3D(origin: SIMD3(x, 0.5, z), scale: SIMD3(1, 1, 1),
                                                                             angles: SIMD3(0.3, 0.7, 0)))
                    XCTAssertEqual(frustum.contains(SceneModelCulling.Sphere(box, world: world)),
                                   SceneModelRenderer.isInsideFrustum(box, world: world, viewProjection: camera.viewProjection))
                }
            }
        }
        XCTAssertTrue(SceneModelCulling.Frustum(cameras[0].viewProjection)
            .contains(SceneModelCulling.Sphere(.unbounded, world: matrix_identity_float4x4)), "a model without bounds")
    }

    /// A skinned or morphed mesh draws where its pose puts it, so the model's rest-pose box
    /// can't cull it (or its shadow): with its box wholly off view it still draws; a rigid one
    /// with the same box culls.
    func testDeformingModelIsNotCulledByItsRestBox() throws {
        let cube = try plan()
        let source = cube.meshes[0]
        func model(deforms: Bool) -> SceneModelPlan {
            SceneModelPlan(path: "posed.mdl", meshes: [SceneModelPlan.Mesh(
                index: 0, material: source.material, format: source.format, vertexData: source.vertexData,
                indexData: source.indexData, usesUInt32Indices: false, indexCount: source.indexCount,
                deforms: deforms)], bounds: cube.bounds, skeleton: nil)
        }
        let frustum = SceneModelCulling.Frustum(Self.camera(eye: SIMD3(0, 0, 5)).viewProjection)
        var world = matrix_identity_float4x4
        world.columns.3 = SIMD4(50, 0, 0, 1)
        XCTAssertEqual(model(deforms: false).cullBounds, cube.bounds)
        XCTAssertFalse(frustum.contains(SceneModelCulling.Sphere(model(deforms: false).cullBounds, world: world)))
        XCTAssertTrue(frustum.contains(SceneModelCulling.Sphere(model(deforms: true).cullBounds, world: world)),
                      "a posed model isn't culled at its rest box")
    }

    /// MT5: a triangle list indexing past its vertices (a script's model data may) reads zeros
    /// there, as D3D11 does: those indices name one zero vertex after the vertices, so the buffer
    /// never grows with the index.
    func testIndicesPastTheVerticesReadZeros() throws {
        let cube = try plan()
        let source = cube.meshes[0]
        var indices = [UInt16](repeating: 0, count: source.indexCount)
        _ = indices.withUnsafeMutableBytes { source.indexData.copyBytes(to: $0) }
        indices += [0, 1000, 2]
        let mesh = SceneModelPlan.Mesh(index: 0, material: source.material, format: source.format, vertexData: source.vertexData,
                                       indexData: indices.withUnsafeBytes { Data($0) }, usesUInt32Indices: false,
                                       indexCount: indices.count)
        let padded = SceneModelPlan(path: "past.mdl", meshes: [mesh], bounds: cube.bounds, skeleton: nil)
        let buffers = try XCTUnwrap(renderer.meshBuffers(padded)[0])
        let streams = try XCTUnwrap(SceneModelVertexStreams(source.format), "positions and other attributes")
        let vertexCount = source.vertexData.count / source.format.stride
        XCTAssertEqual(buffers.vertices.length, (vertexCount + 1) * streams.positionStride)
        let attributes = try XCTUnwrap(buffers.attributes)
        XCTAssertEqual(attributes.length, (vertexCount + 1) * streams.attributeStride)
        let drawn = UnsafeBufferPointer(start: buffers.indices.contents().assumingMemoryBound(to: UInt16.self),
                                        count: indices.count)
        XCTAssertEqual(Array(drawn.suffix(3)), [0, UInt16(vertexCount), 2], "the index past the vertices names the zero vertex")
        for (buffer, stride) in [(buffers.vertices, streams.positionStride), (attributes, streams.attributeStride)] {
            let tail = UnsafeRawBufferPointer(start: buffer.contents() + vertexCount * stride, count: buffer.length - vertexCount * stride)
            XCTAssertTrue(tail.allSatisfy { $0 == 0 }, "the padding is zeros")
        }
        // The streams hold each vertex's bytes, position first.
        let original = [UInt8](source.vertexData)
        let positions = UnsafeRawBufferPointer(start: buffers.vertices.contents(), count: vertexCount * streams.positionStride)
        let rest = UnsafeRawBufferPointer(start: attributes.contents(), count: vertexCount * streams.attributeStride)
        for vertex in 0..<vertexCount {
            let start = vertex * source.format.stride
            XCTAssertEqual(Array(positions[(vertex * streams.positionStride)..<((vertex + 1) * streams.positionStride)]),
                           Array(original[start..<(start + streams.positionStride)]))
            XCTAssertEqual(Array(rest[(vertex * streams.attributeStride)..<((vertex + 1) * streams.attributeStride)]),
                           Array(original[(start + streams.positionStride)..<(start + source.format.stride)]))
        }
        // In range: the streams hold the vertices as they are.
        XCTAssertEqual(try XCTUnwrap(renderer.meshBuffers(cube)[0]).vertices.length, vertexCount * streams.positionStride)
        // Only the indices drawn count, and 32-bit ones read as such.
        let wide: [UInt32] = [3, 70_000, 9]
        XCTAssertEqual(SceneModelRenderer.largestIndex(wide.withUnsafeBytes { Data($0) }, uint32: true, count: 3), 70_000)
        XCTAssertEqual(SceneModelRenderer.largestIndex(wide.withUnsafeBytes { Data($0) }, uint32: true, count: 1), 3)
        XCTAssertNil(SceneModelRenderer.largestIndex(Data(), uint32: false, count: 4))
        let clamped = SceneModelRenderer.clampedIndices(wide.withUnsafeBytes { Data($0) }, uint32: true, to: 8)
        XCTAssertEqual(clamped.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }, [3, 8, 8])
    }

    /// An index near the 32-bit limit adds one vertex, not billions of bytes.
    func testAHugeIndexDoesNotGrowTheVertexBuffer() throws {
        let cube = try plan()
        let source = cube.meshes[0]
        let stride = source.format.stride
        let vertexCount = source.vertexData.count / stride
        let indices: [UInt32] = [0, 1, UInt32.max - 1]
        let buffers = try XCTUnwrap(SceneModelRenderer.makeMeshBuffers(device: device, format: source.format,
                                                                        vertices: source.vertexData,
                                                                        indices: indices.withUnsafeBytes { Data($0) },
                                                                        uint32: true, indexCount: 3))
        let total = buffers.vertices.length + (buffers.attributes?.length ?? 0)
        XCTAssertEqual(total, (vertexCount + 1) * stride)
        let drawn = UnsafeBufferPointer(start: buffers.indices.contents().assumingMemoryBound(to: UInt32.self), count: 3)
        XCTAssertEqual(Array(drawn), [0, 1, UInt32(vertexCount)])
    }

    /// M8/M13: a plan uploads once, on any thread, and the renderer draws those buffers; after
    /// the upload the mesh's bytes are still the file's, read from the buffers' storage.
    func testPlanUploadsOnceAndKeepsItsBytes() throws {
        let cube = try plan()
        let vertices = cube.meshes[0].vertexData, indices = cube.meshes[0].indexData
        var uploaded: [SceneModelRenderer.MeshBuffers?] = []
        DispatchQueue.global().sync { uploaded = cube.upload(device: device) }
        let first = try XCTUnwrap(uploaded[0])
        XCTAssertTrue(first.vertices === cube.upload(device: device)[0]?.vertices, "made once")
        XCTAssertTrue(first.vertices === renderer.meshBuffers(cube)[0]?.vertices, "the renderer draws the uploaded buffers")
        XCTAssertEqual(cube.meshes[0].vertexData, vertices)
        XCTAssertEqual(cube.meshes[0].indexData, indices)
        XCTAssertEqual(cube.meshes[0].indexData.withUnsafeBytes { $0.baseAddress }, UnsafeRawPointer(first.indices.contents()),
                       "no second CPU copy of the indices")
        if first.attributes == nil {
            XCTAssertEqual(cube.meshes[0].vertexData.withUnsafeBytes { $0.baseAddress }, UnsafeRawPointer(first.vertices.contents()),
                           "no second CPU copy of one-stream vertices")
        }
    }

    // MARK: - Planning

    /// WE's model combos (0x140224c70) over `generic4`: `SKINNING` from the mesh's blend indices,
    /// `BONECOUNT` rounded up to 16, 32, 64 or 128, `FOG` at its default (no fog without the
    /// scene's, `SceneFogTests`), the engine's `REVERSEDEPTH`;
    /// `REFLECTION` reads `_rt_MipMappedFrameBuffer`, slot 0 the listed albedo.
    func testGeneric4TakesWEsModelCombos() throws {
        XCTAssertEqual([0, 1, 16, 17, 33, 64, 65, 115, 128, 200].map(ModelMeshCombos.boneCount),
                       [16, 16, 16, 32, 64, 64, 128, 128, 128, 128])
        let skinned = MDLMesh(materials: [], flags: 0, format: MDLVertexFormat(rawValue: 0x180000f), vertexData: Data(), indexData: Data())
        let combos = ModelMeshCombos(mesh: skinned, bones: 40, morphTargets: false)
        XCTAssertEqual(combos.combos, ["SKINNING": 1, "BONECOUNT": 64])
        let plan = try materials.build(materialPath: "materials/generic4.json", mesh: combos)
        let variant = try XCTUnwrap(plan.pass.variant)
        XCTAssertEqual(variant.combos["SKINNING"], 1)
        XCTAssertEqual(variant.combos["BONECOUNT"], 64)
        XCTAssertEqual(variant.combos["FOG"], 1, "generic4's default")
        XCTAssertNil(variant.combos["FOG_DIST"])
        XCTAssertEqual(variant.combos["LIGHTING"], 1, "generic4's default")
        XCTAssertEqual(variant.combos["REFLECTION"], 1)
        guard case .mipMappedFrameBuffer? = plan.pass.textures[3] else { return XCTFail("g_Texture3: \(String(describing: plan.pass.textures[3]))") }
        guard case .asset? = plan.pass.textures[0] else { return XCTFail("g_Texture0") }
        XCTAssertEqual(plan.raster, .engineDefault, "WE's engine defaults: depth test and write, back faces culled")
        XCTAssertTrue(plan.isOpaque)
        XCTAssertNotNil(variant.uniforms?.members["g_Bones"], "the bones slot")
    }

    /// A layer's composite (`_rt_imageLayerComposite_<id>_a`) is another object's image, handed
    /// out by id; alpha-to-coverage blending sets `ALPHATOCOVERAGE` and counts as opaque;
    /// `_rt_Reflection` is bound only where the variant samples it (`ScenePlanarReflectionTests`).
    func testRenderTargetsAndBlending() throws {
        XCTAssertEqual(ModelMaterialPlanBuilder.compositeLayerID("_rt_imageLayerComposite_12_a"), "12")
        XCTAssertNil(ModelMaterialPlanBuilder.compositeLayerID("_rt_imageLayerComposite_12_b"))
        XCTAssertNil(ModelMaterialPlanBuilder.compositeLayerID("_rt_FullFrameBuffer"))
        let mesh = Self.cube()
        let composite = try materials.build(materialPath: "materials/composite.json",
                                            mesh: ModelMeshCombos(mesh: mesh, bones: 0, morphTargets: false))
        guard case .fbo(let name)? = composite.pass.textures[0] else { return XCTFail("g_Texture0") }
        XCTAssertEqual(name, "_rt_imageLayerComposite_12_a")
        XCTAssertEqual(composite.pass.variant?.combos["ALPHATOCOVERAGE"], 1)
        XCTAssertTrue(composite.isOpaque && composite.alphaToCoverage)
        let unreflecting = try materials.build(materialPath: "materials/reflection.json",
                                               mesh: ModelMeshCombos(mesh: mesh, bones: 0, morphTargets: false))
        XCTAssertNil(unreflecting.pass.textures[2], "generic2 without REFLECTION doesn't sample _rt_Reflection")
    }

    /// WE's material pass loader sets `ADDITIVE` for a pass blending additively (blend byte 2,
    /// 0x140154c5a), as it sets `ALPHATOCOVERAGE` for byte 3; the lit shaders' fog reads it
    /// (test-risks GP5).
    func testAdditiveBlendingSetsItsCombo() throws {
        let additive = try materials.build(materialPath: "materials/additive.json",
                                           mesh: ModelMeshCombos(mesh: Self.cube(), bones: 0, morphTargets: false))
        XCTAssertEqual(additive.pass.variant?.combos["ADDITIVE"], 1)
        XCTAssertEqual(ImageMaterialPlanBuilder.blendingCombos(blending: "additive"), ["ADDITIVE": 1])
        XCTAssertEqual(ImageMaterialPlanBuilder.blendingCombos(blending: "AlphaToCoverage"), ["ALPHATOCOVERAGE": 1])
        XCTAssertEqual(ImageMaterialPlanBuilder.blendingCombos(blending: "translucent"), [:])
        XCTAssertEqual(ImageMaterialPlanBuilder.blendingCombos(blending: nil), [:])
    }

    /// WE's draw list puts opaque meshes (normal, alpha-to-coverage) before translucent ones
    /// (0x14021a620), and a model is translucent only when no mesh is opaque (0x140225241).
    func testMeshOrderAndTranslucency() throws {
        let opaque = try plan(), translucent = try plan("materials/facecolor_red.json")
        func mesh(_ index: Int, _ plan: SceneModelPlan, blending: String) -> SceneModelPlan.Mesh {
            let material = plan.meshes[0].material
            let pass = SceneEffectPassPlan(command: .render, variantKey: material.pass.variantKey, variant: material.pass.variant,
                                           blending: blending, target: nil, textures: [:], constants: material.pass.constants)
            let changed = ModelMaterialPlan(materialPath: material.materialPath, pass: pass, raster: material.raster,
                                            clampedSlots: [], meshCombos: material.meshCombos, customShader: material.customShader)
            let source = plan.meshes[0]
            return SceneModelPlan.Mesh(index: index, material: changed, format: source.format, vertexData: source.vertexData,
                                       indexData: source.indexData, usesUInt32Indices: false, indexCount: source.indexCount)
        }
        let meshes = [mesh(0, translucent, blending: "translucent"), mesh(1, opaque, blending: "normal"),
                      mesh(2, opaque, blending: "additive"), mesh(3, opaque, blending: "alphatocoverage")]
        let mixed = SceneModelPlan(path: "m", meshes: meshes, bounds: .unbounded, skeleton: nil)
        XCTAssertEqual(mixed.meshes.map(\.index), [1, 3, 0, 2])
        XCTAssertFalse(mixed.isTranslucent)
        let glass = SceneModelPlan(path: "g", meshes: [meshes[0], meshes[2]], bounds: .unbounded, skeleton: nil)
        XCTAssertTrue(glass.isTranslucent)
    }

    /// A shader input takes the mesh's attribute of its D3D semantic: `a_TexCoord` reads a mesh's
    /// `a_TexCoordVec4`; one the mesh lacks has none (it reads zeros).
    func testShaderInputsTakeTheMeshAttributeOfTheirSemantic() {
        let format = MDLVertexFormat(rawValue: 0x27) // position, normal, tangent4, uvVec4
        XCTAssertEqual(SceneModelRenderer.meshAttribute(for: ["a_TexCoord"], in: format)?.name, "a_TexCoordVec4")
        XCTAssertEqual(SceneModelRenderer.meshAttribute(for: ["a_Position"], in: format)?.name, "a_Position")
        XCTAssertNil(SceneModelRenderer.meshAttribute(for: ["a_BlendIndices"], in: format))
        XCTAssertNil(SceneModelRenderer.meshAttribute(for: ["a_TexCoordC1"], in: format))
    }

    /// docs/models-plan.md §5.11: the cube has no texture coordinates, which `generic4` reads. As
    /// WE's own shader it still draws (zeros for them); the same shader taken as a wallpaper's own
    /// makes no pipeline, so the mesh draws nothing.
    func testOnlyACustomShaderLackingAMeshInputDrawsNothing() throws {
        let cube = Self.cube()
        XCTAssertFalse(cube.format.contains(.texCoord))
        func plan(builtin: Bool) throws -> SceneModelPlan {
            var builder = try XCTUnwrap(materials)
            builder.isBuiltinShader = builtin ? { $0 == "generic4" } : nil
            let material = try builder.build(materialPath: "materials/generic4.json",
                                             mesh: ModelMeshCombos(mesh: cube, bones: 0, morphTargets: false))
            XCTAssertEqual(material.customShader, !builtin)
            return SceneModelPlan(path: "cube.mdl", meshes: [SceneModelPlan.Mesh(
                index: 0, material: material, format: cube.format, vertexData: cube.vertexData, indexData: cube.indexData,
                usesUInt32Indices: false, indexCount: cube.indexCount)], bounds: .unbounded, skeleton: nil)
        }
        XCTAssertTrue(renderer.waitUntilReady(try plan(builtin: true), pixelFormat: .bgra8Unorm), "WE's generic4 draws")
        XCTAssertFalse(renderer.waitUntilReady(try plan(builtin: false), pixelFormat: .bgra8Unorm), "a custom shader doesn't")
    }

    /// The bones slot pads a short palette with identities to the shader's `BONECOUNT`.
    func testTheBonesSlotIsPaddedWithIdentities() throws {
        let mesh = MDLMesh(materials: [], flags: 0, format: MDLVertexFormat(rawValue: 0x180000f), vertexData: Data(), indexData: Data())
        let plan = try materials.build(materialPath: "materials/generic4.json", mesh: ModelMeshCombos(mesh: mesh, bones: 3,
                                                                                                     morphTargets: false))
        let layout = try XCTUnwrap(plan.pass.variant?.uniforms)
        let member = try XCTUnwrap(layout.members["g_Bones"])
        XCTAssertEqual(member.count, 16)
        let uniforms = ModelMaterialUniforms(layout: layout, constants: plan.pass.constants)
        let moved = ScenePuppetPose(bones: [matrix_identity_float4x4, ScenePuppetTests.translation(SIMD3(1, 2, 3)),
                                            matrix_identity_float4x4], bonesAlpha: [1, 1, 1])
        uniforms.writeBones(moved.boneComponents)
        let floats = uniforms.bytes.withUnsafeBytes { raw in
            (0..<16).map { bone in (0..<12).map { component -> Float in
                let column = component / 3, row = component % 3
                return raw.load(fromByteOffset: member.offset + bone * member.arrayStride + column * member.matrixStride + row * 4,
                                as: Float.self)
            } }
        }
        XCTAssertEqual(floats[1], [1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 2, 3])
        for bone in [0, 2, 3, 15] { XCTAssertEqual(floats[bone], ModelMaterialUniforms.identityBones(count: 1), "bone \(bone)") }
    }

    // MARK: - Hull

    /// The convex hull of `points` (monotone chain), counter-clockwise.
    static func hull(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let sorted = points.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Float>] = [], upper: [SIMD2<Float>] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}
