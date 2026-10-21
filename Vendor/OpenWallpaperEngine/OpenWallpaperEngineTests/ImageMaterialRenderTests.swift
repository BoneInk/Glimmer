import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// Image layers drawn through their WE material (`ImageMaterialRenderer`) against the native
/// `sceneFragment` draw they replace: the same layer, quad and texture into the same target must
/// give the same pixels wherever the two agree on what WE does. Uses the bundled WE shaders and the
/// in-process translator, so it needs neither a WE install nor Homebrew.
final class ImageMaterialRenderTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var builder: ImageMaterialPlanBuilder!
    private var renderer: ImageMaterialRenderer!
    private var cache: URL!

    static let sceneSize = SIMD2<Float>(512, 256)
    static let targetSize = (width: 256, height: 128)
    static let background = SIMD4<Float>(0.8, 0.6, 0.4, 1)

    override func setUpWithError() throws {
        let assets = ShaderVariantTests.weAssets
        try XCTSkipUnless(FileManager.default.fileExists(atPath: assets.appending(path: "shaders/genericimage4.frag").path),
                          "bundled WE shaders missing")
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-image-material-\(UUID().uuidString)")
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
    }

    override func tearDownWithError() throws {
        if let cache { try? FileManager.default.removeItem(at: cache) } // scratch cleanup
    }

    // MARK: - Plans

    func testPlainMaterialsPlanWithTheLayerImageInSlotZero() throws {
        for material in ["image4", "image2version", "image2legacy", "additive", "normal"] {
            let plan = try XCTUnwrap(try builder.build(materialPath: "materials/\(material).json", colorBlendMode: nil), material)
            XCTAssertNotNil(plan.pass.variant, material)
            guard case .current? = plan.pass.textures[0] else { return XCTFail("\(material): slot 0 is not the layer image") }
            XCTAssertFalse(plan.readsSceneSnapshot, material)
        }
    }

    func testMaterialsWithoutAnImageKeepTheirOwnPath() throws {
        XCTAssertNil(try builder.build(materialPath: "materials/flat.json", colorBlendMode: nil))
    }

    func testAMissingTextureOnlyUnbindsItsSlot() throws {
        let plan = try XCTUnwrap(try builder.build(materialPath: "materials/missingmask.json", colorBlendMode: nil))
        XCTAssertNil(plan.pass.textures[1])
    }

    func testObjectBlendModeReadsTheScene() throws {
        let plan = try XCTUnwrap(try builder.build(materialPath: "materials/image4.json", colorBlendMode: 2))
        XCTAssertEqual(plan.pass.variant?.combos["BLENDMODE"], 2)
        XCTAssertTrue(plan.readsSceneSnapshot)
        guard case .sceneSnapshot? = plan.pass.textures[4] else { return XCTFail("g_Texture4 is not the scene") }
    }

    func testLegacyAlphaConstantScalesTheLiveAlpha() throws {
        let plan = try XCTUnwrap(try builder.build(materialPath: "materials/image2legacy.json", colorBlendMode: nil))
        XCTAssertEqual(plan.liveFactors["g_UserAlpha"], 0.5)
        XCTAssertEqual(plan.liveFactors["g_Brightness"], 1)
        XCTAssertNil(plan.pass.constants.staticValues["g_UserAlpha"], "a live uniform must not be written as a constant")
    }

    // MARK: - Pixels, material vs native

    func testGenericImage4MatchesTheNativeDraw() throws {
        let layer = Layer(rotation: 0.5)
        try assertMatchesNative("image4", layer)
    }

    func testVersionedGenericImage2MatchesTheNativeDrawWithColourAndBrightness() throws {
        let layer = Layer(rotation: -0.3, color: SIMD3(0.5, 1, 0.8), brightness: 1.2)
        try assertMatchesNative("image2version", layer)
    }

    func testSpriteSheetFrameMatchesTheNativeDraw() throws {
        let layer = Layer(rotation: 0.2, uvOrigin: SIMD2(0.5, 0), uvAxisX: SIMD2(0.25, 0), uvAxisY: SIMD2(0, 0.5))
        try assertMatchesNative("image2spritesheet", layer)
        try assertMatchesNative("image4", layer)
    }

    func testPaddedContentCropMatchesTheNativeDraw() throws {
        let layer = Layer(rotation: 0, uvAxisX: SIMD2(0.75, 0), uvAxisY: SIMD2(0, 0.625), contentSize: SIMD2(48, 40))
        try assertMatchesNative("image4", layer)
    }

    func testAdditiveBlendingMatchesTheNativeAdditiveDraw() throws {
        try assertMatchesNative("additive", Layer(rotation: 0.4), additive: true)
    }

    /// WE's translucent blend applies alpha once (`texel.a · alpha` as the source factor). The
    /// native draw also scaled the colour by it, so a half-transparent layer came out darker.
    func testLayerAlphaIsAppliedOnceLikeWE() throws {
        let plan = try XCTUnwrap(try builder.build(materialPath: "materials/image4.json", colorBlendMode: nil))
        let texture = try Self.solidTexture(device: device, color: [255, 0, 0, 255])
        let pixels = try render { encoder, format in
            XCTAssertTrue(self.drawMaterial(plan, Layer(rotation: 0, alpha: 0.5), texture: texture, snapshot: nil,
                                            encoder: encoder, format: format))
        }
        let center = Self.pixel(pixels, x: 100, y: 64)
        // Scene y = 128 (layer centre) is the target's middle row; x = 200 scene units is column 100.
        XCTAssertEqual(center.red, 0.5 * 1 + 0.5 * Self.background.x, accuracy: 2 / 255)
        XCTAssertEqual(center.green, 0.5 * Self.background.y, accuracy: 2 / 255)
    }

    /// Risk I1: layers that still draw natively (text, fallbacks) blend like WE too: a
    /// half-transparent layer matches its material draw instead of coming out darker.
    func testNativeDrawAppliesLayerAlphaOnce() throws {
        try assertMatchesNative("image4", Layer(rotation: 0.3, alpha: 0.5))
        try assertMatchesNative("additive", Layer(rotation: 0.3, alpha: 0.5), additive: true)
    }

    func testLegacyGenericImage2TakesAlphaFromTheMaterialAndTheLayer() throws {
        let plan = try XCTUnwrap(try builder.build(materialPath: "materials/image2legacy.json", colorBlendMode: nil))
        let texture = try Self.solidTexture(device: device, color: [0, 0, 255, 255])
        let pixels = try render { encoder, format in
            XCTAssertTrue(self.drawMaterial(plan, Layer(rotation: 0, alpha: 0.5), texture: texture, snapshot: nil,
                                            encoder: encoder, format: format))
        }
        let center = Self.pixel(pixels, x: 100, y: 64)
        // 0.5 (layer) × 0.5 (material "Alpha") of blue over the background.
        XCTAssertEqual(center.blue, 0.25 + 0.75 * Self.background.z, accuracy: 2 / 255)
        XCTAssertEqual(center.red, 0.75 * Self.background.x, accuracy: 2 / 255)
    }

    func testNormalBlendingOverwritesTheScene() throws {
        let plan = try XCTUnwrap(try builder.build(materialPath: "materials/normal.json", colorBlendMode: nil))
        let texture = try Self.solidTexture(device: device, color: [0, 255, 0, 64])
        let pixels = try render { encoder, format in
            XCTAssertTrue(self.drawMaterial(plan, Layer(rotation: 0), texture: texture, snapshot: nil,
                                            encoder: encoder, format: format))
        }
        let center = Self.pixel(pixels, x: 100, y: 64)
        XCTAssertEqual(center.green, 1, accuracy: 2 / 255)
        XCTAssertEqual(center.red, 0, accuracy: 2 / 255)
        XCTAssertEqual(center.alpha, 64 / 255, accuracy: 2 / 255)
    }

    /// `colorBlendMode` 2 is WE's multiply: the scene under the layer times the layer.
    func testBlendModeMultipliesWithTheSceneBeneath() throws {
        let plan = try XCTUnwrap(try builder.build(materialPath: "materials/image4.json", colorBlendMode: 2))
        let texture = try Self.solidTexture(device: device, color: [128, 255, 64, 255])
        let snapshot = try Self.solidTexture(device: device, color: Self.background.bytes)
        let pixels = try render { encoder, format in
            XCTAssertTrue(self.drawMaterial(plan, Layer(rotation: 0), texture: texture, snapshot: snapshot,
                                            encoder: encoder, format: format))
        }
        let center = Self.pixel(pixels, x: 100, y: 64)
        XCTAssertEqual(center.red, Self.background.x * 128 / 255, accuracy: 3 / 255)
        XCTAssertEqual(center.green, Self.background.y, accuracy: 3 / 255)
        XCTAssertEqual(center.blue, Self.background.z * 64 / 255, accuracy: 3 / 255)
    }

    /// A solid layer's `flat` has no `BLENDMODE`; WE composites its fill through
    /// `effectpassthrough_4` with the object's blend mode. WE's capture of a 0.2 0.6 1.0 band in
    /// Multiply over its 0.15 grey is (8, 23, 38) = 0.15 × the fill (effect gallery EXTRAS.md item 3).
    func testSolidFillCompositesWithItsBlendMode() throws {
        let plan = try XCTUnwrap(try builder.buildBlendComposite(colorBlendMode: 2))
        XCTAssertEqual(plan.pass.variant?.combos["BLENDMODE"], 2)
        XCTAssertEqual(plan.pass.variant?.combos["FOG_COMPUTED"], 1)
        guard case .current? = plan.pass.textures[0] else { return XCTFail("slot 0 is not the layer's fill") }
        let fill = try Self.solidTexture(device: device, color: [51, 153, 255, 255])
        let snapshot = try Self.solidTexture(device: device, color: Self.background.bytes)
        let pixels = try render { encoder, format in
            XCTAssertTrue(self.drawMaterial(plan, Layer(rotation: 0), texture: fill, snapshot: snapshot,
                                            encoder: encoder, format: format))
        }
        let center = Self.pixel(pixels, x: 100, y: 64)
        XCTAssertEqual(center.red, Self.background.x * 0.2, accuracy: 3 / 255)
        XCTAssertEqual(center.green, Self.background.y * 0.6, accuracy: 3 / 255)
        XCTAssertEqual(center.blue, Self.background.z, accuracy: 3 / 255)
    }

    /// The blend reads the scene pixel under each fragment, not its vertical mirror.
    func testBlendModeReadsTheScenePixelBeneath() throws {
        let plan = try XCTUnwrap(try builder.build(materialPath: "materials/image4.json", colorBlendMode: 2))
        let white = try Self.solidTexture(device: device, color: [255, 255, 255, 255])
        // Scene snapshot: top half red, bottom half blue (row 0 is the scene's top).
        let snapshot = try Self.texture(device: device, size: 4, pixels: (0..<16).flatMap { $0 < 8 ? [255, 0, 0, 255] : [0, 0, 255, 255] as [UInt8] })
        let pixels = try render { encoder, format in
            let layer = Layer(center: Self.sceneSize / 2, size: Self.sceneSize, rotation: 0)
            XCTAssertTrue(self.drawMaterial(plan, layer, texture: white, snapshot: snapshot, encoder: encoder, format: format))
        }
        XCTAssertEqual(Self.pixel(pixels, x: 128, y: 8).red, 1, accuracy: 2 / 255, "top of the scene")
    }

    /// A legacy material's `Brightness` scales the texel once: 0.4 × 1.5 = 0.6 over black.
    func testMaterialBrightnessIsAppliedOnce() throws {
        let plan = try XCTUnwrap(try builder.build(materialPath: "materials/image2legacybright.json", colorBlendMode: nil))
        XCTAssertEqual(plan.liveFactors["g_Brightness"], 1.5)
        let texture = try Self.solidTexture(device: device, color: [102, 102, 102, 255])
        let pixels = try render(background: SIMD4(0, 0, 0, 1)) { encoder, format in
            XCTAssertTrue(self.drawMaterial(plan, Layer(rotation: 0), texture: texture, snapshot: nil,
                                            encoder: encoder, format: format))
        }
        XCTAssertEqual(Self.pixel(pixels, x: 100, y: 64).red, 0.6, accuracy: 2 / 255)
    }

    /// The legacy material heuristics that the material now draws for itself (its `Brightness`)
    /// don't count as an adjustment the native draw would add on top.
    func testObjectBrightnessAloneIsNotANativeAdjustment() {
        var uniform = LayerUniform(position: .zero, size: .zero, sceneSize: SIMD2(1, 1), opacity: 1, particleShape: 0,
                                   rotation: 0, color: SIMD4(repeating: 1), uvOrigin: .zero, uvAxisX: SIMD2(1, 0),
                                   uvAxisY: SIMD2(0, 1), effects: SIMD4(0.8, 1, 1, 0), blur: 0,
                                   colorEffects: SIMD4(0, 1, 0, 0.7), transform: SIMD4(0, 0, 0, 1), transformScaleY: 1)
        XCTAssertTrue(ImageMaterialRenderer.nativeAdjustmentsAreIdentity(uniform, brightness: 0.8))
        XCTAssertFalse(ImageMaterialRenderer.nativeAdjustmentsAreIdentity(uniform, brightness: 1), "a material Brightness heuristic")
        uniform.effects.y = 1.2
        XCTAssertFalse(ImageMaterialRenderer.nativeAdjustmentsAreIdentity(uniform, brightness: 0.8), "a contrast heuristic")
    }

    /// WE presents the scene's colour only: a `normal` layer whose texture has α = 0.25 shows its
    /// full colour on screen, not a quarter of it over the drawable's clear colour.
    func testCompositeIgnoresTheSceneAlpha() throws {
        let plan = try XCTUnwrap(try builder.build(materialPath: "materials/normal.json", colorBlendMode: nil))
        let texture = try Self.solidTexture(device: device, color: [0, 200, 0, 64])
        let scene = try render { encoder, format in
            XCTAssertTrue(self.drawMaterial(plan, Layer(center: Self.sceneSize / 2, size: Self.sceneSize, rotation: 0),
                                            texture: texture, snapshot: nil, encoder: encoder, format: format))
        }
        let sceneTexture = try XCTUnwrap(lastTarget)
        XCTAssertEqual(Self.pixel(scene, x: 128, y: 64).alpha, 64 / 255, accuracy: 2 / 255)
        let library = try XCTUnwrap(SceneMetalLibrary.make(device: device))
        let layerDescriptor = MTLRenderPipelineDescriptor()
        layerDescriptor.vertexFunction = library.makeFunction(name: "sceneVertex")
        layerDescriptor.fragmentFunction = library.makeFunction(name: "sceneFragment")
        layerDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        layerDescriptor.colorAttachments[0].isBlendingEnabled = true
        layerDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        layerDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        let composite = try device.makeRenderPipelineState(descriptor: SceneComposite.pipelineDescriptor(basedOn: layerDescriptor))
        let target = SIMD2<Float>(Float(Self.targetSize.width), Float(Self.targetSize.height))
        let screen = try render(background: SIMD4(0, 0, 0, 1)) { encoder, _ in
            var uniform = LayerUniform(position: target / 2, size: target, sceneSize: target, opacity: 1, particleShape: 0,
                                       rotation: 0, color: SIMD4(repeating: 1), uvOrigin: .zero, uvAxisX: SIMD2(1, 0),
                                       uvAxisY: SIMD2(0, 1), effects: SIMD4(1, 1, 1, 0), blur: 0,
                                       colorEffects: SIMD4(0, 1, 0, 0.7), transform: SIMD4(0, 0, 0, 1), transformScaleY: 1)
            encoder.setRenderPipelineState(composite)
            encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
            encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
            encoder.setFragmentTexture(sceneTexture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        let center = Self.pixel(screen, x: 128, y: 64)
        XCTAssertEqual(center.green, 200 / 255, accuracy: 2 / 255)
        XCTAssertEqual(center.alpha, 1, accuracy: 1 / 255, "the drawable stays opaque")
    }

    /// WE repeats a layer image unless its `.tex` (ClampUVs) or the object (`clampuvs`) clamps it:
    /// genericimage's scroll wraps around instead of smearing the edge.
    func testScrollingImageWrapsUnlessClamped() throws {
        // Left half red, right half blue.
        let texture = try Self.texture(device: device, size: 4, pixels: (0..<16).flatMap { $0 % 4 < 2 ? [255, 0, 0, 255] : [0, 0, 255, 255] as [UInt8] })
        let frame = BuiltinFrameContext(time: 0.25)
        func rightEdge(_ material: String, clampUVs: Bool?) throws -> Float {
            let plan = try XCTUnwrap(try builder.build(materialPath: "materials/\(material).json", colorBlendMode: nil, clampUVs: clampUVs))
            let pixels = try render { encoder, format in
                XCTAssertTrue(self.drawMaterial(plan, Layer(rotation: 0), texture: texture, snapshot: nil,
                                                encoder: encoder, format: format, frame: frame))
            }
            // u = 0.9 of the quad (scene x 264, target column 132) samples u + 0.25 = 1.15.
            return Self.pixel(pixels, x: 132, y: 64).red
        }
        XCTAssertEqual(try rightEdge("scrollwrap", clampUVs: nil), 1, accuracy: 2 / 255, "wraps to the red left half")
        XCTAssertEqual(try rightEdge("scrollclamp", clampUVs: nil), 0, accuracy: 2 / 255, ".tex ClampUVs")
        XCTAssertEqual(try rightEdge("scrollwrap", clampUVs: true), 0, accuracy: 2 / 255, "object clampuvs")
    }

    func testTexFlagsAreReadFromTheHeader() {
        var bytes = Array("TEXV0005\0TEXI0001\0".utf8)
        bytes += [7, 0, 0, 0, 2, 0, 0, 0, 16, 0, 0, 0]
        XCTAssertEqual(TEXHeader.texiWord(1, in: Data(bytes)), 2)
        XCTAssertNil(TEXHeader.texiWord(1, in: Data("PNG".utf8)))
    }

    /// A solid layer's `flat` material has no image and no scene blend; a blend mode on it is
    /// reported rather than dropped quietly.
    func testBlendModeOnAFlatMaterialIsReported() throws {
        XCTAssertNil(try builder.build(materialPath: "materials/flat.json", colorBlendMode: 0))
        XCTAssertThrowsError(try builder.build(materialPath: "materials/flat.json", colorBlendMode: 2)) { error in
            guard case ImageMaterialPlanError.unsupported = error else { return XCTFail("\(error)") }
        }
    }

    func testStillLayerRewritesNoPlacementUniforms() throws {
        let plan = try XCTUnwrap(try builder.build(materialPath: "materials/image4.json", colorBlendMode: nil))
        let texture = try Self.checkerTexture(device: device)
        var built = 0
        let uniforms = ImageMaterialUniforms(layout: plan.pass.variant?.uniforms, constants: plan.pass.constants,
                                             liveFactors: plan.liveFactors)
        let key = ImageMaterialUniforms.PassKey(model: matrix_identity_float4x4, viewProjection: matrix_identity_float4x4,
                                                color: SIMD3(1, 1, 1), alpha: 1, brightness: 1, spriteRotation: SIMD4(1, 0, 0, 1),
                                                spriteTranslation: .zero, screen: SIMD2(256, 128),
                                                textures: [SIMD4(Float(texture.width), Float(texture.height), 0, 0)])
        for _ in 0..<3 {
            uniforms.update(key: key, frame: BuiltinFrameContext(), values: EffectGraphTests.FixedValues()) {
                built += 1
                return BuiltinPassContext(targetSize: SIMD2(256, 128))
            }
        }
        XCTAssertEqual(built, 1)
    }

    /// Risk I2: a layer's effects run on its image in texture space and the material draws their
    /// output, so a pass-through effect changes nothing: no transform, alpha or brightness applied
    /// twice, and no flip, for a rotated, scaled, half-transparent layer.
    func testPassThroughEffectLeavesTheMaterialDrawUnchanged() throws {
        let assets = ShaderVariantTests.weAssets
        let effects = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: cache.appending(path: "archives")))
        defer { effects.pipelineArchive?.flush() } // before tearDown deletes its directory
        let effectBuilder = SceneEffectPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { FileManager.default.contents(atPath: assets.appending(path: $0).path) },
            loadTexture: { _, _ in nil })
        let effect = try JSONDecoder().decode(WEObjectEffect.self, from: Data(
            #"{"file":"effects/tint/effect.json","passes":[{"constantshadervalues":{"color":"1 0 0","alpha":0}}]}"#.utf8))
        let effectPlan = try effectBuilder.build(effect)
        let texture = try Self.checkerTexture(device: device)
        XCTAssertTrue(effects.waitUntilReady([effectPlan], width: texture.width, height: texture.height))
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let context = EffectGraphRenderer.Context(frame: BuiltinFrameContext(), values: EffectGraphTests.FixedValues(),
                                                  assetTexture: { _, _ in nil }, sceneSnapshot: nil,
                                                  layerColor: SIMD3(0.9, 0.8, 1), layerAlpha: 0.5)
        let output = try XCTUnwrap(effects.apply([effectPlan], to: texture, layerID: "layer", context: context,
                                                 commandBuffer: commands))
        commands.commit()
        commands.waitUntilCompleted()

        let plan = try XCTUnwrap(try builder.build(materialPath: "materials/image4.json", colorBlendMode: nil))
        var layer = Layer(size: SIMD2(120, 80), rotation: .pi / 4, color: SIMD3(0.9, 0.8, 1), alpha: 0.5, brightness: 1.2)
        layer.center = SIMD2(250, 120)
        let plain = try render { encoder, format in
            XCTAssertTrue(self.drawMaterial(plan, layer, texture: texture, snapshot: nil, encoder: encoder, format: format))
        }
        let viaEffect = try render { encoder, format in
            XCTAssertTrue(self.drawMaterial(plan, layer, texture: output, snapshot: nil, encoder: encoder, format: format))
        }
        var differing = 0
        for index in stride(from: 0, to: plain.count, by: 4) {
            var delta = 0
            for channel in 0..<4 {
                let a = Int(plain[index + channel])
                let b = Int(viaEffect[index + channel])
                delta = max(delta, abs(a - b))
            }
            if delta > 2 { differing += 1 }
        }
        XCTAssertEqual(differing, 0, "\(differing) pixels differ with a pass-through effect")
    }

    /// Risk I16: a material whose shader can't be found fails loudly at load (the loader logs it
    /// once and draws the layer natively) instead of planning a blank layer.
    func testMissingShaderFailsLoudly() {
        XCTAssertThrowsError(try builder.build(materialPath: "materials/missingshader.json", colorBlendMode: nil))
    }

    /// WE's material pass loader sets `ALPHATOCOVERAGE` for a pass blending alpha-to-coverage
    /// (0x140154bc1), images as models; the pipeline takes coverage from alpha and doesn't blend.
    func testAlphaToCoverageBlendingSetsItsCombo() throws {
        let plan = try XCTUnwrap(try builder.build(materialPath: "materials/coverage.json", colorBlendMode: nil))
        XCTAssertEqual(plan.pass.variant?.combos["ALPHATOCOVERAGE"], 1)
        XCTAssertEqual(plan.pass.blending, "alphatocoverage")
        XCTAssertTrue(plan.pass.variant?.fragmentMSL.contains("fwidth") ?? false, "the shader's coverage sharpening")
        let normal = try XCTUnwrap(try builder.build(materialPath: "materials/depthcull.json", colorBlendMode: nil))
        XCTAssertEqual(normal.pass.variant?.combos["ALPHATOCOVERAGE"] ?? 0, 0)
        let texture = try Self.solidTexture(device: device, color: [255, 0, 0, 255])
        let pixels = try render { encoder, format in
            XCTAssertTrue(self.renderer.waitUntilReady(plan, pixelFormat: format), "the alpha-to-coverage pipeline compiles")
            XCTAssertTrue(self.renderer.draw(plan, ImageMaterialRenderer.Draw(
                layerID: "coverage", quad: SceneQuadGeometry(center: SIMD2(200, 128), axisX: SIMD2(160, 0), axisY: SIMD2(0, 96)),
                sceneSize: Self.sceneSize, color: SIMD3(1, 1, 1), alpha: 1, brightness: 1,
                texture: texture, contentSize: nil, uvOrigin: .zero, uvAxisX: SIMD2(1, 0), uvAxisY: SIMD2(0, 1),
                sceneSnapshot: nil, frame: BuiltinFrameContext(), values: EffectGraphTests.FixedValues(),
                assetTexture: { _, _ in nil }), pixelFormat: format, encoder: encoder, commandBuffer: currentCommands!))
        }
        XCTAssertEqual(Self.pixel(pixels, x: 100, y: 64).red, 1, accuracy: 2 / 255, "an opaque texel is covered")
    }

    /// Risk I23: depth and cull state in a material (including WE's own `culling` spelling) never
    /// makes an invalid pipeline for the depth-less scene pass, and a mirrored layer stays visible.
    func testDepthAndCullStateKeepMirroredLayersVisible() throws {
        let plan = try XCTUnwrap(try builder.build(materialPath: "materials/depthcull.json", colorBlendMode: nil))
        let texture = try Self.solidTexture(device: device, color: [255, 0, 0, 255])
        for mirror in [SIMD2<Float>(-1, 1), SIMD2(1, -1), SIMD2(-1, -1)] {
            let pixels = try render { encoder, format in
                XCTAssertTrue(self.renderer.waitUntilReady(plan, pixelFormat: format), "pipeline for \(mirror)")
                let quad = SceneQuadGeometry(center: SIMD2(200, 128), axisX: SIMD2(160 * mirror.x, 0),
                                             axisY: SIMD2(0, 96 * mirror.y))
                XCTAssertTrue(self.renderer.draw(plan, ImageMaterialRenderer.Draw(
                    layerID: "mirrored", quad: quad, sceneSize: Self.sceneSize, color: SIMD3(1, 1, 1), alpha: 1, brightness: 1,
                    texture: texture, contentSize: nil, uvOrigin: .zero, uvAxisX: SIMD2(1, 0), uvAxisY: SIMD2(0, 1),
                    sceneSnapshot: nil, frame: BuiltinFrameContext(), values: EffectGraphTests.FixedValues(),
                    assetTexture: { _, _ in nil }), pixelFormat: format, encoder: encoder, commandBuffer: currentCommands!))
            }
            XCTAssertEqual(Self.pixel(pixels, x: 100, y: 64).red, 1, accuracy: 2 / 255, "mirrored \(mirror) is drawn")
        }
    }

    /// Risk #14: script clones share their source's plan but each has its own uniform state,
    /// and removing them frees it all.
    func testRemovedClonesFreeTheirUniformState() throws {
        let plan = try XCTUnwrap(try builder.build(materialPath: "materials/image4.json", colorBlendMode: nil))
        let texture = try Self.checkerTexture(device: device)
        let ids = (0..<100).map { "clone\($0)" }
        _ = try render { encoder, format in
            XCTAssertTrue(self.renderer.waitUntilReady(plan, pixelFormat: format))
            for (index, id) in ids.enumerated() {
                let layer = Layer(center: SIMD2(Float(index), 128), rotation: 0)
                XCTAssertTrue(self.renderer.draw(plan, ImageMaterialRenderer.Draw(
                    layerID: id, quad: layer.quad, sceneSize: Self.sceneSize, color: layer.color, alpha: 1, brightness: 1,
                    texture: texture, contentSize: nil, uvOrigin: .zero, uvAxisX: SIMD2(1, 0), uvAxisY: SIMD2(0, 1),
                    sceneSnapshot: nil, frame: BuiltinFrameContext(), values: EffectGraphTests.FixedValues(),
                    assetTexture: { _, _ in nil }), pixelFormat: format, encoder: encoder, commandBuffer: currentCommands!))
            }
        }
        XCTAssertEqual(renderer.programCount, 100)
        XCTAssertEqual(renderer.pipelineCount, 1, "one pipeline for every layer on the same material (risk I11)")
        for id in ids { renderer.releaseLayer(id) }
        XCTAssertEqual(renderer.programCount, 0)
    }

    /// Risk I11: uniform blocks over 4 KB come from the renderer's arena, not a buffer per draw,
    /// and draw exactly what inline uniforms draw.
    func testLargeUniformBlocksComeFromTheArena() throws {
        let plan = try XCTUnwrap(try builder.build(materialPath: "materials/image4.json", colorBlendMode: nil))
        let texture = try Self.checkerTexture(device: device)
        var layer = Layer(size: SIMD2(120, 80), rotation: .pi / 5, color: SIMD3(0.9, 0.8, 1), alpha: 0.5, brightness: 1.2)
        layer.center = SIMD2(250, 120)
        let inline = try render { encoder, format in
            XCTAssertTrue(self.drawMaterial(plan, layer, texture: texture, snapshot: nil, encoder: encoder, format: format))
        }
        XCTAssertEqual(renderer.uniformArena.chunksCreated, 0)
        renderer.uniformArena.inlineLimit = 0
        for _ in 0..<50 {
            let viaArena = try render { encoder, format in
                XCTAssertTrue(self.drawMaterial(plan, layer, texture: texture, snapshot: nil, encoder: encoder, format: format))
            }
            XCTAssertEqual(viaArena, inline)
        }
        XCTAssertEqual(renderer.uniformArena.chunksCreated, 1, "one chunk serves every frame")
    }

    /// Risk I18: text drawn through WE's `font` material (`basefont.json`) tints its coverage with
    /// `g_Color4` once: red text at alpha 0.5 over white is (1, 0.5, 0.5) inside the glyphs, an edge
    /// at half coverage is lighter, not darker, and both match the native draw of the same text.
    func testTextFontMaterialTintsItsCoverageOnce() throws {
        let plan = try XCTUnwrap(try builder.buildText(materialPath: "materials/fonts/basefont.json"))
        XCTAssertEqual(plan.pass.textures.count, 1)
        guard case .current? = plan.pass.textures[0] else { return XCTFail("g_Texture0 is not the text") }
        // Left half full coverage, right half half coverage.
        let size = 16
        let coverage = (0..<size * size).map { UInt8($0 % size < size / 2 ? 255 : 128) }
        let mask = try Self.coverageTexture(device: device, size: size, coverage: coverage)
        let straight = try Self.texture(device: device, size: size, pixels: coverage.flatMap { [255, 255, 255, $0] })
        let layer = Layer(size: SIMD2(160, 96), rotation: 0, color: SIMD3(1, 0, 0), alpha: 0.5)
        let white = SIMD4<Float>(1, 1, 1, 1)
        let viaMaterial = try render(background: white) { encoder, format in
            XCTAssertTrue(self.drawMaterial(plan, layer, texture: mask, snapshot: nil, encoder: encoder, format: format))
        }
        let native = try render(background: white) { encoder, format in
            try self.drawNative(layer, texture: straight, additive: false, encoder: encoder, format: format)
        }
        // The layer covers x 60...140 of the 256-wide target (scene 512 wide), y 40...88.
        let inside = Self.pixel(viaMaterial, x: 80, y: 64), edge = Self.pixel(viaMaterial, x: 120, y: 64)
        XCTAssertEqual(inside.red, 1, accuracy: 2 / 255)
        XCTAssertEqual(inside.green, 0.5, accuracy: 2 / 255)
        XCTAssertEqual(inside.blue, 0.5, accuracy: 2 / 255)
        XCTAssertEqual(edge.green, 0.75, accuracy: 3 / 255, "half coverage at half alpha")
        for (x, y) in [(80, 64), (120, 64), (30, 64)] {
            let a = Self.pixel(viaMaterial, x: x, y: y), b = Self.pixel(native, x: x, y: y)
            XCTAssertEqual(a.red, b.red, accuracy: 3 / 255, "(\(x), \(y))")
            XCTAssertEqual(a.green, b.green, accuracy: 3 / 255, "(\(x), \(y))")
            XCTAssertEqual(a.blue, b.blue, accuracy: 3 / 255, "(\(x), \(y))")
        }
    }

    // MARK: - Helpers

    struct Layer {
        var center = SIMD2<Float>(200, 128)
        var size = SIMD2<Float>(160, 96)
        var rotation: Float
        var color = SIMD3<Float>(1, 1, 1)
        var alpha: Float = 1
        var brightness: Float = 1
        var uvOrigin = SIMD2<Float>(0, 0)
        var uvAxisX = SIMD2<Float>(1, 0)
        var uvAxisY = SIMD2<Float>(0, 1)
        var contentSize: SIMD2<Float>? = nil

        var quad: SceneQuadGeometry {
            let rotation = simd_float2x2(columns: (SIMD2(cos(self.rotation), sin(self.rotation)),
                                                  SIMD2(-sin(self.rotation), cos(self.rotation))))
            return SceneQuadGeometry(center: center, axisX: rotation * SIMD2(size.x, 0), axisY: rotation * SIMD2(0, size.y))
        }
    }

    private func assertMatchesNative(_ material: String, _ layer: Layer, additive: Bool = false,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let plan = try XCTUnwrap(try builder.build(materialPath: "materials/\(material).json", colorBlendMode: nil))
        let texture = try Self.checkerTexture(device: device)
        let expected = try render { encoder, format in
            try self.drawNative(layer, texture: texture, additive: additive, encoder: encoder, format: format)
        }
        let actual = try render { encoder, format in
            XCTAssertTrue(self.drawMaterial(plan, layer, texture: texture, snapshot: nil, encoder: encoder, format: format),
                          file: file, line: line)
        }
        // Edge pixels may round differently (the two draws compute the corners with different
        // matrices); everything inside must agree.
        var differing = 0
        var worst = 0
        for index in stride(from: 0, to: expected.count, by: 4) {
            let channels = additive ? 0..<3 : 0..<4
            let delta = channels.map { abs(Int(expected[index + $0]) - Int(actual[index + $0])) }.max() ?? 0
            if delta > 2 { differing += 1; worst = max(worst, delta) }
        }
        let pixels = expected.count / 4
        XCTAssertLessThan(Double(differing) / Double(pixels), 0.005,
                          "\(material): \(differing) of \(pixels) pixels differ (worst \(worst))", file: file, line: line)
    }

    private func drawMaterial(_ plan: ImageMaterialPlan, _ layer: Layer, texture: MTLTexture, snapshot: MTLTexture?,
                              encoder: MTLRenderCommandEncoder, format: MTLPixelFormat,
                              frame: BuiltinFrameContext = BuiltinFrameContext()) -> Bool {
        guard renderer.waitUntilReady(plan, pixelFormat: format) else { return false }
        return renderer.draw(plan, ImageMaterialRenderer.Draw(
            layerID: "layer", quad: layer.quad, sceneSize: Self.sceneSize, color: layer.color, alpha: layer.alpha, brightness: layer.brightness,
            texture: texture, contentSize: layer.contentSize, uvOrigin: layer.uvOrigin, uvAxisX: layer.uvAxisX,
            uvAxisY: layer.uvAxisY, sceneSnapshot: snapshot, frame: frame, values: EffectGraphTests.FixedValues(),
            assetTexture: { _, _ in nil }), pixelFormat: format, encoder: encoder, commandBuffer: currentCommands!)
    }

    /// `SceneMetalRenderer`'s layer draw: `sceneVertex`/`sceneFragment`, translucent or additive.
    private func drawNative(_ layer: Layer, texture: MTLTexture, additive: Bool,
                            encoder: MTLRenderCommandEncoder, format: MTLPixelFormat) throws {
        let library = try XCTUnwrap(SceneMetalLibrary.make(device: device))
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "sceneVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "sceneFragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = format
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.sourceAlphaBlendFactor = additive ? .one : .sourceAlpha
        attachment.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let target = SIMD2<Float>(Float(Self.targetSize.width), Float(Self.targetSize.height))
        let scale = target / Self.sceneSize
        let quad = layer.quad
        var uniform = LayerUniform(position: quad.center * scale, size: quad.extent * scale, sceneSize: target,
                                   opacity: layer.alpha, particleShape: 0, rotation: 0,
                                   color: SIMD4(layer.color, 1), uvOrigin: layer.uvOrigin, uvAxisX: layer.uvAxisX,
                                   uvAxisY: layer.uvAxisY, effects: SIMD4(layer.brightness, 1, 1, 0), blur: 0,
                                   colorEffects: SIMD4(0, 1, 0, 0.7), transform: SIMD4(0, 0, 0, 1), transformScaleY: 1)
        uniform.quadAxisX = quad.axisX * scale
        uniform.quadAxisY = quad.axisY * scale
        XCTAssertTrue(ImageMaterialRenderer.nativeAdjustmentsAreIdentity(uniform, brightness: layer.brightness))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Clears a bgra8 target (the scene target's format) to `background`, runs `body` and reads it back as RGBA bytes.
    /// The target of the last `render`, for a pass that reads it.
    private var lastTarget: MTLTexture?
    /// The command buffer of the `render` running now.
    private var currentCommands: MTLCommandBuffer?

    private func render(background: SIMD4<Float> = ImageMaterialRenderTests.background,
                        _ body: (MTLRenderCommandEncoder, MTLPixelFormat) throws -> Void) throws -> [UInt8] {
        let format = MTLPixelFormat.bgra8Unorm
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: Self.targetSize.width,
                                                                  height: Self.targetSize.height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        lastTarget = target
        let b = background
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(b.x), green: Double(b.y), blue: Double(b.z), alpha: Double(b.w))
        pass.colorAttachments[0].storeAction = .store
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
        currentCommands = buffer
        defer { currentCommands = nil }
        try body(encoder, format)
        encoder.endEncoding()
        let bytesPerRow = Self.targetSize.width * 4
        let readback = try XCTUnwrap(device.makeBuffer(length: bytesPerRow * Self.targetSize.height, options: .storageModeShared))
        let blit = try XCTUnwrap(buffer.makeBlitCommandEncoder())
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: Self.targetSize.width, height: Self.targetSize.height, depth: 1),
                  to: readback, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: bytesPerRow * Self.targetSize.height)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        var bytes = [UInt8](UnsafeBufferPointer(start: readback.contents().assumingMemoryBound(to: UInt8.self),
                                                count: readback.length))
        for index in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(index, index + 2) } // BGRA → RGBA
        return bytes
    }

    static func pixel(_ bytes: [UInt8], x: Int, y: Int) -> (red: Float, green: Float, blue: Float, alpha: Float) {
        let index = (y * targetSize.width + x) * 4
        return (Float(bytes[index]) / 255, Float(bytes[index + 1]) / 255, Float(bytes[index + 2]) / 255, Float(bytes[index + 3]) / 255)
    }

    /// 64×64 RGBA with four colours per row, a gradient down the rows and an alpha ramp, so any
    /// flip, crop or frame offset shows.
    static func checkerTexture(device: MTLDevice) throws -> MTLTexture {
        let size = 64
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let even = (x / 8 + y / 8) % 2 == 0
                pixels[i] = even ? 230 : UInt8(x * 4)
                pixels[i + 1] = UInt8(y * 4)
                pixels[i + 2] = even ? 40 : 200
                pixels[i + 3] = x < 16 ? 128 : 255
            }
        }
        return try texture(device: device, size: size, pixels: pixels)
    }

    static func coverageTexture(device: MTLDevice, size: Int, coverage: [UInt8]) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: coverage, bytesPerRow: size)
        return texture
    }

    static func solidTexture(device: MTLDevice, color: [UInt8]) throws -> MTLTexture {
        try texture(device: device, size: 4, pixels: Array([[UInt8]](repeating: color, count: 16).joined()))
    }

    static func texture(device: MTLDevice, size: Int, pixels: [UInt8]) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: pixels, bytesPerRow: size * 4)
        return texture
    }
}

private extension SIMD4 where Scalar == Float {
    var bytes: [UInt8] { [x, y, z, w].map { UInt8(($0 * 255).rounded()) } }
}
