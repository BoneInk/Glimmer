import XCTest
import simd
@testable import OpenWallpaperEngine

/// WE's camera on the library's 3D scenes (docs/models-plan.md §2.3): the camera layer each
/// scene starts with, and PaRappa's `camerastyle` choosing among eight layers. Skipped when the
/// library is absent (CI).
final class SceneCameraLibraryTests: XCTestCase {
    private static let storage = URL(fileURLWithPath: "/Volumes/980Pro/OpenWallpaperStorage")

    private func scene(_ id: String) throws -> (WEScene, SceneSpatialContent) {
        let directory = Self.storage.appending(path: id, directoryHint: .isDirectory)
        guard let data = FileManager.default.contents(atPath: directory.appending(path: "scene.json").path) else {
            throw XCTSkip("\(id) not in the library")
        }
        var scene = try decodeTolerant(WEScene.self, from: data)
        scene.objects = SceneObjectIdentity.assigningFallbackIDs(scene.objects)
        let spatial = SceneSpatialContentBuilder(
            readFile: { FileManager.default.contents(atPath: directory.appending(path: $0).path) },
            wallpaperName: id).build(scene, context: SpatialProperties())
        return (scene, spatial)
    }

    /// An object's own `visible` as the loader resolves it: a combo's condition against the
    /// property, else the authored flag.
    private static func visible(_ object: WESceneObject, properties: [String: String]) -> Bool {
        if let property = object.visibleUserProperty, let value = properties[property] {
            if let condition = object.visibleCondition { return condition == value }
            return value == "true" || value == "1"
        }
        return object.visible != false
    }

    private static func input(_ scene: WEScene, properties: [String: String] = [:], hidden: Set<String> = []) -> SceneCameraRigInput {
        var input = SceneCameraRigInput(sceneSize: SIMD2(1920, 1080), aspect: 16.0 / 9, time: 0, deltaTime: 1.0 / 30)
        let objects = Dictionary(scene.objects.map { (String($0.id ?? -1), $0) }, uniquingKeysWith: { a, _ in a })
        input.isVisible = { id in
            guard !hidden.contains(id), let object = objects[id] else { return false }
            return visible(object, properties: properties)
        }
        return input
    }

    /// PaRappa (3159348391): eight camera layers. "Camera Start", last in scene order, is the camera
    /// until its script hides it at the end of its intro dolly; then `camerastyle` picks one of
    /// the seven others by its `visible` condition. The six fixed ones look from their `origin`
    /// down their local −z with their own fov; "Dynamic" plays its random paths.
    func testPaRappasCameraStyleChoosesTheLayer() throws {
        let (scene, spatial) = try scene("3159348391")
        XCTAssertEqual(spatial.cameraLayers.map(\.name), ["Dynamic Cam", "Center", "Center Full", "Above", "PaRappa Cam",
                                                          "Onion Cam", "Outside", "Camera Start"])
        let start = ScenePerspectiveCameraRig(spatial, values: SpatialProperties()).frameCamera(Self.input(scene))
        let startLayer = try XCTUnwrap(spatial.cameraLayers.last)
        XCTAssertEqual(start.eye, spatial.transforms.nodes[startLayer.id]?.local.origin, "the intro camera at its authored origin")
        XCTAssertEqual(start.fieldOfView, 50)

        let ids = ["203", "366", "367", "368", "369", "370", "371"]
        for style in 0..<7 {
            let rig = ScenePerspectiveCameraRig(spatial, values: SpatialProperties())
            let input = Self.input(scene, properties: ["camerastyle": String(style)], hidden: ["222"])
            let camera = rig.frameCamera(input)
            let layer = try XCTUnwrap(spatial.cameraLayers.first { $0.id == ids[style] })
            XCTAssertTrue(camera.isPerspective)
            XCTAssertTrue(camera.eye.x.isFinite && camera.eye.y.isFinite && camera.eye.z.isFinite, "style \(style)")
            if style == 0 {
                XCTAssertEqual(rig.cameraLayers.playingPath("203") != nil, true, "Dynamic plays a path")
                continue
            }
            XCTAssertNil(layer.pathFile?.paths.first, "style \(style): an empty path file")
            let local = try XCTUnwrap(spatial.transforms.nodes[layer.id]?.local)
            XCTAssertEqual(camera.eye, local.origin, "style \(style)")
            let forward = SceneWorldMatrix.forward(local.matrix)
            XCTAssertLessThan(simd_length(camera.forward - forward), 1e-4, "style \(style)")
            XCTAssertEqual(Double(try XCTUnwrap(camera.fieldOfView)), layer.authored.fov, accuracy: 1e-4, "style \(style)")
        }
    }

    /// MG1: in WE, PaRappa (style 0) opens with the same ~4.4 s door dolly on every load, then
    /// random paths. The dolly is no path of "Dynamic Cam" (203) but "Camera Start" (222), the last
    /// camera layer: its `origin` timeline (132 frames at 30 fps, "single") fires "end" on its last
    /// frame, its `animationEvent` script sets `shared.camoff` and its `visible` script then hides
    /// it. 203 plays its paths underneath from load, and its first path (132 frames too) ends on
    /// the same frame, so the first path seen is a fresh draw.
    func testPaRappasIntroIsTheCameraStartLayer() throws {
        let (scene, spatial) = try scene("3159348391")
        let start = try XCTUnwrap(scene.objects.first { $0.id == 222 })
        XCTAssertEqual(start.name, "Camera Start")
        XCTAssertEqual(spatial.cameraLayers.last?.id, "222")
        XCTAssertEqual(spatial.cameraLayers.last?.pathFile?.paths.count, 0, "the dolly is its origin timeline, not a path")

        let data = try XCTUnwrap(FileManager.default.contents(atPath: Self.storage.appending(path: "3159348391/scene.json").path))
        let animations = SceneAnimationSet(document: try JSONDecoder().decode(SceneJSON.self, from: data), wallpaperID: "3159348391")
        let origin = SceneAnimationSite(owner: .object(222), key: "origin")
        var end: Int?
        for frame in 1...200 where end == nil {
            if animations.advance(by: 1.0 / 30).events.contains(where: { $0.site == origin && $0.name == "end" }) { end = frame }
        }
        let endFrame = try XCTUnwrap(end, "the dolly's end event")
        XCTAssertEqual(Double(endFrame), 132, accuracy: 1)

        let rig = ScenePerspectiveCameraRig(spatial, values: SpatialProperties())
        var playing: [Int] = []
        for frame in 1...(endFrame + 2) {
            let input = Self.input(scene, properties: ["camerastyle": "0"], hidden: frame > endFrame ? ["222"] : [])
            _ = rig.frameCamera(input)
            playing.append(try XCTUnwrap(rig.cameraLayers.playingPath("203"), "203 plays under the intro"))
        }
        let switchFrame = try XCTUnwrap(playing.indices.first { playing[$0] != playing[0] }) + 1
        XCTAssertEqual(Double(switchFrame), Double(endFrame + 1), accuracy: 1,
                       "the hidden first path ends as the intro does: \(playing)")
    }

    /// Every library scene with camera layers starts with a finite perspective camera, from its last
    /// visible camera layer.
    func testLibraryScenesStartFromTheirLastVisibleCameraLayer() throws {
        var report = "scene\tlayer\teye\tforward\tfov\n"
        var scenes = 0
        for id in ["3159348391", "3453730450", "3233200129", "3378346807", "3455121165", "3657770939", "3734636606"] {
            guard let (scene, spatial) = try? self.scene(id) else { continue }
            scenes += 1
            let input = Self.input(scene)
            let expected = spatial.cameraLayers.last { input.isVisible($0.id) }
            let rig = ScenePerspectiveCameraRig(spatial, values: SpatialProperties())
            let camera = rig.frameCamera(input)
            XCTAssertNotNil(expected, id)
            XCTAssertTrue(camera.isPerspective, id)
            for value in [camera.eye, camera.forward] {
                XCTAssertTrue(value.x.isFinite && value.y.isFinite && value.z.isFinite, "\(id): \(value)")
            }
            if let expected, expected.pathFile?.paths.isEmpty ?? true {
                XCTAssertEqual(camera.eye, SceneWorldMatrix.translation(spatial.transforms.world(of: expected.id)), id)
            }
            report += "\(id)\t\(expected?.id ?? "-")\t\(camera.eye)\t\(camera.forward)\t\(camera.fieldOfView ?? 0)\n"
        }
        if scenes == 0 { throw XCTSkip("no 3D scene in the library") }
        print("The library's first cameras:\n\(report)")
    }
}
