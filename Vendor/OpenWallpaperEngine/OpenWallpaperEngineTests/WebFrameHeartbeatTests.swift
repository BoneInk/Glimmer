import XCTest
@testable import OpenWallpaperEngine

/// Web wallpapers report `requestAnimationFrame` intervals to the render watchdog.
final class WebFrameHeartbeatTests: XCTestCase {
    func testFrameIntervalsDecodeFromTheMessageBody() {
        XCTAssertEqual(WebWallpaperPropertyBridge.frameIntervals(from: [0.016, 0.5, NSNumber(value: 0.02)]), [0.016, 0.5, 0.02])
        XCTAssertEqual(WebWallpaperPropertyBridge.frameIntervals(from: ["x", -1, Double.nan, 0.1] as [Any]), [0.1])
        XCTAssertEqual(WebWallpaperPropertyBridge.frameIntervals(from: "nope"), [])
    }

    func testHeartbeatDecodesVisibilityAndIntervals() {
        XCTAssertEqual(WebWallpaperPropertyBridge.heartbeat(from: ["visible": true, "intervals": [0.016, "x"]] as [String: Any]),
                       .init(visible: true, intervals: [0.016]))
        XCTAssertEqual(WebWallpaperPropertyBridge.heartbeat(from: ["visible": false, "intervals": []] as [String: Any]),
                       .init(visible: false, intervals: []), "a hidden page still beats")
        XCTAssertNil(WebWallpaperPropertyBridge.heartbeat(from: [0.016]), "the old message shape is not a heartbeat")
        XCTAssertNil(WebWallpaperPropertyBridge.heartbeat(from: ["intervals": [0.016]]))
    }

    func testHeartbeatGateOpensOnlyWhileShowing() {
        var gate = WebHeartbeatGate()
        XCTAssertTrue(gate.expectsHeartbeats)
        gate.windowVisible = false
        XCTAssertFalse(gate.expectsHeartbeats)
        gate.windowVisible = true
        gate.displaysAwake = false
        XCTAssertFalse(gate.expectsHeartbeats)
        gate.displaysAwake = true
        gate.pageVisible = false
        XCTAssertFalse(gate.expectsHeartbeats)
    }

    /// The bootstrap posts every second, not only when it has frames: silence is the hang signal.
    func testBootstrapPostsEverySecondWithVisibility() {
        let script = WebWallpaperPropertyBridge.bootstrapScript
        XCTAssertFalse(script.contains("if (!intervals.length) return;"))
        XCTAssertTrue(script.contains("visible: document.visibilityState === 'visible'"))
    }

    func testBootstrapPostsFrameIntervals() {
        XCTAssertTrue(WebWallpaperPropertyBridge.bootstrapScript.contains(WebWallpaperPropertyBridge.frameMessageName))
        XCTAssertTrue(WebWallpaperPropertyBridge.bootstrapScript.contains("requestAnimationFrame"))
    }

    func testAPageHeldForTheScreenSaverIsSeenWhateverCoversIt() {
        var gate = WebHeartbeatGate()
        gate.windowVisible = false
        gate.playing = false
        gate.heldForScreenSaver = true
        XCTAssertTrue(gate.expectsHeartbeats)
    }
}
