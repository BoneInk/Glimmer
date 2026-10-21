import XCTest
import simd
@testable import OpenWallpaperEngine

/// The seams M0 of docs/models-plan.md added (§4.4): the content's `spatial` part and the frame
/// camera, which must still be the camera the renderer drew with before.
final class SceneSpatialSeamTests: XCTestCase {
    func testSpatialContentCollectsModelsCameraLayersAndPaths() throws {
        let scene = try decodeTolerant(WEScene.self, from: Data("""
        {"camera": {"eye": "1 2 3", "paths": ["scripts/camera_00.json", "scripts/missing.json"]},
         "general": {"orthogonalprojection": null, "transparentsorting": true},
         "objects": [
           {"id": 1, "name": "cam", "camera": "default", "path": "scripts/camera_paths_1.json"},
           {"id": 2, "name": "box", "model": "models/box.mdl", "castshadow": false},
           {"id": 3, "name": "image", "image": "models/a.json"},
           {"id": 4, "name": "both", "model": "models/b.mdl", "camera": "default"},
           {"id": 5, "name": "cam2", "camera": "default"}]}
        """.utf8))
        let files = ["scripts/camera_00.json": try Fixtures.data("Spatial/scene-camera-paths.json"),
                     "scripts/camera_paths_1.json": try Fixtures.data("Spatial/camera-layer-paths.json")]
        var reads: [String] = []
        let content = SceneSpatialContentBuilder(readFile: { reads.append($0); return files[$0] },
                                                 wallpaperName: "fixture").build(scene, context: SpatialProperties())
        XCTAssertTrue(content.camera.projection.isPerspective)
        XCTAssertEqual(content.drawOrder, SceneDrawOrderMode(splitsTranslucent: true))
        XCTAssertEqual(content.staticEye, SIMD3(1, 2, 3))
        XCTAssertEqual(content.staticCenter, SceneCameraDefaults.center)
        XCTAssertEqual(content.staticUp, SceneCameraDefaults.up)
        XCTAssertEqual(content.cameraPaths.map(\.name), ["first", "untimed"])
        XCTAssertEqual(content.models.map(\.id), ["2", "4"])
        XCTAssertEqual(content.models.map(\.order), [1, 3])
        XCTAssertEqual(content.models[0].renderValues[.castshadow], .bool(false))
        XCTAssertEqual(content.cameraLayers.map(\.id), ["1", "5"])
        XCTAssertEqual(content.cameraLayers[0].pathFile?.paths.count, 2)
        XCTAssertNil(content.cameraLayers[1].pathFile)
        XCTAssertEqual(reads, ["scripts/camera_00.json", "scripts/missing.json", "scripts/camera_paths_1.json"])
    }

    /// An orthographic scene's rig is WE's orthographic camera: `ortho(0, w, 0, h)` over
    /// z −2000…2000, reversed, from the origin down −z, with the eye WE reports at (w/2, h/2, 2000).
    /// It frames the scene as the layer pass does.
    func testTheOrthographicRigIsWEsCamera() throws {
        var content = SceneMetalContent(size: SIMD2(1920, 1080), layers: [], particleSystems: [],
                                        bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0,
                                                                  tint: SIMD3(repeating: 1)))
        content.spatial.camera.projection = .orthographic(width: 1920, height: 1080)
        let rig = SceneCameraRigs.make(for: content)
        XCTAssertTrue(rig is SceneOrthographicCameraRig)
        let camera = rig.frameCamera(SceneCameraRigInput(sceneSize: content.size, aspect: 16.0 / 9, time: 1, deltaTime: 1 / 60))
        XCTAssertEqual(camera.eye, SIMD3(960, 540, 2000))
        XCTAssertEqual(camera.forward, SIMD3(0, 0, -1))
        XCTAssertFalse(camera.isPerspective)
        XCTAssertTrue(camera.reversedDepth)
        XCTAssertEqual(camera.fade, 0)
        // WE's scene units are y up, the layer pass's y down: the same corner lands in the same place.
        let layerPass = ImageMaterialRenderer.viewProjection(sceneSize: content.size)
        for (we, drawn) in [(SIMD2<Float>(0, 0), SIMD2<Float>(0, 1080)), (SIMD2(1920, 1080), SIMD2(1920, 0))] {
            let a: SIMD4<Float> = camera.viewProjection * SIMD4(we.x, we.y, 0, 1)
            let b: SIMD4<Float> = layerPass * SIMD4(drawn.x, drawn.y, 0, 1)
            XCTAssertEqual(SIMD2(a.x, a.y), SIMD2(b.x, b.y))
        }
        XCTAssertEqual(camera.viewProjection * SIMD4(1920, 1080, 2000, 1), SIMD4(1, 1, 1, 1), "z = 2000 is the near plane")
        XCTAssertEqual(camera.viewProjection * SIMD4(0, 0, -2000, 1), SIMD4(-1, -1, 0, 1), "z = −2000 the far one")
    }
}
