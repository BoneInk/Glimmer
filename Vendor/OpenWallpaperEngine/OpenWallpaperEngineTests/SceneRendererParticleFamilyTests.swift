import XCTest
import MetalKit
import AppKit
@testable import OpenWallpaperEngine

/// Whole renderer frames with particle children and animated parents: a static child draws where its link puts it, and a system under an animated group
/// moves with the group, particles and all.
final class SceneRendererParticleFamilyTests: XCTestCase {
    private static let size = 128

    func testGPUStaticChildDrawsAtItsLink() throws { try assertStaticChild() }
    func testGPUParticlesFollowTheirAnimatedParent() throws { try assertAnimatedParent() }
    func testGPUParticlesFollowCameraParallax() throws { try assertCameraParallax() }

    // MARK: - Scenarios

    /// A dot at (32, 64) and its static child 64 units to the right.
    private func assertStaticChild(file: StaticString = #filePath, line: UInt = #line) throws {
        var parent = dot().configuration
        parent.order = 1
        var child = dot()
        child.origin = SIMD2(96, 64)
        var childConfiguration = child.configuration
        childConfiguration.order = 1
        childConfiguration.link = ParticleChildLink(parentIndex: 0, kind: .static,
                                                    local: SceneLocalTransform(origin: SIMD2(64, 0), scale: SIMD2(1, 1), angle: 0),
                                                    probability: 1, maximumInstances: 1, instanced: false)
        let pixels = try render(systems: [parent, childConfiguration]) {
            Self.isWhite($0, x: 32, y: 64) && Self.isWhite($0, x: 96, y: 64)
        }
        XCTAssertTrue(Self.isWhite(pixels, x: 32, y: 64), "the parent's dot", file: file, line: line)
        XCTAssertTrue(Self.isWhite(pixels, x: 96, y: 64), "the child's dot: \(Self.bgra(pixels, x: 96, y: 64))",
                      file: file, line: line)
        XCTAssertTrue(Self.isRed(pixels, x: 64, y: 64), "nothing between", file: file, line: line)
    }

    /// Group 1 slides from x 32 to 96 in 0.5 s; its particle system's one long-lived dot goes with
    /// it.
    private func assertAnimatedParent(file: StaticString = #filePath, line: UInt = #line) throws {
        let text = #"""
        [{"id": 1, "origin": {"value": "32 64 0", "animation": {"options": {"mode": "single", "fps": 60, "length": 30},
            "c0": [{"frame": 0, "value": 32}, {"frame": 30, "value": 96}],
            "c1": [{"frame": 0, "value": 64}, {"frame": 30, "value": 64}]}}},
         {"id": 2, "parent": 1, "origin": "0 0 0", "particle": "p.json"}]
        """#
        let objects = try JSONDecoder().decode([WESceneObject].self, from: Data(text.utf8))
        let document = try JSONDecoder().decode(SceneJSON.self, from: Data(#"{"objects": \#(text)}"#.utf8))
        var system = dot().configuration
        system.order = 1
        system.objectID = "2"
        var motions: [String: SceneObjectMotion] = [:]
        for object in objects {
            motions[String(object.id!)] = SceneObjectMotion(object: object, bindings: SceneLayerBindings())
        }
        let pixels = try render(systems: [system],
                                transforms: SceneTransformHierarchy(objects: objects), motions: motions,
                                timelines: SceneTimelineSource(wallpaperID: "family", document: document, signature: "1")) {
            Self.isWhite($0, x: 96, y: 64) && Self.isRed($0, x: 32, y: 64)
        }
        XCTAssertTrue(Self.isWhite(pixels, x: 96, y: 64), "the dot moved with its group: \(Self.bgra(pixels, x: 96, y: 64))",
                      file: file, line: line)
        XCTAssertTrue(Self.isRed(pixels, x: 32, y: 64), "and left its start: \(Self.bgra(pixels, x: 32, y: 64))",
                      file: file, line: line)
    }

    /// WE moves every object's model matrix by camera parallax, particle systems too: the object
    /// at x 40 of a 128-wide scene, with the cursor at the centre and amount 0.5, sits at
    /// 40 + 0.5 · (40 − 64) = 28.
    private func assertCameraParallax(file: StaticString = #filePath, line: UInt = #line) throws {
        let objects = try JSONDecoder().decode([WESceneObject].self, from: Data(#"""
        [{"id": 2, "origin": "40 64 0", "particle": "p.json"}]
        """#.utf8))
        var dot = dot()
        dot.origin = SIMD2(40, 64)
        var system = dot.configuration
        system.order = 1
        system.objectID = "2"
        for parallax in [false, true] {
            let pixels = try render(systems: [system],
                                    transforms: SceneTransformHierarchy(objects: objects),
                                    parallax: parallax) {
                parallax ? Self.isWhite($0, x: 17, y: 64) : Self.isWhite($0, x: 50, y: 64)
            }
            XCTAssertEqual(Self.isWhite(pixels, x: 17, y: 64), parallax, "left edge, parallax \(parallax)", file: file, line: line)
            XCTAssertEqual(Self.isWhite(pixels, x: 50, y: 64), !parallax, "right edge, parallax \(parallax)", file: file, line: line)
        }
    }

    // MARK: - Helpers

    /// One still white dot, 30 units across, that lives long.
    private func dot() -> ParticleTestSystem {
        var system = ParticleTestSystem()
        system.origin = SIMD2(32, 64)
        system.spawnExtent = .zero
        system.minimumVelocity = .zero
        system.maximumVelocity = .zero
        system.size = 60...60
        system.lifetime = 100...100
        system.alpha = 1...1
        system.minimumColor = SIMD4(repeating: 1)
        system.maximumColor = SIMD4(repeating: 1)
        system.maximum = 1
        system.source = .image(SceneContentLoader.pixelImage([1, 1, 1, 1]))
        return system
    }

    /// Frames over a red background until `done` holds for the drawn pixels (or 10 s pass).
    private func render(systems: [SceneMetalParticleSystem],
                        transforms: SceneTransformHierarchy = .empty, motions: [String: SceneObjectMotion] = [:],
                        timelines: SceneTimelineSource? = nil, parallax: Bool = false, until done: ([UInt8]) -> Bool) throws -> [UInt8] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: Self.size, height: Self.size)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view))
        view.isPaused = true
        renderer.setPlacement(.stretch)
        let scene = Float(Self.size)
        var content = SceneMetalContent(size: SIMD2(scene, scene), layers: [background(scene)], particleSystems: systems,
                                        bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7,
                                                                  tint: SIMD3(repeating: 1)))
        content.transforms = transforms
        content.motions = motions
        content.timelines = timelines
        content.camera.parallax = parallax
        content.camera.parallaxAmount = 0.5
        content.camera.parallaxDelay = 0
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
        } while Date() < deadline && !done(pixels)
        XCTAssertFalse(pixels.isEmpty, "a drawable to read")
        return pixels
    }

    private func background(_ scene: Float) -> SceneMetalLayer {
        var layer = SceneMetalLayer(
            id: "A", name: "A", source: .image(SceneContentLoader.pixelImage([1, 0, 0, 1])),
            position: SIMD2(scene / 2, scene / 2), size: SIMD2(scene, scene), scale: SIMD2(1, 1), opacity: 1,
            brightness: 1, color: SIMD4(repeating: 1), text: nil,
            parallaxDepth: .zero, perspective: false, rotation: 0)
        layer.order = 0
        return layer
    }

    private static func bgra(_ pixels: [UInt8], x: Int, y: Int) -> [UInt8] {
        guard pixels.count >= size * size * 4 else { return [] }
        let index = (y * size + x) * 4
        return Array(pixels[index..<index + 4])
    }

    private static func isWhite(_ pixels: [UInt8], x: Int, y: Int) -> Bool {
        let p = bgra(pixels, x: x, y: y)
        return p.count == 4 && p[0] > 250 && p[1] > 250 && p[2] > 250
    }

    private static func isRed(_ pixels: [UInt8], x: Int, y: Int) -> Bool {
        let p = bgra(pixels, x: x, y: y)
        return p.count == 4 && p[0] < 5 && p[1] < 5 && p[2] > 250
    }
}
