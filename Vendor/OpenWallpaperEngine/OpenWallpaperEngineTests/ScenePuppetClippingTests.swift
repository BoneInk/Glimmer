import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// Puppet Warp clipping masks (docs/models-plan.md §2.13a): the `MDLV` 23 records WE 2.8.0.42's
/// editor writes (capture 532 and 532c, `Tests/Fixtures/Models/PuppetGroundTruth532`; we-test-wp-images,
/// tools/peer/requests/owe-beta7/models-open), WE's plan of the draws, and hand-built rigs drawn
/// through the bundled `genericimage4`, which reads the coverage, and `genericimage2`, which doesn't.
final class ScenePuppetClippingTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var builder: ImageMaterialPlanBuilder!
    private var renderer: ScenePuppetRenderer!
    private var cache: URL!
    /// The mask textures the rigs' masks name, by name.
    private var maskTextures: [String: MTLTexture] = [:]

    private static func model(_ name: String) throws -> MDLModel {
        try MDLReader.read(try Fixtures.data("Models/PuppetGroundTruth532/\(name).mdl"))
    }

    // MARK: - The editor's files

    /// "Assign Clipping Mask" on the blue limb with the mask painted over the red one (532
    /// g_mask): the size of the range block goes 0x20 → 0x30, the blue island's part of bone 0's
    /// range splits off (540 + 54 + 486 indices), and one group is the mask: id 30 (the JSON's),
    /// the texture, flags 0, the blue ranges clipped and the red one masking.
    func testTheEditorsMaskIsAGroupOverTheSplitRanges() throws {
        let locked = try Self.model("g_locked"), masked = try Self.model("g_mask")
        XCTAssertEqual(locked.meshes[0].groups ?? [], [])
        XCTAssertEqual(MDLClippingMask.masks(of: locked.meshes[0]), [])
        XCTAssertNil(ScenePuppetClipping(mesh: locked.meshes[0], boneCount: 2))
        XCTAssertEqual(locked.meshes[0].boneRanges(boneCount: 2)?.map(\.indexCount), [594, 486])

        let mesh = masked.meshes[0]
        XCTAssertEqual(mesh.boneRanges(boneCount: 2), [.init(bone: 0, firstIndex: 0, indexCount: 540),
                                                       .init(bone: 0, firstIndex: 540, indexCount: 54),
                                                       .init(bone: 1, firstIndex: 594, indexCount: 486)])
        XCTAssertEqual(MDLClippingMask.masks(of: mesh), [MDLClippingMask(
            id: 30, texture: "masks/clipping_mask_608392ae", flags: [], clippedRanges: [1, 2], maskRanges: [0], parent: nil)])
        XCTAssertEqual(MDLClippingMask.masks(of: try Self.model("c_mask_noclip").meshes[0]), [MDLClippingMask(
            id: 40, texture: "masks/clipping_mask_6efbf20d", flags: [], clippedRanges: [1], maskRanges: [0], parent: nil)])
    }

    /// The panel's checkboxes are the group's flags: "Hide mask geometry" 0x4, "Invert mask" 0xa.
    func testTheMaskSettingsAreTheGroupsFlags() throws {
        XCTAssertEqual(MDLClippingMask.masks(of: try Self.model("g_mask_hide").meshes[0]).first?.flags, [.hidesMaskGeometry])
        XCTAssertEqual(MDLClippingMask.masks(of: try Self.model("g_mask_invert").meshes[0]).first?.flags, [.invert, .drawsInPlace])
    }

    /// WE's frame of g_mask drew three `DrawIndexed(540)` (rd_draws_report): the red part, its
    /// coverage, and the blue parts through it. With "Hide mask geometry" (g_mask_hide) the red
    /// part draws only into the coverage: WE's stills lost the red limb.
    func testThePlanDrawsTheMaskingPartThenTheClippedOnes() throws {
        let clipping = try XCTUnwrap(ScenePuppetClipping(mesh: try Self.model("g_mask").meshes[0], boneCount: 2))
        let steps = clipping.steps(order: clipping.order(nil))
        XCTAssertEqual(steps, [.draw([0]), .clip(layers: [.init(mask: 0, ranges: [0])], clipped: [1, 2], additive: false)])
        let draws = steps.flatMap { step -> [ScenePuppetDrawOrder.Range] in
            switch step {
            case .draw(let ranges): clipping.drawRanges(ranges)
            case let .clip(layers, clipped, _): layers.flatMap { clipping.drawRanges($0.ranges) } + clipping.drawRanges(clipped)
            }
        }
        XCTAssertEqual(draws.map(\.indexCount), [540, 540, 540])

        let hidden = try XCTUnwrap(ScenePuppetClipping(mesh: try Self.model("g_mask_hide").meshes[0], boneCount: 2))
        XCTAssertEqual(hidden.steps(order: hidden.order(nil)),
                       [.clip(layers: [.init(mask: 0, ranges: [0])], clipped: [1, 2], additive: false)])
        XCTAssertEqual(hidden.visibleRanges(order: hidden.order(nil)), [.init(firstIndex: 540, indexCount: 540)])

        let inverted = try XCTUnwrap(ScenePuppetClipping(mesh: try Self.model("g_mask_invert").meshes[0], boneCount: 2))
        XCTAssertEqual(inverted.steps(order: inverted.order(nil)),
                       [.draw([0]), .clip(layers: [.init(mask: 0, ranges: [0])], clipped: [1, 2], additive: false)])
    }

    /// A pose's reordered ranges are taken apart into the parts they merged.
    func testTheOrderFollowsThePosesDrawRanges() throws {
        let clipping = try XCTUnwrap(ScenePuppetClipping(mesh: try Self.model("g_mask").meshes[0], boneCount: 2))
        XCTAssertEqual(clipping.order(nil), [0, 1, 2])
        XCTAssertEqual(clipping.order([.init(firstIndex: 540, indexCount: 540), .init(firstIndex: 0, indexCount: 540)]), [1, 2, 0])
        // Blue first: the mask's last masking part comes after them, and so does their draw.
        XCTAssertEqual(clipping.steps(order: [1, 2, 0]),
                       [.draw([0]), .clip(layers: [.init(mask: 0, ranges: [0])], clipped: [1, 2], additive: false)])
    }

    /// Nesting (0x140262032): a mask whose masking ranges are all clipped by another nests in it;
    /// one that would close a loop doesn't.
    func testMasksNestInTheMaskThatClipsTheirMaskingParts() {
        func group(_ id: UInt64, clipped: [UInt32], masking: [UInt32]) -> MDLMesh.Group {
            MDLMesh.Group(id: id, name: "masks/m\(id)", flags: 0, listA: clipped, listB: masking)
        }
        var mesh = ScenePuppetTests.mesh(format: 0x1800009, flags: 0)
        mesh.groups = [group(1, clipped: [1], masking: [0]), group(2, clipped: [2], masking: [1])]
        XCTAssertEqual(MDLClippingMask.masks(of: mesh).map(\.parent), [nil, 0])
        mesh.groups = [group(1, clipped: [1], masking: [0]), group(2, clipped: [0], masking: [1])]
        XCTAssertEqual(MDLClippingMask.masks(of: mesh).map(\.parent), [1, nil], "A → B → A: the second is left out")
    }

    // MARK: - Drawing

    /// The docs' setup: a limb (blue) clipped by a mask painted over another (red). Moved half over
    /// the red one, blue shows only there; where it leaves the red, it's invisible.
    func testAClippedLimbShowsOnlyOverThePaintedLimb() throws {
        let pixels = try drawTwoLimbs(flags: [])
        assertRow(pixels, width: 16, [red, red, red, red, blue, blue, blue, blue, clear, clear, clear, clear, clear, clear, clear, clear])
    }

    /// "Invert mask": blue shows everywhere but over the painted limb.
    func testAnInvertedMaskShowsTheLimbOnlyAwayFromThePaintedLimb() throws {
        for flags: MDLClippingMask.Flags in [[.invert], [.invert, .drawsInPlace]] {
            let pixels = try drawTwoLimbs(flags: flags)
            assertRow(pixels, width: 16, [red, red, red, red, red, red, red, red, blue, blue, blue, blue, clear, clear, clear, clear],
                      "flags \(flags.rawValue)")
        }
    }

    /// "Hide mask geometry": the red limb isn't drawn, only through the mask (WE 2.8's g_mask_hide).
    func testHiddenMaskGeometryDrawsOnlyIntoTheMask() throws {
        let pixels = try drawTwoLimbs(flags: [.hidesMaskGeometry])
        assertRow(pixels, width: 16, [clear, clear, clear, clear, blue, blue, blue, blue, clear, clear, clear, clear, clear, clear, clear, clear])
    }

    /// "Additive blending": the clipped limb adds to what's under it.
    func testAnAdditiveClippedLimbAddsToThePaintedLimb() throws {
        let pixels = try drawTwoLimbs(flags: [.additive])
        let magenta: [UInt8] = [255, 0, 255, 255]
        assertRow(pixels, width: 16, [red, red, red, red, magenta, magenta, magenta, magenta, clear, clear, clear, clear, clear, clear, clear, clear])
    }

    /// `genericimage2` has no `CLIPPINGTARGET`: the limb draws unclipped, as in WE 2.8's captures of
    /// the editor's default puppet material. "Hide mask geometry" still hides the red limb.
    func testAShaderWithoutClippingDrawsTheLimbWhole() throws {
        let shown = try drawTwoLimbs(flags: [], material: "image2version")
        assertRow(shown, width: 16, [red, red, red, red, blue, blue, blue, blue, blue, blue, blue, blue, clear, clear, clear, clear])
        let hidden = try drawTwoLimbs(flags: [.hidesMaskGeometry], material: "image2version")
        assertRow(hidden, width: 16, [clear, clear, clear, clear, blue, blue, blue, blue, blue, blue, blue, blue, clear, clear, clear, clear])
    }

    /// Nested masks: green clipped by red's mask, blue by green's. Blue shows only where green and
    /// red both are; green's part away from red is hidden, so blue is too.
    func testANestedMaskShowsItsLimbOnlyOverBothLimbs() throws {
        // Texture: red, green, blue thirds of 24 × 8.
        var bytes = [UInt8](repeating: 0, count: 24 * 8 * 4)
        for y in 0..<8 {
            for x in 0..<24 { bytes.replaceSubrange((y * 24 + x) * 4..<(y * 24 + x) * 4 + 4, with: [red, green, blue][x / 8]) }
        }
        // Typed quads: Xcode 26.3 infers the untyped thirds as [Any].
        let quads: [(position: SIMD4<Float>, uv: SIMD4<Float>)] = [
            (SIMD4<Float>(-12, 4, -4, -4), SIMD4<Float>(0, 0, 1 / 3, 1)),
            (SIMD4<Float>(-4, 4, 4, -4), SIMD4<Float>(1 / 3, 0, 2 / 3, 1)),
            (SIMD4<Float>(4, 4, 12, -4), SIMD4<Float>(2 / 3, 0, 1, 1)),
        ]
        var mesh = ScenePuppetTests.mesh(quads: quads, bones: [0, 1, 2])
        mesh.vector4Block = Self.ranges([(0, 0, 6), (1, 6, 6), (2, 12, 6)])
        mesh.groups = [MDLMesh.Group(id: 1, name: "masks/red", flags: 0, listA: [1], listB: [0]),
                       MDLMesh.Group(id: 2, name: "masks/green", flags: 0, listA: [2], listB: [1])]
        maskTextures["masks/red"] = try maskTexture(width: 24, height: 8) { $0 < 8 }
        maskTextures["masks/green"] = try maskTexture(width: 24, height: 8) { $0 >= 8 && $0 < 16 }
        let plan = try plan(mesh, bones: 3, size: SIMD2(24, 8))
        var pose = ScenePuppetPose.bind(boneCount: 3)
        pose.bones[1] = ScenePuppetTests.translation(SIMD3(-4, 0, 0))
        pose.bones[2] = ScenePuppetTests.translation(SIMD3(-12, 0, 0))
        let pixels = try draw(plan, source: ScenePuppetTests.Picture(width: 24, height: 8, pixels: bytes), pose: pose)
        assertRow(pixels, width: 24, [red, red, red, red, blue, blue, blue, blue, clear, clear, clear, clear]
                  + Array(repeating: clear, count: 12))
        XCTAssertEqual(renderer.clippingMaskPasses("puppet"), 2)
    }

    // MARK: - Helpers

    private let red: [UInt8] = [255, 0, 0, 255], green: [UInt8] = [0, 255, 0, 255], blue: [UInt8] = [0, 0, 255, 255]
    private let clear: [UInt8] = [0, 0, 0, 0]

    override func setUpWithError() throws {
        let assets = ShaderVariantTests.weAssets
        try XCTSkipUnless(FileManager.default.fileExists(atPath: assets.appending(path: "shaders/clippingmaskimage4.frag").path),
                          "bundled WE shaders missing")
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-puppet-clip-\(UUID().uuidString)")
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
            loadTexture: { name, _ in
                // The masks' textures; the test hands the drawn ones over by key.
                name.hasPrefix("masks/") ? .dxt(TEXCompressedTexture(format: 0, width: 1, height: 1, data: [], contentWidth: 1,
                                                                    contentHeight: 1)) : nil
            })
        renderer = try XCTUnwrap(ScenePuppetRenderer(device: device, archive: nil))
    }

    override func tearDownWithError() throws {
        if let cache { try? FileManager.default.removeItem(at: cache) } // scratch cleanup
    }

    /// `(bone, firstIndex, indexCount)` records as the file keeps them.
    private static func ranges(_ records: [(UInt32, UInt32, UInt32)]) -> [SIMD4<Float>] {
        records.map { SIMD4(Float(bitPattern: $0.0), Float(bitPattern: 0), Float(bitPattern: $0.1), Float(bitPattern: $0.2)) }
    }

    /// Red left, blue right of a 16 × 8 image; blue (bone 1) clipped by a mask painted over red and
    /// moved 4 px left, so its left half lies over red.
    private func drawTwoLimbs(flags: MDLClippingMask.Flags, material: String = "image4") throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16 * 8 * 4)
        for y in 0..<8 {
            for x in 0..<16 { bytes.replaceSubrange((y * 16 + x) * 4..<(y * 16 + x) * 4 + 4, with: x < 8 ? red : blue) }
        }
        var mesh = ScenePuppetTests.mesh(quads: [(SIMD4(-8, 4, 0, -4), SIMD4(0, 0, 0.5, 1)),
                                                 (SIMD4(0, 4, 8, -4), SIMD4(0.5, 0, 1, 1))], bones: [0, 1])
        mesh.vector4Block = Self.ranges([(0, 0, 6), (1, 6, 6)])
        mesh.groups = [MDLMesh.Group(id: 30, name: "masks/red", flags: flags.rawValue, listA: [1], listB: [0])]
        maskTextures["masks/red"] = try maskTexture(width: 16, height: 8) { $0 < 8 }
        let plan = try plan(mesh, bones: 2, size: SIMD2(16, 8), material: material)
        XCTAssertNotNil(plan.clipping)
        XCTAssertEqual(plan.clipping?.mask != nil, material == "image4", "only genericimage4 reads the coverage")
        var pose = ScenePuppetPose.bind(boneCount: 2)
        pose.bones[1] = ScenePuppetTests.translation(SIMD3(-4, 0, 0))
        return try draw(plan, source: ScenePuppetTests.Picture(width: 16, height: 8, pixels: bytes), pose: pose)
    }

    /// A single-channel mask, 255 in the columns `painted` picks.
    private func maskTexture(width: Int, height: Int, painted: (Int) -> Bool) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let bytes = (0..<height).flatMap { _ in (0..<width).map { painted($0) ? UInt8(255) : 0 } }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width)
        return texture
    }

    private func plan(_ mesh: MDLMesh, bones: Int, size: SIMD2<Float>, material: String = "image4") throws -> ScenePuppetPlan {
        let source = SceneMetalTextureSource.dxt(TEXCompressedTexture(format: 0, width: Int(size.x), height: Int(size.y),
                                                                      data: [], contentWidth: Int(size.x), contentHeight: Int(size.y)))
        return try ScenePuppetPlan.make(model: ScenePuppetTests.model(mesh, bones: bones), rigPath: "rig.mdl",
                                        materialPath: "materials/\(material).json", source: source, imageSize: size,
                                        builder: builder)
    }

    private func draw(_ plan: ScenePuppetPlan, source: ScenePuppetTests.Picture, pose: ScenePuppetPose) throws -> [UInt8] {
        XCTAssertTrue(renderer.waitUntilReady(plan), "the pipelines compile")
        let texture = try ScenePuppetTests.texture(source, device: device)
        let masks = maskTextures
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let target = try XCTUnwrap(renderer.albedo(plan, ScenePuppetRenderer.Draw(
            layerID: "puppet", source: texture, pose: pose, frame: BuiltinFrameContext(), values: EmptySceneValues(),
            assetTexture: { key, _ in masks.first { key.hasSuffix("|\($0.key)") }?.value }), commandBuffer: commands))
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertTrue(renderer.hasDrawn("puppet"))
        return try ScenePuppetTestSupport.rgba8(target, device: device)
    }

    /// The middle row's texels are `expected`, within 2 per channel (colour only where opaque).
    private func assertRow(_ pixels: [UInt8], width: Int, _ expected: [[UInt8]], _ message: String = "",
                           file: StaticString = #filePath, line: UInt = #line) {
        let row = pixels.count / (4 * width) / 2
        for (x, texel) in expected.enumerated() {
            let at = (row * width + x) * 4
            let actual = Array(pixels[at..<at + 4])
            let alphaOK = abs(Int(actual[3]) - Int(texel[3])) <= 2
            let colourOK = texel[3] == 0 || zip(actual.prefix(3), texel.prefix(3)).allSatisfy { abs(Int($0) - Int($1)) <= 2 }
            XCTAssertTrue(alphaOK && colourOK, "texel \(x): \(actual), expected \(texel) \(message)", file: file, line: line)
        }
    }
}
