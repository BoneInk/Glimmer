import XCTest
import simd
import MetalKit
@testable import OpenWallpaperEngine

/// Scene-input sampling, placement scale, .tex content size and emitter-space directions.
final class SceneRendererPlacementTests: XCTestCase {
    private let scene = SIMD2<Float>(1000, 500)

    /// The UV the snapshot mapping gives a corner of the quad, as the vertex stage computes it.
    private func uv(_ quad: SceneQuadGeometry, corner: SIMD2<Float>) -> SIMD2<Float> {
        let m = quad.snapshotUV(sceneSize: scene)
        return m.origin + corner.x * m.axisX + corner.y * m.axisY
    }

    /// Where a scene point lies in the y-down snapshot.
    private func snapshotUV(of point: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(point.x / scene.x, 1 - point.y / scene.y)
    }

    private func assertEqual(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 1e-5, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-5, message, file: file, line: line)
    }

    /// Each corner of the layer texture (top-left, top-right, bottom-left) must read the scene
    /// pixel under that corner of the drawn quad.
    private func assertCornersMatch(_ quad: SceneQuadGeometry, file: StaticString = #filePath, line: UInt = #line) {
        let topLeft = quad.center - quad.axisX / 2 + quad.axisY / 2
        assertEqual(uv(quad, corner: SIMD2(0, 0)), snapshotUV(of: topLeft), "top-left", file: file, line: line)
        assertEqual(uv(quad, corner: SIMD2(1, 0)), snapshotUV(of: topLeft + quad.axisX), "top-right", file: file, line: line)
        assertEqual(uv(quad, corner: SIMD2(0, 1)), snapshotUV(of: topLeft - quad.axisY), "bottom-left", file: file, line: line)
    }

    func testFullSceneQuadMapsToWholeSnapshot() {
        let quad = SceneQuadGeometry(center: scene / 2, axisX: SIMD2(scene.x, 0), axisY: SIMD2(0, scene.y))
        let m = quad.snapshotUV(sceneSize: scene)
        assertEqual(m.origin, .zero)
        assertEqual(m.axisX, SIMD2(1, 0))
        assertEqual(m.axisY, SIMD2(0, 1))
    }

    func testRotatedMirroredAndOffscreenQuadsSampleTheSceneUnderThem() {
        for angle: Float in [0, .pi / 4, .pi / 2, .pi] {
            let world = SceneAffineTransform(SceneLocalTransform(origin: SIMD2(300, 200), scale: SIMD2(1, 1), angle: angle))
            assertCornersMatch(SceneQuadGeometry(world: world, size: SIMD2(200, 100), alignment: nil))
        }
        let mirrored = SceneAffineTransform(SceneLocalTransform(origin: SIMD2(300, 200), scale: SIMD2(-1, 1), angle: 0))
        let mirroredQuad = SceneQuadGeometry(world: mirrored, size: SIMD2(200, 100), alignment: nil)
        assertCornersMatch(mirroredQuad)
        XCTAssertLessThan(mirroredQuad.snapshotUV(sceneSize: scene).axisX.x, 0, "mirrored layer reads the scene right-to-left")
        // Half off the right edge: the far corners sample beyond u = 1 (clamped by the sampler).
        let offscreen = SceneQuadGeometry(center: SIMD2(1000, 250), axisX: SIMD2(200, 0), axisY: SIMD2(0, 100))
        assertCornersMatch(offscreen)
        XCTAssertEqual(uv(offscreen, corner: SIMD2(1, 0)).x, 1.1, accuracy: 1e-5)
    }

    // MARK: Placement

    func testCenterPlacementIsOnePointPerSceneUnit() {
        let drawable = SIMD2<Float>(2880, 1800)
        XCTAssertEqual(ScenePlacementScale.scale(for: .center, sceneSize: SIMD2(1920, 1080), drawableSize: drawable,
                                                 pixelsPerPoint: 2), 2)
        XCTAssertEqual(ScenePlacementScale.scale(for: .center, sceneSize: SIMD2(1920, 1080), drawableSize: drawable,
                                                 pixelsPerPoint: 1), 1)
        XCTAssertEqual(ScenePlacementScale.scale(for: .fit, sceneSize: SIMD2(1920, 1080), drawableSize: drawable,
                                                 pixelsPerPoint: 2), 1.5)
        XCTAssertEqual(ScenePlacementScale.scale(for: .fill, sceneSize: SIMD2(1920, 1080), drawableSize: drawable,
                                                 pixelsPerPoint: 2), 1800 / 1080, accuracy: 1e-5)
    }

    /// Risk #16: the cursor maps back through the same placement the composite draws with, so
    /// the pointer lands on the scene pixel under it: cropped (fill), letterboxed (fit), centred
    /// at one point per unit and stretched. y is up, like the scene.
    func testCursorMapsThroughThePlacement() {
        let scene = SIMD2<Float>(1920, 1080), drawable = SIMD2<Float>(2880, 1800)
        func near(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ message: String) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-3, message)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-3, message)
        }
        func point(_ p: SIMD2<Float>, _ placement: WallpaperPlacement) -> SIMD2<Float> {
            ScenePlacementScale.scenePoint(drawablePoint: p, placement: placement, sceneSize: scene,
                                           drawableSize: drawable, pixelsPerPoint: 2)
        }
        // Fill: 1800/1080 px per unit, 160 px of scene cropped off each side.
        near(point(SIMD2(0, 1800), .fill), SIMD2(96, 1080), "fill: top-left corner")
        near(point(drawable / 2, .fill), scene / 2, "fill: centre")
        // Fit: 1.5 px per unit, 90 px bars above and below.
        near(point(SIMD2(0, 90), .fit), SIMD2(0, 0), "fit: bottom-left of the picture")
        XCTAssertLessThan(point(SIMD2(0, 0), .fit).y, 0, "fit: the bar is outside the scene")
        // Center: 2 px per unit on a Retina drawable.
        near(point(drawable / 2 + SIMD2(200, 100), .center), scene / 2 + SIMD2(100, 50), "center")
        near(point(drawable, .stretch), scene, "stretch: top-right corner")
        let pointer = simd_clamp(point(SIMD2(0, 0), .fit) / scene, SIMD2(0, 0), SIMD2(1, 1))
        near(pointer, SIMD2(0, 0), "g_PointerPosition stays in 0...1")
    }

    // MARK: .tex content size

    /// A minimal TEXV0005 / TEXB0001 DXT1 file: `texture` allocated, `image` the header's content size.
    private func dxt1Tex(texture: SIMD2<UInt32>, image: SIMD2<UInt32>) -> Data {
        var data = Data()
        func string(_ s: String) { data.append(contentsOf: Array(s.utf8) + [0]) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        string("TEXV0005"); string("TEXI0001")
        u32(7); u32(0); u32(texture.x); u32(texture.y); u32(image.x); u32(image.y); u32(0)
        string("TEXB0001"); u32(1)
        u32(1); u32(texture.x); u32(texture.y)
        let size = Int((texture.x + 3) / 4 * ((texture.y + 3) / 4) * 8)
        u32(UInt32(size))
        data.append(Data(count: size))
        return data
    }

    func testCompressedTextureCarriesContentSize() throws {
        let padded = try XCTUnwrap(TEXParser(data: dxt1Tex(texture: SIMD2(16, 8), image: SIMD2(10, 6))).extractCompressedTexture())
        XCTAssertEqual(padded.width, 16)
        XCTAssertEqual(padded.contentWidth, 10)
        XCTAssertEqual(padded.contentHeight, 6)
        XCTAssertEqual(SceneMetalTextureSource.dxt(padded).contentSize, SIMD2(10, 6))

        let unset = try XCTUnwrap(TEXParser(data: dxt1Tex(texture: SIMD2(16, 8), image: .zero)).extractCompressedTexture())
        XCTAssertEqual(SceneMetalTextureSource.dxt(unset).contentSize, SIMD2(16, 8), "no header size: whole allocation")
    }

    // MARK: Emitter directions

    func testEmitterDirectionsFollowParentRotationNotScale() throws {
        let objects = try JSONDecoder().decode([WESceneObject].self, from: Data(#"""
        [{"id": 1, "origin": "100 100 0", "scale": "3 3 1", "angles": "0 0 1.5707963"},
         {"id": 2, "parent": 1, "origin": "0 0 0", "particle": "p.json"}]
        """#.utf8))
        let hierarchy = SceneTransformHierarchy(objects: objects)
        let space = SceneParticleEmitterSpace(world: hierarchy.world(of: "2"))
        let velocity = space.direction(SIMD2(0, 100))
        XCTAssertEqual(simd_length(velocity), 100, accuracy: 1e-3, "scale does not change speed")
        XCTAssertEqual(abs(velocity.x), 100, accuracy: 1e-3, "a quarter turn moves y onto x")
        // Same convention as positions: the direction matches the world transform's own turn.
        let expected = simd_normalize(hierarchy.world(of: "2").linear * SIMD2(0, 1)) * 100
        XCTAssertEqual(velocity.x, expected.x, accuracy: 1e-3)
        XCTAssertEqual(velocity.y, expected.y, accuracy: 1e-3)
    }

    /// A layer wider than the scene (sized so camera parallax never shows its edges) is drawn
    /// centred where its origin puts it, as WE draws it; it isn't pinned against a scene edge.
    func testOversizedLayerStaysWhereItsOriginPutsIt() throws {
        let size = 64
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: size, height: size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: size, height: size)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view))
        view.isPaused = true
        renderer.setPlacement(.stretch)
        let scene = Float(size)
        // Twice the scene's width: red left half, green right half; the seam is at its origin.
        var layer = SceneMetalLayer(
            id: "wide", name: "wide", source: .image(try Self.halves()), position: SIMD2(scene / 2, scene / 2),
            size: SIMD2(scene * 2, scene), scale: SIMD2(1, 1), opacity: 1, brightness: 1, color: SIMD4(repeating: 1),
            text: nil, parallaxDepth: .zero, perspective: false, rotation: 0)
        layer.order = 0
        renderer.setContent(SceneMetalContent(
            size: SIMD2(scene, scene), layers: [layer], particleSystems: [],
            bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7, tint: SIMD3(repeating: 1))))
        // The first frames draw before the layer's pipelines land: opaque black, not the layer.
        // Draw until a frame had every pass in it (`hasCompleteFrame`), however long the compiles
        // take on a loaded machine.
        let deadline = Date().addingTimeInterval(30)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
        } while !renderer.hasCompleteFrame && Date() < deadline
        XCTAssertTrue(renderer.hasCompleteFrame, "a complete frame was drawn")
        // `currentDrawable` hands out the view's drawables in turn: draw until each holds a
        // complete frame, or the one read below can be an early frame's.
        for _ in 0..<4 {
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
        }
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        view.currentDrawable?.texture.getBytes(&pixels, bytesPerRow: size * 4,
                                               from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        func bgra(_ x: Int) -> [UInt8] { Array(pixels[((size / 2) * size + x) * 4..<((size / 2) * size + x) * 4 + 4]) }
        XCTAssertGreaterThan(bgra(size / 4)[2], 200, "red left of the origin: \(bgra(size / 4))")
        XCTAssertLessThan(bgra(size / 4)[1], 50, "\(bgra(size / 4))")
        XCTAssertGreaterThan(bgra(size * 3 / 4)[1], 200, "green right of it: \(bgra(size * 3 / 4))")
        XCTAssertLessThan(bgra(size * 3 / 4)[2], 50, "\(bgra(size * 3 / 4))")
    }

    /// A 4×1 image: two red texels, then two green.
    private static func halves() throws -> NSImage {
        let bytes: [UInt8] = [255, 0, 0, 255, 255, 0, 0, 255, 0, 255, 0, 255, 0, 255, 0, 255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 4, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder32Big),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return NSImage(cgImage: image, size: NSSize(width: 4, height: 1))
    }
}
