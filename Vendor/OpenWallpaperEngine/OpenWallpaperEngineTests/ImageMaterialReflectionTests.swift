import XCTest
import MetalKit
import simd
@testable import OpenWallpaperEngine

/// `genericimage4`'s screen-space reflection (`REFLECTION` with `NORMALMAP`; docs/lighting-plan.md
/// §2.4) through `_rt_MipMappedFrameBuffer`: against a CPU reference of the shader, with the
/// reflection setting off, and through the whole renderer.
final class ImageMaterialReflectionTests: XCTestCase {
    private typealias Stage = SceneMipMappedFrameBufferTests
    private typealias Level = (width: Int, height: Int, texels: [Float])

    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var cache: URL?

    /// A dark, opaque albedo, so the reflection term stands out.
    static let albedo: [UInt8] = [25, 25, 25, 255]
    /// A constant tangent-space normal tilted along x: (0.6, 0.004, 0.8).
    static let normal: [UInt8] = [204, 128, 255, 255]
    /// PBR mask (metallic, roughness, reflection): the left half is smooth metal, the right half
    /// rough and not metallic; both fully reflective.
    static let maskLeft: [UInt8] = [255, 0, 255, 255]
    static let maskRight: [UInt8] = [0, 255, 255, 255]

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ShaderVariantTests.weAssets.appending(path: "shaders/genericimage4.frag").path),
                          "bundled WE shaders missing")
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-reflection-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let cache { try? FileManager.default.removeItem(at: cache) } // scratch cleanup
    }

    /// The layer samples the copy at mip `roughness · g_Texture3MipMapInfo`: the stripes where the
    /// mask's roughness is 0, their grey average where it is 1, each through WE's fresnel,
    /// reflectivity and metallic.
    func testReflectionSamplesTheCopyAtTheRoughnessMip() throws {
        let plan = try reflectionPlan()
        let combos = try XCTUnwrap(plan.pass.variant?.combos)
        XCTAssertEqual(combos["REFLECTION"], 1)
        XCTAssertEqual(combos["NORMALMAP"], 1, "the normal map is bound")
        XCTAssertEqual(combos["PBRMASKS"], 1, "the mask is bound")
        guard case .mipMappedFrameBuffer? = plan.pass.textures[3] else {
            return XCTFail("g_Texture3 is not _rt_MipMappedFrameBuffer: \(String(describing: plan.pass.textures[3]))")
        }
        XCTAssertFalse(plan.readsSceneSnapshot)

        let stage = try filledStage(plan: plan, reflection: true)
        let target = try XCTUnwrap(stage.texture)
        var mips: [Level] = []
        for (level, bgra) in try Stage.levels(of: target, queue: queue).enumerated() {
            mips.append((width: Stage.width >> level, height: Stage.height >> level,
                         texels: Stage.swappingRedAndBlue(bgra).map { $0 / 255 }))
        }
        let pixels = try draw(plan, mipMapped: target)
        let probes: [(Int, Int, String)] = [(17, 40, "white stripe, roughness 0"), (21, 40, "black stripe, roughness 0"),
                                            (25, 90, "white stripe, lower"), (200, 40, "rough: the grey mip"),
                                            (203, 100, "rough, lower")]
        for (x, y, what) in probes {
            let expected = Self.reference(x: x, y: y, mips: mips)
            let actual = Self.pixel(pixels, x: x, y: y)
            for channel in 0..<3 {
                XCTAssertEqual(actual[channel], expected[channel], accuracy: 3 / 255, "\(what) (\(x), \(y)) channel \(channel)")
            }
        }
        XCTAssertGreaterThan(Self.pixel(pixels, x: 17, y: 40)[0], 0.6, "a visible reflection on the metal")
    }

    /// The reflection setting off: the copy is (0, 0, 0, 1), so nothing is reflected.
    func testReflectionSettingOffReflectsNothing() throws {
        let plan = try reflectionPlan()
        let stage = try filledStage(plan: plan, reflection: false)
        let pixels = try draw(plan, mipMapped: stage.texture)
        for (x, y) in [(17, 40), (200, 40), (203, 100)] {
            for channel in 0..<3 {
                XCTAssertEqual(Self.pixel(pixels, x: x, y: y)[channel], Float(Self.albedo[channel]) / 255, accuracy: 1 / 255,
                               "(\(x), \(y))")
            }
        }
    }

    /// Through the whole renderer: the reflective layer reads the last frame's copy, and turning
    /// the setting off takes the reflection away again.
    func testRendererBindsTheCopyAndHonoursTheSetting() throws {
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
        var background = Stage.layer("white", image: SceneContentLoader.pixelImage([1, 1, 1, 1]), size: scene)
        background.order = 0
        // Half-transparent, smooth metal (the left half of the mask) over white.
        var reflective = Stage.layer("reflective", image: try Self.image(width: 1, height: 1, pixels: [25, 25, 25, 128]),
                                     size: scene)
        reflective.order = 1
        reflective.imageMaterial = try reflectionPlan(blending: "translucent", mask: Self.maskLeft)
        renderer.setContent(Stage.content(layers: [background, reflective], size: scene))

        func red() -> Float {
            var pixels = [UInt8](repeating: 0, count: size * size * 4)
            view.currentDrawable?.texture.getBytes(&pixels, bytesPerRow: size * 4,
                                                   from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
            return Float(pixels[((size / 2) * size + size / 2) * 4 + 2]) / 255
        }
        // Unlit: half the albedo over white.
        let alpha: Double = 128.0 / 255.0
        let albedo: Double = 25.0 * alpha
        let white: Double = 255.0 * (1.0 - alpha)
        let unlit = Float((albedo + white) / 255.0)
        var lit: Float = 0
        let deadline = Date().addingTimeInterval(20)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            lit = red()
        } while Date() < deadline && lit < unlit + 0.1
        XCTAssertGreaterThan(lit, unlit + 0.1, "the last frame is reflected")
        let stage = try XCTUnwrap(renderer.mipMappedFrameBuffer)
        XCTAssertGreaterThan(stage.framesCopied, 0)
        XCTAssertEqual(stage.texture?.width, size)

        var settings = SceneRenderSettings()
        settings.reflection = false
        renderer.renderSettings = settings
        for _ in 0..<3 {
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
        }
        XCTAssertEqual(red(), unlit, accuracy: 2 / 255, "no reflection with the setting off")
    }

    // MARK: - CPU reference

    /// `genericimage4.frag`'s `REFLECTION && NORMALMAP` branch (SCENE_ORTHO, METALLIC_MAP,
    /// ROUGHNESS_MAP, REFLECTION_MAP) at pixel (`x`, `y`) of `draw`: the layer covers the scene
    /// unrotated, so its tangent space is the identity; `mips` are the copy's levels (RGBA, 0…1).
    private static func reference(x: Int, y: Int, mips: [Level]) -> SIMD3<Float> {
        let width = Float(Stage.width), height = Float(Stage.height)
        let albedo = SIMD3<Float>(Float(Self.albedo[0]), Float(Self.albedo[1]), Float(Self.albedo[2])) / 255
        let mask = (Float(x) + 0.5) / width < 0.5 ? maskLeft : maskRight
        let metallic = Float(mask[0]) / 255
        let roughness = Float(mask[1]) / 255
        let reflectivity = 4 * Float(mask[2]) / 255
        let compressed = SIMD2<Float>(Float(normal[0]), Float(normal[1])) / 255 * 2 - 1
        let z = max(0, 1 - simd_length_squared(compressed)).squareRoot()
        var n = simd_normalize(SIMD3<Float>(compressed.x, compressed.y, z))
        // SCENE_ORTHO: the view vector is (0, 0, 1).
        let fresnel = max(0.001, n.z)
        let viewProjection = ImageMaterialRenderer.viewProjection(sceneSize: Stage.sceneSize)
        let c0 = viewProjection.columns.0, c1 = viewProjection.columns.1, c2 = viewProjection.columns.2
        let upper = simd_float3x3(SIMD3(c0.x, c0.y, c0.z), SIMD3(c1.x, c1.y, c1.z), SIMD3(c2.x, c2.y, c2.z))
        n = simd_normalize(upper * n)
        // g_Screen.z: the target's aspect.
        let offset = SIMD2<Float>(n.x * 0.15, n.y * 0.15 * (width / height)) * pow(fresnel, 4) * 4
        let uv = SIMD2<Float>((Float(x) + 0.5) / width, (Float(y) + 0.5) / height) + offset
        let lod = min(max(roughness * Float(mips.count), 0), Float(mips.count - 1))
        let low = Int(lod.rounded(.down))
        let high = min(low + 1, mips.count - 1)
        let sample = simd_mix(bilinear(mips[low], uv), bilinear(mips[high], uv), SIMD3(repeating: lod - Float(low)))
        let scaled = sample * (1 - fresnel) * reflectivity
        let exponent = 2 - metallic
        let reflection = SIMD3<Float>(pow(max(0.001, scaled.x), exponent), pow(max(0.001, scaled.y), exponent),
                                      pow(max(0.001, scaled.z), exponent))
        return albedo + simd_clamp(reflection, SIMD3(repeating: 0), SIMD3(repeating: 1)) * fresnel
    }

    /// Clamp-to-edge bilinear sample of an RGBA level (red, green and blue).
    private static func bilinear(_ level: Level, _ uv: SIMD2<Float>) -> SIMD3<Float> {
        let position = uv * SIMD2(Float(level.width), Float(level.height)) - 0.5
        let base = position.rounded(.down)
        let f = position - base
        func texel(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let cx = min(max(x, 0), level.width - 1), cy = min(max(y, 0), level.height - 1)
            let i = (cy * level.width + cx) * 4
            return SIMD3(level.texels[i], level.texels[i + 1], level.texels[i + 2])
        }
        let x0 = Int(base.x), y0 = Int(base.y)
        let top = simd_mix(texel(x0, y0), texel(x0 + 1, y0), SIMD3(repeating: f.x))
        let bottom = simd_mix(texel(x0, y0 + 1), texel(x0 + 1, y0 + 1), SIMD3(repeating: f.x))
        return simd_mix(top, bottom, SIMD3(repeating: f.y))
    }

    // MARK: - Helpers

    /// Plans `materials/reflection.json` with its normal map and a mask (`mask` everywhere, or the
    /// left and right halves), optionally with another blending.
    private func builder(blending: String? = nil, mask: [UInt8]? = nil) throws -> ImageMaterialPlanBuilder {
        let roots = [Fixtures.url("ImageMaterials"), ShaderVariantTests.weAssets]
        let normal = try Self.image(width: 1, height: 1, pixels: Self.normal)
        let maskImage = try mask.map { try Self.image(width: 1, height: 1, pixels: $0) }
            ?? Self.image(width: 2, height: 1, pixels: Self.maskLeft + Self.maskRight)
        return ImageMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { path in
                guard let data = roots.lazy.compactMap({ FileManager.default.contents(atPath: $0.appending(path: path).path) }).first
                else { return nil }
                guard let blending, path == "materials/reflection.json", let text = String(data: data, encoding: .utf8) else { return data }
                return Data(text.replacingOccurrences(of: #""blending":"normal""#, with: #""blending":"\#(blending)""#).utf8)
            },
            loadTexture: { name, _ in
                switch name {
                case "reflection_normal": return .image(normal)
                case "reflection_mask": return .image(maskImage)
                default: return nil
                }
            })
    }

    private func reflectionPlan(blending: String? = nil, mask: [UInt8]? = nil) throws -> ImageMaterialPlan {
        try XCTUnwrap(try builder(blending: blending, mask: mask).build(materialPath: "materials/reflection.json",
                                                                        colorBlendMode: nil))
    }

    /// A stage for `plan` that has copied the stripes once (or, with `reflection` off, cleared itself).
    private func filledStage(plan: ImageMaterialPlan, reflection: Bool) throws -> SceneMipMappedFrameBuffer {
        let stage = SceneMipMappedFrameBuffer(device: device)
        var layer = Stage.layer("reflective")
        layer.imageMaterial = plan
        stage.setContent(Stage.content(layers: [layer]))
        XCTAssertTrue(stage.isSampled)
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        stage.encode(Stage.stageContext(try Stage.sceneTexture(device: device), commands, reflection: reflection))
        commands.commit()
        commands.waitUntilCompleted()
        return stage
    }

    /// Draws `plan` over the whole scene into a fresh 256×128 target; RGBA floats.
    private func draw(_ plan: ImageMaterialPlan, mipMapped: MTLTexture?) throws -> [Float] {
        let renderer = try XCTUnwrap(ImageMaterialRenderer(device: device, archive: nil))
        XCTAssertTrue(renderer.waitUntilReady(plan, pixelFormat: .bgra8Unorm))
        let albedo = try Stage.texture(device: device, width: 1, height: 1, pixels: Self.albedo, format: .rgba8Unorm)
        let normal = try Stage.texture(device: device, width: 1, height: 1, pixels: Self.normal, format: .rgba8Unorm)
        let mask = try Stage.texture(device: device, width: 2, height: 1, pixels: Self.maskLeft + Self.maskRight,
                                     format: .rgba8Unorm)
        let target = try Stage.texture(device: device, width: Stage.width, height: Stage.height,
                                       pixels: [UInt8](repeating: 0, count: Stage.width * Stage.height * 4), format: .bgra8Unorm)
        var frame = BuiltinFrameContext()
        frame.screenSize = SIMD2(Float(Stage.width), Float(Stage.height))
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let encoder = try XCTUnwrap(commands.makeRenderCommandEncoder(descriptor: pass))
        let sceneSize = Stage.sceneSize
        let quad = SceneQuadGeometry(center: sceneSize / 2, axisX: SIMD2(sceneSize.x, 0), axisY: SIMD2(0, sceneSize.y))
        let assets: (String, SceneMetalTextureSource) -> MTLTexture? = { key, _ in
            if key.hasSuffix("reflection_normal") { return normal }
            return key.hasSuffix("reflection_mask") ? mask : nil
        }
        let drew = renderer.draw(plan, ImageMaterialRenderer.Draw(
            layerID: "layer", quad: quad, sceneSize: sceneSize, color: SIMD3(repeating: 1), alpha: 1, brightness: 1,
            texture: albedo, contentSize: nil, uvOrigin: .zero, uvAxisX: SIMD2(1, 0), uvAxisY: SIMD2(0, 1),
            sceneSnapshot: nil, mipMappedFrameBuffer: mipMapped, frame: frame, values: EffectGraphTests.FixedValues(),
            assetTexture: assets), pixelFormat: .bgra8Unorm, encoder: encoder, commandBuffer: commands)
        XCTAssertTrue(drew)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return Stage.swappingRedAndBlue(try Stage.levels(of: target, queue: queue)[0]).map { $0 / 255 }
    }

    private static func pixel(_ rgba: [Float], x: Int, y: Int) -> [Float] {
        let start = (y * Stage.width + x) * 4
        return Array(rgba[start..<start + 4])
    }

    static func image(width: Int, height: Int, pixels: [UInt8]) throws -> NSImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder32Big),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }
}
