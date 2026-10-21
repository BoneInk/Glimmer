import XCTest
import simd
@testable import OpenWallpaperEngine

/// The scene's camera paths as WE's camera update plays them (0x1401894a9…0x140189b07) and their
/// fade (0x140180c1a): the Hermite between keys, key and path sequencing, the loop, and WE's
/// arithmetic before the first key and at the last.
final class SceneCameraPathsTests: XCTestCase {
    private static let up = SIMD3<Float>(0, 1, 0)

    private static func key(_ time: Float, eye: SIMD3<Float>, center: SIMD3<Float> = .zero, zoom: Float = 1) -> WESceneCameraPath.Key {
        WESceneCameraPath.Key(timestamp: time, eye: eye, center: center, up: up, zoom: zoom)
    }

    /// `p0 + (p1 − p0)·(0.5t + 1.5t² − t³)`: the Hermite with both tangents (p1 − p0)/2.
    func testTheHermiteAtItsEndsAndMiddle() {
        XCTAssertEqual(SceneCameraPaths.hermiteWeight(0), 0)
        XCTAssertEqual(SceneCameraPaths.hermiteWeight(0.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(SceneCameraPaths.hermiteWeight(1), 1, accuracy: 1e-6)
        XCTAssertEqual(SceneCameraPaths.hermiteWeight(0.25), 0.125 + 1.5 * 0.0625 - 0.015625, accuracy: 1e-6)
        // The general cubic Hermite with m0 = m1 = (p1 − p0)/2 gives the same curve.
        for t in stride(from: Float(0), through: 1, by: 0.1) {
            let h00 = 2 * t * t * t - 3 * t * t + 1, h10 = t * t * t - 2 * t * t + t
            let h01 = -2 * t * t * t + 3 * t * t, h11 = t * t * t - t * t
            let p0: Float = 2, p1: Float = 7, m = (p1 - p0) / 2
            let hermite = h00 * p0 + h10 * m + h01 * p1 + h11 * m
            XCTAssertEqual(p0 + (p1 - p0) * SceneCameraPaths.hermiteWeight(t), hermite, accuracy: 1e-5, "t = \(t)")
        }
    }

    /// Sampled before the advance: frame n shows time n·dt, per component of eye, centre, up and zoom.
    func testAPathIsSampledAtEachFramesTimeThenAdvanced() throws {
        var paths = SceneCameraPaths([WESceneCameraPath(duration: 2, keys: [
            Self.key(0, eye: SIMD3(0, 0, 10), zoom: 1), Self.key(2, eye: SIMD3(4, 2, 10), center: SIMD3(1, 0, 0), zoom: 3)])])
        let first = try XCTUnwrap(paths.advance(by: 0.5))
        XCTAssertEqual(first.eye, SIMD3(0, 0, 10), "time 0: the first key")
        XCTAssertEqual(paths.time, 0.5)
        let second = try XCTUnwrap(paths.advance(by: 0.5))
        let weight = SceneCameraPaths.hermiteWeight(0.25)
        XCTAssertEqual(second.eye.x, 4 * weight, accuracy: 1e-5)
        XCTAssertEqual(second.eye.y, 2 * weight, accuracy: 1e-5)
        XCTAssertEqual(second.center.x, weight, accuracy: 1e-5)
        XCTAssertEqual(second.zoom, 1 + 2 * weight, accuracy: 1e-5)
        _ = paths.advance(by: 0.5)
        let middle = try XCTUnwrap(paths.advance(by: 0.5))
        XCTAssertEqual(middle.eye.x, 4 * SceneCameraPaths.hermiteWeight(0.75), accuracy: 1e-5, "time 1.5")
    }

    /// Past the last key's segment the next path starts at time 0; after the last path, the first.
    func testPathsPlayInOrderAndLoop() throws {
        let a = WESceneCameraPath(name: "a", duration: 1, keys: [Self.key(0, eye: SIMD3(1, 0, 0)), Self.key(1, eye: SIMD3(2, 0, 0))])
        let b = WESceneCameraPath(name: "b", duration: 1, keys: [Self.key(0, eye: SIMD3(10, 0, 0)), Self.key(1, eye: SIMD3(20, 0, 0))])
        var paths = SceneCameraPaths([a, b])
        var shown: [Float] = []
        for _ in 0..<12 { shown.append(try XCTUnwrap(paths.advance(by: 0.25)).eye.x) }
        // Each path: 0, 0.25, 0.5, 0.75, 1.0 of its segment (time 1 passes the end only after it).
        let h = { (t: Float) in SceneCameraPaths.hermiteWeight(t) }
        let expected: [Float] = [1, 1 + h(0.25), 1 + h(0.5), 1 + h(0.75), 2,
                                 10, 10 + 10 * h(0.25), 10 + 10 * h(0.5), 10 + 10 * h(0.75), 20,
                                 1, 1 + h(0.25)]
        for (value, want) in zip(shown, expected) { XCTAssertEqual(value, want, accuracy: 1e-5, "\(shown)") }
        XCTAssertEqual(paths.pathIndex, 0)
    }

    /// Across a key boundary within a path: the second segment starts from the middle key.
    func testKeysAdvanceWithinAPath() throws {
        var paths = SceneCameraPaths([WESceneCameraPath(duration: 3, keys: [
            Self.key(0, eye: SIMD3(0, 0, 0)), Self.key(1, eye: SIMD3(1, 0, 0)), Self.key(3, eye: SIMD3(5, 0, 0))])])
        var shown: [Float] = []
        for _ in 0..<7 { shown.append(try XCTUnwrap(paths.advance(by: 0.5)).eye.x) }
        let h = { (t: Float) in SceneCameraPaths.hermiteWeight(t) }
        let expected: [Float] = [0, h(0.5), 1, 1 + 4 * h(0.25), 1 + 4 * h(0.5), 1 + 4 * h(0.75), 5]
        for (value, want) in zip(shown, expected) { XCTAssertEqual(value, want, accuracy: 1e-5, "\(shown)") }
    }

    /// A first key after 0 holds until its segment "ends" at its timestamp plus the next one's (WE's sum).
    func testBeforeTheFirstKeyItHolds() throws {
        var paths = SceneCameraPaths([WESceneCameraPath(duration: 4, keys: [
            Self.key(1, eye: SIMD3(3, 0, 0)), Self.key(2, eye: SIMD3(6, 0, 0))])])
        XCTAssertEqual(try XCTUnwrap(paths.advance(by: 0.5)).eye.x, 3, "time 0 < 1: the first key")
        XCTAssertEqual(try XCTUnwrap(paths.advance(by: 0.5)).eye.x, 3, "time 0.5")
        let weight = SceneCameraPaths.hermiteWeight(0)
        XCTAssertEqual(try XCTUnwrap(paths.advance(by: 0.5)).eye.x, 3 + 3 * weight, "time 1: the segment starts")
    }

    /// `1 − 2·min(t, duration − t)` within half a second of either end, after the frame's advance; none between.
    func testTheFadeAtBothEnds() {
        var paths = SceneCameraPaths([WESceneCameraPath(duration: 3, keys: [
            Self.key(0, eye: SIMD3(0, 0, 1)), Self.key(3, eye: SIMD3(1, 0, 1))])])
        XCTAssertEqual(paths.fade, 1, "before the first frame: time 0")
        var fades: [Float] = []
        for _ in 0..<15 {
            _ = paths.advance(by: 0.2)
            fades.append(paths.fade)
        }
        let expected: [Float] = [0.6, 0.2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.2, 0.6, 1]
        for (index, (fade, want)) in zip(fades, expected).enumerated() {
            XCTAssertEqual(fade, want, accuracy: 1e-4, "frame \(index): \(fades)")
        }
        XCTAssertEqual(SceneCameraPaths([]).fade, 0)
    }
}
