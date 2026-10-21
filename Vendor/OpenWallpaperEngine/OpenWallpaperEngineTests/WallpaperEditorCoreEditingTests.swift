import CoreGraphics
import ImageIO
import MetalKit
import UniformTypeIdentifiers
import XCTest
import OWESceneEditing
@testable import OpenWallpaperEngine

/// The Wallpaper Editor's phase 2–3 edits in the app: layers it adds draw, effect parameters it
/// sets reach the renderer (through a fresh read and live, without one), and its imported files
/// are found where the scene names them.
@MainActor
final class WallpaperEditorCoreEditingTests: XCTestCase {
    private static let sceneJSON = """
    {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
     "general": {"orthogonalprojection": {"width": 480, "height": 272}, "clearcolor": "0 0 0"}, "objects": []}
    """

    /// A local wallpaper with an empty 480 × 272 scene, and its identity's overlay files removed after.
    private func makeWallpaper() throws -> (directory: URL, identity: WallpaperSettingsIdentity) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-editor-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"file": "scene.json", "type": "scene", "title": "Editor \#(UUID().uuidString)"}"#.utf8)
            .write(to: directory.appending(path: "project.json"))
        try Data(Self.sceneJSON.utf8).write(to: directory.appending(path: "scene.json"))
        let identity = WallpaperSettingsIdentity.resolve(directory: directory)
        addTeardownBlock {
            let store = SceneEditOverlayFiles.defaultStore
            try? store.remove(identity.rawValue)
            try? FileManager.default.removeItem(at: store.assetsDirectory(for: identity.rawValue))
            try? FileManager.default.removeItem(at: directory)
            Fixtures.removeStoredSettings(for: directory)
        }
        return (directory, identity)
    }

    private func session(for directory: URL, overlay: SceneEditOverlay = SceneEditOverlay()) throws -> SceneEditSession {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return SceneEditSession(outline: try SceneOutline(sceneData: Data(contentsOf: directory.appending(path: "scene.json"))),
                                overlay: overlay, undoManager: undoManager)
    }

    private func png(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat, at url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    // MARK: The overlay where the scene loads

    func testAddedLayersAndEffectsReachTheParsedScene() throws {
        let (directory, _) = try makeWallpaper()
        let session = try session(for: directory)
        let image = session.addLayer(SceneLayerFactory.image(name: "Logo", model: "models/editor/logo-1.json",
                                                             size: SIMD2(64, 64), origin: SIMD2(100, 100)), actionName: "Add")
        let text = session.addLayer(SceneLayerFactory.text(name: "Clock", value: "12:34", font: "systemfont_arial", pointSize: 40,
                                                           origin: SIMD2(240, 136),
                                                           script: SceneLayerFactory.TextScript.clock.source,
                                                           scriptProperties: SceneLayerFactory.TextScript.clock.properties),
                                    actionName: "Add")
        let solid = session.addLayer(SceneLayerFactory.solid(name: "Fill", color: SIMD3(0, 0, 1), size: SIMD2(480, 272),
                                                             origin: SIMD2(240, 136)), actionName: "Add")
        let tint = EffectCatalogEntry(file: "effects/tint/effect.json", title: "Tint")
        let key = try XCTUnwrap(session.addEffect(tint, to: solid, actionName: "Add Effect"))
        session.setEffectConstant("color", to: .string("0 1 0"), effect: key, of: solid, actionName: "Change Color")
        session.setEffectConstant("alpha", to: .number(0.5), effect: key, of: solid, actionName: "Change Alpha")
        session.move([solid], relativeTo: image, above: false, actionName: "Reorder")

        let resolved = try ScenePreparation.resolvedScene(Data(Self.sceneJSON.utf8), edits: [:], overlay: session.overlay)
        let scene = try JSONDecoder().decode(WEScene.self, from: resolved)
        XCTAssertEqual(scene.objects.map(\.id), [solid, image, text].map(Optional.some), "added, in the order the editor gave them")
        XCTAssertEqual(scene.objects[1].image, "models/editor/logo-1.json")
        XCTAssertEqual(scene.objects[0].image, "models/util/solidlayer.json")
        let effect = try XCTUnwrap(scene.objects[0].effects?.first)
        XCTAssertEqual(effect.file, "effects/tint/effect.json")
        let pass = try XCTUnwrap(effect.passes?.first)
        XCTAssertEqual(pass.constantshadervalues?["color"]?.string, "0 1 0", "the effect parameter reaches the renderer's model")
        XCTAssertEqual(pass.constantshadervalues?["alpha"]?.number, 0.5)
        XCTAssertEqual(scene.objects[2].textValue, "12:34", "the text layer")
    }

    func testImportedFilesAreFoundWhereTheSceneNamesThem() throws {
        let (directory, identity) = try makeWallpaper()
        let source = directory.appending(path: "blue.png")
        try png(width: 8, height: 8, red: 0, green: 0, blue: 1, at: source)
        let imported = try SceneEditOverlayFiles.assets(for: identity).importImage(from: source)
        XCTAssertNotNil(SceneEditOverlayFiles.assetData(imported.model, for: identity))
        XCTAssertNotNil(SceneEditOverlayFiles.assetData("materials/\(imported.texture).png", for: identity))
        XCTAssertNil(SceneEditOverlayFiles.assetData("scene.json", for: identity), "only the editor's own folders")
    }

    func testTheSceneCacheKeyFollowsStructuralEdits() throws {
        let (directory, _) = try makeWallpaper()
        let session = try session(for: directory)
        let before = session.overlay.digest
        session.addLayer(SceneLayerFactory.fullscreen(name: "FX"), actionName: "Add")
        XCTAssertNotEqual(session.overlay.digest, before)
    }

    // MARK: Live

    func testLiveValuesMoveTheBuiltLayer() {
        var values = SceneEditLiveValues()
        var layer = SceneEditLiveValues.Layer()
        layer.origin = (SIMD3(100, 100, 0), SIMD3(130, 90, 0))
        layer.scale = (SIMD3(1, 1, 1), SIMD3(2, 2, 1))
        layer.angles = (SIMD3(0, 0, 0), SIMD3(0, 0, 0.5))
        layer.alpha = (1, 0.25)
        layer.color = (SIMD3(1, 1, 1), SIMD3(1, 0, 0))
        values.layers[7] = layer
        values.effects[7] = [2: SceneEditLiveValues.Effect(visible: nil, constants: ["color": [0, 1, 0]])]
        let live = SceneEditorLive(values, revision: 3)
        let local = live.local(SceneLocalTransform(origin: SIMD2(100, 100), scale: SIMD2(1.5, 1.5), angle: 0.1), id: "7")
        XCTAssertEqual(local.origin, SIMD2(130, 90))
        XCTAssertEqual(local.scale, SIMD2(3, 3), "scale by the ratio")
        XCTAssertEqual(local.angle, 0.6, accuracy: 1e-6)
        var base = SceneLayerBaseValues(position: .zero, scale: SIMD2(1, 1), rotation: 0)
        base.opacity = 0.8
        let moved = live.base(base, id: "7")
        XCTAssertEqual(moved.opacity, 0.2, accuracy: 1e-6)
        XCTAssertEqual(moved.color, SIMD4(1, 0, 0, 1))
        let effects = live.effects([], of: "7", scripted: (hidden: [], writes: [2: [SceneScriptConstantWrite(name: "alpha", value: [1])]],
                                                           revision: 1))
        XCTAssertEqual(effects.writes[2]?.map(\.name), ["color", "alpha"], "a script's writes still come last")
        XCTAssertNotEqual(effects.revision, 1, "the chain runs again")
        XCTAssertEqual(live.local(local, id: "8"), local, "other layers are as built")
    }

    /// Renders a solid layer with a Tint effect added in the editor, then changes the tint's colour
    /// live: the renderer draws the new colour without the scene being read again.
    func testAnAddedLayerRendersAndItsEffectFollowsTheEditorLive() throws {
        let assets = try Fixtures.assets()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: assets.appending(path: "effects/tint/materials/effects/tint.json").path),
                          "WE's Tint effect isn't in the assets")
        let (directory, identity) = try makeWallpaper()
        let session = try session(for: directory)
        let solid = session.addLayer(SceneLayerFactory.solid(name: "Fill", color: SIMD3(1, 1, 1), size: SIMD2(480, 272),
                                                             origin: SIMD2(240, 136)), actionName: "Add")
        let tint = EffectCatalogEntry(file: "effects/tint/effect.json", title: "Tint")
        // As the editor does before adding it: the effect's material and shaders go into the project.
        let project = try JSONDecoder().decode(WEProject.self, from: Data(contentsOf: directory.appending(path: "project.json")))
        try EditorWallpaperResources(wallpaper: WEWallpaper(using: project, where: directory), package: nil,
                                     assets: SceneEditOverlayFiles.assets(for: identity)).prepareEffect(tint)
        XCTAssertNotNil(SceneEditOverlayFiles.assetData("materials/effects/tint.json", for: identity))
        let key = try XCTUnwrap(session.addEffect(tint, to: solid, actionName: "Add Effect"))
        session.setEffectConstant("color", to: .string("0 0 1"), effect: key, of: solid, actionName: "Change Color")
        try SceneEditOverlayFiles.save(session.overlay, for: identity, wallpaperDirectory: directory)

        let harness = try SceneFrameHarness(directory: directory, size: SIMD2(480, 272))
        defer { harness.close() }
        // The effect's pipeline compiles off the render thread: the layer draws without it until then.
        var blue = SIMD3(255, 255, 255)
        for _ in 0..<60 where blue.x > 60 {
            harness.draw(frames: 5)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            blue = try XCTUnwrap(Self.pixel(harness, x: 240, y: 136))
        }
        XCTAssertGreaterThan(blue.z, 200, "the tint the editor set: \(blue)")
        XCTAssertLessThan(blue.x, 60)

        let built = try XCTUnwrap(harness.model.loadedEditOverlay)
        XCTAssertEqual(built, session.overlay, "the scene was read with the editor's overlay")
        session.setEffectConstant("color", to: .string("0 1 0"), effect: key, of: solid, actionName: "Change Color")
        let live = try XCTUnwrap(SceneEditLiveValues.make(built: built, current: session.overlay, base: session.baseOutline),
                                 "a constant is drawn live")
        harness.renderer.setEditorLiveValues(live)
        harness.draw(frames: 10)
        let green = try XCTUnwrap(Self.pixel(harness, x: 240, y: 136))
        XCTAssertGreaterThan(green.y, 200, "the live colour: \(green)")
        XCTAssertLessThan(green.z, 60)
    }

    /// An effect the Wallpaper Editor adds to a layer Scene Edit / Export saved as JSON (its JSON
    /// editor stores the whole authored object) draws in the editor's canvas: the replaced object
    /// is the base the draft's edits apply to, not a copy laid over them.
    func testAnEffectAddedToALayerSceneEditExportReplacedRendersInTheCanvas() throws {
        let assets = try Fixtures.assets()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: assets.appending(path: "effects/tint/materials/effects/tint.json").path),
                          "WE's Tint effect isn't in the assets")
        let (directory, identity) = try makeWallpaper()
        var solid = SceneLayerFactory.solid(name: "Fill", color: SIMD3(1, 1, 1), size: SIMD2(480, 272), origin: SIMD2(240, 136))
        solid["id"] = .number(1)
        let object = try XCTUnwrap(SceneJSONValue.object(solid).any as? [String: Any])
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.sceneJSON.utf8)) as? [String: Any])
        root["objects"] = [object]
        try JSONSerialization.data(withJSONObject: root).write(to: directory.appending(path: "scene.json"))
        // Scene Edit / Export's JSON editor saved the object as authored, with one field added.
        var replaced = object
        replaced["castshadow"] = false
        let replacedJSON = String(decoding: try JSONSerialization.data(withJSONObject: replaced), as: UTF8.self)
        let project = try JSONDecoder().decode(WEProject.self, from: Data(contentsOf: directory.appending(path: "project.json")))
        let wallpaper = WEWallpaper(using: project, where: directory)
        WallpaperPropertyTargets(wallpaper: wallpaper, scopes: [.shared]).save(["_owe_scene_object_1_json": replacedJSON])
        let draft = WallpaperEditorDraft(wallpaper: wallpaper)
        draft.startProperties(resuming: false)
        defer { try? draft.discard() } // Cleanup: the draft's overlay and properties.

        // The editor adds a blue Tint to the layer; the draft keeps it, as the window's edits.
        let session = try session(for: directory)
        let tint = EffectCatalogEntry(file: "effects/tint/effect.json", title: "Tint")
        try EditorWallpaperResources(wallpaper: wallpaper, package: nil, assets: SceneEditOverlayFiles.assets(for: identity))
            .prepareEffect(tint)
        let key = try XCTUnwrap(session.addEffect(tint, to: 1, actionName: "Add Effect"))
        session.setEffectConstant("color", to: .string("0 0 1"), effect: key, of: 1, actionName: "Change Color")
        try draft.saveOverlay(session.overlay)

        let harness = try SceneFrameHarness(directory: directory, scope: .editorDraft, size: SIMD2(480, 272))
        defer { harness.close() }
        XCTAssertEqual(harness.model.loadedEditOverlay, session.overlay, "the canvas reads the draft")
        // The effect's pipeline compiles off the render thread: the layer draws without it until then.
        var blue = SIMD3(255, 255, 255)
        for _ in 0..<60 where blue.x > 60 {
            harness.draw(frames: 5)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            blue = try XCTUnwrap(Self.pixel(harness, x: 240, y: 136))
        }
        XCTAssertGreaterThan(blue.z, 200, "the tint the editor added: \(blue)")
        XCTAssertLessThan(blue.x, 60)
    }

    /// An image imported in the editor and a text layer it added draw where the editor put them.
    func testAnImportedImageLayerAndATextLayerRender() throws {
        _ = try Fixtures.assets()
        let (directory, identity) = try makeWallpaper()
        let source = directory.appending(path: "red.png")
        try png(width: 64, height: 64, red: 1, green: 0, blue: 0, at: source)
        let imported = try SceneEditOverlayFiles.assets(for: identity).importImage(from: source)
        // The source sits beside the wallpaper only for the import.
        try FileManager.default.removeItem(at: source)
        let session = try session(for: directory)
        session.addLayer(SceneLayerFactory.image(name: "Red", model: imported.model, size: imported.size, origin: SIMD2(100, 100)),
                         actionName: "Add")
        session.addLayer(SceneLayerFactory.text(name: "Text", value: "HELLO", font: "systemfont_arial", pointSize: 48,
                                                origin: SIMD2(340, 200)), actionName: "Add")
        try SceneEditOverlayFiles.save(session.overlay, for: identity, wallpaperDirectory: directory)

        let harness = try SceneFrameHarness(directory: directory, size: SIMD2(480, 272))
        defer { harness.close() }
        harness.draw(frames: 20)
        // Scene y is up; the frame's row 0 is the top.
        let red = try XCTUnwrap(Self.pixel(harness, x: 100, y: 272 - 100))
        XCTAssertGreaterThan(red.x, 200, "the imported image: \(red)")
        XCTAssertLessThan(red.y, 60)
        let background = try XCTUnwrap(Self.pixel(harness, x: 20, y: 20))
        XCTAssertLessThan(max(background.x, background.y, background.z), 32, "nothing else drawn: \(background)")
        var lit = 0
        for y in (272 - 230)..<(272 - 170) {
            for x in 260..<420 {
                if let pixel = try Self.pixel(harness, x: x, y: y), pixel.x > 128 { lit += 1 }
            }
        }
        XCTAssertGreaterThan(lit, 100, "the text is drawn")
    }

    /// The drawable's pixel as RGB (row 0 at the top).
    private static func pixel(_ harness: SceneFrameHarness, x: Int, y: Int) throws -> SIMD3<Int>? {
        guard let texture = harness.view.currentDrawable?.texture, let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(), x >= 0, y >= 0, x < texture.width, y < texture.height,
              let buffer = device.makeBuffer(length: 4, options: .storageModeShared),
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
                  sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: 4, destinationBytesPerImage: 4)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
        // BGRA.
        return SIMD3(Int(bytes[2]), Int(bytes[1]), Int(bytes[0]))
    }
}
