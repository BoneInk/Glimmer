import XCTest
import simd
@testable import OpenWallpaperEngine

/// `thisScene.getCameraTransforms()`/`setCameraTransforms()` (docs/models-plan.md §2.3 "Script
/// camera"): they read and write WE's default camera, the `camera` block, which camera layers and
/// paths don't move (the camera-sync script of 3734636606 relies on that); the renderer's rig
/// takes what a script set while nothing else drives the camera.
final class SceneScriptCameraTests: XCTestCase {
    private var storage: URL!

    override func setUpWithError() throws {
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-script-camera-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let storage, FileManager.default.fileExists(atPath: storage.path) { try FileManager.default.removeItem(at: storage) }
    }

    /// The default camera scripts see: the `camera` block with WE's defaults; an orthographic scene
    /// without paths resets it to the origin looking down −z.
    func testScriptsSeeWEsDefaultCamera() throws {
        func camera(_ json: String) throws -> [SceneScriptSceneField: [Float]] {
            guard case .object(let root) = try SceneScriptSiteBuilder.document(from: Data(json.utf8)) else {
                throw XCTSkip("not an object")
            }
            return SceneScriptSceneDescriber.defaultCamera(root)
        }
        let defaults = try camera(#"{"general": {}, "objects": []}"#)
        XCTAssertEqual(defaults[.cameraEye], [2, 2, 2])
        XCTAssertEqual(defaults[.cameraCenter], [0, 0, 0])
        XCTAssertEqual(defaults[.cameraUp], [0, 1, 0])
        XCTAssertEqual(defaults[.cameraZoom], [1])
        let authored = try camera(#"{"camera": {"eye": "1 2 3", "center": "0 1 0"}, "general": {"orthogonalprojection": null}, "objects": []}"#)
        XCTAssertEqual(authored[.cameraEye], [1, 2, 3])
        XCTAssertEqual(authored[.cameraCenter], [0, 1, 0])
        let ortho = try camera(#"{"camera": {"eye": "1 2 3"}, "general": {"orthogonalprojection": {"width": 10, "height": 10}}, "objects": []}"#)
        XCTAssertEqual(ortho[.cameraEye], [0, 0, 0])
        XCTAssertEqual(ortho[.cameraCenter], [0, 0, -1])
        let orthoPaths = try camera(#"{"camera": {"eye": "1 2 3", "paths": ["a.json"]}, "general": {"orthogonalprojection": {"width": 10, "height": 10}}, "objects": []}"#)
        XCTAssertEqual(orthoPaths[.cameraEye], [1, 2, 3], "paths keep the block")
    }

    /// A round trip: a script reads the default camera, sets another, the next frame reads it back,
    /// and the renderer's rig draws from it.
    func testSetCameraTransformsRoundTrip() throws {
        _ = try Fixtures.assets()
        let script = #"""
            export function update(value) {
                const c = thisScene.getCameraTransforms();
                if (shared.frames === undefined) {
                    shared.first = [c.eye.x, c.eye.y, c.eye.z, c.center.y, c.up.y, c.zoom].join();
                    thisScene.setCameraTransforms({ eye: new Vec3(0, 1, 5), center: new Vec3(0, 1, 0) });
                    shared.frames = 1;
                } else {
                    shared.second = [c.eye.x, c.eye.y, c.eye.z, c.center.y, c.up.y, c.zoom].join();
                }
                return value;
            }
            """#
        let objects = [#"{"id": 1, "name": "Probe", "origin": {"script": \#(jsonString(script)), "value": "0 0 0"}}"#]
        let wallpaper = try make(objects: objects, camera: #""camera": {"eye": "3 4 5", "center": "0 0 0", "up": "0 1 0"}"#)
        let first = try frame(wallpaper)
        XCTAssertEqual(try string(wallpaper, "first"), "3,4,5,0,1,1")
        let pose = try XCTUnwrap(first.scene.scriptCamera, "the script's camera reaches the renderer")
        XCTAssertEqual(pose.eye, SIMD3(0, 1, 5))
        XCTAssertEqual(pose.center, SIMD3(0, 1, 0))
        XCTAssertEqual(pose.up, SIMD3(0, 1, 0), "unset fields keep the default camera's")
        _ = try frame(wallpaper)
        XCTAssertEqual(try string(wallpaper, "second"), "0,1,5,1,1,1")

        // The rig draws from it while no camera layer or path drives the camera.
        var input = SceneCameraRigInput(sceneSize: SIMD2(1920, 1080), aspect: 16.0 / 9, time: 0, deltaTime: 0)
        input.scriptCamera = first.scene.scriptCamera
        let camera = ScenePerspectiveCameraRig(SceneSpatialContent(), values: SpatialProperties()).frameCamera(input)
        XCTAssertEqual(camera.eye, SIMD3(0, 1, 5))
        XCTAssertEqual(camera.forward, SIMD3(0, 0, -1))
    }

    /// WE 2.8 with a camera path playing (docs/models-plan.md §5.5,
    /// tools/peer/requests/owe-beta3/models-open/505-path-camera/README.md): on 3159348391 every
    /// read from 0.25 s to 10 s is the static `camera` block while the path visibly moves the view.
    /// Every frame here reads the block; nothing writes the path's pose back.
    func testGetCameraTransformsIsTheStaticCameraWhilePathsPlay() throws {
        _ = try Fixtures.assets()
        let script = #"""
            export function update(value) {
                const c = thisScene.getCameraTransforms();
                shared.reads = (shared.reads || []).concat([[c.eye.x, c.eye.y, c.eye.z, c.center.x, c.center.y, c.center.z,
                                                             c.up.y].map(function (v) { return v.toFixed(3); }).join()]);
                return value;
            }
            """#
        let objects = [#"{"id": 1, "name": "Logger", "origin": {"script": \#(jsonString(script)), "value": "0 0 0"}}"#]
        let camera = #""camera": {"eye": "-0.171 1.759 3.836", "center": "-0.144 1.683 2.839", "up": "0 1 0", "paths": ["scripts/camera_paths_203.json"]}"#
        let wallpaper = try make(objects: objects, camera: camera)
        for _ in 0..<5 {
            let state = try frame(wallpaper)
            XCTAssertNil(state.scene.scriptCamera, "reading leaves the camera to the rig")
        }
        let reads = try XCTUnwrap(try string(wallpaper, "reads.join('|')"))
        XCTAssertEqual(reads.split(separator: "|").count, 5)
        XCTAssertEqual(Set(reads.split(separator: "|").map(String.init)), ["-0.171,1.759,3.836,-0.144,1.683,2.839,1.000"])
    }

    // MARK: - Support

    private func jsonString(_ text: String) -> String {
        String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
    }

    private func make(objects: [String], camera: String) throws -> SceneScriptWallpaper {
        let text = #"{\#(camera), "general": {"orthogonalprojection": null}, "objects": [\#(objects.joined(separator: ", "))]}"#
        let document = try SceneScriptSiteBuilder.document(from: Data(text.utf8))
        let content = SceneScriptSceneContent(wallpaperID: "camera-\(UUID().uuidString.prefix(8))", document: document,
                                              documentSignature: "1", project: nil, userValues: { [:] },
                                              file: { _ in nil }, makeLayer: { _ in nil })
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                                           media: SceneScriptReplayMediaSource(), spectrum: { .silent })
        let wallpaper = try XCTUnwrap(try SceneScriptWallpaper(content: content, services: services, screenID: "test"))
        addTeardownBlock { wallpaper.tearDown(); wallpaper.waitUntilIdle() }
        return wallpaper
    }

    private func frame(_ wallpaper: SceneScriptWallpaper) throws -> SceneScriptFrameState {
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 30
        wallpaper.submit(input)
        wallpaper.waitUntilIdle()
        return try XCTUnwrap(wallpaper.take().state)
    }

    private func string(_ wallpaper: SceneScriptWallpaper, _ key: String) throws -> String? {
        wallpaper.thread.sync { wallpaper.scriptRuntime?.context.evaluateScript("shared.\(key)")?.toString() }
    }
}
