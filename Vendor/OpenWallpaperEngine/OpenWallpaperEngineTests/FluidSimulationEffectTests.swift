import XCTest
import Metal
@testable import OpenWallpaperEngine

/// WE's built-in `effects/fluidsimulation` (stable fluids) through the generic effect graph:
/// curl → vorticity → divergence → clear → 9 Jacobi pressure passes → gradient subtract →
/// velocity advection → dye advection → (normal, `LIGHTING` 1) → combine, then two `swap`
/// commands that carry velocity and dye into the next frame. Its FBOs are `unique`, `fit` 256
/// (`rg1616f` velocity, `r16f` pressure, divergence and curl) or `scale` 2 (`rgba_backbuffer` dye).
final class FluidSimulationEffectTests: XCTestCase {
    private static let file = "effects/fluidsimulation/effect.json"
    /// effect.json's `passes`, commands included.
    private static let authoredPasses = 20
    private static let pressureIterations = 9

    private var device: MTLDevice!
    private var builder: SceneEffectPlanBuilder!
    private var cache: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ShaderVariantTests.weAssets.path), "WE install not present")
        let root = ShaderVariantTests.weAssets
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root.appending(path: Self.file).path), "no fluidsimulation")
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-fluid-\(UUID().uuidString)")
        builder = SceneEffectPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { FileManager.default.contents(atPath: root.appending(path: $0).path) },
            loadTexture: { name, materialPath in
                let effectDirectory = materialPath.split(separator: "/").prefix(2).joined(separator: "/")
                for path in ["materials/\(name).tex", "\(name).tex", "\(effectDirectory)/materials/\(name).tex"] {
                    if let data = FileManager.default.contents(atPath: root.appending(path: path).path),
                       let image = TEXParser(data: data).extractImage() { return .image(image) }
                }
                return nil
            })
    }

    override func tearDownWithError() throws {
        if let cache { try? FileManager.default.removeItem(at: cache) }
    }

    struct NoValues: SceneValueContext {
        func userProperty(_ name: String) -> String? { nil }
    }

    /// The scene.json instance with `combos` on every pass.
    private func plan(combos: [String: Int] = [:]) throws -> SceneEffectPlan {
        let pass = (try? JSONSerialization.data(withJSONObject: ["combos": combos])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let passes = Array(repeating: pass, count: Self.authoredPasses).joined(separator: ",")
        let json = #"{"file":"\#(Self.file)","passes":[\#(passes)]}"#
        return try builder.build(try JSONDecoder().decode(WEObjectEffect.self, from: Data(json.utf8)))
    }

    func testPassGraph() throws {
        let raw = try XCTUnwrap(FileManager.default.contents(atPath: ShaderVariantTests.weAssets.appending(path: Self.file).path))
        let document = try decodeTolerant(EffectDocument.self, from: raw)
        XCTAssertEqual(document.passes.count, Self.authoredPasses)
        XCTAssertEqual(document.fbos.count, 9)
        let plan = try plan()
        // `LIGHTING` 0 drops the normal pass.
        XCTAssertEqual(plan.passes.count, Self.authoredPasses - 1)
        // effect.json passes 4…12 are fluidsimulation_pressure, ping-ponging the two pressure FBOs.
        let pressure = plan.passes.filter { (4...12).contains($0.materialIndex) }
        XCTAssertEqual(pressure.count, Self.pressureIterations, "never fewer Jacobi iterations than WE")
        XCTAssertEqual(Set(pressure.map(\.variantKey)).count, 1)
        XCTAssertEqual(pressure.map(\.target), (0..<Self.pressureIterations).map { $0 % 2 == 0 ? "_rt_SmokePressure1" : "_rt_SmokePressure2" })
        let swaps = plan.passes.compactMap { pass -> [String]? in
            if case .swap(let a, let b) = pass.command { return [a, b] } else { return nil }
        }
        XCTAssertEqual(swaps, [["_rt_SmokeVelocity1", "_rt_SmokeVelocity2"], ["_rt_SmokeDye1", "_rt_SmokeDye2"]])
        XCTAssertTrue(plan.carriesFrames, "the simulation reads its last frame")
        let fbos = Dictionary(uniqueKeysWithValues: plan.fbos.map { ($0.name, $0) })
        XCTAssertEqual(fbos["_rt_SmokeVelocity1"]?.fit, 256)
        XCTAssertEqual(fbos["_rt_SmokeVelocity1"]?.unique, true)
        XCTAssertEqual(EffectGraphRenderer.pixelFormat("rg1616f", frameBuffer: .rgba8Unorm), .rg16Float)
        XCTAssertEqual(EffectGraphRenderer.pixelFormat("r16f", frameBuffer: .rgba8Unorm), .r16Float)
        XCTAssertEqual(fbos["_rt_SmokeDye1"]?.scale, 2)
        XCTAssertNil(fbos["_rt_SmokeNormal"], "its conditions want LIGHTING 1: never made")
        XCTAssertEqual(plan.fbos.count, 8)
        let size = EffectGraphRenderer.fboSize(try XCTUnwrap(fbos["_rt_SmokeVelocity1"]), width: 1920, height: 1080)
        XCTAssertEqual(max(size.x, size.y), 256)
    }

    /// FBO and bind conditions: `_rt_SmokeNormal` is made and bound to the combine pass only with
    /// `LIGHTING` 1, `_rt_SmokeVelocity2` bound to its slot 4 only with `RENDERING` 3.
    func testConditionalFBOsAndBinds() throws {
        let raw = try XCTUnwrap(FileManager.default.contents(atPath: ShaderVariantTests.weAssets.appending(path: Self.file).path))
        let document = try decodeTolerant(EffectDocument.self, from: raw)
        let combine = try XCTUnwrap(document.passes.firstIndex { $0.material?.hasSuffix("fluidsimulation_combine.json") == true })
        func combinePass(_ plan: SceneEffectPlan) throws -> SceneEffectPassPlan {
            try XCTUnwrap(plan.passes.first { $0.materialIndex == combine })
        }
        func fbo(_ input: SceneEffectTextureInput?) -> String? {
            if case .fbo(let name)? = input { return name } else { return nil }
        }
        let plain = try plan()
        XCTAssertNil(fbo(try combinePass(plain).textures[2]))
        XCTAssertNil(fbo(try combinePass(plain).textures[4]))
        let lit = try plan(combos: ["LIGHTING": 1])
        XCTAssertTrue(lit.fbos.contains { $0.name == "_rt_SmokeNormal" })
        XCTAssertEqual(lit.passes.count, Self.authoredPasses, "the normal pass runs")
        XCTAssertEqual(fbo(try combinePass(lit).textures[2]), "_rt_SmokeNormal")
        let distortion = try plan(combos: ["RENDERING": 3])
        XCTAssertFalse(distortion.fbos.contains { $0.name == "_rt_SmokeNormal" })
        XCTAssertEqual(fbo(try combinePass(distortion).textures[4]), "_rt_SmokeVelocity2")
    }

    /// Every variant the effect's options reach translates: rendering modes, emitter counts.
    func testShadersTranslate() throws {
        for combos in [[:], ["RENDERING": 1], ["RENDERING": 2], ["RENDERING": 3],
                       ["POINTEMITTER": 3, "LINEEMITTER": 3], ["POINTEMITTER": 0], ["OPAQUE": 1, "PERSPECTIVE": 1]] {
            let plan = try plan(combos: combos)
            for pass in plan.passes {
                if case .render = pass.command { XCTAssertNotNil(pass.variant, "\(combos) \(pass.variantKey)") }
            }
        }
    }

    /// The default point emitter pushes dye from the centre: it advects over frames, and the
    /// velocity and pressure stay finite and bounded.
    func testDyeAdvectsOverFrames() throws {
        let plan = try plan()
        let renderer = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: cache.appending(path: "archives")))
        defer { renderer.pipelineArchive?.flush() }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 256, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let input = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let grey = [UInt8](repeating: 128, count: 256 * 256 * 4)
        input.replace(region: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0, withBytes: grey, bytesPerRow: 256 * 4)
        XCTAssertTrue(renderer.waitUntilReady([plan], width: 256, height: 256), "pipelines still compiling")

        let frameTime = 1.0 / 25
        var dyes: [[Float]] = []
        for frame in 0..<30 {
            var frameContext = BuiltinFrameContext(time: Double(frame) * frameTime)
            frameContext.serial = UInt64(frame + 1)
            frameContext.frameTime = frameTime
            frameContext.pointer = SIMD2(-1, -1)
            frameContext.pointerLast = SIMD2(-1, -1)
            let context = EffectGraphRenderer.Context(frame: frameContext, values: NoValues(), assetTexture: { _, _ in nil },
                                                      sceneSnapshot: nil, layerColor: SIMD3(1, 1, 1), layerAlpha: 1)
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertNotNil(renderer.apply([plan], to: input, layerID: "fluid", context: context, commandBuffer: buffer))
            buffer.commit()
            buffer.waitUntilCompleted()
            XCTAssertNil(buffer.error)
            if frame == 0 || frame == 29 {
                dyes.append(try floats(XCTUnwrap(renderer.fboTexture("_rt_SmokeDye1", effect: 0, layer: "fluid")), queue: queue))
            }
        }
        for name in ["_rt_SmokeVelocity1", "_rt_SmokePressure1", "_rt_SmokeDye1"] {
            let values = try floats(XCTUnwrap(renderer.fboTexture(name, effect: 0, layer: "fluid")), queue: queue)
            XCTAssertTrue(values.allSatisfy(\.isFinite), "\(name) has a NaN or infinity")
            XCTAssertLessThan(values.map(abs).max() ?? 0, 60_000, "\(name) diverges")
        }
        let first = dyes[0], last = dyes[1]
        XCTAssertGreaterThan(last.reduce(0, +), 0, "no dye was emitted")
        let change = zip(first, last).reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / Float(first.count)
        XCTAssertGreaterThan(change, 0.001, "the dye didn't move")
    }

    /// effect.json's `functions`: `clearVelocity` and `clearDye` clear both buffers of a pair.
    func testFunctionsDecode() throws {
        let plan = try plan()
        XCTAssertEqual(plan.functions["clearVelocity"], EffectFunction(action: "clear", fbos: ["_rt_SmokeVelocity1", "_rt_SmokeVelocity2"]))
        XCTAssertEqual(plan.functions["clearDye"], EffectFunction(action: "clear", fbos: ["_rt_SmokeDye1", "_rt_SmokeDye2"]))
        XCTAssertEqual(plan.functions["clearDye"]?.actionKind, .clear)
    }

    /// `executeMaterialFunction('clearDye')` and `('clearVelocity')` start the simulation over: the
    /// next frame's dye is the first frame's again, not what 30 frames built up. An unknown name
    /// leaves the buffers alone.
    func testClearFunctionsRestartTheSimulation() throws {
        let plan = try plan()
        let renderer = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: cache.appending(path: "archives")))
        defer { renderer.pipelineArchive?.flush() }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 256, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let input = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        input.replace(region: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0,
                      withBytes: [UInt8](repeating: 128, count: 256 * 256 * 4), bytesPerRow: 256 * 4)
        XCTAssertTrue(renderer.waitUntilReady([plan], width: 256, height: 256), "pipelines still compiling")
        let frameTime = 1.0 / 25
        func render(_ frame: Int, at time: Int? = nil) throws -> [Float] {
            var frameContext = BuiltinFrameContext(time: Double(time ?? frame) * frameTime)
            frameContext.serial = UInt64(frame + 1)
            frameContext.frameTime = frameTime
            frameContext.pointer = SIMD2(-1, -1)
            frameContext.pointerLast = SIMD2(-1, -1)
            let context = EffectGraphRenderer.Context(frame: frameContext, values: NoValues(), assetTexture: { _, _ in nil },
                                                      sceneSnapshot: nil, layerColor: SIMD3(1, 1, 1), layerAlpha: 1)
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertNotNil(renderer.apply([plan], to: input, layerID: "fluid", context: context, commandBuffer: buffer))
            buffer.commit()
            buffer.waitUntilCompleted()
            XCTAssertNil(buffer.error)
            return try floats(XCTUnwrap(renderer.fboTexture("_rt_SmokeDye1", effect: 0, layer: "fluid")), queue: queue)
        }
        func distance(_ a: [Float], _ b: [Float]) -> Float {
            zip(a, b).reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / Float(max(a.count, 1))
        }
        let first = try render(0)
        var last = first
        for frame in 1..<30 { last = try render(frame) }
        let builtUp = distance(last, first)
        XCTAssertGreaterThan(builtUp, 0.001, "the dye didn't move")

        renderer.executeFunction(named: "noSuchFunction", effectIndex: 0, of: [plan], layer: "fluid")
        let kept = try render(30)
        XCTAssertGreaterThan(distance(kept, first), builtUp / 2, "an unknown function cleared something")

        renderer.executeFunction(named: "clearDye", effectIndex: 0, of: [plan], layer: "fluid")
        renderer.executeFunction(named: "clearVelocity", effectIndex: 0, of: [plan], layer: "fluid")
        let restarted = try render(31, at: 0)
        XCTAssertLessThan(distance(restarted, first), builtUp / 4, "the dye wasn't cleared")
        let velocity = try floats(XCTUnwrap(renderer.fboTexture("_rt_SmokeVelocity1", effect: 0, layer: "fluid")), queue: queue)
        XCTAssertTrue(velocity.allSatisfy(\.isFinite))
    }

    /// A texture's channels as floats (8-bit unorm or 16-bit float formats).
    private func floats(_ texture: MTLTexture, queue: MTLCommandQueue) throws -> [Float] {
        let (channels, bytes): (Int, Int)
        switch texture.pixelFormat {
        case .r16Float: (channels, bytes) = (1, 2)
        case .rg16Float: (channels, bytes) = (2, 2)
        case .rgba16Float: (channels, bytes) = (4, 2)
        case .rgba8Unorm, .bgra8Unorm, .rgba8Unorm_srgb, .bgra8Unorm_srgb: (channels, bytes) = (4, 1)
        default: throw XCTSkip("unexpected format \(texture.pixelFormat.rawValue)")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width,
                                                                  height: texture.height, mipmapped: false)
        descriptor.storageMode = .shared
        let copy = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(buffer.makeBlitCommandEncoder())
        blit.copy(from: texture, to: copy)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        let rowBytes = texture.width * channels * bytes
        var raw = [UInt8](repeating: 0, count: rowBytes * texture.height)
        copy.getBytes(&raw, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        if bytes == 1 { return raw.map { Float($0) / 255 } }
        return stride(from: 0, to: raw.count, by: 2).map { Self.half(UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8) }
    }

    private static func half(_ bits: UInt16) -> Float {
        let sign: Float = bits & 0x8000 != 0 ? -1 : 1
        let exponent = Int(bits >> 10 & 0x1f), mantissa = Float(bits & 0x3ff)
        if exponent == 0x1f { return mantissa == 0 ? sign * .infinity : .nan }
        if exponent == 0 { return sign * mantissa * pow(2, -24) }
        return sign * (1 + mantissa / 1024) * pow(2, Float(exponent - 15))
    }
}
