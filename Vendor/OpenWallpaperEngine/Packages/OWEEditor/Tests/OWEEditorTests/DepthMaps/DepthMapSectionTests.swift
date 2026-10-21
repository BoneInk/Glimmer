import CoreGraphics
import XCTest
@testable import OWEEditor
@testable import OWESceneEditing

/// The depth map section as both editors run it, with a fake model and pictures: Generate keeps
/// the depth map with the editor's files; the scene's Apply adds WE's effect bound to it through
/// the overlay, a new generation rebinds it, Strength and Remove change the overlay, each one undo
/// step; a layer's Create Mask from Depth Map writes it as an effect's mask; and the picture each
/// kind of layer is generated from.
@MainActor
final class DepthMapSectionTests: XCTestCase {
    private static let scene = Data("""
    {
      "general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
      "objects": [
        {"id": 1, "name": "Background", "image": "models/bg.json", "origin": "960 540 0", "size": "1920 1080"},
        {"id": 2, "name": "Title", "text": {"value": "Hello"}, "pointsize": 40, "origin": "300 200 0", "parent": 1},
        {"id": 3, "name": "Snow", "particle": "particles/snow.json", "origin": "960 540 0"},
        {"id": 4, "name": "Logo", "image": "models/logo.json", "origin": "1700 900 0", "size": "200 100"},
        {"id": 5, "name": "Speaker", "sound": ["sounds/a.mp3"]},
        {"id": 6, "name": "Photo", "image": "models/photo.json", "origin": "960 540 0", "size": "200 100",
         "effects": [
           {"file": "effects/shake/effect.json"},
           {"file": "effects/tint/effect.json", "passes": [{"textures": [null, "masks/tint_mask_painted"]}]},
           {"file": "effects/scroll/effect.json"}
         ]},
        {"id": 7, "name": "Faded", "image": "models/faded.json", "origin": "960 540 0", "size": "200 100",
         "effects": [
           {"file": "effects/opacity/effect.json", "passes": [{"textures": [null, "masks/opacity_mask_painted"]}]},
           {"file": "effects/tint/effect.json"}
         ]}
      ]
    }
    """.utf8)

    private var directory: URL!
    private var session: SceneEditSession!
    private var scheduler: ManualIdleScheduler!
    private var requests: [DepthMapSourceRequest] = []
    private var prepared = 0
    private var prepareFails = false
    private var preparedEffects: [String] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "owe-depthmap-section-\(UUID().uuidString)",
                                                                    directoryHint: .isDirectory)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        session = SceneEditSession(outline: try SceneOutline(sceneData: Self.scene), undoManager: undoManager)
        scheduler = ManualIdleScheduler()
        requests = []
        prepared = 0
        prepareFails = false
        preparedEffects = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory) // Scratch: a leftover is harmless.
    }

    private struct PrepareFailure: LocalizedError {
        var errorDescription: String? { "WE's assets are missing" }
    }

    private func services(installed: Bool = true) -> DepthMapEditorServices {
        let generator = DepthMapGenerator(locateModel: { installed ? DepthMapTestSupport.model() : nil },
                                          loadModel: { try FakeModelLoader().load($0) }, cache: nil,
                                          scheduler: scheduler, log: { _ in })
        return DepthMapEditorServices(
            generator: generator, assetStore: EditorAssetStore(directory: directory),
            source: { [unowned self] request in
                self.requests.append(request)
                let isScene: Bool
                if case .scene = request.target { isScene = true } else { isScene = false }
                // Each request draws a little wider, as an edited layer would: a new depth map each time.
                return DepthMapSource(image: DepthMapTestSupport.edge(width: 62 + 2 * self.requests.count, height: 32),
                                      isOneFrame: isScene)
            },
            prepareEffect: { [unowned self] in
                if self.prepareFails { throw PrepareFailure() }
                self.prepared += 1
            },
            texture: { _ in nil },
            openPlugins: {},
            effectSchema: { file in Self.schemas[file] },
            prepareBuiltInEffect: { [unowned self] entry in
                if self.prepareFails { throw PrepareFailure() }
                self.preparedEffects.append(entry.file)
            },
            // A stand-in for the app's `.tex` writer: the size, then the grey values.
            encodeMask: { pixels, width, height in Data([UInt8(width), UInt8(height)] + pixels) })
    }

    /// WE's samplers for the effects on "Photo": Shake's flow mask and two grey masks, Tint's one,
    /// Scroll none; and WE's Opacity effect's one (`effects/opacity`'s `g_Texture1`).
    private static let schemas: [String: EffectSchema] = [
        "effects/shake/effect.json": EffectSchema(textures: [
            .init(slot: 1, title: "Direction", defaultTexture: "util/noflow", isMask: true, mode: "flowmask"),
            .init(slot: 2, title: "Time Offset", defaultTexture: "util/black", isMask: true, combo: "TIMEOFFSET", mode: "opacitymask"),
            .init(slot: 3, title: "Opacity", isMask: true, combo: "MASK", mode: "opacitymask"),
        ]),
        "effects/tint/effect.json": EffectSchema(textures: [
            .init(slot: 1, title: "Opacity Mask", isMask: true, combo: "MASK", paintDefault: [0, 0, 0, 1], mode: "opacitymask"),
        ]),
        "effects/scroll/effect.json": EffectSchema(),
        "effects/opacity/effect.json": EffectSchema(textures: [
            .init(slot: 1, title: "Opacity Mask", isMask: true, combo: "MASK", paintDefault: [0, 0, 0, 1], mode: "opacitymask",
                  materialName: "opacity"),
        ]),
    ]

    // MARK: A layer

    func testALayerGeneratesButNoLongerAppliesDepthParallax() async throws {
        let model = DepthMapSectionModel(session: session, layerID: 4, services: services())
        XCTAssertEqual(model.title, DL("Create Mask from Depth Map"))
        XCTAssertFalse(model.isApplied)
        await model.generate()
        XCTAssertNil(model.problem)
        let texture = try XCTUnwrap(model.generatedTexture)
        XCTAssertTrue(texture.hasPrefix("depth/editor_logo-"))
        XCTAssertNotNil(EditorAssetStore(directory: directory).depthMapURL(texture), "kept with the editor's files")
        XCTAssertNotNil(model.depthPreview)
        XCTAssertNotNil(model.maskPreview, "a layer previews the mask")
        XCTAssertFalse(model.isOneFrame, "a still image's own texture")
        XCTAssertFalse(session.overlay.hasSceneEdits, "generating alone changes nothing")

        model.apply()
        XCTAssertEqual(prepared, 0)
        XCTAssertFalse(model.isApplied, "depth parallax is the scene's")
        XCTAssertFalse(session.overlay.hasSceneEdits)
    }

    func testDepthParallaxAppliedToALayerBeforeFollowsANewMapAndCanBeRemoved() async throws {
        await DepthMapSectionModel(session: session, layerID: 4, services: services()).generate()
        _ = session.applyDepthParallax(texture: "depth/editor_old-000000000000", strength: 0.7, to: 4, actionName: "Apply")
        let model = DepthMapSectionModel(session: session, layerID: 4, services: services())
        XCTAssertTrue(model.isApplied)
        model.strength = 1.4
        XCTAssertEqual(try XCTUnwrap(session.depthParallaxStrength(of: 4)), 1.4, accuracy: 1e-9)
        await model.generate()
        let second = try XCTUnwrap(model.generatedTexture)
        XCTAssertEqual(session.depthParallaxTexture(of: 4), second, "a new generation rebinds it")
        model.remove()
        XCTAssertNil(session.depthParallaxEffect(of: 4))
        session.undo()
        XCTAssertEqual(session.depthParallaxTexture(of: 4), second, "Remove is one undo step")
    }

    func testAMissingEffectIsAProblemAndChangesNothing() async throws {
        prepareFails = true
        let model = DepthMapSectionModel(session: session, layerID: nil, services: services())
        await model.generate()
        model.apply()
        XCTAssertEqual(model.problem, "WE's assets are missing")
        XCTAssertFalse(session.overlay.hasSceneEdits)
    }

    func testAParticleSystemHasNoMaskSection() {
        XCTAssertFalse(DepthMapSectionModel(session: session, layerID: 3, services: services()).isSupported,
                       "it carries no effects; the scene's depth parallax covers it")
    }

    // MARK: Create Mask from Depth Map

    func testTheMenuListsTheLayersGreyMasks() async throws {
        let model = DepthMapSectionModel(session: session, layerID: 6, services: services())
        let targets = model.maskTargets
        XCTAssertEqual(targets.map(\.id), ["opacity:0:1", "0:0:2", "0:0:3", "1:0:1"],
                       "Layer Opacity first, then grey masks only: not Shake's flow mask, nothing of Scroll")
        XCTAssertEqual(targets.map(\.title), [DL("Layer Opacity"), "Shake › Time Offset", "Shake › Opacity", "Tint"])
        XCTAssertEqual(targets.map(\.addsEffect), [true, false, false, false], "the layer has no Opacity effect")
        XCTAssertEqual(targets.map(\.replacesMask), [false, false, false, true], "Tint has a painted mask")
        XCTAssertEqual(targets[3].currentMask, "masks/tint_mask_painted")
        XCTAssertEqual(DepthMapSectionModel(session: session, layerID: 4, services: services()).maskTargets.map(\.id), ["opacity:0:1"],
                       "a layer without effects: Layer Opacity only")
    }

    // MARK: Layer Opacity

    func testLayerOpacityAddsWEsOpacityEffectWithTheMaskInOneUndoStep() async throws {
        let model = DepthMapSectionModel(session: session, layerID: 4, services: services())
        await model.generate()
        let target = try XCTUnwrap(model.maskTargets.first)
        XCTAssertTrue(target.isLayerOpacity && target.addsEffect)
        model.useAsMask(target)
        XCTAssertNil(model.problem)
        XCTAssertEqual(preparedEffects, [DepthMask.opacityEffect.file], "its files are copied as adding it from the browser does")
        let effect = try XCTUnwrap(session.outline.layer(4)?.effects.last)
        XCTAssertEqual(effect.file, "effects/opacity/effect.json")
        let path = try XCTUnwrap(session.effectTexture(1, effect: effect.key, of: 4))
        XCTAssertTrue(path.hasPrefix("masks/opacity_mask_"), "WE's name for the Opacity effect's mask: \(path)")
        XCTAssertEqual(session.effectCombo("MASK", effect: effect.key, of: 4, default: 0), 1, "the mask's combo goes on")
        let pixels = Array(try Data(contentsOf: XCTUnwrap(EditorAssetStore(directory: directory).url(for: "materials/\(path).tex"))).dropFirst(2))
        XCTAssertLessThan(pixels[50 * 200 + 2], 60, "far fades")
        XCTAssertGreaterThan(pixels[50 * 200 + 197], 200, "near shows")
        XCTAssertEqual(model.maskNotice, DL("The depth map is now the layer’s opacity, through the Opacity effect added to it."))
        let after = model.maskTargets
        XCTAssertEqual(after.first?.effectKey, effect.key, "Layer Opacity is now the added effect's mask")
        XCTAssertEqual(after.first?.replacesMask, true)
        XCTAssertEqual(after.first?.addsEffect, false)

        session.undo()
        XCTAssertEqual(session.outline.layer(4)?.effects.count, 0, "one undo step: the effect and its mask")
        XCTAssertFalse(session.overlay.hasSceneEdits)
        session.redo()
        XCTAssertEqual(session.effectTexture(1, effect: effect.key, of: 4), path)
    }

    func testLayerOpacityFillsAnExistingOpacityEffectsMask() async throws {
        let model = DepthMapSectionModel(session: session, layerID: 7, services: services())
        await model.generate()
        let targets = model.maskTargets
        XCTAssertEqual(targets.map(\.id), ["0:0:1", "1:0:1"])
        XCTAssertEqual(targets.map(\.title), [DL("Layer Opacity"), "Tint"])
        let opacity = targets[0]
        XCTAssertTrue(opacity.isLayerOpacity)
        XCTAssertFalse(opacity.addsEffect)
        XCTAssertEqual(opacity.currentMask, "masks/opacity_mask_painted", "listed under Replaces the current mask")

        model.maskInverted = true
        model.maskContrast = 4
        model.useAsMask(opacity)
        XCTAssertEqual(preparedEffects, [], "nothing to add")
        XCTAssertEqual(session.outline.layer(7)?.effects.count, 2)
        let path = try XCTUnwrap(session.effectTexture(1, effect: "0", of: 7))
        XCTAssertTrue(path.hasPrefix("masks/opacity_mask_"))
        XCTAssertNotEqual(path, "masks/opacity_mask_painted")
        let pixels = Array(try Data(contentsOf: XCTUnwrap(EditorAssetStore(directory: directory).url(for: "materials/\(path).tex"))).dropFirst(2))
        XCTAssertEqual(pixels[50 * 200 + 2], 255, "inverted: far shows; contrast 4 makes it white")
        XCTAssertEqual(pixels[50 * 200 + 197], 0, "and near fades to transparent")
        XCTAssertEqual(model.maskNotice, DL("The effect’s mask was replaced. Undo brings the old one back; its file is kept."))
        session.undo()
        XCTAssertEqual(session.effectTexture(1, effect: "0", of: 7), "masks/opacity_mask_painted", "one undo step")
    }

    func testLayerOpacityWithoutWEsAssetsIsAProblemAndChangesNothing() async throws {
        let model = DepthMapSectionModel(session: session, layerID: 4, services: services())
        await model.generate()
        prepareFails = true
        model.useAsMask(try XCTUnwrap(model.maskTargets.first))
        XCTAssertNotNil(model.problem)
        XCTAssertEqual(session.outline.layer(4)?.effects.count, 0)
        XCTAssertFalse(session.overlay.hasSceneEdits)
    }

    func testUseAsMaskWritesTheShapedDepthMapIntoTheEffectsSlot() async throws {
        let model = DepthMapSectionModel(session: session, layerID: 6, services: services())
        await model.generate()
        let target = try XCTUnwrap(model.maskTargets.first { $0.id == "0:0:3" })
        model.maskContrast = 2
        model.useAsMask(target)
        XCTAssertNil(model.problem)
        let path = try XCTUnwrap(session.effectTexture(3, effect: "0", of: 6))
        XCTAssertTrue(path.hasPrefix("masks/shake_mask_"), "WE's name for an effect's mask: \(path)")
        XCTAssertEqual(session.effectCombo("MASK", effect: "0", of: 6, default: 0), 1, "the slot's combo goes on")
        let file = try XCTUnwrap(EditorAssetStore(directory: directory).url(for: "materials/\(path).tex"))
        let tex = [UInt8](try Data(contentsOf: file))
        XCTAssertEqual(Array(tex.prefix(2)), [200, 100], "the layer's size (200 × 100)")
        let pixels = Array(tex.dropFirst(2))
        XCTAssertEqual(pixels.count, 200 * 100)
        // The fake depth map is an edge: far on the left, near on the right; contrast 2 hardens it.
        XCTAssertLessThanOrEqual(pixels[50 * 200 + 2], 5)
        XCTAssertGreaterThanOrEqual(pixels[50 * 200 + 197], 250)
        XCTAssertEqual(model.maskNotice, DL("The depth map is now the effect’s mask."))

        // Inverted, into Tint's mask: replaced, undoable, and the mask it replaced is kept.
        model.maskInverted = true
        model.maskContrast = 1
        let tint = try XCTUnwrap(model.maskTargets.first { $0.id == "1:0:1" })
        XCTAssertTrue(tint.replacesMask)
        model.useAsMask(tint)
        let inverted = try XCTUnwrap(session.effectTexture(1, effect: "1", of: 6))
        XCTAssertTrue(inverted.hasPrefix("masks/tint_mask_"))
        XCTAssertNotEqual(inverted, "masks/tint_mask_painted")
        let invertedPixels = Array(try Data(contentsOf: XCTUnwrap(EditorAssetStore(directory: directory)
            .url(for: "materials/\(inverted).tex"))).dropFirst(2))
        XCTAssertGreaterThan(invertedPixels[50 * 200 + 2], 200, "far is white once inverted")
        XCTAssertLessThan(invertedPixels[50 * 200 + 197], 55)
        XCTAssertEqual(model.maskNotice, DL("The effect’s mask was replaced. Undo brings the old one back; its file is kept."))
        session.undo()
        XCTAssertEqual(session.effectTexture(1, effect: "1", of: 6), "masks/tint_mask_painted", "one undo step")
        XCTAssertEqual(session.effectTexture(3, effect: "0", of: 6), path)
        XCTAssertNotNil(EditorAssetStore(directory: directory).url(for: "materials/\(inverted).tex"),
                        "files are named by content and never deleted, so Redo finds it")
        session.redo()
        XCTAssertEqual(session.effectTexture(1, effect: "1", of: 6), inverted)
    }

    func testWithoutADepthMapThereIsNoMask() {
        let model = DepthMapSectionModel(session: session, layerID: 6, services: services())
        model.useAsMask(model.maskTargets[0])
        XCTAssertFalse(session.overlay.hasSceneEdits)
    }

    func testTheWholeScene() async throws {
        let model = DepthMapSectionModel(session: session, layerID: nil, services: services())
        await model.generate()
        model.apply()
        let top = try XCTUnwrap(session.depthParallaxLayer(above: nil))
        XCTAssertEqual(session.outline.layers.last?.id, top)
        XCTAssertEqual(session.outline.layer(top)?.name, DL("Scene Depth Parallax"))
        guard case .scene(upTo: nil)? = requests.last?.target else { return XCTFail("the scene as drawn") }
        XCTAssertNil(requests.last?.drawnLayers)
        session.undo()
        XCTAssertNil(session.depthParallaxLayer(above: nil))
    }

    func testASoundLayerCantHaveIt() {
        let model = DepthMapSectionModel(session: session, layerID: 5, services: services())
        XCTAssertFalse(model.isSupported)
    }

    func testWithoutThePluginNothingRuns() async {
        let model = DepthMapSectionModel(session: session, layerID: 4, services: services(installed: false))
        XCTAssertFalse(model.services.generator.isInstalled)
        await model.generate()
        XCTAssertNotNil(model.problem)
        XCTAssertNil(model.generatedTexture)
    }

    // MARK: What each layer is generated from

    func testRequestsByKindOfLayer() throws {
        let picture = session.depthMapRequest(for: 4)
        XCTAssertEqual(picture.target, .layer(4))
        XCTAssertEqual(picture.pictureModel, "models/logo.json", "a still picture may serve as it is")
        let rect = try XCTUnwrap(picture.sceneRect)
        XCTAssertEqual(rect.minX, 1600, accuracy: 1e-6)
        XCTAssertEqual(rect.minY, 850, accuracy: 1e-6)
        XCTAssertEqual(rect.width, 200, accuracy: 1e-6)
        XCTAssertEqual(rect.height, 100, accuracy: 1e-6)
        XCTAssertEqual(picture.drawnLayers, [4])
        XCTAssertEqual(picture.sceneSize, SIMD2(1920, 1080))

        let text = session.depthMapRequest(for: 2)
        XCTAssertEqual(text.target, .layer(2))
        XCTAssertNil(text.pictureModel)
        XCTAssertEqual(text.drawnLayers, [2, 1], "drawn with its parent")
        XCTAssertNotNil(text.sceneRect)

        let particles = session.depthMapRequest(for: 3)
        XCTAssertEqual(particles.target, .scene(upTo: 3))
        XCTAssertEqual(particles.drawnLayers, [1, 2, 3], "the scene drawn so far")
        XCTAssertNil(particles.sceneRect)

        let composition = session.addLayer(SceneLayerFactory.composition(name: "Comp", size: SIMD2(400, 400), origin: SIMD2(960, 540)),
                                           actionName: "Add")
        let order = session.outline.layers.map(\.id)
        let below = Set(order.prefix(through: try XCTUnwrap(order.firstIndex(of: composition))))
        XCTAssertEqual(session.depthMapRequest(for: composition).drawnLayers, below, "what it shows: the scene under it")

        let scene = session.depthMapRequest(for: nil)
        XCTAssertEqual(scene.target, .scene(upTo: nil))
        XCTAssertNil(scene.drawnLayers)
        XCTAssertEqual(Set(scene.allLayers), Set(session.outline.layers.map(\.id)))
    }
}
