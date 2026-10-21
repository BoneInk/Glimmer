import JavaScriptCore
import simd
import XCTest
@testable import OpenWallpaperEngine

/// `TestSceneScriptCompiler` with the cursor callbacks exported.
private struct CursorTestCompiler: SceneScriptModuleCompiling {
    private static let exportNames = ["init", "update", "destroy", "cursorEnter", "cursorLeave", "cursorMove",
                                      "cursorDown", "cursorUp", "cursorClick", "cursorHitTest"]

    func compile(_ source: String) throws -> SceneScriptCompiledModule {
        let getters = Self.exportNames
            .map { "get \($0)() { return typeof \($0) === 'undefined' ? undefined : \($0); }" }
            .joined(separator: ", ")
        let header = "(function (__rt, __scope) { 'use strict'; var thisLayer = __scope.thisLayer, thisObject = __scope.thisObject; "
        return SceneScriptCompiledModule(factorySource: header + source + "\nreturn { \(getters) }; })")
    }
}

/// The cursor callbacks in a runtime (docs/scenescript-plan.md WP10): only the scripts of the hit
/// object, WE's event object, first in the frame, and the table-backed layers.
final class SceneScriptCursorExtensionTests: XCTestCase {
    /// Logs every cursor callback into `shared.log[<name>]` as "callback world local button".
    private static func loggingScript(_ name: String) -> String {
        """
        shared.log = shared.log || {};
        shared.log['\(name)'] = [];
        function log(kind, event) {
            shared.log['\(name)'].push(kind + ' ' + event.worldPosition.x + ',' + event.worldPosition.y + ' ' +
                event.localPosition.x + ',' + event.localPosition.y + ',' + event.localPosition.z + ' ' + event.button +
                ' ' + (event.worldPosition instanceof Vec3) + ' ' + (event.hitBox === undefined));
        }
        function update(value) { shared.log['\(name)'].push('update'); return value; }
        function cursorEnter(event) { log('enter', event); }
        function cursorLeave(event) { log('leave', event); }
        function cursorMove(event) { log('move', event); }
        function cursorDown(event) { log('down', event); }
        function cursorUp(event) { log('up', event); }
        function cursorClick(event) { log('click', event); }
        function cursorHitTest(event) { log('hitTest', event); }
        """
    }

    private let cursor = SceneScriptCursorExtension()

    private func makeRuntime() throws -> SceneScriptRuntime {
        try SceneScriptRuntime(host: TestSceneScriptHost(), compiler: CursorTestCompiler(), extensions: [cursor])
    }

    private func log(_ name: String, in runtime: SceneScriptRuntime) -> [String] {
        runtime.context.evaluateScript("shared.log['\(name)']")?.toArray() as? [String] ?? []
    }

    /// Two 100 × 100 quads at (0, 0) (slot 0, below) and (300, 0) (slot 1).
    private let layers = [
        SceneScriptCursorLayer(slot: 0, worldMatrix: sceneScriptCursorMatrix(translation: .zero), size: SIMD2(100, 100)),
        SceneScriptCursorLayer(slot: 1, worldMatrix: sceneScriptCursorMatrix(translation: SIMD2(300, 0)), size: SIMD2(100, 100)),
    ]

    private func publish(_ x: Float, down: Bool) {
        cursor.publish(SceneScriptCursorFrame(cursorWorldPosition: SIMD3(x, 25, 0), leftButtonDown: down, layers: layers))
    }

    func testOnlyTheHitObjectsScriptsHearTheClickWithWEsEventObject() throws {
        _ = try Fixtures.assets()
        let runtime = try makeRuntime()
        runtime.add(SceneScriptInstance(id: "a", source: Self.loggingScript("a"), objectSlot: 0))
        runtime.add(SceneScriptInstance(id: "b", source: Self.loggingScript("b"), objectSlot: 1))
        runtime.add(SceneScriptInstance(id: "b2", source: Self.loggingScript("b2"), objectSlot: 1))
        runtime.add(SceneScriptInstance(id: "scene", source: Self.loggingScript("scene")))
        runtime.load()

        publish(325, down: false)
        publish(325, down: true)
        XCTAssertEqual(log("b", in: runtime), [], "events wait for the next frame")
        runtime.frame(deltaTime: 1.0 / 60)
        publish(325, down: false)
        runtime.frame(deltaTime: 1.0 / 60)

        let expected = [
            "enter 325,25 75,25,0 0 true true", "move 325,25 75,25,0 0 true true", "down 325,25 75,25,0 0 true true",
            "update", "up 325,25 75,25,0 0 true true", "click 325,25 75,25,0 0 true true", "update",
        ]
        XCTAssertEqual(log("b", in: runtime), expected, "cursor events come before update, in the pass's order")
        XCTAssertEqual(log("b2", in: runtime), expected, "every script of the object")
        XCTAssertEqual(log("a", in: runtime), ["update", "update"], "another object's scripts hear nothing")
        XCTAssertEqual(log("scene", in: runtime), ["update", "update"], "nor do scene-level scripts")
        XCTAssertFalse(log("b", in: runtime).contains { $0.hasPrefix("hitTest") }, "WE never sends cursorHitTest")
    }

    func testAHitBoxNameReachesTheEventObject() throws {
        _ = try Fixtures.assets()
        let runtime = try makeRuntime()
        runtime.add(SceneScriptInstance(id: "p", source: """
            shared.boxes = [];
            function cursorDown(event) { shared.boxes.push(String(event.hitBox)); }
            function cursorEnter(event) { shared.boxes.push(String(event.hitBox)); }
            """, objectSlot: 0))
        runtime.load()
        let box = SceneScriptCursorShape.HitBox(name: "head", halfExtents: SIMD3(repeating: 1000), matrix: matrix_identity_float4x4)
        let puppet = SceneScriptCursorLayer(slot: 0, worldMatrix: sceneScriptCursorMatrix(translation: .zero), size: SIMD2(100, 100),
                                            hitBoxes: .init(boxes: [box], order: [0], boneWorlds: [matrix_identity_float4x4]))
        cursor.publish(SceneScriptCursorFrame(cursorWorldPosition: SIMD3(10, 10, 0), leftButtonDown: false, layers: [puppet]))
        cursor.publish(SceneScriptCursorFrame(cursorWorldPosition: SIMD3(10, 10, 0), leftButtonDown: true, layers: [puppet]))
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(runtime.context.evaluateScript("shared.boxes")?.toArray() as? [String], ["undefined", "head"],
                       "named only on the frame the button changed")
    }

    func testEachScriptGetsItsOwnEventObject() throws {
        _ = try Fixtures.assets()
        let runtime = try makeRuntime()
        let mutating = """
            shared.seen = shared.seen || [];
            function cursorEnter(event) { shared.seen.push(event.worldPosition.x); event.worldPosition.x = -1; }
            """
        runtime.add(SceneScriptInstance(id: "a", source: mutating, objectSlot: 1))
        runtime.add(SceneScriptInstance(id: "b", source: mutating, objectSlot: 1))
        runtime.load()
        publish(325, down: false)
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(runtime.context.evaluateScript("shared.seen")?.toArray() as? [Double], [325, 325])
    }

    func testAThrowingCursorCallbackIsDisabledOnlyForItsScript() throws {
        _ = try Fixtures.assets()
        let runtime = try makeRuntime()
        runtime.add(SceneScriptInstance(id: "a", source: """
            shared.clicks = 0; shared.moves = 0;
            function cursorClick(event) { shared.clicks += 1; throw new Error('boom'); }
            function cursorMove(event) { shared.moves += 1; }
            """, objectSlot: 1))
        runtime.load()
        for x: Float in [310, 320] {
            publish(x, down: true)
            publish(x, down: false)
            runtime.frame(deltaTime: 1.0 / 60)
        }
        XCTAssertEqual(runtime.context.evaluateScript("shared.clicks")?.toInt32(), 1, "WE disables the callback that threw")
        XCTAssertEqual(runtime.context.evaluateScript("shared.moves")?.toInt32(), 2, "its other callbacks keep running")
    }

    func testNothingIsPostedAfterTearDown() throws {
        let runtime = try makeRuntime()
        runtime.load()
        runtime.tearDown()
        publish(325, down: false)
        XCTAssertTrue(runtime.inbox.drain().isEmpty)
    }

    func testAPausedWallpaperKeepsEveryClickAndTheNewestMove() {
        var events: [SceneScriptEvent] = []
        for index in 0..<(SceneScriptInbox.capacity + 10) {
            let callback: SceneScriptCursorEvent.Callback = index % 2 == 0 ? .cursorMove : .cursorClick
            events.append(SceneScriptCursorEvent(callback: callback, slot: 1, worldPosition: SIMD3(Float(index), 0, 0),
                                                 localPosition: .zero).inboxEvent)
        }
        let compacted = SceneScriptInbox.compacted(events)
        XCTAssertEqual(compacted.filter { $0.kind == .cursorMove }.count, 1)
        XCTAssertEqual(compacted.filter { $0.kind == .cursor }.count, (SceneScriptInbox.capacity + 10) / 2)
    }

    func testLayersReadFromTheObjectTable() throws {
        let context = try XCTUnwrap(JSContext())
        let table = try XCTUnwrap(SceneScriptObjectTable(capacity: 4, in: context))
        for slot in 0..<4 { table.reset(slot: slot, with: [:]) }
        table[1, .size] = [100, 50]
        table[1, .origin] = [300, 20, 0]
        table[1, .parallaxDepth] = [0.5, 2]
        let matrix = sceneScriptCursorMatrix(translation: SIMD2(300, 20), degrees: 90, scale: SIMD2(2, 1))
        let base = SceneScriptObjectTable.index(slot: 1, field: SceneScriptObjectTable.Layout.worldMatrix)
        for column in 0..<4 {
            for row in 0..<4 { table.values[base + column * 4 + row] = matrix[column][row] }
        }
        table[2, .solid] = [0]
        table[3, .visible] = [0]
        let parents = [1: 3]

        let layers = SceneScriptCursorLayer.layers(
            in: table, drawOrder: [.init(slot: 1, disablesPropagation: true), .init(slot: 2), .init(slot: 9)],
            parentOf: { parents[$0] })
        XCTAssertEqual(layers.map(\.slot), [1, 2], "slots outside the table are skipped")
        let layer = layers[0]
        XCTAssertEqual(layer.worldMatrix, matrix)
        XCTAssertEqual(layer.size, SIMD2(100, 50))
        XCTAssertEqual(layer.origin, SIMD2(300, 20))
        XCTAssertEqual(layer.parallaxDepth, SIMD2(0.5, 2))
        XCTAssertTrue(layer.isSolid, "WE's objects are solid unless they say otherwise")
        XCTAssertTrue(layer.disablesPropagation)
        XCTAssertFalse(layer.isVisible, "its parent is hidden")
        XCTAssertFalse(layer.stopsPropagation)
        XCTAssertFalse(layers[1].isSolid)
        XCTAssertTrue(layers[1].isVisible)
    }

    func testSceneObjectsDecodeDisablePropagation() throws {
        let json = #"{"id": 7, "name": "button", "disablepropagation": true, "solid": false}"#
        let object = try JSONDecoder().decode(WESceneObject.self, from: Data(json.utf8))
        XCTAssertEqual(object.disablepropagation, true)
        XCTAssertEqual(object.solid, false)
        let plain = try JSONDecoder().decode(WESceneObject.self, from: Data(#"{"id": 8, "name": "plain"}"#.utf8))
        XCTAssertNil(plain.disablepropagation)
    }
}
