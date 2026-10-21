import XCTest
@testable import OWESceneEditing

/// A sound layer's fields through the overlay, as WE's sound properties write them: the mode,
/// the volume (left alone where a user property sets it), the random mode's times, mute in
/// editor, start silent and spatialization; WE's defaults are no edit; one undo step each.
@MainActor
final class SoundLayerEditTests: XCTestCase {
    private static let sceneJSON = """
    {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
     "general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
     "objects": [{"id": 5, "name": "Rain", "sound": ["sounds/rain.mp3"], "playbackmode": "loop", "volume": 0.8},
                 {"id": 6, "name": "Music", "sound": ["sounds/music.mp3"], "volume": {"user": "musicvolume", "value": 0.5}}]}
    """
    private var session: SceneEditSession!
    private var sceneData: Data { Data(Self.sceneJSON.utf8) }

    override func setUp() async throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        session = SceneEditSession(outline: try SceneOutline(sceneData: sceneData), undoManager: undoManager)
    }

    func testTheSoundFieldsReachTheScene() throws {
        session.setValue(.string("random"), for: "playbackmode", of: 5, actionName: "Change")
        session.setValue(.number(0.4), for: "volume", of: 5, actionName: "Change")
        session.setValue(.number(2), for: "mintime", of: 5, actionName: "Change")
        session.setValue(.number(8), for: "maxtime", of: 5, actionName: "Change")
        session.setValue(.bool(true), for: "muteineditor", of: 5, actionName: "Change")
        session.setValue(.bool(true), for: "startsilent", of: 5, actionName: "Change")
        session.setValue(.bool(true), for: "spatialization", of: 5, actionName: "Change")
        session.setValue(.number(300), for: "mindistance", of: 5, actionName: "Change")
        let rain = try Fixtures.object(5, in: try session.overlay.applied(to: sceneData))
        XCTAssertEqual(rain["playbackmode"] as? String, "random")
        XCTAssertEqual(rain["volume"] as? Double, 0.4)
        XCTAssertEqual(rain["mintime"] as? Double, 2)
        XCTAssertEqual(rain["maxtime"] as? Double, 8)
        XCTAssertEqual(rain["muteineditor"] as? Bool, true)
        XCTAssertEqual(rain["startsilent"] as? Bool, true)
        XCTAssertEqual(rain["spatialization"] as? Bool, true)
        XCTAssertEqual(rain["mindistance"] as? Double, 300)
        XCTAssertEqual(rain["sound"] as? [String], ["sounds/rain.mp3"], "the samples stay")
        for _ in 0..<8 { session.undo() }
        XCTAssertTrue(session.overlay.isEmpty, "one undo step each")
    }

    func testWEsDefaultsAreNoEdit() {
        session.setValue(.string("loop"), for: "playbackmode", of: 5, actionName: "Change")
        session.setValue(.number(0.8), for: "volume", of: 5, actionName: "Change")
        session.setValue(.number(1), for: "mintime", of: 5, actionName: "Change")
        session.setValue(.number(5), for: "maxtime", of: 5, actionName: "Change")
        session.setValue(.bool(false), for: "startsilent", of: 5, actionName: "Change")
        session.setValue(.bool(false), for: "spatialization", of: 5, actionName: "Change")
        XCTAssertTrue(session.overlay.isEmpty)
    }

    func testAVolumeAUserPropertySetsIsNotEdited() {
        XCTAssertEqual(session.binding("volume", of: 6), .userProperty("musicvolume"))
        session.setValue(.number(0.2), for: "volume", of: 6, actionName: "Change")
        XCTAssertTrue(session.overlay.isEmpty)
    }
}
