import JavaScriptCore
import Metal
import AppKit
import simd
import XCTest
@testable import OpenWallpaperEngine

/// Script-made geometry (lib.sceneScript.d.ts `IScene.createModelData`, `IModelData.applyData`;
/// scenescript64.dll 0x18162fd40, 0x1816362d9): the API and its checks with WE's messages, the
/// token a model layer's configuration carries, the store's `applyData` rules, and the renderer
/// drawing the geometry a script changes (3734636606's cloth).
final class SceneScriptModelDataTests: XCTestCase {
    private func fixture() throws -> SceneScriptObjectFixture {
        try SceneScriptObjectFixture(FakeSceneScriptObjectHost(scene: SceneScriptObjectModelTests.sceneDescription(),
                                                               describe: SceneScriptObjectModelTests.describe))
    }

    /// A triangle of position, normal and uv, as the physics script lays out its cloth.
    private static let triangle = """
        var vertices = new Float32Array([0,0,0, 0,0,1, 0,0,  1,0,0, 0,0,1, 1,0,  0,1,0, 0,0,1, 0,1]);
        var shape = { vertexBuffer: vertices, indexBuffer: new Uint16Array([0, 1, 2]),
                      vertexFormat: [IModelData.POSITION, IModelData.NORMAL, IModelData.UV],
                      material: 'materials/M_Cloth.json', isVertexBufferDynamic: true };
        """

    func testCreateModelDataHandsOutATokenTheLayerConfigurationCarries() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        f.evaluate(Self.triangle + "var data = thisScene.createModelData({ shapes: [shape] });")
        XCTAssertEqual(f.evaluate("data instanceof IModelData")?.toBool(), true)
        let token = try XCTUnwrap(f.evaluate("data.__modelDataToken")?.toInt32())
        let stored = try XCTUnwrap(f.model.modelData.snapshot(Int(token))?.data)
        XCTAssertEqual(stored.shapes.count, 1)
        XCTAssertEqual(stored.shapes[0].format.rawValue, 0x1 | 0x2 | 0x8, "position, normal, uv in .mdl's table")
        XCTAssertEqual(stored.shapes[0].vertexCount, 3)
        XCTAssertEqual(stored.shapes[0].indexCount, 3)
        XCTAssertEqual(stored.shapes[0].materialPaths, ["materials/M_Cloth.json"])
        XCTAssertEqual(stored.bounds, MDLBounds(min: .zero, max: SIMD3(1, 1, 0)), "the positions' box without an authored one")
        // `_Internal.stringifyConfig` writes the token as the layer's `model`.
        f.evaluate("var layer = thisScene.createLayer({ name: 'cloth', model: data });")
        guard case .configuration(let json)? = f.host.described.last else { return XCTFail("no configuration described") }
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((object["model"] as? NSNumber)?.intValue, Int(token))
        XCTAssertEqual(SceneScriptSceneDescriber.kind(of: ["model": .number(Double(token))]), .model)
        // Passing the model data alone makes the same layer.
        f.evaluate("thisScene.createLayer(data);")
        guard case .configuration(let alone)? = f.host.described.last else { return XCTFail("no configuration described") }
        XCTAssertEqual(alone, #"{"model":\#(token)}"#)
        XCTAssertTrue(f.scriptHost.errors.isEmpty, "\(f.scriptHost.errors)")
    }

    func testTheConfigurationIsCheckedWithWEsMessages() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        f.evaluate(Self.triangle)
        func message(_ expression: String) -> String? {
            f.evaluate("(function () { try { \(expression); return 'ok'; } catch (e) { return e.message; } })()")?.toString()
        }
        XCTAssertEqual(message("thisScene.createModelData({})"), "Shapes missing.")
        XCTAssertEqual(message("thisScene.createModelData({ shapes: [Object.assign({}, shape, { vertexBuffer: [1, 2] })] })"),
                       "Vertex buffer missing.")
        XCTAssertEqual(message("thisScene.createModelData({ shapes: [Object.assign({}, shape, { vertexFormat: ['uv', 'position'] })] })"),
                       "Vertex format in incorrect order.")
        XCTAssertEqual(message("thisScene.createModelData({ shapes: [Object.assign({}, shape, { material: undefined })] })"),
                       "Material missing.")
        XCTAssertEqual(message("thisScene.createModelData({ shapes: [Object.assign({}, shape, { vertexBuffer: new Float32Array(7) })] })"),
                       "Inconsistent vertex buffer size")
        XCTAssertEqual(message("thisScene.createModelData({ shapes: [Object.assign({}, shape, { indexBuffer: new Int8Array(3) })] })"),
                       "Incorrect index buffer type")
        // A registered asset names its file; the box can be authored.
        XCTAssertEqual(message("""
            box = thisScene.createModelData({ boundingBoxMins: new Vec3(-5, -5, -5), boundingBoxMaxs: new Vec3(5, 5, 5),
                                                  shapes: [shape] })
            """), "ok")
        let token = try XCTUnwrap(f.evaluate("box.__modelDataToken")?.toInt32())
        XCTAssertEqual(f.model.modelData.snapshot(Int(token))?.data.bounds,
                       MDLBounds(min: SIMD3(repeating: -5), max: SIMD3(repeating: 5)))
    }

    func testApplyDataChangesOnlyWhatIsPassed() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        f.evaluate(Self.triangle + "var data = thisScene.createModelData({ shapes: [shape] });")
        let token = Int(try XCTUnwrap(f.evaluate("data.__modelDataToken")?.toInt32()))
        let before = try XCTUnwrap(f.model.modelData.snapshot(token))
        // The physics script's per-frame payload: the vertex buffer alone, changed in place.
        f.evaluate("vertices[0] = 0.25; data.applyData({ shapes: [{ vertexBuffer: vertices }] });")
        let after = try XCTUnwrap(f.model.modelData.snapshot(token))
        XCTAssertGreaterThan(after.revision, before.revision)
        XCTAssertEqual(after.data.shapes[0].vertices.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }, 0.25)
        XCTAssertEqual(after.data.shapes[0].indices, before.data.shapes[0].indices)
        func message(_ expression: String) -> String? {
            f.evaluate("(function () { try { \(expression); return 'ok'; } catch (e) { return e.message; } })()")?.toString()
        }
        XCTAssertEqual(message("data.applyData({ vertexBuffer: new Float32Array(32) })"), "Vertex buffer size cannot increase")
        XCTAssertEqual(message("data.applyData({ indexBuffer: new Uint16Array([0, 1, 2]) })"), "Model data not created as dynamic")
        XCTAssertEqual(message("data.applyData([{ vertexBuffer: vertices }, { vertexBuffer: vertices }])"),
                       "Cannot add shapes in IModelData.update")
        XCTAssertEqual(message("data.applyData([null])"), "Cannot delete shape or buffers in IModelData.update")
        XCTAssertEqual(message("data.applyData({ material: 'materials/other.json' })"), "Material cannot be changed in IModelData.update")
        XCTAssertEqual(message("data.applyData({ vertexFormat: [IModelData.POSITION] })"),
                       "Vertex format cannot be changed in IModelData.update")
        // A smaller buffer is taken.
        XCTAssertEqual(message("data.applyData({ vertexBuffer: vertices.subarray(0, 16) })"), "ok")
        XCTAssertEqual(f.model.modelData.snapshot(token)?.data.shapes[0].vertexCount, 2)
        // `replaceData` may change anything, outside `update`; `destroyModelData` drops the data.
        XCTAssertEqual(message("data.replaceData({ vertexBuffer: new Float32Array(48) })"), "ok")
        XCTAssertEqual(f.model.modelData.snapshot(token)?.data.shapes[0].vertexCount, 6)
        f.evaluate("thisScene.destroyModelData(data);")
        XCTAssertNil(f.model.modelData.snapshot(token))
        XCTAssertEqual(message("data.applyData({ vertexBuffer: vertices })"), "Invalid model data token")
    }

    func testCreateModelDataIsNotForTheGlobalScope() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        f.add("global-model", slot: nil, Self.triangle + "var made = thisScene.createModelData({ shapes: [shape] });")
        f.runtime.load()
        XCTAssertTrue(f.scriptHost.errors.contains { $0.message.contains("createModelData cannot be called from global scope.") },
                      "\(f.scriptHost.errors)")
    }

    func testATypedArrayViewIsReadFromItsOffset() throws {
        let context = try XCTUnwrap(JSContext())
        let view = try XCTUnwrap(context.evaluateScript("new Float32Array(new Float32Array([1, 2, 3, 4, 5]).buffer, 8, 2)"))
        let read = try XCTUnwrap(SceneScriptObjectModel.typedArray(view))
        XCTAssertEqual(read.bytes.count, 8)
        XCTAssertEqual(read.bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }, [3, 4])
        XCTAssertNil(SceneScriptObjectModel.typedArray(context.evaluateScript("[1, 2]")))
    }

    // MARK: - Drawing

    /// A quad facing +z at x in `left…left+1`, y in −0.5…0.5, as position and normal floats.
    private static func quad(left: Float) -> [Float] {
        [SIMD2<Float>(left, -0.5), SIMD2(left + 1, -0.5), SIMD2(left + 1, 0.5), SIMD2(left, 0.5)].flatMap { [$0.x, $0.y, 0, 0, 0, 1] }
    }

    func testTheRendererDrawsWhatApplyDataLeaves() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cache = FileManager.default.temporaryDirectory.appending(path: "owe-modeldata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) } // scratch cleanup
        let roots = [Fixtures.url("ModelMaterials"), ShaderVariantTests.weAssets]
        let materials = ModelMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { path in roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first },
            loadTexture: { _, _ in .image(NSImage(size: NSSize(width: 4, height: 4))) })
        let store = SceneScriptModelDataStore()
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]
        let shape = SceneScriptModelData.Shape(
            format: try XCTUnwrap(SceneScriptModelData.format(["position", "normal"])),
            materialPaths: ["materials/workshop/1/facecolor.json", "materials/facecolor.json"],
            vertices: Self.quad(left: -1.5).withUnsafeBytes { Data($0) }, indices: indices.withUnsafeBytes { Data($0) },
            usesUInt32Indices: false, dynamicVertices: true, dynamicIndices: false)
        let token = store.create(SceneScriptModelData(shapes: [shape], bounds: MDLBounds(min: SIMD3(-2, -1, -1), max: SIMD3(2, 1, 1))))
        let geometry = SceneScriptModelGeometry(store: store, token: token)
        geometry.replan = { [weak geometry] data in
            geometry.flatMap { SceneScriptModelPlanBuilder(materials: materials).plan(data, geometry: $0, objectName: "cloth") }
        }
        let plan = try XCTUnwrap(SceneScriptModelPlanBuilder(materials: materials).plan(
            try XCTUnwrap(store.snapshot(token)?.data), geometry: geometry,
            objectName: "cloth"), "the first material path that exists plans")
        XCTAssertEqual(plan.meshes.first?.material.materialPath, "materials/facecolor.json")

        let renderer = try XCTUnwrap(SceneModelRenderer(device: device, archive: nil))
        let depthStates = try XCTUnwrap(SceneDepthStates(device: device))
        let object = SceneModelObject(id: "7", name: "cloth", order: 0, authored: WESceneModel(source: .loadedID(token)), plan: plan)
        renderer.setContent([object], content: SceneMetalContent(size: SIMD2(64, 64), layers: [], particleSystems: [],
                                                                 bloom: SceneBloomSettings(enabled: false, strength: 0,
                                                                                           threshold: 0.7, tint: SIMD3(repeating: 1))))
        XCTAssertTrue(renderer.waitUntilReady(plan, pixelFormat: .bgra8Unorm))
        let camera = ModelRenderTests.camera(eye: SIMD3(0, 0, 4))
        let size = 64
        func draw() throws -> [UInt8] {
            let target = try ModelRenderTests.target(device: device, size: size)
            let depth = SceneDepthBuffer(device: device)
            XCTAssertTrue(depth.prepare(width: size, height: size, sampleCount: 1))
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
            renderer.draw(object, SceneModelDraw(world: matrix_identity_float4x4, camera: camera, frame: frame,
                                                 values: EffectGraphTests.FixedValues(), pixelFormat: .bgra8Unorm, sampleCount: 1,
                                                 depth: depthStates, mipMappedFrameBuffer: nil, assetTexture: { _, _ in nil }),
                          encoder: encoder, commandBuffer: buffer)
            encoder.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            XCTAssertNil(buffer.error)
            return try TextureUploadTests.read(target, device: device)
        }
        func lit(_ bytes: [UInt8], x: Int) -> Bool {
            let index = (size / 2 * size + x) * 4
            return Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2]) > 30
        }
        let first = try draw()
        XCTAssertTrue(lit(first, x: size / 2 - 12), "the quad left of centre")
        XCTAssertFalse(lit(first, x: size / 2 + 12))
        // The script moves the quad right of centre, as the cloth's `applyData` does every frame.
        try store.apply(token, [SceneScriptModelDataUpdate(vertices: Self.quad(left: 0.5).withUnsafeBytes { Data($0) })])
        let moved = try draw()
        XCTAssertFalse(lit(moved, x: size / 2 - 12), "the old geometry is gone")
        XCTAssertTrue(lit(moved, x: size / 2 + 12), "the new geometry draws")
        // `replaceData` with other shapes (two, one with 32-bit indices): WE re-creates the model,
        // so both draw (test-risks GP3).
        let wide: [UInt32] = [0, 1, 2, 0, 2, 3]
        var second = shape
        second.vertices = Self.quad(left: -1.5).withUnsafeBytes { Data($0) }
        second.indices = wide.withUnsafeBytes { Data($0) }
        second.usesUInt32Indices = true
        var right = shape
        right.vertices = Self.quad(left: 0.5).withUnsafeBytes { Data($0) }
        try store.replace(token, with: SceneScriptModelData(shapes: [right, second], bounds: MDLBounds(min: SIMD3(-2, -1, -1),
                                                                                                        max: SIMD3(2, 1, 1))))
        let replaced = try draw()
        XCTAssertTrue(lit(replaced, x: size / 2 - 12), "the new second shape draws")
        XCTAssertTrue(lit(replaced, x: size / 2 + 12), "the first shape draws")
        XCTAssertNil(geometry.replacement(for: plan), "planned once per replacement")
    }
}
