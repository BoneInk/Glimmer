import XCTest
import MetalKit
import AppKit
@testable import OpenWallpaperEngine

/// Memory pressure trims what the renderer can rebuild, and nothing a frame still uses.
final class SceneMemoryPressureTests: XCTestCase {
    func testLevels() {
        XCTAssertEqual(SceneMemoryPressure.level(for: .warning), .warning)
        XCTAssertEqual(SceneMemoryPressure.level(for: .critical), .critical)
        XCTAssertEqual(SceneMemoryPressure.level(for: [.warning, .critical]), .critical)
        XCTAssertNil(SceneMemoryPressure.level(for: .normal))
    }

    func testTextCacheKeepsTheMostRecentEntries() {
        var cache = SceneLRUCache<String, Int>(capacity: 10)
        for index in 0..<5 { cache.insert(index, for: "\(index)") }
        _ = cache.value(for: "0")
        cache.trim(to: 2)
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.value(for: "0"), 0)
        XCTAssertEqual(cache.value(for: "4"), 4)
        XCTAssertNil(cache.value(for: "3"))
        cache.trim(to: 5)
        XCTAssertEqual(cache.count, 2)
    }

    /// A blend-mode layer draws through its material on the very next frame after a critical
    /// trim: its pipeline was in use, so it stays (the native fallback would not add).
    func testCriticalTrimKeepsWhatTheSceneDrawsWith() throws {
        _ = try Fixtures.assets()
        let size = 64
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: size, height: size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: size, height: size)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view))
        view.isPaused = true
        renderer.setPlacement(.stretch)
        let scene = Float(size)
        let roots = [Fixtures.url("ImageMaterials"), ShaderVariantTests.weAssets]
        let builder = ImageMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil),
            readFile: { path in roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first },
            loadTexture: { _, _ in nil })
        var top = layer("B", color: [0, 0.5, 0, 1], size: scene, order: 1)
        top.imageMaterial = try XCTUnwrap(try builder.build(materialPath: "materials/image4.json", colorBlendMode: 9))
        renderer.setContent(SceneMetalContent(
            size: SIMD2(scene, scene), layers: [layer("A", color: [0.25, 0.25, 0.25, 1], size: scene, order: 0), top],
            particleSystems: [],
            bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7, tint: SIMD3(repeating: 1))))

        func frame() -> [Double] {
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            guard let texture = view.currentDrawable?.texture else { return [] }
            var pixel = [UInt8](repeating: 0, count: 4)
            texture.getBytes(&pixel, bytesPerRow: size * 4, from: MTLRegionMake2D(size / 2, size / 2, 1, 1), mipmapLevel: 0)
            return pixel.prefix(3).map { Double($0) / 255 }
        }
        func added(_ bgra: [Double]) -> Bool {
            bgra.count == 3 && zip(bgra, [0.25, 0.75, 0.25]).allSatisfy { abs($0 - $1) < 3.0 / 255 }
        }
        var pixel: [Double] = []
        let deadline = Date().addingTimeInterval(20)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            pixel = frame()
        } while Date() < deadline && !added(pixel)
        XCTAssertTrue(added(pixel), "\(pixel)")
        renderer.trimMemory(.critical)
        XCTAssertTrue(added(frame()), "drawn through its material right after the trim")
        renderer.trimMemory(.warning)
        renderer.trimMemory(.critical)
        XCTAssertTrue(added(frame()), "and after repeated trims")
    }

    private func layer(_ id: String, color: [Double], size: Float, order: Int) -> SceneMetalLayer {
        var layer = SceneMetalLayer(
            id: id, name: id, source: .image(SceneContentLoader.pixelImage(color)), position: SIMD2(size / 2, size / 2),
            size: SIMD2(size, size), scale: SIMD2(1, 1), opacity: 1, brightness: 1, color: SIMD4(repeating: 1), text: nil,
            parallaxDepth: .zero, perspective: false, rotation: 0)
        layer.order = order
        return layer
    }
}
