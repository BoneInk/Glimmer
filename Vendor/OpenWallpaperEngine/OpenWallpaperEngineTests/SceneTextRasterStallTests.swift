import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// A text layer whose string changes (dino_run's score, a clock) keeps drawing its previous
/// raster while a pool job makes the new one: the render thread doesn't wait on Core Text.
final class SceneTextRasterStallTests: XCTestCase {
    /// dino_run's `label_coins`: pointsize 64, right-aligned in a 780×291 box.
    private func score(_ value: String) -> SceneTextRasterRequest {
        let text = SceneMetalText(value: value, font: nil, pointSize: 64, horizontalAlignment: "right",
                                  verticalAlignment: "center", padding: .zero, maxWidth: nil, maxRows: nil,
                                  useEllipsis: false, anchor: "topright", blockAlign: false)
        return SceneTextRasterRequest(text: text, value: value, fontName: "System", pointSize: 64, bold: false,
                                      italic: false, rasterScale: 2, fill: nil)
    }

    private func milliseconds(_ body: () -> Void) -> Double {
        let start = CACurrentMediaTime()
        body()
        return (CACurrentMediaTime() - start) * 1000
    }

    func testChangedStringDoesNotStallTheRenderThread() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = SceneTextRasterQueue(device: device, loader: MTKTextureLoader(device: device))

        // The first raster has nothing to stand in for it, so it's made on the spot.
        var first: (result: SceneTextRasterResult, isNew: Bool)?
        let synchronous = milliseconds { first = queue.raster(key: "0", slot: "score", request: score("00000")) }
        XCTAssertEqual(first?.isNew, true)

        var stalls: [Double] = []
        for value in 1...20 {
            let key = String(format: "%05d", value)
            var drawn: (result: SceneTextRasterResult, isNew: Bool)?
            stalls.append(milliseconds { drawn = queue.raster(key: key, slot: "score", request: score(key)) })
            // The previous raster draws while the new one is made.
            XCTAssertEqual(drawn?.isNew, false)
            var landed: SceneTextRasterResult?
            let deadline = Date().addingTimeInterval(2)
            while landed == nil, Date() < deadline {
                landed = queue.takeFinished().first { $0.key == key }?.result
                if landed == nil { usleep(200) }
            }
            let result = try XCTUnwrap(landed, "the raster job for \(key) never landed")
            queue.show(result, slot: "score")
        }
        stalls.sort()
        let median = stalls[stalls.count / 2], worst = stalls.last ?? 0
        print("text raster stall: synchronous \(String(format: "%.2f", synchronous)) ms; "
              + "queued median \(String(format: "%.3f", median)) ms, max \(String(format: "%.3f", worst)) ms")
        XCTAssertLessThan(median, 1, "a changed string must not stall the render thread")
    }

    /// Content changes drop jobs in flight, so an old wallpaper's raster never lands in the new one.
    func testResetDiscardsJobsInFlight() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = SceneTextRasterQueue(device: device, loader: MTKTextureLoader(device: device))
        _ = queue.raster(key: "a", slot: "s", request: score("1"))
        _ = queue.raster(key: "b", slot: "s", request: score("2"))
        queue.reset()
        usleep(300_000)
        XCTAssertTrue(queue.takeFinished().isEmpty)
        // With no previous raster after the reset, the next one is made on the spot.
        XCTAssertEqual(queue.raster(key: "b", slot: "s", request: score("2"))?.isNew, true)
    }
}
