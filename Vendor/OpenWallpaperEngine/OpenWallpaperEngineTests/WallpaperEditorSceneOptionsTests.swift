import XCTest
import OWESceneEditing
@testable import OpenWallpaperEngine

/// The Wallpaper Editor's Scene Options and Project Settings reach the player: each setting the
/// session writes into the overlay's `general` is what the scene's decoded settings read (bloom
/// and HDR bloom, colours, camera, shake and parallax, fog, sorting, resolution).
@MainActor
final class WallpaperEditorSceneOptionsTests: XCTestCase {
    private static let sceneJSON = """
    {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
     "general": {"orthogonalprojection": {"width": 1920, "height": 1080}, "clearcolor": "0 0 0"},
     "objects": [{"id": 1, "image": "models/bg.json", "size": "1920 1080", "origin": "960 540 0"}]}
    """

    private struct NoValues: SceneValueContext {
        func userProperty(_ name: String) -> String? { nil }
    }

    private func readBack(_ session: SceneEditSession) throws -> WEScene {
        let data = try session.overlay.applied(to: Data(Self.sceneJSON.utf8))
        return try JSONDecoder().decode(WEScene.self, from: data)
    }

    func testTheSceneOptionsAreWhatThePlayerReads() throws {
        let session = SceneEditSession(outline: try SceneOutline(sceneData: Data(Self.sceneJSON.utf8)))
        let change = "Change Scene Options"
        session.setGeneral(.bool(false), for: "bloom", actionName: change)
        session.setGeneral(.number(1.25), for: "bloomstrength", actionName: change)
        session.setGeneral(.number(0.4), for: "bloomthreshold", actionName: change)
        session.setGeneral(.string("1 0.5 0.25"), for: "bloomtint", actionName: change)
        session.setGeneral(.bool(true), for: "hdr", actionName: change)
        session.setGeneral(.number(3), for: "bloomhdrstrength", actionName: change)
        session.setGeneral(.number(6), for: "bloomhdriterations", actionName: change)
        session.setGeneral(.string("0.1 0.2 0.3"), for: "clearcolor", actionName: change)
        session.setGeneral(.string("0.3 0.3 0.3"), for: "ambientcolor", actionName: change)
        session.setGeneral(.string("0.5 0.6 0.7"), for: "skylightcolor", actionName: change)
        session.setGeneral(.bool(true), for: "transparentsorting", actionName: change)
        session.setGeneral(.number(60), for: "perspectiveoverridefov", actionName: change)
        session.setGeneral(.number(0.5), for: "nearz", actionName: change)
        session.setGeneral(.number(5000), for: "farz", actionName: change)
        session.setGeneral(.number(1.5), for: "zoom", actionName: change)
        session.setGeneral(.bool(true), for: "camerashake", actionName: change)
        session.setGeneral(.number(0.9), for: "camerashakeamplitude", actionName: change)
        session.setGeneral(.bool(true), for: "cameraparallax", actionName: change)
        session.setGeneral(.number(0.7), for: "cameraparallaxamount", actionName: change)
        session.setGeneral(.number(0.3), for: "cameraparallaxmouseinfluence", actionName: change)
        session.setGeneral(.bool(true), for: "fogdistance", actionName: change)
        session.setGeneral(.number(2), for: "fogdistancestart", actionName: change)
        session.setGeneral(.number(9), for: "fogdistanceend", actionName: change)
        session.setGeneral(.bool(true), for: "fogheight", actionName: change)
        session.setGeneral(.string("1 1 1"), for: "fogheightcolor", actionName: change)
        session.setGeneral(.number(0.25), for: "fogheightenddensity", actionName: change)

        let scene = try readBack(session)
        let context = NoValues()
        let bloom = SceneBloomSettings(scene.general, in: context)
        XCTAssertFalse(bloom.enabled)
        XCTAssertEqual(bloom.strength, 1.25)
        XCTAssertEqual(bloom.threshold, 0.4, accuracy: 1e-6)
        XCTAssertEqual(bloom.tint, SIMD3<Float>(1, 0.5, 0.25))
        XCTAssertTrue(bloom.hdr.enabled)
        XCTAssertEqual(bloom.hdr.strength, 3)
        XCTAssertEqual(bloom.hdr.iterations, 6)
        XCTAssertEqual(scene.general.clearColor(in: context), SIMD3<Float>(0.1, 0.2, 0.3))

        let lighting = SceneLightingSettings(scene.general, in: context)
        XCTAssertEqual(lighting.ambient, SIMD3<Float>(repeating: 0.3))
        XCTAssertEqual(lighting.skylight, SIMD3<Float>(0.5, 0.6, 0.7))
        XCTAssertTrue(lighting.fog.distance)
        XCTAssertEqual(lighting.fog.distanceStart, 2)
        XCTAssertEqual(lighting.fog.distanceEnd, 9)
        XCTAssertTrue(lighting.fog.height)
        XCTAssertEqual(lighting.fog.heightColor, SIMD3<Float>(repeating: 1))
        XCTAssertEqual(lighting.fog.heightEndDensity, 0.25)

        let camera = SceneCameraSettings(scene.general, in: context)
        XCTAssertEqual(camera.perspectiveOverrideFov, 60)
        XCTAssertEqual(camera.nearZ, 0.5, accuracy: 1e-6)
        XCTAssertEqual(camera.farZ, 5000)
        XCTAssertEqual(camera.zoom, 1.5)
        XCTAssertTrue(camera.transparentSorting)

        let effects = SceneCameraEffects(scene.general, in: context)
        XCTAssertTrue(effects.shake)
        XCTAssertEqual(effects.shakeAmplitude, 0.9, accuracy: 1e-6)
        XCTAssertTrue(effects.parallax)
        XCTAssertEqual(effects.parallaxAmount, 0.7, accuracy: 1e-6)
        XCTAssertEqual(effects.parallaxMouseInfluence, 0.3, accuracy: 1e-6)
    }

    func testTheResolutionIsTheScenesSize() throws {
        let session = SceneEditSession(outline: try SceneOutline(sceneData: Data(Self.sceneJSON.utf8)))
        session.setProjectResolution(SIMD2(2560, 1440), actionName: "Change Project Settings")
        let scene = try readBack(session)
        XCTAssertEqual(scene.general.projection, .orthographic(width: 2560, height: 1440))
    }
}
