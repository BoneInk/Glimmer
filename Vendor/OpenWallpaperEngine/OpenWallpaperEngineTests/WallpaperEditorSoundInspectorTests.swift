import XCTest
import OWESceneEditing
@testable import OpenWallpaperEngine

/// The Wallpaper Editor's sound inspector reaches the player: the fields the session writes
/// into the overlay are what the scene's sound layer decodes.
@MainActor
final class WallpaperEditorSoundInspectorTests: XCTestCase {
    private static let sceneJSON = """
    {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
     "general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
     "objects": [{"id": 5, "name": "Rain", "sound": ["sounds/rain.mp3"], "playbackmode": "loop", "volume": 0.8}]}
    """

    func testTheSoundFieldsAreWhatThePlayerReads() throws {
        let data = Data(Self.sceneJSON.utf8)
        let session = SceneEditSession(outline: try SceneOutline(sceneData: data))
        session.setValue(.string("random"), for: "playbackmode", of: 5, actionName: "Change Mode")
        session.setValue(.number(0.4), for: "volume", of: 5, actionName: "Change Volume")
        session.setValue(.number(2), for: "mintime", of: 5, actionName: "Change Min Time")
        session.setValue(.number(8), for: "maxtime", of: 5, actionName: "Change Max Time")
        session.setValue(.bool(true), for: "muteineditor", of: 5, actionName: "Change Mute in Editor")
        session.setValue(.bool(true), for: "startsilent", of: 5, actionName: "Change Start Silent")
        session.setValue(.bool(true), for: "spatialization", of: 5, actionName: "Change Spatialization")
        session.setValue(.number(300), for: "mindistance", of: 5, actionName: "Change Distance")
        session.setValue(.number(2), for: "attenuation", of: 5, actionName: "Change Attenuation")

        let scene = try JSONDecoder().decode(WEScene.self, from: try session.overlay.applied(to: data))
        let sound = try XCTUnwrap(scene.objects.first?.sound)
        XCTAssertEqual(sound.files, ["sounds/rain.mp3"])
        XCTAssertEqual(sound.playbackMode, .random)
        XCTAssertEqual(sound.volume, .number(0.4))
        XCTAssertEqual(sound.minTime, 2)
        XCTAssertEqual(sound.maxTime, 8)
        XCTAssertTrue(sound.muteInEditor)
        XCTAssertTrue(sound.startSilent)
        XCTAssertTrue(sound.spatialization)
        XCTAssertEqual(sound.minDistance, .number(300))
        XCTAssertEqual(sound.attenuation, .number(2))
    }
}
