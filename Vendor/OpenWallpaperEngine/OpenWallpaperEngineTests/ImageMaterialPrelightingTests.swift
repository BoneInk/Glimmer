import XCTest
import MetalKit
import simd
@testable import OpenWallpaperEngine

/// WE's prelighting path (docs/lighting-plan.md §2.3, A4): a lit or reflective layer with effects
/// is lit by its material with `PRELIGHTING` into the buffer its effects start from, at the
/// layer's place in the scene (the `g_Alt*` matrices), and then drawn with both combos off.
final class ImageMaterialPrelightingTests: XCTestCase {
    private typealias Lit = ImageMaterialLightingTests
    private typealias Stage = SceneMipMappedFrameBufferTests

    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var cache: URL?

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ShaderVariantTests.weAssets.appending(path: "shaders/genericimage4.frag").path),
                          "bundled WE shaders missing")
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-prelighting-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let cache { try? FileManager.default.removeItem(at: cache) } // scratch cleanup
    }

    // MARK: - Plans

    /// 0x140209540: the prepass is the layer's own material with its `LIGHTING` and `PRELIGHTING`,
    /// unblended; the layer draws with `LIGHTING` and `REFLECTION` off.
    func testALitLayerWithEffectsPlansAPrepass() throws {
        let plan = try XCTUnwrap(try builder().build(materialPath: "materials/lit.json", colorBlendMode: nil, prelit: true))
        let prepass = try XCTUnwrap(plan.prelighting)
        XCTAssertEqual(prepass.variant?.combos["LIGHTING"], 1)
        XCTAssertEqual(prepass.variant?.combos["PRELIGHTING"], 1)
        XCTAssertEqual(prepass.variant?.combos["LIGHTS_POINT"], 1, "the engine's light combos")
        XCTAssertEqual(prepass.blending, "disabled")
        XCTAssertEqual(plan.pass.variant?.combos["LIGHTING"], 0)
        XCTAssertEqual(plan.pass.variant?.combos["REFLECTION"], 0)
        XCTAssertNil(plan.pass.variant?.combos["PRELIGHTING"])
        XCTAssertEqual(plan.pass.blending, "translucent")

        let direct = try XCTUnwrap(try builder().build(materialPath: "materials/lit.json", colorBlendMode: nil))
        XCTAssertNil(direct.prelighting, "without effects the layer is lit where it is drawn")
    }

    /// A reflective layer with effects reflects in its prepass, which reads
    /// `_rt_MipMappedFrameBuffer`, so the copy is made for it.
    func testAReflectiveLayerWithEffectsReflectsInItsPrepass() throws {
        let plan = try XCTUnwrap(try builder().build(materialPath: "materials/reflection.json", colorBlendMode: nil, prelit: true))
        let prepass = try XCTUnwrap(plan.prelighting)
        XCTAssertEqual(prepass.variant?.combos["REFLECTION"], 1)
        guard case .mipMappedFrameBuffer? = prepass.textures[3] else { return XCTFail("the prepass doesn't read the copy") }
        XCTAssertNil(plan.pass.textures[3], "the layer's own draw doesn't reflect")
        var layer = Stage.layer("reflective")
        layer.imageMaterial = plan
        XCTAssertTrue(SceneMipMappedFrameBuffer.samples(Stage.content(layers: [layer])))
    }

    // MARK: - The prepass

    /// Without lights and with a white ambient (witcher's `ведьмак` layer), lighting gives the
    /// albedo back: the prepass writes the image texel for texel, padding included.
    func testWhiteAmbientWithoutLightsGivesTheImageBack() throws {
        let plan = try XCTUnwrap(try builder(budget: nil).build(materialPath: "materials/lit.json", colorBlendMode: nil, prelit: true))
        let (width, height) = (64, 32)
        let texels = Stage.bytes({ x, y in [UInt8(x * 4), UInt8(y * 8), UInt8((x * y) % 256), UInt8(128 + x)] },
                                 width: width, height: height)
        let image = try Stage.texture(device: device, width: width, height: height, pixels: texels, format: .rgba8Unorm)
        let quad = SceneQuadGeometry(center: SIMD2(200, 100), axisX: SIMD2(90, 40), axisY: SIMD2(-20, 60))
        let output = try prelight(plan, image: image, contentSize: SIMD2(48, 20), quad: quad, ambient: SIMD3(repeating: 1),
                                  lights: [])
        var worst = 0
        for index in texels.indices { worst = max(worst, abs(Int(texels[index]) - Int(output[index]))) }
        XCTAssertLessThanOrEqual(worst, 1, "the prepass changed the image by \(worst)/255")
    }

    /// Each texel of the prepass is lit where it lies in the scene: the CPU model of WE's shader
    /// (which the direct path matches, `ImageMaterialLightingTests`) at the texel's scene position,
    /// for a turned layer with a normal map, a mask and all four light types.
    func testPrepassTexelsAreLitWhereTheyLieInTheScene() throws {
        let plan = try XCTUnwrap(try builder().build(materialPath: "materials/litpbr.json", colorBlendMode: nil, prelit: true))
        let (width, height) = (32, 16)
        let image = try Stage.texture(device: device, width: width, height: height,
                                      pixels: Stage.bytes({ _, _ in Lit.albedo }, width: width, height: height),
                                      format: .rgba8Unorm)
        let axis = SIMD2<Float>(cos(0.3), sin(0.3))
        let quad = SceneQuadGeometry(center: SIMD2(260, 130), axisX: axis * 360, axisY: SIMD2(-axis.y, axis.x) * 180)
        let output = try prelight(plan, image: image, contentSize: nil, quad: quad, ambient: Lit.ambient, lights: Lit.lights)

        let texel = SIMD2(Float(Lit.normal[0]), Float(Lit.normal[1])) / 255
        let normal = LightingReference.mappedNormal(texel, tangent: SIMD3(axis, 0), bitangent: SIMD3(-axis.y, axis.x, 0))
        let surface = LightingReference.Surface(albedo: Lit.albedoColor, normal: normal, roughness: Float(Lit.mask[1]) / 255,
                                                metallic: Float(Lit.mask[0]) / 255, specularTint: SIMD3(1, 0.9, 0.8))
        var worst: Float = 0
        for y in 0..<height {
            for x in 0..<width {
                let uv = SIMD2((Float(x) + 0.5) / Float(width), (Float(y) + 0.5) / Float(height))
                let world = quad.center + (uv.x - 0.5) * quad.axisX + (0.5 - uv.y) * quad.axisY
                let expected = LightingReference.shade(surface, at: SIMD3(world, 0), lights: Lit.lights, ambient: Lit.ambient)
                for channel in 0..<3 {
                    let actual = Float(output[(y * width + x) * 4 + channel]) / 255
                    worst = max(worst, abs(actual - min(max(expected[channel], 0), 1)))
                }
            }
        }
        XCTAssertLessThanOrEqual(worst, 1.5 / 255, "prepass vs the CPU model: \(worst * 255)/255")
    }

    /// Through the whole renderer: a lit layer whose effect changes nothing draws what the same
    /// layer without effects draws (lit directly), and its prepass runs every frame.
    func testALayerWithAnIdentityEffectMatchesTheDirectPath() throws {
        let tint = try identityTint()
        let viaEffects = try renderScene(effects: [tint]).pixels
        let direct = try renderScene(effects: []).pixels
        var worst = 0
        for index in direct.indices where index % 4 != 3 { worst = max(worst, abs(Int(direct[index]) - Int(viaEffects[index]))) }
        XCTAssertLessThanOrEqual(worst, 3, "prelit through an identity effect vs lit directly: \(worst)/255")
        XCTAssertGreaterThan(Set(direct.enumerated().filter { $0.offset % 4 == 2 }.map(\.element)).count, 20,
                             "the lighting varies over the layer")
    }

    /// LF5: a prelit layer whose effects all are hidden (or still compiling) draws its prelit
    /// image, not its image unlit: the layer's own draw has `LIGHTING` and `REFLECTION` off.
    func testALayerWhoseEffectsAreHiddenStillDrawsLit() throws {
        var hidden = try identityTint()
        hidden.visible = false
        let viaHidden = try renderScene(effects: [hidden]).pixels
        let direct = try renderScene(effects: []).pixels
        var worst = 0
        for index in direct.indices where index % 4 != 3 { worst = max(worst, abs(Int(direct[index]) - Int(viaHidden[index]))) }
        XCTAssertLessThanOrEqual(worst, 3, "prelit with its effect hidden vs lit directly: \(worst)/255")
    }

    /// LF3: in HDR the prepass draws into the frame-buffer format, RGBA16F, as WE's layer buffers
    /// are: `CombineLighting`'s overbright reaches the effects and the float scene target, as it
    /// does for the same layer lit directly.
    func testAnHDRPrepassKeepsTheOverbright() throws {
        let tint = try identityTint()
        let viaEffects = try XCTUnwrap(try renderScene(effects: [tint], hdr: true).scene)
        let direct = try XCTUnwrap(try renderScene(effects: [], hdr: true).scene)
        func brightest(_ image: HDRReference.Image) -> Float { image.pixels.map { $0.max() }.max() ?? 0 }
        XCTAssertGreaterThan(brightest(direct), 1.03, "the lit layer is overbright in HDR")
        // The prepass lights the 16×16 image per texel and the direct draw per pixel, so only the
        // peak is compared: RGBA8 would clip it at 1.
        XCTAssertEqual(brightest(viaEffects), brightest(direct), accuracy: 0.03, "the prelit image keeps the overbright")
    }

    // MARK: - Helpers

    /// `tint` with alpha 0: an effect that changes nothing.
    private func identityTint() throws -> SceneEffectPlan {
        let assets = ShaderVariantTests.weAssets
        let effectBuilder = SceneEffectPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { FileManager.default.contents(atPath: assets.appending(path: $0).path) },
            loadTexture: { _, _ in nil })
        let effect = try JSONDecoder().decode(WEObjectEffect.self, from: Data(
            #"{"file":"effects/tint/effect.json","passes":[{"constantshadervalues":{"color":"1 0 0","alpha":0}}]}"#.utf8))
        return try effectBuilder.build(effect)
    }

    private func builder(budget: WELightConfig? = Lit.budget, hdr: Bool = false) throws -> ImageMaterialPlanBuilder {
        let roots = [Fixtures.url("ImageMaterials"), ShaderVariantTests.weAssets]
        let normal = try Lit.image(Lit.normal)
        let mask = try Lit.image(Lit.mask)
        let reflectionNormal = try Lit.image(ImageMaterialReflectionTests.normal)
        let reflectionMask = try Lit.image(ImageMaterialReflectionTests.maskLeft)
        return ImageMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { path in roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first },
            loadTexture: { name, _ in
                switch name {
                case "lit_normal": return .image(normal)
                case "lit_mask": return .image(mask)
                case "reflection_normal": return .image(reflectionNormal)
                case "reflection_mask": return .image(reflectionMask)
                default: return nil
                }
            },
            sceneEngineCombos: SceneEngineCombos(hdr: hdr, sceneOrtho: true, lightBudget: budget))
    }

    private func frame(ambient: SIMD3<Float>, lights: [LightingReference.Light]) -> BuiltinFrameContext {
        var frame = BuiltinFrameContext()
        frame.screenSize = SIMD2(256, 128)
        frame.lighting = SceneFrameLighting(ambient: ambient, skylight: SIMD3(repeating: 0.3),
                                            arrays: Self.packed(lights))
        return frame
    }

    private func assetTextures() throws -> (String, SceneMetalTextureSource) -> MTLTexture? {
        let normal = try Stage.texture(device: device, width: 1, height: 1, pixels: Lit.normal, format: .rgba8Unorm)
        let mask = try Stage.texture(device: device, width: 1, height: 1, pixels: Lit.mask, format: .rgba8Unorm)
        return { key, _ in key.hasSuffix("lit_normal") ? normal : key.hasSuffix("lit_mask") ? mask : nil }
    }

    /// The prepass of `plan` over `image`; its RGBA bytes.
    private func prelight(_ plan: ImageMaterialPlan, image: MTLTexture, contentSize: SIMD2<Float>?, quad: SceneQuadGeometry,
                          ambient: SIMD3<Float>, lights: [LightingReference.Light]) throws -> [UInt8] {
        let renderer = try XCTUnwrap(ImageMaterialRenderer(device: device, archive: nil))
        XCTAssertTrue(renderer.waitUntilReady(plan, pixelFormat: .bgra8Unorm))
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let output = try XCTUnwrap(renderer.prelight(plan, ImageMaterialRenderer.Draw(
            layerID: "layer", quad: quad, sceneSize: Lit.sceneSize, color: SIMD3(repeating: 1), alpha: 1, brightness: 1,
            texture: image, contentSize: contentSize, uvOrigin: .zero, uvAxisX: SIMD2(1, 0), uvAxisY: SIMD2(0, 1),
            sceneSnapshot: nil, frame: frame(ambient: ambient, lights: lights), values: EffectGraphTests.FixedValues(),
            assetTexture: try assetTextures()), commandBuffer: commands))
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertEqual(renderer.prelitDraws, 1)
        XCTAssertEqual(output.width, image.width)
        XCTAssertEqual(output.height, image.height)
        return try TextureUploadTests.read(output, device: device)
    }

    /// A 128×128 scene with one lit layer (its image a gradient) under a point light, through the
    /// whole renderer, with `effects` on the layer; the drawable's RGBA bytes once the material
    /// draws, and in `hdr` (a brighter light) the float scene target.
    private func renderScene(effects: [SceneEffectPlan],
                             hdr: Bool = false) throws -> (pixels: [UInt8], scene: HDRReference.Image?) {
        let size = 128
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: size, height: size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: size, height: size)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view))
        view.isPaused = true
        renderer.setPlacement(.stretch)
        let scene = SIMD2<Float>(Float(size), Float(size))
        let gradient = try ImageMaterialReflectionTests.image(width: 16, height: 16,
                                                              pixels: Stage.bytes({ x, y in [UInt8(x * 16), 200, UInt8(y * 16), 255] },
                                                                                  width: 16, height: 16))
        var layer = Stage.layer("lit", image: gradient, size: scene)
        layer.weEffects = effects
        let budget = WELightConfig(point: 1)
        layer.imageMaterial = try builder(budget: budget, hdr: hdr).build(materialPath: "materials/lit.json",
                                                                           colorBlendMode: nil, prelit: !effects.isEmpty)
        XCTAssertEqual(layer.imageMaterial?.prelighting != nil, !effects.isEmpty)
        var content = Stage.content(layers: [layer], size: scene)
        var point = SceneLight(kind: .point)
        point.intensity = hdr ? 12 : 3
        // A white light bright enough for `CombineLighting` to exceed 1 (the default colour is black).
        if hdr { point.color = SIMD3(repeating: 1) }
        point.radius = 120
        content.engineCombos = SceneEngineCombos(hdr: hdr, sceneOrtho: true, lightBudget: budget)
        content.lighting.settings.lightConfig = budget
        content.lighting.settings.ambient = SIMD3(repeating: 0.2)
        content.lighting.lights = [SceneLightObject(id: "9", authored: WESceneLight(kind: .point), light: point,
                                                    depth: SceneLightDepth(originZ: 25))]
        content.transforms = SceneTransformHierarchy(nodes: [
            "lit": .init(parentID: nil, local: SceneLocalTransform(origin: layer.position, scale: SIMD2(1, 1), angle: 0)),
            "9": .init(parentID: nil, local: SceneLocalTransform(origin: SIMD2(40, 90), scale: SIMD2(1, 1), angle: 0)),
        ])
        renderer.setContent(content)
        func pixels() -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: size * size * 4)
            view.currentDrawable?.texture.getBytes(&bytes, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size),
                                                   mipmapLevel: 0)
            return bytes
        }
        // Until every pipeline is ready the layer draws natively (or its effects take it unlit);
        // then two frames in a row agree. Time spent compiling doesn't count (it varies with load).
        var last: [UInt8] = []
        var settleFrames = 600
        let hardDeadline = Date().addingTimeInterval(600)
        while settleFrames > 0, Date() < hardDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            if !renderer.pipelinesCompiling { settleFrames -= 1 }
            let now = pixels()
            if now == last, !renderer.pipelinesCompiling, renderer.imageMaterialDraws > 0,
               effects.isEmpty || renderer.imageMaterialPrelitDraws > 0 { break }
            last = now
        }
        XCTAssertGreaterThan(renderer.imageMaterialDraws, 0, "the layer never drew through its material")
        if !effects.isEmpty { XCTAssertGreaterThan(renderer.imageMaterialPrelitDraws, 0, "the prepass never ran") }
        var sceneTarget: HDRReference.Image?
        if hdr, let target = renderer.lastSceneTarget {
            XCTAssertEqual(target.pixelFormat, .rgba16Float)
            sceneTarget = try HDRReference.read(target, device: device)
        }
        renderer.releaseContent()
        return (Stage.swappingRedAndBlue(last), sceneTarget)
    }

    static func packed(_ lights: [LightingReference.Light]) -> [String: [Float]] {
        ImageMaterialLightingTests.packed(lights)
    }
}
