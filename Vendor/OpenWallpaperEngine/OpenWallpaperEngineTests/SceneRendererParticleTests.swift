import XCTest
import MetalKit
import AppKit
@testable import OpenWallpaperEngine

/// Whole frames of `SceneMetalRenderer` with a particle system between two layers: particles cover the layer below and are covered by the layer above.
final class SceneRendererParticleTests: XCTestCase {
    private static let size = 128

    func testGPUSimulatedParticlesDrawBetweenTheirLayers() throws {
        try assertDrawOrder(material: false)
    }

    func testGPUSimulatedParticlesDrawThroughTheirMaterialBetweenTheirLayers() throws {
        _ = try Fixtures.assets()
        try assertDrawOrder(material: true)
    }

    func testGPUSimulatedRefractionReadsTheSceneUpToItsSystem() throws {
        _ = try Fixtures.assets()
        try assertRefractionSnapshot()
    }

    // MARK: - Helpers

    /// A: red under everything. C: green over the left half, below the particles. B: blue over
    /// the right half, above them. A refracting sprite on the left samples half a screen to its
    /// right (`refract_normal.json`): the snapshot there holds A, and not yet B.
    private func assertRefractionSnapshot(file: StaticString = #filePath, line: UInt = #line) throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: Self.size, height: Self.size)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view))
        view.isPaused = true
        renderer.setPlacement(.stretch)

        let scene = Float(Self.size)
        let a = layer("A", color: [1, 0, 0, 1], center: SIMD2(scene / 2, scene / 2), size: SIMD2(scene, scene), order: 0)
        let c = layer("C", color: [0, 1, 0, 1], center: SIMD2(scene / 4, scene / 2), size: SIMD2(scene / 2, scene), order: 1)
        let b = layer("B", color: [0, 0, 1, 1], center: SIMD2(scene * 3 / 4, scene / 2), size: SIMD2(scene / 2, scene), order: 3)
        var system = ParticleTestSystem()
        system.origin = SIMD2(scene / 4, scene / 2)
        system.spawnExtent = .zero
        system.minimumVelocity = .zero
        system.maximumVelocity = .zero
        system.size = 120...120
        system.lifetime = 100...100
        system.alpha = 1...1
        system.minimumColor = SIMD4(repeating: 1)
        system.maximumColor = SIMD4(repeating: 1)
        system.maximum = 5
        system.source = .image(image([1, 1, 1, 1]))
        system.material = try refractionMaterial()
        var configuration = system.configuration
        configuration.order = 2
        let content = SceneMetalContent(size: SIMD2(scene, scene), layers: [a, c, b], particleSystems: [configuration],
                                        bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7, tint: SIMD3(repeating: 1)))
        renderer.setContent(content)

        var pixels: [UInt8] = []
        let deadline = Date().addingTimeInterval(10)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            guard let texture = view.currentDrawable?.texture else { continue }
            pixels = [UInt8](repeating: 0, count: Self.size * Self.size * 4)
            texture.getBytes(&pixels, bytesPerRow: Self.size * 4,
                             from: MTLRegionMake2D(0, 0, Self.size, Self.size), mipmapLevel: 0)
        } while Date() < deadline && !isRed(pixels, x: 32, y: 64)
        XCTAssertTrue(isRed(pixels, x: 32, y: 64), "refracts A from the right half, without B: \(bgra(pixels, x: 32, y: 64))",
                      file: file, line: line)
        XCTAssertTrue(isGreen(pixels, x: 5, y: 64), "C beside the sprite: \(bgra(pixels, x: 5, y: 64))", file: file, line: line)
        XCTAssertTrue(isBlue(pixels, x: 96, y: 64), "B over the right half: \(bgra(pixels, x: 96, y: 64))", file: file, line: line)
    }

    /// `refract_normal.json` with a normal map pointing along +x (alpha 1), its mask (red) 1.
    private func refractionMaterial() throws -> ParticleMaterialPlan {
        let roots = [Fixtures.url("Particles"), ShaderVariantTests.weAssets]
        let normal = image([1, 0.5, 0.5, 1])
        let builder = ParticleMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil),
            readFile: { path in roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first },
            loadTexture: { name, _ in name == "refractnormal" ? .image(normal) : nil })
        let renderer = try JSONDecoder().decode(WEParticleRenderer.self, from: Data(#"{"name":"sprite"}"#.utf8))
        return try builder.build(materialPath: "materials/refract_normal.json", renderer: renderer, flags: 0,
                                 baseTexture: .image(NSImage()), spriteSheet: nil)
    }

    private func isGreen(_ pixels: [UInt8], x: Int, y: Int) -> Bool {
        let p = bgra(pixels, x: x, y: y)
        return p.count == 4 && p[0] < 5 && p[1] > 250 && p[2] < 5
    }

    private func assertDrawOrder(material: Bool,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: Self.size, height: Self.size)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view))
        view.isPaused = true
        renderer.setPlacement(.stretch)

        let scene = Float(Self.size)
        // A: red under everything. B: blue over the left half, above the particles.
        let below = layer("A", color: [1, 0, 0, 1], center: SIMD2(scene / 2, scene / 2), size: SIMD2(scene, scene), order: 0)
        let above = layer("B", color: [0, 0, 1, 1], center: SIMD2(scene / 4, scene / 2), size: SIMD2(scene / 2, scene), order: 2)
        var system = ParticleTestSystem()
        system.origin = SIMD2(scene / 2, scene / 2)
        system.spawnExtent = .zero
        system.minimumVelocity = .zero
        system.maximumVelocity = .zero
        // The built-in disc and WE's material both draw the particle's size, half the authored one:
        // a 100 disc, a 50 square.
        system.size = material ? 100...100 : 200...200
        system.lifetime = 100...100
        system.alpha = 1...1
        system.minimumColor = SIMD4(repeating: 1)
        system.maximumColor = SIMD4(repeating: 1)
        system.maximum = 5
        system.source = .image(image([1, 1, 1, 1]))
        if material { system.material = try solidMaterial() }
        var configuration = system.configuration
        configuration.order = 1
        let content = SceneMetalContent(size: SIMD2(scene, scene), layers: [below, above], particleSystems: [configuration],
                                        bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7, tint: SIMD3(repeating: 1)))
        renderer.setContent(content)

        // Content loads off the main thread, and material pipelines compile in the background.
        var pixels: [UInt8] = []
        let deadline = Date().addingTimeInterval(10)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            guard let texture = view.currentDrawable?.texture else { continue }
            pixels = [UInt8](repeating: 0, count: Self.size * Self.size * 4)
            texture.getBytes(&pixels, bytesPerRow: Self.size * 4,
                             from: MTLRegionMake2D(0, 0, Self.size, Self.size), mipmapLevel: 0)
            // WE's shader draws the sprite half its size wide (a 50-unit square here); the
            // built-in draw a 100-unit disc. The material compiles in the background meanwhile.
        } while Date() < deadline && !(isWhite(pixels, x: 80, y: 64) && isBlue(pixels, x: 50, y: 64)
                                       && (material ? isRed(pixels, x: 100, y: 64) : isWhite(pixels, x: 100, y: 64)))
        XCTAssertFalse(pixels.isEmpty, "a drawable to read", file: file, line: line)
        guard !pixels.isEmpty else { return }
        XCTAssertTrue(isWhite(pixels, x: 80, y: 64), "particles cover the layer below: \(bgra(pixels, x: 80, y: 64))", file: file, line: line)
        XCTAssertTrue(isBlue(pixels, x: 50, y: 64), "the layer above covers the particles: \(bgra(pixels, x: 50, y: 64))", file: file, line: line)
        XCTAssertTrue(isRed(pixels, x: 120, y: 64), "the layer below shows elsewhere: \(bgra(pixels, x: 120, y: 64))", file: file, line: line)
        XCTAssertTrue(isBlue(pixels, x: 10, y: 64), file: file, line: line)
        if material {
            XCTAssertTrue(isRed(pixels, x: 100, y: 64), "drawn through WE's shader: \(bgra(pixels, x: 100, y: 64))", file: file, line: line)
        } else {
            XCTAssertTrue(isWhite(pixels, x: 100, y: 64), "the built-in disc: \(bgra(pixels, x: 100, y: 64))", file: file, line: line)
        }
    }

    private func bgra(_ pixels: [UInt8], x: Int, y: Int) -> [UInt8] {
        guard pixels.count >= Self.size * Self.size * 4 else { return [] }
        let index = (y * Self.size + x) * 4
        return Array(pixels[index..<index + 4])
    }

    private func isWhite(_ pixels: [UInt8], x: Int, y: Int) -> Bool {
        let p = bgra(pixels, x: x, y: y)
        return p.count == 4 && p[0] > 250 && p[1] > 250 && p[2] > 250
    }

    private func isBlue(_ pixels: [UInt8], x: Int, y: Int) -> Bool {
        let p = bgra(pixels, x: x, y: y)
        return p.count == 4 && p[0] > 250 && p[1] < 5 && p[2] < 5
    }

    private func isRed(_ pixels: [UInt8], x: Int, y: Int) -> Bool {
        let p = bgra(pixels, x: x, y: y)
        return p.count == 4 && p[0] < 5 && p[1] < 5 && p[2] > 250
    }

    private func solidMaterial() throws -> ParticleMaterialPlan {
        let roots = [Fixtures.url("Particles"), ShaderVariantTests.weAssets]
        let builder = ParticleMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil),
            readFile: { path in roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first },
            loadTexture: { _, _ in nil })
        let renderer = try JSONDecoder().decode(WEParticleRenderer.self, from: Data(#"{"name":"sprite"}"#.utf8))
        return try builder.build(materialPath: "materials/solid.json", renderer: renderer, flags: 0,
                                 baseTexture: .image(NSImage()), spriteSheet: nil)
    }

    /// Exact texels, not AppKit drawing (which colour-matches `NSColor.red` to about (237, 47, 25)).
    private func image(_ rgba: [Double]) -> NSImage { SceneContentLoader.pixelImage(rgba) }

    private func layer(_ id: String, color: [Double], center: SIMD2<Float>, size: SIMD2<Float>, order: Int) -> SceneMetalLayer {
        var layer = SceneMetalLayer(
            id: id, name: id, source: .image(image(color)), position: center, size: size, scale: SIMD2(1, 1), opacity: 1,
            brightness: 1, color: SIMD4(repeating: 1), text: nil,
            parallaxDepth: .zero, perspective: false, rotation: 0)
        layer.order = order
        return layer
    }
}
