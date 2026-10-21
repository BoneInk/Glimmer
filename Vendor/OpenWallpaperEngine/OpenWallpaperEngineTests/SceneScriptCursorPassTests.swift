import simd
import XCTest
@testable import OpenWallpaperEngine

/// WE's cursor pass (wallpaper64.exe 0x140189e10): event sequences, pairing, dragging, and the
/// top-down walk with `disablepropagation`.
final class SceneScriptCursorPassTests: XCTestCase {
    /// A 100 × 100 quad centred at `x`, 0.
    private func quad(_ slot: Int, x: Float = 0, solid: Bool = true, stops: Bool = false,
                      visible: Bool = true) -> SceneScriptCursorLayer {
        SceneScriptCursorLayer(slot: slot, worldMatrix: sceneScriptCursorMatrix(translation: SIMD2(x, 0)), size: SIMD2(100, 100),
                         isSolid: solid, disablesPropagation: stops, isVisible: visible)
    }

    private var pass = SceneScriptCursorPass()

    /// Runs one frame and returns its events as "callback slot".
    private func step(_ x: Float, down: Bool = false, _ layers: [SceneScriptCursorLayer]) -> [String] {
        let frame = SceneScriptCursorFrame(cursorWorldPosition: SIMD3(x, 0, 0), leftButtonDown: down, layers: layers)
        return pass.update(frame).map { "\($0.callback.rawValue) \($0.slot)" }
    }

    func testEnterMoveAndLeave() {
        let layers = [quad(1)]
        XCTAssertEqual(step(500, layers), [], "off the quad")
        XCTAssertEqual(step(10, layers), ["cursorEnter 1", "cursorMove 1"])
        XCTAssertEqual(step(10, layers), [], "a still cursor sends nothing")
        XCTAssertEqual(step(20, layers), ["cursorMove 1"])
        XCTAssertEqual(step(500, layers), ["cursorLeave 1"])
        XCTAssertEqual(step(600, layers), [])
    }

    func testPressAndReleaseOnTheSameObjectClicks() {
        let layers = [quad(1)]
        _ = step(10, layers)
        XCTAssertEqual(step(10, down: true, layers), ["cursorDown 1"])
        XCTAssertEqual(pass.pressedSlots, [1])
        XCTAssertEqual(step(10, down: true, layers), [], "holding still sends nothing")
        XCTAssertEqual(step(10, down: false, layers), ["cursorUp 1", "cursorClick 1"])
        XCTAssertEqual(pass.pressedSlots, [])
    }

    func testReleasingElsewhereSendsUpWithoutClickAndDraggingSuspendsHover() {
        let layers = [quad(1, x: 0), quad(2, x: 300)]
        XCTAssertEqual(step(0, down: true, layers), ["cursorEnter 1", "cursorMove 1", "cursorDown 1"])
        XCTAssertEqual(step(300, down: true, layers), ["cursorMove 1"],
                       "while dragging only the pressed object hears moves; no leave, no enter")
        XCTAssertEqual(step(310, down: true, layers), ["cursorMove 1"])
        XCTAssertEqual(step(310, down: false, layers), ["cursorEnter 2", "cursorUp 2", "cursorUp 1", "cursorLeave 1"],
                       "released over 2: up there, and up (no click) for the pressed object 1")
        XCTAssertEqual(step(310, down: true, layers), ["cursorDown 2"])
        XCTAssertEqual(step(310, down: false, layers), ["cursorUp 2", "cursorClick 2"])
    }

    func testPressingOffEveryObjectPressesNothing() {
        let layers = [quad(1)]
        XCTAssertEqual(step(500, down: true, layers), [])
        XCTAssertEqual(step(10, down: true, layers), ["cursorEnter 1", "cursorMove 1"], "not a drag: nothing was pressed")
        XCTAssertEqual(step(10, down: false, layers), ["cursorUp 1"], "released over it: up, but no click")
    }

    func testOverlappingObjectsHearTopmostFirst() {
        let layers = [quad(1), quad(2), quad(3, solid: false)]
        XCTAssertEqual(step(0, layers), ["cursorEnter 2", "cursorMove 2", "cursorEnter 1", "cursorMove 1"],
                       "draw order bottom first: 2 is above 1; 3 is not solid")
        XCTAssertEqual(step(0, down: true, layers), ["cursorDown 2", "cursorDown 1"])
        XCTAssertEqual(step(0, down: false, layers), ["cursorUp 2", "cursorClick 2", "cursorUp 1", "cursorClick 1"])
    }

    func testDisablePropagationOnAVisibleHitStopsThePass() {
        let layers = [quad(1), quad(2, stops: true)]
        XCTAssertEqual(step(0, layers), ["cursorEnter 2", "cursorMove 2"])
        XCTAssertEqual(pass.hoveredSlots, [2])
        // Off 2 but the pass never reached 1 while 2 blocked it; nothing to leave there.
        XCTAssertEqual(step(500, layers), ["cursorLeave 2"])

        let below = [quad(1, x: 0), quad(2, x: 80, stops: true)]
        XCTAssertEqual(step(10, below), ["cursorEnter 1", "cursorMove 1"])
        XCTAssertEqual(step(40, below), ["cursorEnter 2", "cursorMove 2"],
                       "1 is still under the cursor but not visited: no move and no leave")
        XCTAssertEqual(pass.hoveredSlots, [1, 2])
        XCTAssertEqual(step(-40, below), ["cursorLeave 2", "cursorMove 1"])
    }

    func testHiddenObjectsAreHitButDoNotStopThePass() {
        let layers = [quad(1), quad(2, stops: true, visible: false)]
        XCTAssertEqual(step(0, layers), ["cursorEnter 2", "cursorMove 2", "cursorEnter 1", "cursorMove 1"])
    }

    func testAnObjectThatIsGoneIsForgotten() {
        _ = step(0, [quad(1)])
        XCTAssertEqual(step(0, []), [])
        XCTAssertEqual(pass.hoveredSlots, [])
        XCTAssertEqual(step(0, [quad(1)]), ["cursorEnter 1"], "a slot that comes back is entered again")
    }

    func testEventsCarryTheWorldAndLocalPositions() {
        let frame = SceneScriptCursorFrame(cursorWorldPosition: SIMD3(25, -25, 3), leftButtonDown: false, layers: [quad(4)])
        let events = pass.update(frame)
        XCTAssertEqual(events.first, SceneScriptCursorEvent(callback: .cursorEnter, slot: 4, worldPosition: SIMD3(25, -25, 3),
                                                      localPosition: SIMD3(75, 75, 0)))
    }
}
