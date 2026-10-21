import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// Depth, draw order and 2D layers in perspective scenes (docs/models-plan.md §2.4, M4): WE's pass
/// state tables, the object loop's order modes, and a layer quad drawn through a 3D camera, with
/// the depth buffer and culling, on the GPU through the bundled WE shaders.
final class SceneDepthDrawTests: XCTestCase {
    // MARK: - Pass state (0x1401577e0)

    func testPassStateDefaultsAreWEsEngineDefaults() {
        let unauthored = SceneRasterState(depthtest: nil, depthwrite: nil, cullmode: nil)
        XCTAssertEqual(unauthored, SceneRasterState(depthTest: true, depthWrite: true, cullsBackFaces: true))
        XCTAssertEqual(unauthored, .engineDefault)
        XCTAssertEqual(unauthored.depthMode, .testAndWrite)
        XCTAssertEqual(unauthored.cullMode, .back)
    }

    func testPassStateTable() {
        let cases: [(String?, String?, String?, SceneRasterState.DepthMode, MTLCullMode)] = [
            ("enabled", "enabled", "normal", .testAndWrite, .back),
            ("enabled", "disabled", "nocull", .testOnly, .none),
            ("disabled", "disabled", "nocull", .off, .none),
            // Without a test D3D writes nothing: WE has three states (0x140099050).
            ("disabled", "enabled", "normal", .off, .back),
            ("DISABLED", nil, "NoCull", .off, .none),
            ("bogus", "bogus", "bogus", .testAndWrite, .back),
        ]
        for (test, write, cull, mode, cullMode) in cases {
            let state = SceneRasterState(depthtest: test, depthwrite: write, cullmode: cull)
            XCTAssertEqual(state.depthMode, mode, "\(String(describing: test)) \(String(describing: write))")
            XCTAssertEqual(state.cullMode, cullMode, String(describing: cull))
        }
        XCTAssertEqual(SceneRasterState.disabled.depthMode, .off)
        XCTAssertEqual(SceneRasterState.disabled.cullMode, .none)
    }

    /// WE's context ORs "no write" into the depth-stencil state of every translucent or additive
    /// draw (0x140099f84), whatever the pass authors; normal and alpha-to-coverage keep it.
    func testBlendedPassesWriteNoDepth() {
        let cases: [(String?, SceneRasterState.DepthMode)] = [
            (nil, .testAndWrite), ("normal", .testAndWrite), ("alphatocoverage", .testAndWrite), ("disabled", .testAndWrite),
            ("translucent", .testOnly), ("Additive", .testOnly),
        ]
        for (blending, mode) in cases {
            let state = SceneRasterState(depthtest: "enabled", depthwrite: "enabled", cullmode: "nocull", blending: blending)
            XCTAssertEqual(state.depthMode, mode, String(describing: blending))
        }
        XCTAssertEqual(SceneRasterState(depthtest: "disabled", depthwrite: nil, cullmode: nil, blending: "translucent").depthMode, .off)
    }

    func testTextDrawsThroughBasefontOrBasefontDepth() {
        // basefont_depth.json: test on; basefont.json: off; both nocull and translucent, so neither writes.
        XCTAssertEqual(SceneRasterState.text(depthTest: true).depthMode, .testOnly)
        XCTAssertEqual(SceneRasterState.text(depthTest: false).depthMode, .off)
        XCTAssertEqual(SceneRasterState.text(depthTest: true).cullMode, .none)
    }

    func testDepthStatesCompareGreater() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        XCTAssertNotNil(SceneDepthStates(device: device))
        XCTAssertEqual(SceneDepthStates.format, .depth32Float)
        // WE's clear value 0 through the translator's (z + w) / 2.
        XCTAssertEqual(SceneDepthStates.clearDepth, 0.5)
    }

    func testPipelineKeysWithoutDepthAreUnchanged() throws {
        let pass = SceneEffectPassPlan(command: .render, variantKey: "v", variant: nil, blending: "translucent",
                                       target: nil, textures: [:], constants: ShaderConstantResolver.ResolvedConstants(staticValues: [:], dynamic: []))
        XCTAssertEqual(ImageMaterialRenderer.pipelineKey(pass, pixelFormat: .bgra8Unorm), "image|v|80|translucent")
        XCTAssertEqual(ImageMaterialRenderer.pipelineKey(pass, pixelFormat: .bgra8Unorm, depthFormat: .depth32Float),
                       "image|v|80|translucent|d252")
    }

    // MARK: - Draw order (0x14018aac0)

    private func entries() -> [SceneDrawEntry] {
        [
            SceneDrawEntry(item: .layer(0), sortOrder: 3, translucent: true, origin: SIMD3(0, 0, -1)),
            SceneDrawEntry(item: .particles(0), sortOrder: 1, translucent: true, origin: SIMD3(0, 0, -5)),
            SceneDrawEntry(item: .model(0), sortOrder: 2, translucent: false, origin: SIMD3(0, 0, -9)),
            SceneDrawEntry(item: .layer(1), sortOrder: 1, translucent: true, origin: SIMD3(0, 0, -5), drawsLast: true),
            SceneDrawEntry(item: .layer(2), sortOrder: 0, translucent: false, origin: SIMD3(0, 0, -2)),
            SceneDrawEntry(item: .layer(3), sortOrder: 0, translucent: true, origin: SIMD3(0, 0, -5)),
        ]
    }

    func testSceneOrderKeepsTheList() {
        XCTAssertEqual(SceneDrawOrderMode.sceneOrder.ordered(entries(), forward: SIMD3(0, 0, -1)),
                       entries().map(\.item))
        XCTAssertFalse(SceneDrawOrderMode.sceneOrder.reorders)
    }

    func testCustomSortOrderIsAStableAscendingSort() {
        let mode = SceneDrawOrderMode(sortsBySortOrder: true)
        XCTAssertEqual(mode.ordered(entries(), forward: SIMD3(0, 0, -1)),
                       [.layer(2), .layer(3), .particles(0), .layer(1), .model(0), .layer(0)])
    }

    func testTransparentSortingDrawsOpaqueFirstThenTranslucentBackToFront() {
        let mode = SceneDrawOrderMode(splitsTranslucent: true)
        // Looking down −z: dot(origin, forward) = −z, larger is farther, drawn first. Equal keys
        // keep list order; a fullscreen layer (flag 0x200) draws last.
        XCTAssertEqual(mode.ordered(entries(), forward: SIMD3(0, 0, -1)),
                       [.model(0), .layer(2), .particles(0), .layer(3), .layer(0), .layer(1)])
        // Looking the other way the translucent order reverses, ties still in list order.
        XCTAssertEqual(mode.ordered(entries(), forward: SIMD3(0, 0, 1)),
                       [.model(0), .layer(2), .layer(0), .particles(0), .layer(3), .layer(1)])
    }

    func testTheModeFollowsTheSceneFlags() {
        var settings = SceneCameraSettings()
        settings.transparentSorting = true
        settings.projection = .perspective
        XCTAssertEqual(SceneDrawOrderMode(settings), SceneDrawOrderMode(splitsTranslucent: true))
        settings.projection = .orthographic(width: 1920, height: 1080)
        XCTAssertEqual(SceneDrawOrderMode(settings), .sceneOrder, "transparentsorting needs a perspective scene")
        settings.customSortOrder = true
        XCTAssertEqual(SceneDrawOrderMode(settings), .sceneOrder, "customsortorder needs transparentsorting off")
        settings.transparentSorting = false
        XCTAssertEqual(SceneDrawOrderMode(settings), SceneDrawOrderMode(sortsBySortOrder: true))
    }

    func testImageTranslucency() {
        // 0x1401fb31b: translucent unless normal or alpha-to-coverage; passthrough models are
        // translucent unless they are solid layers.
        XCTAssertTrue(SceneDrawEntry.imageIsTranslucent(blending: "translucent"))
        XCTAssertTrue(SceneDrawEntry.imageIsTranslucent(blending: "additive"))
        XCTAssertFalse(SceneDrawEntry.imageIsTranslucent(blending: "normal"))
        XCTAssertFalse(SceneDrawEntry.imageIsTranslucent(blending: "alphatocoverage"))
        XCTAssertFalse(SceneDrawEntry.imageIsTranslucent(blending: nil))
        XCTAssertTrue(SceneDrawEntry.imageIsTranslucent(blending: "normal", passthrough: true))
        XCTAssertFalse(SceneDrawEntry.imageIsTranslucent(blending: "normal", passthrough: true, solidLayer: true))
    }

    func testSortOrderAndTextDepthResolveFromTheObjects() throws {
        let json = """
        {"camera":{},"general":{"orthogonalprojection":null},"objects":[
         {"id":1,"name":"a","image":"models/a.json","sortorder":4},
         {"id":2,"name":"t","text":{"value":"x"},"depthtest":"enabled"},
         {"id":3,"name":"u","text":{"value":"y"},"depthtest":"disabled","sortorder":{"value":-2}},
         {"id":4,"name":"p","image":"models/a.json","perspective":true}]}
        """
        let scene = try decodeTolerant(WEScene.self, from: Data(json.utf8))
        let builder = SceneSpatialContentBuilder(readFile: { _ in nil }, wallpaperName: "test")
        let spatial = builder.build(scene, context: SpatialProperties())
        XCTAssertEqual(spatial.sortOrder(of: "1"), 4)
        XCTAssertEqual(spatial.sortOrder(of: "3"), -2)
        XCTAssertEqual(spatial.sortOrder(of: "4"), 0)
        XCTAssertEqual(spatial.depthTest(of: "2"), true)
        XCTAssertEqual(spatial.depthTest(of: "3"), false)
        XCTAssertNil(spatial.depthTest(of: "1"))
    }

    /// A `perspective` layer of an orthographic scene is placed from the scene's hierarchy, whose
    /// root without an `origin` sits at 0 as on the 2D path (§5.13).
    func testAnOrthographicSceneWithPerspectiveLayersPutsRootsAtZeroLikeThe2DPath() throws {
        let json = """
        {"camera":{},"general":{"orthogonalprojection":{"width":1000,"height":500}},"objects":[
         {"id":1,"name":"p","image":"models/a.json","perspective":true},
         {"id":2,"name":"q","image":"models/a.json","origin":"10 20 30"}]}
        """
        let scene = try decodeTolerant(WEScene.self, from: Data(json.utf8))
        let spatial = SceneSpatialContentBuilder(readFile: { _ in nil }, wallpaperName: "test")
            .build(scene, context: SpatialProperties())
        XCTAssertEqual(spatial.transforms.nodes["1"]?.local.origin, .zero)
        XCTAssertEqual(spatial.transforms.nodes["2"]?.local.origin, SIMD3(10, 20, 30))
        XCTAssertEqual(SceneTransformHierarchy(objects: scene.objects).nodes["1"]?.local.origin, .zero)
    }

    // MARK: - Placement

    private static let targetSize = SIMD2<Float>(256, 128)

    /// A camera at (0, 0, 5) looking down −z, 60° vertical fov, the target's aspect.
    private static func camera(eye: SIMD3<Float> = SIMD3(0, 0, 5)) -> SceneFrameCamera {
        let aspect = targetSize.x / targetSize.y
        return SceneFrameCamera(view: SceneCamera.lookAt(eye: eye, center: eye - SIMD3(0, 0, 5), up: SIMD3(0, 1, 0)),
                                projection: SceneCamera.perspective(fovDegrees: 60, aspect: aspect, near: 0.1, far: 100),
                                eye: eye, forward: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0), fieldOfView: 60)
    }

    private static func world(_ local: SceneLocalTransform3D) -> simd_float4x4 { SceneWorldMatrix.local(local) }

    func testAQuadLandsWhereTheWorldMatrixAndTheCameraPutIt() throws {
        let local = SceneLocalTransform3D(origin: SIMD3(0.5, -0.25, -1), scale: SIMD3(0.01, 0.01, 0.01),
                                          angles: SIMD3(0.3, 0.2, 0.1))
        let placement = SceneLayerPlacement(world: Self.world(local), size: SIMD2(200, 100), offset: SIMD2(10, 0),
                                            camera: Self.camera())
        for uv in ImageMaterialRenderer.corners {
            let corner = placement.corner(uv)
            let point: SIMD4<Float> = SIMD4<Float>(corner, 1)
            let cameraMatrix: simd_float4x4 = placement.camera.projection * placement.camera.view
            let clip: SIMD4<Float> = cameraMatrix * (placement.world * point)
            let placed: SIMD4<Float> = placement.modelViewProjection * point
            // Products grouped differently round differently in the last bit.
            XCTAssertLessThan(simd_length(placed - clip), 1e-5)
            // The shaders' view-projection is y-flipped; their vertex stage flips it back.
            let shader: SIMD4<Float> = placement.shaderViewProjection * (placement.world * point)
            let unflipped = SIMD4<Float>(shader.x, -shader.y, shader.z, shader.w)
            XCTAssertLessThan(simd_length(unflipped - clip), 1e-5)
        }
        // The top-left corner: object (−100 + 10, 50), 1/100 scale, rotated, then projected.
        let point = try XCTUnwrap(placement.pixel(placement.corner(SIMD2(0, 0)), targetSize: Self.targetSize))
        let objectPoint = SIMD4<Float>(-90, 50, 0, 1)
        let viewProjection: simd_float4x4 = Self.camera().viewProjection
        let clip: SIMD4<Float> = viewProjection * (Self.world(local) * objectPoint)
        let ndcX: Float = clip.x / clip.w
        let ndcY: Float = clip.y / clip.w
        let expectedX: Float = (ndcX * 0.5 + 0.5) * 256
        let expectedY: Float = (0.5 - ndcY * 0.5) * 128
        let expected = SIMD2<Float>(expectedX, expectedY)
        XCTAssertEqual(point.x, expected.x, accuracy: 1e-3)
        XCTAssertEqual(point.y, expected.y, accuracy: 1e-3)
    }

    func testPassContextTakesTheCameraMatrices() {
        let placement = SceneLayerPlacement(world: Self.world(SceneLocalTransform3D(origin: SIMD3(1, 2, 3), scale: SIMD3(2, 2, 2),
                                                                                     angles: .zero)),
                                            size: SIMD2(1, 1), camera: Self.camera())
        var pass = BuiltinPassContext(targetSize: Self.targetSize)
        pass.place(placement)
        XCTAssertEqual(pass.modelMatrix, placement.world)
        XCTAssertEqual(pass.viewMatrix, placement.camera.view)
        XCTAssertEqual(pass.viewProjection, PassMatrices.flipY * placement.camera.viewProjection)
        XCTAssertEqual(pass.modelViewProjection, pass.viewProjection * placement.world)
        let mvp = BuiltinUniforms.value(named: "g_ModelViewProjectionMatrix", frame: BuiltinFrameContext(), pass: pass)
        XCTAssertEqual(mvp, [pass.modelViewProjection.columns.0, pass.modelViewProjection.columns.1,
                             pass.modelViewProjection.columns.2, pass.modelViewProjection.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] })
    }

    func testThePerspectiveLayerCameraFramesTheSceneLikeTheOrthographicOne() throws {
        let size = SIMD2<Float>(1920, 1080)
        let camera = SceneLayerPlacement.perspectiveLayerCamera(sceneSize: size, fov: 95)
        // 0x1401e5b60: d = (h/2)/tan(fov/2), near 5, far max(15000, d + 1000).
        let distance = 540 / tan(95 * Float.pi / 360)
        XCTAssertEqual(camera.eye.z, distance, accuracy: 1e-3)
        let flat = SceneLayerPlacement(world: matrix_identity_float4x4, size: SIMD2(1, 1), camera: camera)
        for point in [SIMD3<Float>(0, 0, 0), SIMD3(1920, 1080, 0), SIMD3(300, 700, 0), SIMD3(960, 540, 0)] {
            let pixel = try XCTUnwrap(flat.pixel(point, targetSize: size))
            XCTAssertEqual(pixel.x, point.x, accuracy: 0.05)
            XCTAssertEqual(pixel.y, size.y - point.y, accuracy: 0.05)
        }
        // Depth shows perspective: a point towards the camera spreads out from the centre.
        let near = try XCTUnwrap(flat.pixel(SIMD3(1920, 540, 200), targetSize: size))
        XCTAssertGreaterThan(near.x, 1920)
    }

    func testTextRasterDensityFollowsTheProjection() throws {
        // 1 unit at distance 5 with a 60° fov over 128 rows: 128 / (2·5·tan 30°) px.
        let placement = SceneLayerPlacement(world: matrix_identity_float4x4, size: SIMD2(1, 1), camera: Self.camera())
        let expected = 128 / (2 * 5 * tan(Float.pi / 6))
        XCTAssertEqual(try XCTUnwrap(placement.pixelsPerUnit(targetSize: Self.targetSize)), expected, accuracy: 1e-2)
        let behind = SceneLayerPlacement(world: SceneWorldMatrix.local(SceneLocalTransform3D(origin: SIMD3(0, 0, 10),
                                                                                              scale: SIMD3(1, 1, 1), angles: .zero)),
                                         size: SIMD2(1, 1), camera: Self.camera())
        XCTAssertNil(behind.pixelsPerUnit(targetSize: Self.targetSize), "behind the eye")
    }

    func testParticleOrientationFacesTheCamera() {
        let orientation = ParticleOrientation()
        let axes = orientation.axes(linear: matrix_identity_float2x2, cameraForward: SIMD3(1, 0, 0), cameraUp: SIMD3(0, 1, 0))
        XCTAssertEqual(axes.forward, SIMD3(-1, 0, 0))
        XCTAssertEqual(axes.up, SIMD3(0, 1, 0))
        XCTAssertEqual(axes.right, simd_cross(SIMD3(0, 1, 0), SIMD3(-1, 0, 0)))
        let flat = orientation.axes(linear: matrix_identity_float2x2)
        XCTAssertEqual(flat.forward, SIMD3(0, 0, 1), "the 2D camera looks down −z")
    }

    // MARK: - GPU: the quad, depth and culling

    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var builder: ImageMaterialPlanBuilder!
    private var renderer: ImageMaterialRenderer!
    private var cache: URL?
    private var depthStates: SceneDepthStates!

    private func setUpGPU() throws {
        let assets = ShaderVariantTests.weAssets
        try XCTSkipUnless(FileManager.default.fileExists(atPath: assets.appending(path: "shaders/genericimage4.frag").path),
                          "bundled WE shaders missing")
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        let cache = FileManager.default.temporaryDirectory.appending(path: "owe-depth-\(UUID().uuidString)")
        self.cache = cache
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
        renderer = try XCTUnwrap(ImageMaterialRenderer(device: device, archive: nil))
        depthStates = try XCTUnwrap(SceneDepthStates(device: device))
    }

    override func tearDownWithError() throws {
        if let cache { try? FileManager.default.removeItem(at: cache) } // scratch cleanup
    }

    private struct Quad {
        var local: SceneLocalTransform3D
        var color: [UInt8]
        var raster: SceneRasterState? = nil
    }

    /// Draws `quads` in order through `depthcull.json` (normal blending, depth test and write, back
    /// faces culled; or `material`) and the test camera into a bgra8 target with a depth32Float attachment
    /// cleared to WE's far depth; returns RGBA bytes.
    private func render(_ quads: [Quad], material: String = "depthcull", nativeQuads: [Quad] = []) throws -> [UInt8] {
        let plan = try XCTUnwrap(try builder.build(materialPath: "materials/\(material).json", colorBlendMode: nil))
        let format = MTLPixelFormat.bgra8Unorm
        XCTAssertTrue(renderer.waitUntilReady(plan, pixelFormat: format, depthFormat: SceneDepthStates.format))
        let width = Int(Self.targetSize.x), height = Int(Self.targetSize.y)
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        colorDescriptor.usage = [.renderTarget]
        colorDescriptor.storageMode = .private
        let target = try XCTUnwrap(device.makeTexture(descriptor: colorDescriptor))
        let depth = SceneDepthBuffer(device: device)
        XCTAssertTrue(depth.prepare(width: width, height: height, sampleCount: 1))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        depth.attach(to: pass, clear: true)
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
        for quad in quads {
            let texture = try ImageMaterialRenderTests.solidTexture(device: device, color: quad.color)
            let placement = SceneLayerPlacement(world: Self.world(quad.local), size: SIMD2(1, 1), camera: Self.camera())
            XCTAssertTrue(renderer.draw(plan, ImageMaterialRenderer.Draw(
                layerID: "\(quad.color)", quad: SceneQuadGeometry(center: .zero, axisX: SIMD2(1, 0), axisY: SIMD2(0, 1)),
                sceneSize: Self.targetSize, color: SIMD3(repeating: 1), alpha: 1, brightness: 1, texture: texture,
                contentSize: nil, uvOrigin: .zero, uvAxisX: SIMD2(1, 0), uvAxisY: SIMD2(0, 1), sceneSnapshot: nil,
                frame: BuiltinFrameContext(), values: EffectGraphTests.FixedValues(), assetTexture: { _, _ in nil },
                placement: placement, raster: quad.raster),
                pixelFormat: format, depth: depthStates, encoder: encoder, commandBuffer: buffer))
        }
        if !nativeQuads.isEmpty {
            let library = try XCTUnwrap(SceneMetalLibrary.make(device: device))
            let pipelines = try SceneLayerPipelines(
                device: device, vertex: try XCTUnwrap(library.makeFunction(name: "sceneVertex")),
                fragment: try XCTUnwrap(library.makeFunction(name: "sceneFragment")),
                copyFragment: try XCTUnwrap(library.makeFunction(name: "sceneCopyFragment")),
                placedVertex: library.makeFunction(name: "sceneVertex3D"), formats: [format])
            let placed = try XCTUnwrap(pipelines.pipelines(for: format, sampleCount: 1, depthFormat: SceneDepthStates.format)?.placedNormal)
            for quad in nativeQuads {
                let texture = try ImageMaterialRenderTests.solidTexture(device: device, color: quad.color)
                var placement = SceneLayerPlacement(world: Self.world(quad.local), size: SIMD2(1, 1), camera: Self.camera()).native
                var uniform = LayerUniform(position: .zero, size: .zero, sceneSize: Self.targetSize, opacity: 1, particleShape: 0,
                                           rotation: 0, color: SIMD4(repeating: 1), uvOrigin: .zero, uvAxisX: SIMD2(1, 0),
                                           uvAxisY: SIMD2(0, 1), effects: SIMD4(1, 1, 1, 0), blur: 0,
                                           colorEffects: SIMD4(0, 1, 0, 0.7), transform: SIMD4(0, 0, 0, 1), transformScaleY: 1)
                encoder.setRenderPipelineState(placed)
                depthStates.apply(quad.raster ?? .engineDefault, to: encoder)
                encoder.setVertexBytes(&placement, length: MemoryLayout<LayerPlacement3D>.stride, index: 1)
                encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
                encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        encoder.endEncoding()
        let bytesPerRow = width * 4
        let readback = try XCTUnwrap(device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared))
        let blit = try XCTUnwrap(buffer.makeBlitCommandEncoder())
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        var bytes = [UInt8](UnsafeBufferPointer(start: readback.contents().assumingMemoryBound(to: UInt8.self), count: readback.length))
        for index in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(index, index + 2) } // BGRA → RGBA
        return bytes
    }

    private func color(_ bytes: [UInt8], _ point: SIMD2<Float>) -> [UInt8] {
        let x = Int(point.x), y = Int(point.y)
        let index = (y * Int(Self.targetSize.x) + x) * 4
        return Array(bytes[index..<index + 3])
    }

    private static let red: [UInt8] = [255, 0, 0, 255]
    private static let green: [UInt8] = [0, 255, 0, 255]

    func testTheQuadCoversExactlyItsProjection() throws {
        try setUpGPU()
        let local = SceneLocalTransform3D(origin: SIMD3(0.4, 0.2, -1), scale: SIMD3(1.5, 1, 1), angles: SIMD3(0.5, 0.3, 0.2))
        let bytes = try render([Quad(local: local, color: Self.red, raster: .text(depthTest: true))])
        let placement = SceneLayerPlacement(world: Self.world(local), size: SIMD2(1, 1), camera: Self.camera())
        let centre = try XCTUnwrap(placement.pixel(SIMD3(0, 0, 0), targetSize: Self.targetSize))
        XCTAssertEqual(color(bytes, centre), [255, 0, 0], "the quad's centre")
        // Just inside and outside each corner, along the diagonal through the centre.
        for uv in ImageMaterialRenderer.corners {
            let corner = try XCTUnwrap(placement.pixel(placement.corner(uv), targetSize: Self.targetSize))
            let direction = simd_normalize(corner - centre)
            XCTAssertEqual(color(bytes, corner - direction * 3), [255, 0, 0], "inside corner \(uv)")
            let outside = corner + direction * 3
            if outside.x >= 0, outside.y >= 0, outside.x < Self.targetSize.x, outside.y < Self.targetSize.y {
                XCTAssertEqual(color(bytes, outside), [0, 0, 0], "outside corner \(uv)")
            }
        }
    }

    func testDepthHidesWhatIsBehindWhateverTheOrder() throws {
        try setUpGPU()
        let near = Quad(local: SceneLocalTransform3D(origin: SIMD3(0, 0, 0), scale: SIMD3(2, 2, 1), angles: .zero), color: Self.red)
        let far = Quad(local: SceneLocalTransform3D(origin: SIMD3(0.5, 0, -2), scale: SIMD3(4, 4, 1), angles: .zero), color: Self.green)
        let centre = Self.targetSize / 2
        XCTAssertEqual(color(try render([near, far]), centre), [255, 0, 0], "drawn later but behind")
        XCTAssertEqual(color(try render([far, near]), centre), [255, 0, 0], "drawn later and in front")
        var untested = far
        untested.raster = .disabled
        XCTAssertEqual(color(try render([near, untested]), centre), [0, 255, 0], "depthtest disabled draws over")
    }

    /// 3455121165's orbit rings: a translucent image authoring depth test and write, drawn before
    /// what lies behind it, doesn't hide it (WE writes no depth for a blended draw).
    func testATranslucentLayerDoesNotHideWhatIsDrawnBehindItLater() throws {
        try setUpGPU()
        let near = Quad(local: SceneLocalTransform3D(origin: SIMD3(0, 0, 0), scale: SIMD3(2, 2, 1), angles: .zero), color: Self.red)
        let far = Quad(local: SceneLocalTransform3D(origin: SIMD3(0.5, 0, -2), scale: SIMD3(4, 4, 1), angles: .zero), color: Self.green)
        let centre = Self.targetSize / 2
        XCTAssertEqual(color(try render([near, far], material: "depthcull_translucent"), centre), [0, 255, 0],
                       "the translucent quad in front wrote no depth")
        // It still tests: behind a quad that wrote depth, it stays hidden.
        var writing = far
        writing.raster = .engineDefault
        var behind = near
        behind.local.origin.z = -3
        XCTAssertEqual(color(try render([writing, behind], material: "depthcull_translucent"), centre), [0, 255, 0],
                       "the translucent quad behind is depth-tested")
    }

    func testBackFacesAreCulledUnlessNocull() throws {
        try setUpGPU()
        let back = SceneLocalTransform3D(origin: .zero, scale: SIMD3(2, 2, 1), angles: SIMD3(0, .pi, 0))
        let front = SceneLocalTransform3D(origin: .zero, scale: SIMD3(2, 2, 1), angles: .zero)
        let centre = Self.targetSize / 2
        XCTAssertEqual(color(try render([Quad(local: front, color: Self.red)]), centre), [255, 0, 0], "WE's quad faces the camera")
        XCTAssertEqual(color(try render([Quad(local: back, color: Self.red)]), centre), [0, 0, 0], "turned away: culled")
        let nocull = SceneRasterState(depthTest: true, depthWrite: true, cullsBackFaces: false)
        XCTAssertEqual(color(try render([Quad(local: back, color: Self.red, raster: nocull)]), centre), [255, 0, 0])
    }

    func testTheNativeDrawSharesTheMaterialsPlacementAndDepth() throws {
        try setUpGPU()
        let local = SceneLocalTransform3D(origin: SIMD3(-0.3, 0.1, -0.5), scale: SIMD3(1.2, 0.8, 1), angles: SIMD3(0.2, -0.4, 0.3))
        let material = try render([Quad(local: local, color: Self.red)])
        let native = try render([], nativeQuads: [Quad(local: local, color: Self.red)])
        var differing = 0
        for index in stride(from: 0, to: material.count, by: 4) where material[index] != native[index] { differing += 1 }
        XCTAssertLessThan(differing, 40, "edge pixels only")
        // Depth written by one draw path holds back the other: the same (z + w) / 2.
        let behind = SceneLocalTransform3D(origin: SIMD3(0, 0, -1), scale: SIMD3(4, 4, 1), angles: .zero)
        let mixed = try render([Quad(local: SceneLocalTransform3D(origin: .zero, scale: SIMD3(2, 2, 1), angles: .zero), color: Self.red)],
                               nativeQuads: [Quad(local: behind, color: Self.green)])
        XCTAssertEqual(color(mixed, Self.targetSize / 2), [255, 0, 0])
    }
}
