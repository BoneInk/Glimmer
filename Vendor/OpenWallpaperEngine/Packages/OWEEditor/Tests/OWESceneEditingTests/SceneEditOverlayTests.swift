import XCTest
@testable import OWESceneEditing

/// The overlay applied on top of scene.json, and written and read back.
final class SceneEditOverlayTests: XCTestCase {
    func testAppliesObjectFieldsAndKeepsTheRest() throws {
        var overlay = SceneEditOverlay()
        overlay.setField("origin", to: .string("100 200 0"), of: 10)
        overlay.setField("alpha", to: .number(0.5), of: 10)
        overlay.setField("colorBlendMode", to: .number(3), of: 10)
        let applied = try overlay.applied(to: Fixtures.sceneData)
        let background = try Fixtures.object(10, in: applied)
        XCTAssertEqual(background["origin"] as? String, "100 200 0")
        XCTAssertEqual((background["alpha"] as? NSNumber)?.doubleValue, 0.5)
        XCTAssertEqual((background["colorBlendMode"] as? NSNumber)?.intValue, 3, "a whole number is written as an integer")
        XCTAssertEqual(background["size"] as? String, "1920.00000 1080.00000", "fields not edited stay as authored")
        let clock = try Fixtures.object(11, in: applied)
        XCTAssertEqual(clock["origin"] as? String, "100 50 0", "other objects stay as authored")
    }

    func testObjectWithoutAnIDIsKeyedByItsIndex() throws {
        var overlay = SceneEditOverlay()
        overlay.setField("visible", to: .bool(false), of: 2)
        let applied = try overlay.applied(to: Fixtures.sceneData)
        XCTAssertEqual(try Fixtures.object(2, in: applied)["visible"] as? Bool, false)
    }

    func testDrivenFieldKeepsItsScriptAndTakesTheNewStartingValue() throws {
        var overlay = SceneEditOverlay()
        overlay.setField("origin", to: .string("10 20 0"), of: 14)
        let origin = try Fixtures.object(14, in: try overlay.applied(to: Fixtures.sceneData))["origin"] as? [String: Any]
        XCTAssertEqual(origin?["value"] as? String, "10 20 0")
        XCTAssertNotNil(origin?["script"], "the script still runs")
    }

    func testEffectVisibilityAndConstants() throws {
        var overlay = SceneEditOverlay()
        overlay.setEffectVisible(false, effect: 0, of: 10)
        overlay.setEffectConstant("speed", to: .number(3), effect: 0, of: 10)
        overlay.setEffectConstant("ripplescale", to: .number(2), effect: 0, of: 10)
        overlay.setEffectVisible(false, effect: 1, of: 10)
        overlay.setEffectVisible(false, effect: 7, of: 10)
        let effects = try Fixtures.object(10, in: try overlay.applied(to: Fixtures.sceneData))["effects"] as! [[String: Any]]
        XCTAssertEqual(effects.count, 2, "an effect the scene doesn't have is skipped")
        XCTAssertEqual(effects[0]["visible"] as? Bool, false)
        let constants = (effects[0]["passes"] as! [[String: Any]])[0]["constantshadervalues"] as! [String: Any]
        XCTAssertEqual((constants["Speed"] as? NSNumber)?.doubleValue, 3, "the authored key's spelling is kept")
        XCTAssertNil(constants["speed"])
        XCTAssertEqual((constants["ripplescale"] as? NSNumber)?.doubleValue, 2)
        let bound = effects[1]["visible"] as? [String: Any]
        XCTAssertEqual(bound?["user"] as? String, "showblur", "a user-bound value keeps its binding")
        XCTAssertEqual(bound?["value"] as? Bool, false)
    }

    func testNoSceneEditsLeavesTheDataUntouched() throws {
        var overlay = SceneEditOverlay()
        overlay.setLocked(true, 10)
        XCTAssertFalse(overlay.hasSceneEdits)
        XCTAssertEqual(try overlay.applied(to: Fixtures.sceneData), Fixtures.sceneData)
    }

    func testNotASceneThrows() {
        var overlay = SceneEditOverlay()
        overlay.setField("alpha", to: .number(0), of: 1)
        XCTAssertThrowsError(try overlay.applied(to: Data("[1, 2]".utf8)))
    }

    func testRoundTripsThroughItsFile() throws {
        var overlay = SceneEditOverlay()
        overlay.setField("origin", to: .string("1 2 3"), of: 10)
        overlay.setField("alpha", to: .number(0.25), of: 11)
        overlay.setField("visible", to: .bool(false), of: 2)
        overlay.setField("custom", to: .object(["a": .array([.number(1), .null, .string("x")])]), of: 13)
        overlay.setEffectConstant("Speed", to: .number(2), effect: 0, of: 10)
        overlay.setEffectVisible(true, effect: 1, of: 10)
        overlay.setLocked(true, 14)
        let data = try overlay.encoded()
        XCTAssertEqual(try SceneEditOverlay.decoded(from: data), overlay)
        XCTAssertEqual(try SceneEditOverlay.decoded(from: data).encoded(), data, "the same edits write the same bytes")
    }

    func testANewerFileIsRefused() {
        let data = Data(#"{"version": 99, "objects": {}}"#.utf8)
        XCTAssertThrowsError(try SceneEditOverlay.decoded(from: data)) { error in
            XCTAssertEqual(error as? SceneEditOverlayError, .newerVersion(99))
        }
    }

    func testDroppingTheLastEditDropsTheObject() {
        var overlay = SceneEditOverlay()
        overlay.setField("alpha", to: .number(0.5), of: 10)
        overlay.setEffectVisible(false, effect: 0, of: 10)
        overlay.setField("alpha", to: nil, of: 10)
        overlay.setEffectVisible(nil, effect: 0, of: 10)
        XCTAssertTrue(overlay.isEmpty)
        XCTAssertTrue(overlay.objects.isEmpty)
    }

    func testDigestFollowsSceneEditsOnly() {
        var a = SceneEditOverlay()
        a.setField("alpha", to: .number(0.5), of: 10)
        var b = a
        b.setLocked(true, 10)
        XCTAssertEqual(a.digest, b.digest, "locking a layer doesn't change the scene")
        b.setField("alpha", to: .number(0.6), of: 10)
        XCTAssertNotEqual(a.digest, b.digest)
    }

    func testStoreSavesLoadsAndRemoves() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SceneEditOverlayStore(directory: directory.appending(path: "editor"))
        XCTAssertNil(try store.overlay(for: "workshop-1"))
        var overlay = SceneEditOverlay()
        overlay.setField("alpha", to: .number(0.5), of: 10)
        try store.save(overlay, for: "workshop-1")
        XCTAssertEqual(try store.overlay(for: "workshop-1"), overlay)
        try store.save(SceneEditOverlay(), for: "workshop-1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: "workshop-1").path),
                       "an empty overlay leaves no file")
    }

    func testStoreFileNamesStayInTheFolder() {
        let store = SceneEditOverlayStore(directory: URL(fileURLWithPath: "/tmp/editor"))
        XCTAssertEqual(store.fileURL(for: "../../etc/passwd").deletingLastPathComponent().path, "/tmp/editor")
        XCTAssertEqual(store.fileURL(for: "local-ab12-My Wallpaper").lastPathComponent, "local-ab12-My Wallpaper.json")
    }

    func testFieldBindings() {
        XCTAssertEqual(SceneFieldBinding(nil), .absent)
        XCTAssertEqual(SceneFieldBinding(.string("1 2 3")), .literal)
        XCTAssertEqual(SceneFieldBinding(.object(["user": .string("showlogo"), "value": .bool(true)])), .userProperty("showlogo"))
        XCTAssertEqual(SceneFieldBinding(.object(["user": .object(["name": .string("p"), "condition": .string("1")])])),
                       .userProperty("p"))
        XCTAssertEqual(SceneFieldBinding(.object(["script": .string("…"), "value": .number(1)])), .driven)
        XCTAssertEqual(SceneFieldBinding.literal(of: .object(["animation": .number(3), "value": .string("1 1 1")])),
                       .string("1 1 1"))
    }

    func testJSONValuesKeepBooleansApartFromNumbers() {
        XCTAssertEqual(SceneJSONValue(any: true as NSNumber), .bool(true))
        XCTAssertEqual(SceneJSONValue(any: 1 as NSNumber), .number(1))
        XCTAssertEqual(SceneVector.string([960, 540.5, -0.0000001]), "960 540.5 0")
        XCTAssertEqual(SceneVector.components(.string("1.00000 2.5 3")), [1, 2.5, 3])
        XCTAssertEqual(SceneVector.components(.object(["x": .number(1), "y": .number(2)])), [1, 2])
    }

    /// WE's vector text splits at spaces and commas (tabs and newlines too where asked); a token
    /// that isn't a number is skipped by `numbers`.
    func testVectorTextTokensAndNumbers() {
        XCTAssertEqual(SceneVector.tokens(" 1, 2  x\t3"), ["1", "2", "x\t3"])
        XCTAssertEqual(SceneVector.tokens("1\t2\n3,4", separatedBy: .whitespaceAndCommas), ["1", "2", "3", "4"])
        XCTAssertEqual(SceneVector.numbers("1 x 2,3"), [1, 2, 3])
        XCTAssertEqual(SceneVector.floats("0.1 y"), [Float(0.1)])
    }
}
