import XCTest
import simd
@testable import OpenWallpaperEngine

/// WE's camera matrices and the perspective rig (docs/models-plan.md §2.1, §2.2, M2): a
/// right-handed view, reversed-Z projections (near → 1, far → 0), the fov clamp, `zoom` ignored in
/// perspective, the static camera's defaults, and camera shake moving the eye and the centre.
final class SceneCameraTests: XCTestCase {
    private func assertEqual(_ a: SIMD4<Float>, _ b: SIMD4<Float>, accuracy: Float = 1e-4, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_length(a - b), accuracy, "\(a) vs \(b) \(message)", file: file, line: line)
    }

    private func assertEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float = 1e-4, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_length(a - b), accuracy, "\(a) vs \(b) \(message)", file: file, line: line)
    }

    // MARK: - Matrices

    /// 0x14009a370's matrix, element by element: [cot/a 0 0 0; 0 cot 0 0; 0 0 n/(f−n) −1; 0 0 nf/(f−n) 0]
    /// as WE's rows, which are simd's columns.
    func testThePerspectiveProjectionIsWEsReversedRightHandedOne() {
        let near: Float = 0.1, far: Float = 100, aspect: Float = 2
        let projection = SceneCamera.perspective(fovDegrees: 90, aspect: aspect, near: near, far: far)
        let cot: Float = 1 / tan(.pi / 4)
        assertEqual(projection.columns.0, SIMD4(cot / aspect, 0, 0, 0))
        assertEqual(projection.columns.1, SIMD4(0, cot, 0, 0))
        assertEqual(projection.columns.2, SIMD4(0, 0, near / (far - near), -1))
        assertEqual(projection.columns.3, SIMD4(0, 0, near * far / (far - near), 0))
        // Right-handed: the camera looks down −z. Reversed: near → 1, far → 0.
        let atNear = projection * SIMD4(0, 0, -near, 1), atFar = projection * SIMD4(0, 0, -far, 1)
        XCTAssertEqual(atNear.z / atNear.w, 1, accuracy: 1e-5)
        XCTAssertEqual(atFar.z / atFar.w, 0, accuracy: 1e-5)
        let middle = projection * SIMD4(0, 0, -10, 1)
        XCTAssertGreaterThan(middle.z / middle.w, 0)
        XCTAssertLessThan(middle.z / middle.w, 1)
        // The frustum's top edge at 45°: y = −z lands on the clip square's top.
        let top = projection * SIMD4(0, 10, -10, 1)
        XCTAssertEqual(top.y / top.w, 1, accuracy: 1e-5)
        let right = projection * SIMD4(20, 0, -10, 1)
        XCTAssertEqual(right.x / right.w, 1, accuracy: 1e-5, "the aspect widens x")
    }

    /// 0x14009a630: m22 = −1/(n−f), m32 = −f/(n−f), reversed like the perspective one.
    func testTheOrthographicProjectionIsReversed() {
        let projection = SceneCamera.orthographic(left: 0, right: 1920, bottom: 0, top: 1080, near: -2000, far: 2000)
        assertEqual(projection.columns.2, SIMD4(0, 0, -1 / (-2000 - 2000), 0))
        assertEqual(projection.columns.3, SIMD4(-1, -1, -2000 / (-2000 - 2000), 1))
        assertEqual(projection * SIMD4(0, 0, 2000, 1), SIMD4(-1, -1, 1, 1), "z = 2000 is near")
        assertEqual(projection * SIMD4(1920, 1080, -2000, 1), SIMD4(1, 1, 0, 1), "z = −2000 is far")
        XCTAssertEqual(SceneCamera.orthographic(size: SIMD2(1920, 1080)), projection)
    }

    /// 0x14019d920: glm's `lookAtRH`, rows right, up and back, translated by the eye.
    func testLookAtIsRightHanded() {
        let eye = SIMD3<Float>(2, 2, 2)
        let view = SceneCamera.lookAt(eye: eye, center: .zero, up: SIMD3(0, 1, 0))
        assertEqual(view * SIMD4(eye, 1), SIMD4(0, 0, 0, 1), "the eye is the view's origin")
        let center = view * SIMD4(0, 0, 0, 1)
        XCTAssertEqual(center.z, -simd_length(eye), accuracy: 1e-5, "the centre is straight ahead, down −z")
        XCTAssertEqual(center.x, 0, accuracy: 1e-5)
        XCTAssertEqual(center.y, 0, accuracy: 1e-5)
        let above = view * SIMD4(0, 1, 0, 1)
        XCTAssertGreaterThan(above.y, 0, "+y world stays up")
        XCTAssertEqual(view.determinant, 1, accuracy: 1e-5)
    }

    /// The camera layer's write-back (0x1401f324f…, M3's `SceneWorldMatrix.lookAtAngles`) is the
    /// view's inverse: the object built from the angles looks from the eye at the centre down its
    /// local −z with its +y up, so the camera it gives is the view.
    func testLookAtAnglesRebuildTheView() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let eye = SIMD3<Float>(Float.random(in: -5...5, using: &generator), Float.random(in: -5...5, using: &generator),
                                   Float.random(in: -5...5, using: &generator))
            let direction = simd_normalize(SIMD3<Float>(Float.random(in: -1...1, using: &generator),
                                                        Float.random(in: -0.9...0.9, using: &generator),
                                                        Float.random(in: -1...1, using: &generator)))
            let center = eye + 3 * direction
            let angles = SceneWorldMatrix.lookAtAngles(eye: eye, center: center, up: SIMD3(0, 1, 0))
            let object = SceneWorldMatrix.local(SceneLocalTransform3D(origin: eye, scale: SIMD3(repeating: 1), angles: angles))
            let view = SceneCamera.lookAt(eye: eye, center: center, up: SIMD3(0, 1, 0))
            // The object is the view's inverse: its rows are right, up and back.
            let product = view * object
            for column in 0..<4 {
                assertEqual(product[column], matrix_identity_float4x4[column], accuracy: 1e-3, "\(angles)")
            }
        }
    }

    // MARK: - The perspective rig

    private func rig(_ spatial: SceneSpatialContent) -> ScenePerspectiveCameraRig {
        ScenePerspectiveCameraRig(spatial, values: SpatialProperties())
    }

    private func input(delta: Float = 1.0 / 30, aspect: Float = 16.0 / 9) -> SceneCameraRigInput {
        SceneCameraRigInput(sceneSize: SIMD2(1920, 1080), aspect: aspect, time: 0, deltaTime: delta)
    }

    /// Without camera layers or paths: the `camera` block with WE's defaults, `general`'s fov,
    /// near and far, and zoom ignored.
    func testTheStaticCameraHasWEsDefaults() {
        var spatial = SceneSpatialContent()
        spatial.camera.zoom = 4
        let camera = rig(spatial).frameCamera(input())
        assertEqual(camera.eye, SIMD3(2, 2, 2))
        assertEqual(camera.forward, simd_normalize(SIMD3(-2, -2, -2)))
        XCTAssertEqual(camera.fieldOfView, 50)
        XCTAssertTrue(camera.reversedDepth)
        XCTAssertEqual(camera.projection, SceneCamera.perspective(fovDegrees: 50, aspect: 16.0 / 9, near: 0.1, far: 10000),
                       "zoom does nothing in perspective")
        XCTAssertEqual(camera.view, SceneCamera.lookAt(eye: SIMD3(2, 2, 2), center: .zero, up: SIMD3(0, 1, 0)))
        XCTAssertEqual(camera.fade, 0)
    }

    /// Scripts' `thisScene.fov`, `nearz` and `farz` win; the fov is clamped to 0.1…179.9 (0x140189b1a).
    func testFovIsScriptableAndClamped() {
        let rig = rig(SceneSpatialContent())
        var frame = input()
        frame.fov = 300
        frame.nearZ = 1
        frame.farZ = 50
        let camera = rig.frameCamera(frame)
        XCTAssertEqual(camera.fieldOfView, 179.9)
        XCTAssertEqual(camera.projection, SceneCamera.perspective(fovDegrees: 179.9, aspect: 16.0 / 9, near: 1, far: 50))
        frame.fov = -3
        XCTAssertEqual(rig.frameCamera(frame).fieldOfView, 0.1)
    }

    /// 0x140199580: eye and centre move together by the shake; in a perspective scene it is 3D.
    func testShakeMovesTheEyeAndTheCentre() {
        let rig = rig(SceneSpatialContent())
        var frame = input()
        frame.shake = SceneCameraShake.cameraOffset(time: 0.4, speed: 2, amplitude: 3, roughness: 1, orthographicHeight: nil)
        XCTAssertNotEqual(frame.shake.z, 0)
        let camera = rig.frameCamera(frame)
        assertEqual(camera.eye, SIMD3(2, 2, 2) + frame.shake)
        assertEqual(camera.forward, simd_normalize(SIMD3(-2, -2, -2)), "a translation keeps the direction")
        // The phase: speed² · t, (cos, sin 1.333, sin), scaled by amplitude · 0.1.
        let phase: Float = 4 * 0.4
        assertEqual(frame.shake, SIMD3(cos(phase), sin(1.333 * phase), sin(phase)) * 0.3)
    }

    /// `thisScene.setCameraTransforms` replaces the `camera` block while no layer or path drives the camera.
    func testTheScriptCameraReplacesTheCameraBlock() {
        var frame = input()
        frame.scriptCamera = SceneCameraPose(eye: SIMD3(0, 1, 5), center: SIMD3(0, 1, 0), up: SIMD3(0, 1, 0))
        let camera = rig(SceneSpatialContent()).frameCamera(frame)
        assertEqual(camera.eye, SIMD3(0, 1, 5))
        assertEqual(camera.forward, SIMD3(0, 0, -1))
    }

    /// `camerafade` follows the scene's paths, and a script can turn it off.
    func testTheFadeFollowsThePathsAndTheSetting() {
        var spatial = SceneSpatialContent()
        spatial.cameraPaths = [WESceneCameraPath(duration: 4, keys: [
            .init(timestamp: 0, eye: SIMD3(0, 0, 5), center: .zero, up: SIMD3(0, 1, 0)),
            .init(timestamp: 4, eye: SIMD3(5, 0, 5), center: .zero, up: SIMD3(0, 1, 0))])]
        let faded = rig(spatial)
        XCTAssertEqual(faded.frameCamera(input(delta: 0.1)).fade, 0.8, accuracy: 1e-5, "0.1 s in: 1 − 2·0.1")
        var off = input(delta: 0.1)
        off.cameraFade = false
        XCTAssertEqual(rig(spatial).frameCamera(off).fade, 0)
        spatial.camera.cameraFade = false
        XCTAssertEqual(rig(spatial).frameCamera(input(delta: 0.1)).fade, 0)
    }
}

extension SceneCameraTests {
    /// WE 2.8.0.42 ignores `general.zoom` in a perspective scene: a static box renders pixel
    /// identical at zoom 1 and 2, and Workshop 3657770939 keeps its static elements' size
    /// (we-test-wp-images @ 2aad5f2, tools/peer/requests/owe-beta3). The frame camera is the same.
    func testPerspectiveSceneIgnoresGeneralZoom() {
        func camera(zoom: Double) -> SceneFrameCamera {
            var spatial = SceneSpatialContent()
            spatial.camera.projection = .perspective
            spatial.camera.zoom = zoom
            let input = SceneCameraRigInput(sceneSize: SIMD2(1920, 1080), aspect: 16.0 / 9, time: 0, deltaTime: 1.0 / 30)
            return ScenePerspectiveCameraRig(spatial, values: SpatialProperties()).frameCamera(input)
        }
        let plain = camera(zoom: 1)
        XCTAssertTrue(plain.isPerspective)
        XCTAssertEqual(camera(zoom: 2), plain)
        XCTAssertEqual(camera(zoom: 0.5), plain)
    }
}
