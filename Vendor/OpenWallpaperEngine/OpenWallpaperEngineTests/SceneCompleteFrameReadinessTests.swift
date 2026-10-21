import XCTest
import MetalKit
import OWESceneEditing
@testable import OpenWallpaperEngine

/// A complete frame (`SceneMetalRenderer.hasCompleteFrame`, what the screen saver, Live Photos and
/// depth captures start from) has every pass that compiles its pipelines off the render thread in
/// it: the shadow casters' (`SceneShadowPass`) and a puppet's texture channels'
/// (`ScenePuppetChannelRenderer`), as the effects', materials', meshes' and volumetrics' already
/// were (`pipelinesCompiling`, `pipelinesLanded`).
///
/// Each test first shows the scene without the pass, so every other pipeline is compiled (a
/// renderer keeps its pipelines across contents), then gives the renderer the scene with it: only
/// the pass's own pipelines compile, so a frame that didn't count them would be complete at once,
/// without the pass.
final class SceneCompleteFrameReadinessTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "owe-complete-frame-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let scratch, FileManager.default.fileExists(atPath: scratch.path) { try FileManager.default.removeItem(at: scratch) }
    }

    /// More Physics (3734636606, rated Everyone): its directional light's three cascades with
    /// shadows high. The first complete frame's atlas holds every caster draw the settled scene's does.
    func testTheFirstCompleteFrameHasEveryShadowCaster() throws {
        _ = try Fixtures.assets()
        let directory = URL(fileURLWithPath: "/Volumes/980Pro/OpenWallpaperStorage/3734636606", isDirectory: true)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: directory.appending(path: "project.json").path),
                          "3734636606 isn't in the library")
        var off = SceneRenderSettings()
        off.shadows = .disabled
        let harness = try ModelSceneHarness(directory: directory, settings: off, size: SIMD2(480, 270),
                                            storage: scratch.appending(path: "scripts"))
        defer { harness.close() }
        let shadows = try XCTUnwrap(harness.renderer.shadowPass)
        XCTAssertTrue(harness.waitForPipelines(), "the scene without shadows compiles")
        XCTAssertTrue(harness.renderer.hasCompleteFrame)
        XCTAssertEqual(shadows.casterDraws, 0, "no shadows yet")

        var high = SceneRenderSettings()
        high.shadows = .high
        let loader = SceneContentLoader(wallpaper: WEWallpaper(using: try ModelSceneHarness.project(in: directory), where: directory))
        loader.setRenderSettings(high)
        let content = try XCTUnwrap(loader.metalContent())
        harness.renderer.renderSettings = high
        harness.renderer.setContent(content)
        let landing = Date().addingTimeInterval(60)
        while !harness.renderer.hasContent || harness.renderer.hasCompleteFrame, Date() < landing {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(harness.renderer.hasContent, "the scene with shadows never landed")

        // Per frame: complete, and the caster draws its atlas holds (a reused atlas holds the last
        // drawn one's).
        var frames: [(complete: Bool, atlas: Int)] = []
        var atlas = 0, idle = 0
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            let draws = shadows.casterDraws, reused = shadows.atlasesReused
            harness.frame(step: 0)
            if shadows.atlasesReused == reused, shadows.casterDraws > draws { atlas = shadows.casterDraws - draws }
            frames.append((harness.renderer.hasCompleteFrame, atlas))
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            idle = harness.renderer.pipelinesCompiling ? 0 : idle + 1
            if harness.renderer.hasCompleteFrame, idle >= 10 { break }
        }
        let first = try XCTUnwrap(frames.firstIndex(where: \.complete), "no complete frame")
        let settled = try XCTUnwrap(frames.last).atlas
        XCTAssertGreaterThan(settled, 0, "the casters draw into the atlas")
        XCTAssertEqual(frames[first].atlas, settled, "the first complete frame's atlas (frame \(first) of \(frames.count))")
        XCTAssertEqual(harness.gpuErrors, [])
    }

    /// WE's rope puppet with one texture channel (`Tests/Fixtures/Models/TextureChannels`), first
    /// at weight 0 (no channel drawn), then with a clip that holds the channel at weight 1: the
    /// first complete frame's image has the channel's colour (70, 250, 200) where the settled one
    /// has it. A frame drawn while the channel's pipeline compiles shows the rope's orange
    /// (250, 200, 70) there. No library rig has texture channels
    /// (docs/models-plan.md §2.13), so the scene is built here from WE's own files.
    func testTheFirstCompleteFrameHasThePuppetsTextureChannel() throws {
        let assets = try Fixtures.assets()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: assets.appending(path: "shaders/puppettexturechannels.vert").path),
                          "WE's puppettexturechannels shader missing")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 96, height: 512), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 96, height: 512)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "complete-frame"))
        defer { renderer.releaseContent() }
        view.isPaused = true
        var now: CFTimeInterval = 1000
        renderer.wallTime = { now }

        func frame() {
            now += 1.0 / 30
            renderer.renderShared([SceneViewport(drawableSize: SIMD2(96, 512), pointSize: SIMD2(96, 512), cursor: nil,
                                                 frameRateLimit: 30)])
            renderer.lastCommandBuffer?.waitUntilCompleted()
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        func show(channelOn: Bool) throws {
            let directory = try channelScene(channelOn: channelOn)
            addTeardownBlock { Fixtures.removeStoredSettings(for: directory) }
            let project = try JSONDecoder().decode(WEProject.self, from: Data(contentsOf: directory.appending(path: "project.json")))
            let content = try XCTUnwrap(SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory)).metalContent())
            XCTAssertNotNil(content.layers.first(where: { $0.id == "1" })?.puppet?.channels, "the rope has its channel")
            renderer.setContent(content)
            let landing = Date().addingTimeInterval(60)
            while !renderer.hasContent || renderer.hasCompleteFrame, Date() < landing {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertTrue(renderer.hasContent)
            let deadline = Date().addingTimeInterval(60)
            while !renderer.hasCompleteFrame, Date() < deadline { frame() }
            XCTAssertTrue(renderer.hasCompleteFrame, "no complete frame")
        }
        /// The image's texels in the channel's colour and in the rope's.
        func colours() throws -> (channel: Int, rope: Int) {
            let drawn = try XCTUnwrap(renderer.puppetImage(ofLayer: "1"), "the mesh drew")
            let pixels = try ScenePuppetTestSupport.rgba8(drawn.image, device: device)
            var channel = 0, rope = 0
            for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] == 255 {
                let rgb = pixels[index..<index + 3].map { Int($0) }
                if zip(rgb, [70, 250, 200]).allSatisfy({ abs($0 - $1) <= 3 }) { channel += 1 }
                if zip(rgb, [250, 200, 70]).allSatisfy({ abs($0 - $1) <= 3 }) { rope += 1 }
            }
            return (channel, rope)
        }

        try show(channelOn: false)
        XCTAssertEqual(try colours().channel, 0, "weight 0: the rope as it is")
        try show(channelOn: true)
        let first = try colours()
        for _ in 0..<30 { frame() }
        let settled = try colours()
        XCTAssertGreaterThan(settled.channel, 1000, "the settled image shows the channel")
        // The rope's chain swings as the clock runs, which moves a few texels; a frame without the
        // channel has none of its colour.
        XCTAssertGreaterThan(Double(first.channel), 0.95 * Double(settled.channel),
                             "the first complete frame has the channel (\(first.channel) of \(settled.channel) texels)")
    }

    /// A scene of one image, the rope puppet with its channel (`rope_puppet_on.mdl`, plus a clip
    /// whose channel track holds 1); with `channelOn` its animation layer plays that clip.
    private func channelScene(channelOn: Bool) throws -> URL {
        let fixture = Fixtures.url("Models/TextureChannels")
        let directory = scratch.appending(path: channelOn ? "on" : "off", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for folder in ["materials", "models"] {
            try FileManager.default.copyItem(at: fixture.appending(path: folder), to: directory.appending(path: folder))
        }
        var document = try PuppetMDLReader.read(try Fixtures.data("Models/TextureChannels/models/rope_puppet_on.mdl"),
                                                imageSize: SIMD2(96, 512))
        let clip = document.addClip(named: "channel on", fps: 10, frames: 4)
        document.clips[clip].channelTracks = [PuppetChannelTrack(tag: 0, samples: [1, 1, 1, 1])]
        try PuppetMDLWriter.write(document).write(to: directory.appending(path: "models/rope_puppet.mdl"))
        let layers = channelOn
            ? #", "animationlayers": [ { "id": 2, "animation": \#(document.clips[clip].id), "blend": 1, "rate": 1, "visible": true, "additive": false } ]"#
            : ""
        try Data(#"{"file": "scene.json", "title": "Fixture: a puppet's texture channel", "type": "scene"}"#.utf8)
            .write(to: directory.appending(path: "project.json"))
        try Data("""
            {
              "camera": { "center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0" },
              "general": { "bloom": false, "clearcolor": "0 0 0", "orthogonalprojection": { "width": 96, "height": 512 } },
              "objects": [
                { "id": 1, "name": "Rope", "image": "models/rope.json", "origin": "48 256 0", "size": "96 512"\(layers) }
              ],
              "version": 1
            }
            """.utf8).write(to: directory.appending(path: "scene.json"))
        return directory
    }
}
