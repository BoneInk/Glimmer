import XCTest
import simd
@testable import OpenWallpaperEngine

/// User property values for the spatial tests.
struct SpatialProperties: SceneValueContext {
    var values: [String: String] = [:]
    func userProperty(_ name: String) -> String? { values[name] }
}

/// scene.json's 3D fields (docs/models-plan.md M0): model objects, camera layers, both camera-path
/// formats, `orthogonalprojection` and `general`'s camera fields, with WE's defaults, against
/// fixtures from the library survey (`Tests/Fixtures/Spatial`).
final class SceneSpatialDecodeTests: XCTestCase {
    /// `[{"item", "object"}]`, each object decoded as a scene object.
    private func libraryObjects(_ file: String) throws -> [(item: String, object: WESceneObject)] {
        let failures = DecodeFailureLog()
        let entries = try decodeTolerant([LibraryEntry].self, from: Fixtures.data("Spatial/\(file)"), failures: failures)
        XCTAssertEqual(failures.messages, [], file)
        return entries.map { ($0.item, $0.object) }
    }

    private struct LibraryEntry: Decodable {
        var item: String
        var object: WESceneObject
    }

    private func object(_ json: String) throws -> WESceneObject {
        try decodeTolerant(WESceneObject.self, from: Data(json.utf8))
    }

    private func general(_ json: String) throws -> WESceneGeneral {
        try decodeTolerant(WESceneGeneral.self, from: Data(json.utf8))
    }

    // MARK: - Model objects

    func testLibraryModelObjectsKeepEveryField() throws {
        let objects = try libraryObjects("library-model-objects.json")
        XCTAssertEqual(objects.count, 5)
        XCTAssertTrue(objects.allSatisfy { $0.object.model != nil && $0.object.cameraLayer == nil })

        let dojyoObject = try XCTUnwrap(objects.first { $0.object.name == "dojyo" }?.object)
        let dojyo = try XCTUnwrap(dojyoObject.model)
        XCTAssertEqual(dojyo.source, .path("models/dojyo/dojyo.mdl"))
        XCTAssertEqual(dojyo.path, "models/dojyo/dojyo.mdl")
        XCTAssertNil(dojyo.attachment)
        XCTAssertEqual(dojyo.skin, 0)
        XCTAssertTrue(dojyo.rootMotion)
        XCTAssertEqual(dojyoObject.animationLayers.count, 2)
        let closed = dojyoObject.animationLayers[0]
        XCTAssertEqual(closed.animation, 272)
        XCTAssertEqual(closed.id, 322)
        XCTAssertEqual(closed.name, "Closed")
        XCTAssertEqual(closed.blend, 1)
        XCTAssertEqual(closed.rate, 1)
        XCTAssertEqual(closed.blendTime, 0.5)
        XCTAssertFalse(closed.additive)
        XCTAssertTrue(closed.visible)
        // `blend` animated by a timeline: its value and its keyframes are both kept.
        let open = dojyoObject.animationLayers[1]
        XCTAssertEqual(open.animation, 273)
        XCTAssertEqual(open.blend, 0)
        let timeline = try SceneTimelineDocument(json: XCTUnwrap(open.values[.blend]?.animation))
        XCTAssertEqual(timeline.channels.first?.map(\.frame), [0, 30, 35, 112, 116])
        XCTAssertEqual(timeline.options?.mode, .single)

        // A layer without `blendin`, `blendout` or `blendtime` gets WE's defaults.
        let sas = try XCTUnwrap(objects.first { $0.item == "3233200129" }?.object.animationLayers.first)
        XCTAssertEqual(sas.animation, 14)
        XCTAssertEqual(sas.rate, 1.27, accuracy: 1e-9)
        XCTAssertFalse(sas.blendIn)
        XCTAssertFalse(sas.blendOut)
        XCTAssertEqual(sas.blendTime, 0.5)

        let skybox = try XCTUnwrap(objects.first { $0.object.name == "BG_SKYB0X" }?.object)
        XCTAssertEqual(skybox.renderValues[.castshadow], .bool(false))
        XCTAssertEqual(skybox.dependencies, [.id(16)])
        XCTAssertEqual(skybox.solid, false)

        let lens = try XCTUnwrap(objects.first { $0.item == "3384390033" }?.object)
        XCTAssertEqual(lens.visibleUserProperty, "gravitational")
        XCTAssertEqual(lens.perspective, true)

        let dome = try XCTUnwrap(objects.first { $0.object.name == "Dome" }?.object)
        XCTAssertEqual(dome.renderValues[.reflected], .bool(true))
    }

    func testModelFieldsAndDefaults() throws {
        let model = try object("""
        {"id": 5, "model": "models/a.mdl", "skin": 2, "attachment": "правая рука", "rootmotion": false,
         "sortorder": 3, "castshadow": {"user": "shadows", "value": true}, "reflected": false,
         "animationlayers": [{"animation": 7, "additive": true, "blendin": true, "blendout": true, "rate": 2,
                              "blend": 0.5, "blendtime": 1, "visible": false, "autosort": true, "index": 1},
                             {"animation": "7"}, {"name": "no clip"}, 3]}
        """)
        let authored = try XCTUnwrap(model.model)
        XCTAssertEqual(authored.skin, 2)
        XCTAssertEqual(authored.attachment, "правая рука")
        XCTAssertFalse(authored.rootMotion)
        XCTAssertEqual(model.renderValues[.sortorder]?.literalInt, 3)
        XCTAssertEqual(model.renderValues[.castshadow]?.userPropertyName, "shadows")
        XCTAssertEqual(model.renderValues[.reflected]?.literalBool, false)
        // The non-object entry is skipped; a non-numeric or missing `animation` makes no clip id.
        XCTAssertEqual(model.animationLayers.count, 3)
        let layer = model.animationLayers[0]
        XCTAssertEqual(layer.animation, 7)
        XCTAssertEqual(layer.autosort, true)
        XCTAssertEqual(layer.index, 1)
        XCTAssertTrue(layer.additive && layer.blendIn && layer.blendOut)
        XCTAssertFalse(layer.visible)
        XCTAssertEqual([layer.rate, layer.blend, layer.blendTime], [2, 0.5, 1])
        XCTAssertNil(model.animationLayers[1].animation)
        XCTAssertNil(model.animationLayers[2].animation)
    }

    /// A model object's `perspective` (flag 0x80) reaches the spatial content, off unless authored.
    func testModelObjectsKeepPerspective() throws {
        var scene = try decodeTolerant(WEScene.self, from: Data(#"""
        {"camera": {}, "general": {}, "objects": [{"id": 3, "model": "models/a.mdl", "perspective": true},
                                                  {"id": 4, "model": "models/b.mdl"}]}
        """#.utf8))
        scene.objects = SceneObjectIdentity.assigningFallbackIDs(scene.objects)
        let content = SceneSpatialContentBuilder(readFile: { _ in nil }, wallpaperName: "test")
            .build(scene, context: SpatialProperties())
        XCTAssertEqual(content.models.map(\.perspective), [true, false])
    }

    /// WE's dispatcher: `model` first, as a string, number or object; `camera` as a string.
    func testWhichObjectsAreModelsAndCameraLayers() throws {
        XCTAssertEqual(try object(#"{"model": 12}"#).model?.source, .loadedID(12))
        XCTAssertEqual(try object(#"{"model": {"file": "x"}}"#).model?.source, .object(.object(["file": .string("x")])))
        XCTAssertNil(try object(#"{"model": null, "image": "models/a.json"}"#).model)
        XCTAssertNil(try object(#"{"model": true}"#).model)
        XCTAssertNil(try object(#"{"model": ["a.mdl"]}"#).model)
        let both = try object(#"{"model": "models/a.mdl", "camera": "default", "image": "models/b.json"}"#)
        XCTAssertNotNil(both.model)
        XCTAssertNotNil(both.cameraLayer, "decoded as authored; the builder makes it a model only")
        XCTAssertNil(try object(#"{"camera": 1}"#).cameraLayer)
        XCTAssertNil(try object(#"{"camera": null}"#).cameraLayer)
    }

    // MARK: - Camera layers and paths

    func testLibraryCameraLayers() throws {
        let objects = try libraryObjects("library-camera-layers.json")
        XCTAssertEqual(objects.count, 15)
        XCTAssertEqual(Set(objects.map(\.item)).count, 7)
        for (item, object) in objects {
            let layer = try XCTUnwrap(object.cameraLayer, item)
            XCTAssertNil(object.model)
            XCTAssertEqual(layer.camera, "default")
            XCTAssertEqual(layer.queueMode, .random)
            XCTAssertEqual(layer.zoom, 1)
            XCTAssertNotNil(layer.path)
        }
        let dynamic = try XCTUnwrap(objects.first { $0.object.id == 203 }?.object)
        XCTAssertEqual(dynamic.cameraLayer?.fov ?? 0, 31.139999, accuracy: 1e-9)
        XCTAssertEqual(dynamic.cameraLayer?.path, "scripts/camera_paths_203.json")
        XCTAssertEqual(dynamic.visibleUserProperty, "camerastyle")
        XCTAssertEqual(dynamic.visibleCondition, "0")
        // 3378346807 binds the fov to a user property.
        let bound = try XCTUnwrap(objects.first { $0.item == "3378346807" }?.object.cameraLayer)
        XCTAssertEqual(bound.values[.fov]?.userPropertyName, "camerazoom")
        XCTAssertEqual(bound.fov, 75)

        let defaults = try XCTUnwrap(try object(#"{"camera": "default", "queuemode": "sequential"}"#).cameraLayer)
        XCTAssertEqual(defaults.fov, 50)
        XCTAssertEqual(defaults.zoom, 1)
        XCTAssertEqual(defaults.queueMode, .sequential)
        XCTAssertNil(defaults.path)
    }

    func testCameraLayerPathFile() throws {
        let failures = DecodeFailureLog()
        let file = try WECameraLayerPathFile(data: Fixtures.data("Spatial/camera-layer-paths.json"), failures: failures)
        // The path without `fps` is dropped; the number is skipped and logged.
        XCTAssertEqual(file.paths.map(\.name), ["Left to Right", "Right to Left"])
        XCTAssertEqual(failures.messages.count, 1)
        let path = file.paths[0]
        XCTAssertEqual(path.id, 208)
        XCTAssertEqual(path.visible, .bool(true))
        XCTAssertEqual(path.options.fps, 30)
        XCTAssertEqual(path.options.length, 132)
        XCTAssertEqual(path.options.mode, .single)
        let eye = try XCTUnwrap(path.eye)
        XCTAssertEqual(eye.channels.count, 3)
        XCTAssertEqual(eye.channels.map { $0.map(\.frame) }, [[0, 132], [0, 132], [0, 132]])
        XCTAssertEqual(eye.channels[0][0].value, -1.47644, accuracy: 1e-5)
        XCTAssertEqual(eye.channels[2][1].value, 3.14998, accuracy: 1e-5)
        XCTAssertEqual(eye.options, path.options)
        XCTAssertEqual(path.up?.channels[1].map(\.value), [1, 1])
        XCTAssertEqual(path.center?.channels[0][1].value ?? 0, 0.57026, accuracy: 1e-5)
        // `fov` is a bare keyframe list: one channel.
        XCTAssertEqual(path.fov?.channels.map { $0.map(\.value) }, [[50, 50]])
        XCTAssertNil(path.zoom, "`zoom: null`: the layer's own zoom")

        XCTAssertEqual(try WECameraLayerPathFile(data: Data(#"{"paths": []}"#.utf8)).paths, [])
    }

    func testSceneCameraPathFile() throws {
        let file = try WESceneCameraPathFile(data: Fixtures.data("Spatial/scene-camera-paths.json"))
        // The disabled path and the one without transforms are skipped.
        XCTAssertEqual(file.paths.map(\.name), ["first", "untimed"])
        let first = file.paths[0]
        XCTAssertEqual(first.duration, 30)
        XCTAssertEqual(first.keys.map(\.timestamp), [0, 30])
        XCTAssertLessThan(simd_distance(first.keys[0].eye, SIMD3(-3.544, 2.168, 2.274)), 1e-5)
        XCTAssertLessThan(simd_distance(first.keys[0].center, SIMD3(-2.968, 1.777, 1.556)), 1e-5)
        XCTAssertEqual(first.keys[0].up, SIMD3(0, 1, 0))
        XCTAssertEqual(first.keys.map(\.zoom), [1, 2])
        // Without timestamps a key sits at i / (n − 1) · duration, n counting the disabled key.
        let untimed = file.paths[1]
        XCTAssertEqual(untimed.keys.map(\.timestamp), [0, 20])
        XCTAssertEqual(untimed.keys.map(\.eye.x), [0, 2])
    }

    // MARK: - Projection and general

    func testOrthogonalProjectionFollowsWE() throws {
        let cases: [(String, WESceneProjection)] = [
            (#"{}"#, .perspective),
            (#"{"orthogonalprojection": null}"#, .perspective),
            (#"{"orthogonalprojection": 5}"#, .perspective),
            (#"{"orthogonalprojection": {}}"#, .perspective),
            (#"{"orthogonalprojection": {"auto": true}}"#, .orthographicAuto),
            (#"{"orthogonalprojection": {"auto": true, "width": 100, "height": 50}}"#, .orthographicAuto),
            (#"{"orthogonalprojection": {"auto": false, "width": 100, "height": 50}}"#, .orthographic(width: 100, height: 50)),
            (#"{"orthogonalprojection": {"auto": 1, "width": 0, "height": 0}}"#, .perspective),
            (#"{"orthogonalprojection": {"width": 0, "height": 0}}"#, .perspective),
            (#"{"orthogonalprojection": {"width": 1920, "height": 0}}"#, .perspective),
            (#"{"orthogonalprojection": {"width": "1920", "height": "1080"}}"#, .perspective),
            (#"{"orthogonalprojection": {"width": 1920.7, "height": 1080}}"#, .orthographic(width: 1920, height: 1080)),
        ]
        for (json, expected) in cases {
            XCTAssertEqual(try general(json).projection, expected, json)
        }
    }

    /// The renderer's gates follow `projection`: a scene without the key is perspective in WE, so
    /// it has no parallax displacement, no pixel-unit particle defaults and WE's perspective rig.
    func testTheRenderersGatesFollowTheProjection() throws {
        for (json, perspective) in [(#"{}"#, true), (#"{"orthogonalprojection": null}"#, true),
                                    (#"{"orthogonalprojection": {"width": 0, "height": 1080}}"#, true),
                                    (#"{"orthogonalprojection": {"width": 1920, "height": 1080}}"#, false),
                                    (#"{"orthogonalprojection": {"auto": true}}"#, false)] {
            let scene = try decodeTolerant(WEScene.self, from: Data(#"{"camera": {}, "general": \#(json), "objects": []}"#.utf8))
            XCTAssertEqual(SceneCameraEffects(scene.general, in: SpatialProperties()).orthographic, !perspective, json)
            XCTAssertEqual(SceneContentLoader.particlesUsePixelUnits(scene), !perspective, json)
            var content = SceneMetalContent(size: SIMD2(1920, 1080), layers: [], particleSystems: [],
                                            bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0,
                                                                      tint: SIMD3(repeating: 1)))
            content.spatial.camera = SceneCameraSettings(scene.general, in: SpatialProperties())
            XCTAssertEqual(SceneCameraRigs.make(for: content) is ScenePerspectiveCameraRig, perspective, json)
        }
    }

    func testCameraSettingsDefaultsAndBindings() throws {
        let none = SceneCameraSettings(try general(#"{}"#), in: SpatialProperties())
        XCTAssertEqual(none, SceneCameraSettings())
        XCTAssertEqual(none.fov, 50)
        XCTAssertEqual(none.perspectiveOverrideFov, 95)
        XCTAssertEqual(none.nearZ, 0.1)
        XCTAssertEqual(none.farZ, 10000)
        XCTAssertEqual(none.zoom, 1)
        XCTAssertTrue(none.cameraFade)
        XCTAssertFalse(none.transparentSorting)
        XCTAssertFalse(none.customSortOrder)
        XCTAssertEqual(none.sceneFov, 50)

        // 3378346807's form: `fov` bound to a user property.
        let json = """
        {"orthogonalprojection": null, "fov": {"user": "camerazoom", "value": 75.0}, "nearz": 0.01, "farz": 500,
         "zoom": 2, "camerafade": false, "transparentsorting": true, "customsortorder": true,
         "perspectiveoverridefov": 70}
        """
        let bound = try general(json)
        XCTAssertEqual(bound.fov, 75)
        XCTAssertEqual(bound.values[.fov]?.userPropertyName, "camerazoom")
        // The loader resolves the binding (`UserPropertyBindingTable`) before the settings read it.
        let resolved = try BoundDocument.decode(WESceneGeneral.self, from: Data(json.utf8),
                                                properties: ["camerazoom": "200"])
        let settings = SceneCameraSettings(resolved, in: SpatialProperties())
        XCTAssertEqual(settings.fov, 200)
        XCTAssertEqual(settings.sceneFov, 179.9, "clamped")
        XCTAssertEqual(settings.nearZ, 0.01, accuracy: 1e-7)
        XCTAssertEqual(settings.farZ, 500)
        XCTAssertEqual(settings.zoom, 2)
        XCTAssertFalse(settings.cameraFade)
        XCTAssertTrue(settings.transparentSorting && settings.customSortOrder)

        var ortho = settings
        ortho.projection = .orthographic(width: 100, height: 100)
        XCTAssertEqual(ortho.sceneFov, 70, "an ortho scene's fov is perspectiveoverridefov")
    }

    func testDrawOrderModeFollowsTheObjectLoop() {
        func mode(transparent: Bool, custom: Bool, perspective: Bool) -> SceneDrawOrderMode {
            var settings = SceneCameraSettings()
            settings.transparentSorting = transparent
            settings.customSortOrder = custom
            settings.projection = perspective ? .perspective : .orthographic(width: 10, height: 10)
            return SceneDrawOrderMode(settings)
        }
        XCTAssertEqual(mode(transparent: false, custom: false, perspective: true), .sceneOrder)
        XCTAssertEqual(mode(transparent: false, custom: false, perspective: false), .sceneOrder)
        XCTAssertEqual(mode(transparent: true, custom: false, perspective: true), SceneDrawOrderMode(splitsTranslucent: true))
        XCTAssertEqual(mode(transparent: true, custom: false, perspective: false), .sceneOrder)
        XCTAssertEqual(mode(transparent: false, custom: true, perspective: false), SceneDrawOrderMode(sortsBySortOrder: true))
        XCTAssertEqual(mode(transparent: true, custom: true, perspective: false), .sceneOrder)
        XCTAssertEqual(mode(transparent: true, custom: true, perspective: true), SceneDrawOrderMode(splitsTranslucent: true))
    }
}
