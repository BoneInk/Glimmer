import XCTest
import MetalKit
import simd
@testable import OpenWallpaperEngine

/// Lit image layers (`LIGHTING`, docs/lighting-plan.md §2.3, A3) drawn through `genericimage4` with
/// the engine's `LIGHTS_*` combos and the packed lights, against `LightingReference`, a CPU model
/// of WE's shader: a point, a spot, a tube and a directional light; a normal map; metallic and
/// roughness from constants or from a PBR mask whose `.tex` flags mark the painted channels.
final class ImageMaterialLightingTests: XCTestCase {
    private typealias Stage = SceneMipMappedFrameBufferTests

    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var cache: URL?

    static let sceneSize = SIMD2<Float>(512, 256)
    static let width = 256
    static let height = 128
    static let albedo: [UInt8] = [153, 128, 102, 255]
    /// A tangent-space normal tilted toward +x and −y.
    static let normal: [UInt8] = [180, 110, 255, 255]
    /// Metallic 0.8, roughness ≈ 0.25; blue and alpha (reflection, emissive) aren't painted.
    static let mask: [UInt8] = [204, 64, 0, 255]
    static let ambient = SIMD3<Float>(0.2, 0.15, 0.1)

    /// Each type once, all in front of the layer (z > 0). The spot turns 2.2 rad, so its cone
    /// points up and to the left, (cos 2.2, sin 2.2); the directional is tilted toward the viewer.
    static let lights: [LightingReference.Light] = [
        .init(kind: .point, position: SIMD3(100, 180, 60), color: SIMD3(1, 0.8, 0.6), intensity: 3, radius: 300, exponent: 2),
        .init(kind: .spot, position: SIMD3(380, 60, 80), angles: SIMD3(0, 0, 2.2), color: SIMD3(0.6, 0.8, 1), intensity: 4,
              radius: 400, exponent: 1.5, innerCone: 30, outerCone: 60),
        .init(kind: .tube, position: SIMD3(50, 20, 40), color: SIMD3(0.9, 1, 0.7), intensity: 2, radius: 200, exponent: 2,
              controlPoint: SIMD3(400, 0, 0)),
        .init(kind: .directional, position: SIMD3(0, 0, 0), angles: SIMD3(0, 0.9, 0.5), color: SIMD3(1, 1, 1), intensity: 0.5),
    ]
    static let budget = WELightConfig(point: 1, spot: 1, tube: 1, directional: 1)

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ShaderVariantTests.weAssets.appending(path: "shaders/genericimage4.frag").path),
                          "bundled WE shaders missing")
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-lighting-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let cache { try? FileManager.default.removeItem(at: cache) } // scratch cleanup
    }

    // MARK: - Plans

    /// `LIGHTING` draws through its material now, with the budget's `LIGHTS_*` combos.
    func testLightingPlansWithTheEngineLightCombos() throws {
        let plan = try XCTUnwrap(try builder().build(materialPath: "materials/lit.json", colorBlendMode: nil))
        let combos = try XCTUnwrap(plan.pass.variant?.combos)
        XCTAssertEqual(combos["LIGHTING"], 1)
        XCTAssertEqual(combos["LIGHTS_POINT"], 1)
        XCTAssertEqual(combos["LIGHTS_SPOT"], 1)
        XCTAssertEqual(combos["LIGHTS_TUBE"], 1)
        XCTAssertEqual(combos["LIGHTS_DIRECTIONAL"], 1)
        XCTAssertEqual(combos["SCENE_ORTHO"], 1)
        XCTAssertNil(combos["LIGHTS_SHADOW_MAPPING"])
        XCTAssertEqual(combos["NORMALMAP"], 0)
    }

    /// WE switches a PBR mask's component combos on from the bound texture's `.tex` flags (bit
    /// 20 + channel, 0x14016c800), and sets `TEX1FORMAT` for the RG88 normal map (`formatcombo`).
    func testMaskComponentsFollowTheTexFlags() throws {
        let plan = try XCTUnwrap(try builder().build(materialPath: "materials/litpbr.json", colorBlendMode: nil))
        let combos = try XCTUnwrap(plan.pass.variant?.combos)
        XCTAssertEqual(combos["NORMALMAP"], 1)
        XCTAssertEqual(combos["PBRMASKS"], 1)
        XCTAssertEqual(combos["METALLIC_MAP"], 1, "flag bit 20")
        XCTAssertEqual(combos["ROUGHNESS_MAP"], 1, "flag bit 21")
        XCTAssertNotEqual(combos["REFLECTION_MAP"], 1, "bit 22 is clear")
        XCTAssertNotEqual(combos["EMISSIVE_MAP"], 1, "bit 23 is clear")
        // The builder sets `TEX1FORMAT` 8 (RG88) for the normal map, but genericimage4 never reads
        // it (only common_fragment.h does), so it isn't part of the variant (LF8).
        XCTAssertNil(combos["TEX1FORMAT"])
    }

    func testComponentCombosNeedTheirFlagBit() {
        let source = ShaderSource(stage: .fragment, path: "test.frag", text: "", combos: [], uniforms: [
            ShaderUniformDeclaration(type: "sampler2D", name: "g_Texture2", arrayCount: nil, annotation: [
                "combo": "PBRMASKS",
                "components": [["combo": "METALLIC_MAP"], ["combo": "ROUGHNESS_MAP"], ["combo": "REFLECTION_MAP"],
                               ["combo": "EMISSIVE_MAP"]],
            ]),
        ])
        let empty = ShaderSource(stage: .vertex, path: "test.vert", text: "", combos: [], uniforms: [])
        let reflection = ShaderVariantTranslator.resolveCombos(vertex: empty, fragment: source, overrides: [],
                                                               boundTextureSlots: [2], textureFlags: [2: 0x400002])
        XCTAssertEqual(reflection, ["PBRMASKS": 1, "REFLECTION_MAP": 1], "меч's mask: only the reflection channel")
        let unbound = ShaderVariantTranslator.resolveCombos(vertex: empty, fragment: source, overrides: [],
                                                            boundTextureSlots: [], textureFlags: [2: 0xF00000])
        XCTAssertEqual(unbound, ["PBRMASKS": 0], "nothing without the texture bound")
    }

    // MARK: - Against the CPU model

    /// No normal map: the normal is the layer's +z; metallic 0 and roughness 0.7 (the defaults).
    func testFlatLayerMatchesTheReference() throws {
        let plan = try XCTUnwrap(try builder().build(materialPath: "materials/lit.json", colorBlendMode: nil))
        let quad = SceneQuadGeometry(center: Self.sceneSize / 2, axisX: SIMD2(Self.sceneSize.x, 0), axisY: SIMD2(0, Self.sceneSize.y))
        let pixels = try draw(plan, quad: quad)
        let surface = LightingReference.Surface(albedo: Self.albedoColor, normal: SIMD3(0, 0, 1), roughness: 0.7, metallic: 0)
        try assertMatches(pixels, surface: { _ in surface }, samples: Self.samples)
    }

    /// A normal map and a mask, on a layer turned 0.5 rad: the tangent space turns with it.
    func testNormalMappedTurnedLayerMatchesTheReference() throws {
        let plan = try XCTUnwrap(try builder().build(materialPath: "materials/litpbr.json", colorBlendMode: nil))
        let turn: Float = 0.5
        let axis = SIMD2(cos(turn), sin(turn))
        let quad = SceneQuadGeometry(center: Self.sceneSize / 2, axisX: axis * 700, axisY: SIMD2(-axis.y, axis.x) * 700)
        let pixels = try draw(plan, quad: quad)
        let texel = SIMD2(Float(Self.normal[0]), Float(Self.normal[1])) / 255
        let normal = LightingReference.mappedNormal(texel, tangent: SIMD3(axis, 0), bitangent: SIMD3(-axis.y, axis.x, 0))
        let surface = LightingReference.Surface(albedo: Self.albedoColor, normal: normal, roughness: Float(Self.mask[1]) / 255,
                                                metallic: Float(Self.mask[0]) / 255, specularTint: SIMD3(1, 0.9, 0.8))
        try assertMatches(pixels, surface: { _ in surface }, samples: Self.samples)
    }

    /// The spot's cone lies along its turned +X, (cos 2.2, sin 2.2): up and to the left of it, not
    /// down (where the old clockwise convention put it).
    func testSpotConePointsAlongItsTurnedAxis() throws {
        let plan = try XCTUnwrap(try builder(budget: WELightConfig(spot: 1)).build(materialPath: "materials/lit.json", colorBlendMode: nil))
        let quad = SceneQuadGeometry(center: Self.sceneSize / 2, axisX: SIMD2(Self.sceneSize.x, 0), axisY: SIMD2(0, Self.sceneSize.y))
        let spot = Self.lights[1]
        let pixels = try draw(plan, quad: quad, lights: [spot])
        func red(atWorld point: SIMD2<Float>) -> Float {
            let x = Int(point.x / Self.sceneSize.x * Float(Self.width))
            let y = Int((1 - point.y / Self.sceneSize.y) * Float(Self.height))
            return pixel(pixels, x: x, y: y).x
        }
        let along = SIMD2(spot.position.x, spot.position.y) + 60 * SIMD2(cos(2.2), sin(2.2))
        let mirrored = SIMD2(spot.position.x, spot.position.y) + 60 * SIMD2(cos(2.2), -sin(2.2))
        let unlit = Self.albedoColor.x * Self.ambient.x
        XCTAssertGreaterThan(red(atWorld: along), unlit + 0.03, "lit along the cone")
        XCTAssertEqual(red(atWorld: mirrored), unlit, accuracy: 0.01, "dark on the mirrored side")
        let surface = LightingReference.Surface(albedo: Self.albedoColor, normal: SIMD3(0, 0, 1), roughness: 0.7, metallic: 0)
        try assertMatches(pixels, surface: { _ in surface }, samples: Self.samples, lights: [spot])
    }

    /// Without `lightconfig` WE's budget is 0: the layer is its albedo times the ambient colour.
    func testAmbientOnlyIsTheAlbedoTimesTheAmbient() throws {
        let plan = try XCTUnwrap(try builder(budget: nil).build(materialPath: "materials/lit.json", colorBlendMode: nil))
        XCTAssertEqual(plan.pass.variant?.combos["LIGHTS_POINT"], 0)
        let quad = SceneQuadGeometry(center: Self.sceneSize / 2, axisX: SIMD2(Self.sceneSize.x, 0), axisY: SIMD2(0, Self.sceneSize.y))
        let pixels = try draw(plan, quad: quad, lights: [])
        for (x, y) in Self.samples {
            let actual = pixel(pixels, x: x, y: y)
            let expected = Self.albedoColor * Self.ambient
            for channel in 0..<3 { XCTAssertEqual(actual[channel], expected[channel], accuracy: 0.002, "(\(x), \(y))") }
        }
    }

    /// Through the whole renderer: the content's light object is packed each frame from its
    /// transform, and the layer draws through its material, lit.
    func testRendererLightsTheLayerFromTheContentsLights() throws {
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
        var layer = Stage.layer("lit", image: try Self.image(Self.albedo), size: scene)
        let budget = WELightConfig(spot: 1)
        layer.imageMaterial = try builder(budget: budget).build(materialPath: "materials/lit.json", colorBlendMode: nil)
        XCTAssertNotNil(layer.imageMaterial)
        var content = Stage.content(layers: [layer], size: scene)
        var spot = SceneLight(kind: .spot)
        spot.color = SIMD3(repeating: 1)
        spot.intensity = 4
        spot.radius = 200
        spot.innerCone = 30
        spot.outerCone = 60
        content.lighting.settings.lightConfig = budget
        content.lighting.settings.ambient = SIMD3(repeating: 0)
        content.lighting.lights = [SceneLightObject(id: "9", authored: WESceneLight(kind: .spot), light: spot,
                                                    depth: SceneLightDepth(originZ: 30))]
        // At the left edge, turned a quarter: its cone points up the scene (+y).
        content.transforms = SceneTransformHierarchy(nodes: [
            "lit": .init(parentID: nil, local: SceneLocalTransform(origin: scene / 2, scale: SIMD2(1, 1), angle: 0)),
            "9": .init(parentID: nil, local: SceneLocalTransform(origin: SIMD2(64, 20), scale: SIMD2(1, 1), angle: .pi / 2)),
        ])
        renderer.setContent(content)

        func red(x: Int, y: Int) -> Float {
            var bytes = [UInt8](repeating: 0, count: size * size * 4)
            view.currentDrawable?.texture.getBytes(&bytes, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size),
                                                   mipmapLevel: 0)
            return Float(bytes[(y * size + x) * 4 + 2]) / 255
        }
        // The native draw (the albedo, unlit) shows until the material's pipeline is ready. Under
        // load the first frames can be blank too (nothing drawn yet), which isn't the lit frame
        // either: wait while both the spot's dark side and its lit side are black.
        let deadline = Date().addingTimeInterval(20)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
        } while Date() < deadline && (red(x: 64, y: 125) > 0.3 || red(x: 64, y: 125) + red(x: 64, y: 30) == 0)
        XCTAssertLessThan(red(x: 64, y: 125), 0.01, "dark behind the spot (scene y ≈ 2), with no ambient")
        XCTAssertGreaterThan(red(x: 64, y: 30), 0.05, "lit up from it (scene y ≈ 98)")
        XCTAssertLessThan(red(x: 4, y: 110), 0.01, "dark to its side, outside the cone")
    }

    /// The cost of lighting a layer: a 1920×1080 `genericimage4` layer with 4 tubes (One piece
    /// girls' budget) against the same layer unlit, GPU time per draw.
    func testLitDrawCost() throws {
        let tubes = (0..<4).map { index in
            LightingReference.Light(kind: .tube, position: SIMD3(Float(index) * 640, -46, 250), intensity: 10, radius: 500,
                                    exponent: 2, controlPoint: SIMD3(1.9, 1131.8, 0))
        }
        let lit = try XCTUnwrap(try builder(budget: WELightConfig(tube: 4)).build(materialPath: "materials/lit.json", colorBlendMode: nil))
        let unlit = try XCTUnwrap(try builder(budget: nil).build(materialPath: "materials/image4.json", colorBlendMode: nil))
        func median(_ plan: ImageMaterialPlan) throws -> Double {
            let renderer = try XCTUnwrap(ImageMaterialRenderer(device: device, archive: nil))
            XCTAssertTrue(renderer.waitUntilReady(plan, pixelFormat: .bgra8Unorm))
            let albedo = try Stage.texture(device: device, width: 1, height: 1, pixels: Self.albedo, format: .rgba8Unorm)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1920, height: 1080,
                                                                      mipmapped: false)
            descriptor.usage = [.renderTarget]
            descriptor.storageMode = .private
            let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            var frame = BuiltinFrameContext()
            frame.screenSize = SIMD2(1920, 1080)
            frame.lighting = SceneFrameLighting(ambient: Self.ambient, skylight: SIMD3(repeating: 0.3), arrays: Self.packed(tubes))
            var times: [Double] = []
            for _ in 0..<30 {
                let commands = try XCTUnwrap(queue.makeCommandBuffer())
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .dontCare
                pass.colorAttachments[0].storeAction = .store
                let encoder = try XCTUnwrap(commands.makeRenderCommandEncoder(descriptor: pass))
                XCTAssertTrue(renderer.draw(plan, ImageMaterialRenderer.Draw(
                    layerID: "layer", quad: SceneQuadGeometry(center: SIMD2(960, 540), axisX: SIMD2(1920, 0), axisY: SIMD2(0, 1080)),
                    sceneSize: SIMD2(1920, 1080), color: SIMD3(repeating: 1), alpha: 1, brightness: 1, texture: albedo,
                    contentSize: nil, uvOrigin: .zero, uvAxisX: SIMD2(1, 0), uvAxisY: SIMD2(0, 1), sceneSnapshot: nil,
                    frame: frame, values: EffectGraphTests.FixedValues(), assetTexture: { _, _ in nil }),
                    pixelFormat: .bgra8Unorm, encoder: encoder, commandBuffer: commands))
                encoder.endEncoding()
                commands.commit()
                commands.waitUntilCompleted()
                times.append((commands.gpuEndTime - commands.gpuStartTime) * 1000)
            }
            return times.sorted()[times.count / 2]
        }
        let litTime = try median(lit), unlitTime = try median(unlit)
        print(String(format: "Lit layer cost at 1920×1080, 4 tubes: %.3f ms lit, %.3f ms unlit (GPU, median of 30)",
                     litTime, unlitTime))
        XCTAssertLessThan(litTime, 16, "a lit full-screen layer fits a frame")
    }

    // MARK: - Helpers

    static var albedoColor: SIMD3<Float> { SIMD3(Float(albedo[0]), Float(albedo[1]), Float(albedo[2])) / 255 }

    /// Pixels across the target, away from the edges.
    static let samples: [(Int, Int)] = stride(from: 8, to: width, by: 23).flatMap { x in
        stride(from: 6, to: height, by: 17).map { y in (x, y) }
    }

    private func builder(budget: WELightConfig? = ImageMaterialLightingTests.budget) throws -> ImageMaterialPlanBuilder {
        let roots = [Fixtures.url("ImageMaterials"), ShaderVariantTests.weAssets]
        let normal = try Self.image(Self.normal)
        let mask = try Self.image(Self.mask)
        return ImageMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { path in roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first },
            loadTexture: { name, _ in
                switch name {
                case "lit_normal": return .image(normal)
                case "lit_mask": return .image(mask)
                default: return nil
                }
            },
            sceneEngineCombos: SceneEngineCombos(sceneOrtho: true, lightBudget: budget))
    }

    /// Draws `plan` with the lights packed as the renderer packs them, into a cleared rgba16Float
    /// target; RGBA floats.
    private func draw(_ plan: ImageMaterialPlan, quad: SceneQuadGeometry,
                      lights: [LightingReference.Light] = ImageMaterialLightingTests.lights) throws -> [Float] {
        let renderer = try XCTUnwrap(ImageMaterialRenderer(device: device, archive: nil))
        XCTAssertTrue(renderer.waitUntilReady(plan, pixelFormat: .rgba16Float))
        let albedo = try Stage.texture(device: device, width: 1, height: 1, pixels: Self.albedo, format: .rgba8Unorm)
        let normal = try Stage.texture(device: device, width: 1, height: 1, pixels: Self.normal, format: .rgba8Unorm)
        let mask = try Stage.texture(device: device, width: 1, height: 1, pixels: Self.mask, format: .rgba8Unorm)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: Self.width,
                                                                  height: Self.height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var frame = BuiltinFrameContext()
        frame.screenSize = SIMD2(Float(Self.width), Float(Self.height))
        frame.lighting = SceneFrameLighting(ambient: Self.ambient, skylight: SIMD3(repeating: 0.3), arrays: Self.packed(lights))
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let encoder = try XCTUnwrap(commands.makeRenderCommandEncoder(descriptor: pass))
        let drew = renderer.draw(plan, ImageMaterialRenderer.Draw(
            layerID: "layer", quad: quad, sceneSize: Self.sceneSize, color: SIMD3(repeating: 1), alpha: 1, brightness: 1,
            texture: albedo, contentSize: nil, uvOrigin: .zero, uvAxisX: SIMD2(1, 0), uvAxisY: SIMD2(0, 1),
            sceneSnapshot: nil, frame: frame, values: EffectGraphTests.FixedValues(),
            assetTexture: { key, _ in key.hasSuffix("lit_normal") ? normal : key.hasSuffix("lit_mask") ? mask : nil }),
            pixelFormat: .rgba16Float, encoder: encoder, commandBuffer: commands)
        XCTAssertTrue(drew)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var halves = [UInt16](repeating: 0, count: Self.width * Self.height * 4)
        target.getBytes(&halves, bytesPerRow: Self.width * 8, from: MTLRegionMake2D(0, 0, Self.width, Self.height), mipmapLevel: 0)
        return halves.map(Self.float)
    }

    /// The `LightingV1` arrays of `lights`, through the renderer's packer and world transform.
    static func packed(_ lights: [LightingReference.Light]) -> [String: [Float]] {
        let entries = lights.map { source -> SceneLightPacker.Light in
            var light = SceneLight(kind: source.kind)
            light.color = source.color
            light.intensity = source.intensity
            light.radius = source.radius
            light.exponent = source.exponent
            light.innerCone = source.innerCone
            light.outerCone = source.outerCone
            light.controlPoint = source.controlPoint
            let local = SceneLocalTransform(origin: SIMD2(source.position.x, source.position.y), scale: SIMD2(1, 1),
                                            angle: source.angles.z)
            let depth = SceneLightDepth(originZ: source.position.z, anglesXY: SIMD2(source.angles.x, source.angles.y))
            return SceneLightPacker.Light(light: light, world: SceneFrameLighting.world(parent: .identity, local: local, depth: depth),
                                          localOrigin: source.position, visible: true)
        }
        var budget = WELightConfig()
        for light in lights {
            switch light.kind {
            case .point: budget.point += 1
            case .spot: budget.spot += 1
            case .tube: budget.tube += 1
            case .directional: budget.directional += 1
            case .legacyPoint: break
            }
        }
        return SceneLightPacker.lightingV1(entries, budget: budget, shadows: true, viewForward: SIMD3(0, 0, -1))
    }

    private func assertMatches(_ pixels: [Float], surface: (SIMD3<Float>) -> LightingReference.Surface,
                               samples: [(Int, Int)], lights: [LightingReference.Light] = ImageMaterialLightingTests.lights,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        var worst: Float = 0
        for (x, y) in samples {
            let world = SIMD3((Float(x) + 0.5) / Float(Self.width) * Self.sceneSize.x,
                              (1 - (Float(y) + 0.5) / Float(Self.height)) * Self.sceneSize.y, 0)
            let expected = LightingReference.shade(surface(world), at: world, lights: lights, ambient: Self.ambient)
            let actual = pixel(pixels, x: x, y: y)
            for channel in 0..<3 {
                let error = abs(actual[channel] - expected[channel])
                worst = max(worst, error)
                XCTAssertLessThanOrEqual(error, 0.004 + 0.004 * abs(expected[channel]),
                                         "(\(x), \(y)) channel \(channel): \(actual) vs \(expected)", file: file, line: line)
            }
        }
        XCTAssertGreaterThan(samples.count, 50)
        print("lighting reference: worst difference \(worst) over \(samples.count) pixels")
    }

    private func pixel(_ rgba: [Float], x: Int, y: Int) -> SIMD4<Float> {
        let i = (y * Self.width + x) * 4
        return SIMD4(rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3])
    }

    /// IEEE half to float (Float16 isn't available on every Mac the tests run on).
    static func float(_ half: UInt16) -> Float {
        let sign: Float = half & 0x8000 != 0 ? -1 : 1
        let exponent = Int((half >> 10) & 0x1F), mantissa = Float(half & 0x3FF)
        if exponent == 0 { return sign * mantissa * pow(2, -24) }
        if exponent == 31 { return mantissa == 0 ? sign * .infinity : .nan }
        return sign * (1 + mantissa / 1024) * pow(2, Float(exponent - 15))
    }

    static func image(_ rgba: [UInt8]) throws -> NSImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let image = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder32Big),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return NSImage(cgImage: image, size: NSSize(width: 1, height: 1))
    }
}
