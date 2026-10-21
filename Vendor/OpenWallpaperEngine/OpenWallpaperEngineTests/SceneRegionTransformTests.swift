import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import OpenWallpaperEngine

/// Roadmap §8.2: a composition layer's image is the scene under the layer as it is drawn this
/// frame, as WE's `composelayer` makes it (0x1402092d7: `_rt_FullFrameBuffer` sampled at the quad's
/// projection by `g_ModelViewProjectionMatrix`), whatever its parents, timeline, script or rotation
/// put it. The fixture draws a patterned scene and two composition layers with WE's pass-through
/// effect (`effects/_empty`): one in the scene's plane, the child of a turned, non-uniformly scaled
/// parent with an animated origin and its own rotation; one drawn through the perspective camera
/// (`perspective`), the child of a turned parent, with an animated origin and a tilt. Drawn back
/// where they are, both must leave the frame as it is without them: a region cropped anywhere else
/// (the local position, the authored origin, the unrotated box, an affine stand-in for the
/// perspective) shows another part of the scene over the whole quad.
final class SceneRegionTransformTests: XCTestCase {
    private var directory: URL { Fixtures.url("Scenes/scene-region") }

    func testCompositionLayersShowTheSceneUnderTheirLiveQuads() throws {
        _ = try Fixtures.assets()
        let with = try FixtureSceneRenderer(directory: directory).render()
        let without = try FixtureSceneRenderer(directory: directory, sceneFile: "reference.json").render()
        try Self.write(with, name: "scene-region-with")
        try Self.write(without, name: "scene-region-without")
        assertSame(with, without)
    }

    /// `"copybackground": false` (wallpaper64.exe swaps in `composelayer_clearalpha`): the 2D layer's
    /// base is the scene with alpha 0, so its tint (a blend that keeps alpha) draws nothing and the
    /// frame is the one without the layers. Copying the scene with its alpha drew the tinted region.
    func testALayerWithoutCopyBackgroundStartsTransparent() throws {
        _ = try Fixtures.assets()
        let cleared = try FixtureSceneRenderer(directory: directory, sceneFile: "cleared.json").render()
        let without = try FixtureSceneRenderer(directory: directory, sceneFile: "reference.json").render()
        try Self.write(cleared, name: "scene-region-cleared")
        assertSame(cleared, without)
    }

    private func assertSame(_ with: FixtureSceneRenderer.Frame, _ without: FixtureSceneRenderer.Frame,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(with.width, without.width, file: file, line: line)
        XCTAssertEqual(with.height, without.height, file: file, line: line)
        var differing = 0
        var total = 0
        for y in 0..<with.height {
            for x in 0..<with.width {
                let delta = with.pixel(x, y) &- without.pixel(x, y)
                let largest = max(abs(delta.x), abs(delta.y), abs(delta.z))
                total += largest
                if largest > 48 { differing += 1 }
            }
        }
        let pixels = with.width * with.height
        let mean = Double(total) / Double(pixels * 3)
        // The two quads cover about 9 % of the frame; only their antialiased edges may differ.
        XCTAssertLessThan(Double(differing) / Double(pixels), 0.01, "pixels that differ by more than 48/255", file: file, line: line)
        XCTAssertLessThan(mean, 1.5, "mean difference per channel", file: file, line: line)
    }

    /// The same layers with WE's tint instead of the pass-through: they are drawn, where their live
    /// transforms put them. The 2D layer's centre is its parent's origin (190, 120) plus the parent's
    /// turn (0.4 rad) of its scale (1.2, 0.9) times the timeline's last origin (40, −25), and it
    /// covers its size times the parent's scale.
    func testTheLayersAreDrawnWhereTheirTransformsPutThem() throws {
        _ = try Fixtures.assets()
        let frame = try FixtureSceneRenderer(directory: directory, sceneFile: "marked.json").render()
        try Self.write(frame, name: "scene-region-marked")
        var magenta = (count: 0, sum: SIMD2<Double>(0, 0))
        var cyan = (count: 0, sum: SIMD2<Double>(0, 0), minX: Int.max)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let pixel = frame.pixel(x, y)
                let centre = SIMD2<Double>(Double(x) + 0.5, Double(y) + 0.5)
                if pixel.x > 240, pixel.y < 15, pixel.z > 240 {
                    magenta.count += 1
                    magenta.sum += centre
                } else if pixel.x < 15, pixel.y > 240, pixel.z > 240 {
                    cyan.count += 1
                    cyan.sum += centre
                    cyan.minX = min(cyan.minX, x)
                }
            }
        }
        let offset = SIMD2<Double>(48, -22.5)
        let turn: Double = 0.4
        let cosTurn: Double = cos(turn)
        let sinTurn: Double = sin(turn)
        let centreX: Double = 190 + offset.x * cosTurn - offset.y * sinTurn
        let centreY: Double = 120 + offset.x * sinTurn + offset.y * cosTurn
        let centre = SIMD2<Double>(centreX, centreY)
        let expectedArea: Double = 120 * 80 * 1.2 * 0.9
        let areaTolerance: Double = 120 * 80 * 0.04
        XCTAssertEqual(Double(magenta.count), expectedArea, accuracy: areaTolerance, "the 2D layer's area")
        let magentaCount: Double = Double(max(magenta.count, 1))
        let drawn: SIMD2<Double> = magenta.sum / magentaCount
        XCTAssertEqual(drawn.x, centre.x, accuracy: 0.75, "the 2D layer's centre")
        XCTAssertEqual(drawn.y, 272 - centre.y, accuracy: 0.75, "the 2D layer's centre (rows from the top)")
        XCTAssertGreaterThan(cyan.count, 3000, "the layer drawn through the perspective camera")
        XCTAssertGreaterThan(cyan.minX, 300, "it stays by its parent, on the right")
    }

    /// Before/after pictures for review, when `OWE_RT_OUT` names a folder.
    static func write(_ frame: FixtureSceneRenderer.Frame, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["OWE_RT_OUT"], !folder.isEmpty else { return }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(frame.pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: frame.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false,
                                          intent: .defaultIntent))
        let url = URL(fileURLWithPath: folder).appending(path: name + ".png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
