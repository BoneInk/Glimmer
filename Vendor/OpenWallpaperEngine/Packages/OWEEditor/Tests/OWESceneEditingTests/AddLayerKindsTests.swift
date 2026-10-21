import XCTest
import simd
@testable import OWESceneEditing

/// The layers of WE's Add Asset dialog beyond images, text and sounds (models, lights, cameras,
/// the Full Composition Layer, the Solid Placeholder) as scene.json objects WE's scenes have,
/// and the presets that add them.
@MainActor
final class AddLayerKindsTests: XCTestCase {
    private func session() throws -> SceneEditSession {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData), undoManager: undoManager)
    }

    private func appliedObjects(_ session: SceneEditSession) throws -> [[String: Any]] {
        let data = try session.overlay.applied(to: Fixtures.sceneData)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["objects"] as? [[String: Any]])
    }

    // MARK: Objects

    func testANewLightIsWEsNewLight() {
        let flat = SceneLayerFactory.light(name: "Light", is2D: true, centre: SIMD3(960, 540, 0))
        XCTAssertEqual(flat["light"]?.stringValue, "lpoint")
        XCTAssertEqual(flat["radius"]?.doubleValue, 500)
        XCTAssertEqual(flat["intensity"]?.doubleValue, 10)
        XCTAssertEqual(flat["origin"]?.stringValue, "960 540 250", "the view's centre at z 250")
        let deep = SceneLayerFactory.light(name: "Light", kind: .spot, is2D: false, centre: SIMD3(1, 2, 3))
        XCTAssertEqual(deep["light"]?.stringValue, "lspot")
        XCTAssertEqual(deep["radius"]?.doubleValue, 5)
        XCTAssertEqual(deep["intensity"]?.doubleValue, 5)
        XCTAssertEqual(deep["origin"]?.stringValue, "1 2 3")
        XCTAssertEqual(SceneLayerFactory.LightKind.allCases.map(\.rawValue), ["lpoint", "lspot", "ltube", "ldirectional"])
    }

    func testANewCameraLooksWhereTheScenesCameraLooks() {
        let straight = SceneLayerFactory.camera(name: "Camera", eye: .zero, centre: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0), fov: 50)
        XCTAssertEqual(straight["camera"]?.stringValue, "default")
        XCTAssertEqual(straight["angles"]?.stringValue, "0 0 0", "down −Z with +Y up is WE's unturned camera")
        XCTAssertEqual(straight["fov"]?.doubleValue, 50)
        XCTAssertEqual(straight["visible"], .bool(true), "WE plays a camera layer's paths only when it authors visible")
        // Looking along −X: a quarter turn about Y.
        let turned = SceneLayerFactory.lookAtAngles(eye: .zero, centre: SIMD3(-1, 0, 0), up: SIMD3(0, 1, 0))
        XCTAssertEqual(turned.x, 0, accuracy: 1e-9)
        XCTAssertEqual(turned.y, Double.pi / 2, accuracy: 1e-9)
        XCTAssertEqual(turned.z, 0, accuracy: 1e-9)
        // The angles' −row 2 (WE's R = Rz·Ry·Rx) is the direction looked along.
        let eye = SIMD3(-0.17083, 1.75878, 3.83613), centre = SIMD3(-0.14421, 1.68254, 2.83940)
        let angles = SceneLayerFactory.lookAtAngles(eye: eye, centre: centre, up: SIMD3(0, 1, 0))
        let (cx, sx, cy, sy, cz, sz) = (cos(angles.x), sin(angles.x), cos(angles.y), sin(angles.y), cos(angles.z), sin(angles.z))
        let row2 = SIMD3(cx * sy * cz + sx * sz, cx * sy * sz - sx * cz, cx * cy)
        let expected: SIMD3<Double> = simd_normalize(centre - eye)
        XCTAssertEqual(simd_length(-row2 - expected), 0, accuracy: 1e-9)
    }

    func testTheFullCompositionAndSolidPlaceholderAreWEsObjects() {
        let project = SceneLayerFactory.fullComposition(name: "Full Composition Layer", size: SIMD2(1920, 1080), origin: SIMD2(960, 540))
        XCTAssertEqual(project["image"]?.stringValue, "models/util/projectlayer.json")
        XCTAssertEqual(project["size"]?.stringValue, "1920 1080")
        XCTAssertEqual(project["parallaxDepth"]?.stringValue, "0 0")
        let placeholder = SceneLayerFactory.solidPlaceholder(name: "Solid Placeholder", model: "models/solid_instance_model_1.json",
                                                             color: SIMD3(1, 1, 1), size: SIMD2(256, 256), origin: SIMD2(960, 540))
        XCTAssertEqual(placeholder["image"]?.stringValue, "models/solid_instance_model_1.json")
        XCTAssertEqual(placeholder["instance"]?["textures"], .array([.string("util/white")]))
        XCTAssertEqual(placeholder["instance"]?["combos"]?["version"]?.doubleValue, 2)
        XCTAssertEqual(SceneLayerFactory.solidPlaceholderModel["instanced"] as? Bool, true)
        XCTAssertEqual(SceneLayerFactory.solidPlaceholderModel["material"] as? String, "materials/util/solidlayer_instance_4.json")
        let model = SceneLayerFactory.model(name: "Tree", model: "models/tree/tree.mdl", origin: SIMD3(1, 2, 3))
        XCTAssertEqual(model["model"]?.stringValue, "models/tree/tree.mdl")
        XCTAssertEqual(model["origin"]?.stringValue, "1 2 3")
    }

    func testAddedLightsModelsAndCamerasAreTheirKindsInTheOutline() throws {
        let session = try session()
        let light = session.addLayer(SceneLayerFactory.light(name: "Light", is2D: true, centre: .zero), actionName: "Add Light")
        let model = session.addLayer(SceneLayerFactory.model(name: "Tree", model: "models/tree/tree.mdl", origin: .zero),
                                     actionName: "Add Model")
        let camera = session.addLayer(SceneLayerFactory.camera(name: "Camera", eye: .zero, centre: SIMD3(0, 0, -1),
                                                               up: SIMD3(0, 1, 0), fov: 50), actionName: "Add Camera")
        XCTAssertEqual(session.outline.layer(light)?.kind, .light)
        XCTAssertEqual(session.outline.layer(model)?.kind, .model)
        XCTAssertNotNil(session.outline.layer(camera))
        let objects = try appliedObjects(session)
        XCTAssertEqual(objects.last?["camera"] as? String, "default")
    }

    // MARK: Several at once

    func testAddLayersIsOneUndoStepSelectingTheFirst() throws {
        let session = try session()
        let before = session.outline.layers.count
        let ids = session.addLayers([SceneLayerFactory.group(name: "A", origin: .zero), SceneLayerFactory.group(name: "B", origin: .zero)],
                                    actionName: "Add Preset")
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[1], ids[0] + 1)
        XCTAssertEqual(session.selection, ids[0])
        XCTAssertEqual(session.outline.layers.count, before + 2)
        XCTAssertEqual(Array(session.outline.layers.suffix(2).map(\.id)), ids, "in order, on top")
        session.undo()
        XCTAssertEqual(session.outline.layers.count, before)
    }

    // MARK: Presets

    /// WE's presets folder: a particle preset, the clock (text variants) and light shafts (a
    /// shape with a built-in effect, and a particle variant).
    private func presetsFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "AddLayerKindsTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        func write(_ folder: String, _ json: String) throws {
            let url = root.appending(path: folder)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: url.appending(path: "preset.json"))
        }
        try write("rain", #"{"name": "Rain", "variants": [{"objects": [{"particle": "particles/rain.json"}]}]}"#)
        try write("clock", #"""
        {"name": "ui_clock", "tag": "scene2d", "options": {"droplistOptions": [{"label": "ui_clock_a", "value": 0}, {"label": "ui_clock_b", "value": 1}]},
         "variants": [{"objects": [{"name": "Clock", "text": {"value": "12:34"}, "origin": "960 540 0"}]},
                      {"objects": [{"name": "3D Clock", "text": {"value": "12:34"}, "perspective": true}]}]}
        """#)
        try write("lightshafts", #"""
        {"name": "Light Shafts", "tag": "scene2d",
         "variants": [{"objects": [{"name": "Corner", "shape": "quad", "effects": [{"file": "effects/lightshafts/effect.json"}]}],
                       "dependencies": [{"file": "effects/lightshafts/effect.json"}]},
                      {"objects": [{"particle": "particles/presets/dust.json"}], "dependencies": ["particles/presets/dust.json"]},]}
        """#)
        return root
    }

    func testPresetsSplitIntoParticleOnesAndLayerOnes() throws {
        let root = try presetsFolder()
        let translate: (String) -> String? = { ["ui_clock": "Clock", "ui_clock_a": "Clock", "ui_clock_b": "3D Clock"][$0] }
        let particles = ParticlePresetCatalog.load(presetsDirectory: root, translate: translate)
        XCTAssertEqual(particles.map(\.id), ["lightshafts", "rain"])
        XCTAssertEqual(particles.first?.variants.map(\.id), [1], "the shape variant isn't a particle one")
        let layers = ParticlePresetCatalog.load(presetsDirectory: root, contents: .layers, translate: translate)
        XCTAssertEqual(layers.map(\.id), ["clock", "lightshafts"])
        XCTAssertEqual(layers.first?.variants.map(\.title), ["Clock", "3D Clock"])
        let shafts = try XCTUnwrap(layers.last?.variants.first)
        XCTAssertEqual(shafts.effects, ["effects/lightshafts/effect.json"])
        XCTAssertTrue(shafts.dependencies.isEmpty, "an effect dependency isn't a file of the preset")
        XCTAssertFalse(shafts.addsParticlesOnly)
    }
}
