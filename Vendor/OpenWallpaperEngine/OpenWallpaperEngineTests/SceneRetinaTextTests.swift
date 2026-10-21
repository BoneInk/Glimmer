import XCTest
import simd
@testable import OpenWallpaperEngine

/// Roadmap §8.1: text is sharp on a Retina display. WE draws the scene at the output's pixel size:
/// the scene pass's viewport is the context's screen size (`wallpaper64.exe` 0x140180ad5 reads
/// ctx+0x84/+0x88), and the orthographic camera fits the scene to it (0x140183a70). Here the scene
/// target follows the display's pixel density (`SceneRenderResolution`) and a text layer is
/// rasterised at its on-screen density (`SceneTextRasterScale.layer`), so at a 2× backing scale the
/// glyphs carry twice the pixels per scene unit, not a 1× raster scaled up, and the other layers
/// draw the same scene at twice the pixels.
final class SceneRetinaTextTests: XCTestCase {
    private var directory: URL { Fixtures.url("Scenes/text-retina") }

    /// Rows and columns in 1× pixels (the scene is 480 × 272, row 0 at the top).
    private struct Box {
        let x: Range<Int>
        let y: Range<Int>
        func scaled(_ scale: Int) -> Box { Box(x: x.lowerBound * scale..<x.upperBound * scale,
                                               y: y.lowerBound * scale..<y.upperBound * scale) }
    }
    private let textBox = Box(x: 110..<480, y: 40..<150)
    private let squareBox = Box(x: 0..<220, y: 150..<272)

    private struct Coverage {
        var ink = 0
        var partial = 0
        var minX = Int.max
        var maxX = Int.min
    }

    /// White text on black: ink is any lit pixel, partial one between 15 % and 85 % lit.
    private func coverage(_ frame: FixtureSceneRenderer.Frame, in box: Box) -> Coverage {
        var result = Coverage()
        for y in box.y {
            for x in box.x {
                let value = frame.pixel(x, y).x
                guard value > 38 else { continue }
                result.ink += 1
                if value < 217 { result.partial += 1 }
                result.minX = min(result.minX, x)
                result.maxX = max(result.maxX, x)
            }
        }
        return result
    }

    func testTextAtTwiceTheBackingScaleHasTwiceTheGlyphDensity() throws {
        let one = try FixtureSceneRenderer(directory: directory, pixelsPerPoint: 1).render()
        let two = try FixtureSceneRenderer(directory: directory, pixelsPerPoint: 2).render()
        try SceneRegionTransformTests.write(one, name: "text-retina-1x")
        try SceneRegionTransformTests.write(two, name: "text-retina-2x")
        XCTAssertEqual(one.width, 480)
        XCTAssertEqual(two.width, 960, "the scene target follows the backing scale")
        XCTAssertEqual(two.height, 544)

        let text1 = coverage(one, in: textBox), text2 = coverage(two, in: textBox.scaled(2))
        XCTAssertGreaterThan(text1.ink, 800, "the text is drawn")
        // The same glyphs over twice the pixels each way: four times the ink, twice the span.
        let span1 = Float(text1.maxX - text1.minX), span2 = Float(text2.maxX - text2.minX)
        XCTAssertEqual(span2 / span1, 2, accuracy: 0.05, "glyph pixels per scene unit double")
        XCTAssertEqual(Float(text2.ink) / Float(text1.ink), 4, accuracy: 0.6)
        // Edges stay one or two pixels wide: rasterised at 2×, the antialiased rim doubles with the
        // outline's length; a 1× raster scaled up would also double its width (about 4×).
        let rim = Float(text2.partial) / Float(text1.partial)
        XCTAssertLessThan(rim, 3, "partially covered pixels: \(text1.partial) at 1×, \(text2.partial) at 2×")
    }

    func testOtherLayersDrawTheSameSceneAtTwiceThePixels() throws {
        _ = try Fixtures.assets()
        let one = try FixtureSceneRenderer(directory: directory, pixelsPerPoint: 1).render()
        let two = try FixtureSceneRenderer(directory: directory, pixelsPerPoint: 2).render()
        // Each 1× pixel against the average of the 2 × 2 it became; the square's edges are hard in
        // both (no MSAA), so compare where the 1× pixel's neighbourhood is uniform.
        var compared = 0
        var differing = 0
        for y in squareBox.y.dropFirst().dropLast() {
            for x in squareBox.x.dropFirst().dropLast() {
                let centre = one.pixel(x, y)
                let uniform = [(-1, 0), (1, 0), (0, -1), (0, 1)].allSatisfy { one.pixel(x + $0.0, y + $0.1) == centre }
                guard uniform else { continue }
                var sum = SIMD4<Int>(repeating: 0)
                for dy in 0..<2 { for dx in 0..<2 { sum &+= two.pixel(x * 2 + dx, y * 2 + dy) } }
                let average = sum / 4
                let delta = average &- centre
                if max(abs(delta.x), abs(delta.y), abs(delta.z)) > 2 { differing += 1 }
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 10_000)
        // A hard edge can still cut the corner of a pixel whose neighbours are all on one side.
        XCTAssertLessThan(Float(differing) / Float(compared), 0.01, "the square and the background are the same at 2×")
        let squarePixels1 = (0..<one.pixels.count / 4).filter { one.pixels[$0 * 4 + 2] > 200 && one.pixels[$0 * 4] < 80 }.count
        let squarePixels2 = (0..<two.pixels.count / 4).filter { two.pixels[$0 * 4 + 2] > 200 && two.pixels[$0 * 4] < 80 }.count
        XCTAssertEqual(Float(squarePixels2) / Float(squarePixels1), 4, accuracy: 0.1, "the square covers the same scene area")
    }
}
