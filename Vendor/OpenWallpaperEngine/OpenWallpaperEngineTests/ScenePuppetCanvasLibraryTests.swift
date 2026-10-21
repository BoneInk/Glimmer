import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// The Knight (2515150033): its puppet `centurion 1080p_sheet` (id 21, no effects) holds a sword
/// whose blade its `idle` clip carries past the image's left edge (scene x ≈ 172). WE draws a
/// puppet without effects through its mesh in the scene (docs/models-plan.md §2.13), so the blade
/// runs on to the screen's edge; drawn only inside its image, it was cut off square at the edge.
///
/// The puppet drawn alone (every other object hidden, the clear colour black): left of its image
/// its pixels show. `OWE_SWORD_OUT` names a folder for the frames as PNG. Skipped without the wallpaper;
/// `OWE_LIBRARY` overrides the library root.
final class ScenePuppetCanvasLibraryTests: XCTestCase {
    private static let drawable = SIMD2(960, 540)
    private static let puppet = "21"

    func testTheKnightsSwordDrawsPastItsImage() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OWE_LIBRARY"] ?? "/Volumes/980Pro/OpenWallpaperStorage")
        let directory = root.appending(path: "2515150033", directoryHint: .isDirectory)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: directory.appending(path: "scene.json").path), "wallpaper not present")
        let frames = try sceneFrames(directory, only: Self.puppet)
        let output = ProcessInfo.processInfo.environment["OWE_SWORD_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        // Left of the image's rect (scene x < 165 of 1920), where the image alone can't draw.
        let edge: Int = Self.drawable.x * 165 / 1920
        var changed: [Int] = []
        for (index, frame) in frames.enumerated() {
            var count = 0
            for y in 0..<Self.drawable.y {
                for x in 0..<edge {
                    let i = (y * Self.drawable.x + x) * 4
                    if (0..<3).contains(where: { frame[i + $0] > 6 }) { count += 1 }
                }
            }
            changed.append(count)
            if let output {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try ScenePuppetLibraryTests.png(frame, size: Self.drawable)
                    .write(to: output.appending(path: "knight-puppet-\(index).png"))
            }
        }
        if let output {
            for (index, frame) in try sceneFrames(directory, only: nil).enumerated() {
                try ScenePuppetLibraryTests.png(frame, size: Self.drawable).write(to: output.appending(path: "knight-scene-\(index).png"))
            }
        }
        print("The Knight's puppet left of its image, changed pixels per frame: \(changed)")
        let most: Int = changed.max() ?? 0
        // The blade is ~10 px tall here and runs ~80 px past the edge in the clip's widest poses.
        XCTAssertGreaterThan(most, 300, "the sword is cut off at the image's edge: \(changed)")
    }

    /// Frames at 1, 2, … 6 s of `directory`'s scene (with only object `only` shown), RGBA.
    private func sceneFrames(_ directory: URL, only: String?) throws -> [[UInt8]] {
        let project = try JSONDecoder().decode(WEProject.self, from: Data(contentsOf: directory.appending(path: "project.json")))
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        var content = try XCTUnwrap(model.metalContent())
        defer { Fixtures.removeStoredSettings(for: directory) }
        XCTAssertNotNil(content.layers.first { $0.id == Self.puppet }?.puppet, "layer 21 is a puppet")
        if let only {
            for id in content.objectIDs { content.visibility[String(id)] = String(id) == only }
        }
        let storage = FileManager.default.temporaryDirectory.appending(path: "owe-puppet-canvas-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storage) } // scratch cleanup
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                                           media: SceneScriptReplayMediaSource(), spectrum: { .silent })
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let size = Self.drawable
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: size.x, height: size.y), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: size.x, height: size.y)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: services, screenID: "puppet-canvas"))
        view.isPaused = true
        var settings = SceneRenderSettings()
        settings.postProcessing = .disabled
        renderer.renderSettings = settings
        renderer.setPlacement(.stretch)
        renderer.scripts.frameWait = 5
        var now: CFTimeInterval = 1000
        renderer.wallTime = { now }
        renderer.setContent(content)
        let deadline = Date().addingTimeInterval(60)
        while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        defer { renderer.releaseContent() }
        func draw() {
            now += 1.0 / 20
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            renderer.scripts.wallpaper?.waitUntilIdle()
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        // Until the mesh and the layer materials are ready.
        while renderer.puppetImage(ofLayer: Self.puppet) == nil, Date() < deadline { draw() }
        var result: [[UInt8]] = []
        for _ in 0..<6 {
            for _ in 0..<20 { draw() }
            var bytes = [UInt8](repeating: 0, count: size.x * size.y * 4)
            let texture = try XCTUnwrap(view.currentDrawable?.texture)
            texture.getBytes(&bytes, bytesPerRow: size.x * 4, from: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0)
            result.append(SceneMipMappedFrameBufferTests.swappingRedAndBlue(bytes))
        }
        return result
    }
}
