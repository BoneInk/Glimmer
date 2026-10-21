import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// End to end (docs/scenescript-plan.md WP11): scenes loaded through the real loader, drawn
/// headlessly by the renderer with its SceneScript runtime, and script writes checked in the
/// pixels: an origin moves a layer, visibility scripts show and hide layers, a material constant
/// changes an effect's output, `createLayer` draws, and a text script changes the text.
final class SceneScriptRenderTests: XCTestCase {
    private var storage: URL!

    override func setUpWithError() throws {
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-render-scripts-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let storage, FileManager.default.fileExists(atPath: storage.path) {
            try FileManager.default.removeItem(at: storage)
        }
    }

    // MARK: - Pixels

    func testScriptWritesReachThePixels() throws {
        _ = try Fixtures.assets()
        let scene = try Scene(fixture: "scripted", services: services(), size: SIMD2(128, 64))
        defer { scene.close() }
        // Effect pipelines compile off the render thread; the tinted layer draws plain until then.
        let pixels = try scene.render(frames: 6) { !Fixtures.hasWEShaderSources || $0.color(atScene: SIMD2(16, 16)) != .white }

        XCTAssertEqual(pixels.color(atScene: SIMD2(48, 32)), .red, "the origin script moved Mover to x = 48")
        XCTAssertEqual(pixels.color(atScene: SIMD2(8, 32)), .black, "nothing is left where Mover was authored")
        XCTAssertEqual(pixels.color(atScene: SIMD2(32, 56)), .green, "a layer hidden at load is shown by its script")
        XCTAssertEqual(pixels.color(atScene: SIMD2(32, 8)), .black, "a visible layer is hidden by its script")
        XCTAssertEqual(pixels.color(atScene: SIMD2(56, 56)), .yellow, "the layer createLayer made is drawn")
        XCTAssertGreaterThan(pixels.litPixels(from: SIMD2(70, 20), to: SIMD2(122, 44)), 40,
                             "the text script's string (a user-bound script property) is drawn")
        if Fixtures.hasWEShaderSources {
            XCTAssertEqual(pixels.color(atScene: SIMD2(16, 16)), .green, "the constant script turned the tint green")
        }
    }

    /// A still (the lock screen's picture, the screen saver's) leaves out every text layer and the
    /// clock hands (a rotation script that reads the date), so it never shows the time it was taken;
    /// the frames drawn live, before and after it, keep them.
    func testAStillLeavesOutTheTextAndTheClockHandsAndTheLiveFramesKeepThem() throws {
        _ = try Fixtures.assets()
        let scene = try Scene(fixture: "still-layers", services: services(), size: SIMD2(128, 64))
        defer { scene.close() }
        let label = (low: SIMD2(70, 20), high: SIMD2(122, 44))
        let live = try scene.render(frames: 3) { $0.litPixels(from: label.low, to: label.high) > 40 }
        XCTAssertEqual(scene.renderer.stillLayerIDs, ["2", "3"])
        XCTAssertEqual(live.color(atScene: SIMD2(16, 32)), .blue)
        XCTAssertEqual(live.color(atScene: SIMD2(48, 32)), .red, "the live frame draws the clock hand")
        XCTAssertGreaterThan(live.litPixels(from: label.low, to: label.high), 40, "and the text")

        final class Captured: @unchecked Sendable { var image: CGImage? }
        let captured = Captured()
        let done = expectation(description: "the still")
        let viewport = SceneViewport(drawableSize: SIMD2(128, 64), pointSize: SIMD2(128, 64), cursor: nil, frameRateLimit: 60)
        XCTAssertTrue(scene.renderer.captureStill(pixelSize: SIMD2(128, 64), pixelsPerPoint: 1, viewports: [viewport],
                                                  restores: false) { image in
            captured.image = image
            done.fulfill()
        })
        wait(for: [done], timeout: 10)
        XCTAssertFalse(scene.renderer.hidesStillLayers, "only the still's frame leaves them out")
        let still = try Pixels(XCTUnwrap(captured.image))
        XCTAssertEqual(still.color(atScene: SIMD2(16, 32)), .blue, "the other layers stay")
        XCTAssertEqual(still.color(atScene: SIMD2(48, 32)), .black, "no clock hand")
        XCTAssertEqual(still.litPixels(from: label.low, to: label.high), 0, "no text")

        let after = try scene.render(frames: 1)
        XCTAssertEqual(after.color(atScene: SIMD2(48, 32)), .red)
        XCTAssertGreaterThan(after.litPixels(from: label.low, to: label.high), 40)
    }

    /// Without scripts the same scene shows what scene.json authored: a baseline for the test above.
    /// WP4-C: the layer `createLayer` made draws in the first frame that takes its event, not a
    /// frame or more later (WE builds it inside `createLayer`).
    func testACreatedLayerDrawsInTheFrameThatTakesIt() throws {
        _ = try Fixtures.assets()
        let scene = try Scene(fixture: "scripted", services: services(), size: SIMD2(128, 64))
        defer { scene.close() }
        let deadline = Date().addingTimeInterval(30)
        while !scene.renderer.hasContent && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            scene.renderer.draw(in: scene.view)
            scene.renderer.lastCommandBuffer?.waitUntilCompleted()
        }
        // The scripts' `init` (and its createLayer) ran; its event waits for the next draw.
        scene.renderer.scripts.wallpaper?.waitUntilIdle()
        scene.renderer.draw(in: scene.view)
        scene.renderer.lastCommandBuffer?.waitUntilCompleted()
        XCTAssertEqual(scene.renderer.pendingScriptLayers, 0, "nothing was left to build off the frame")
        XCTAssertEqual(scene.read().color(atScene: SIMD2(56, 56)), .yellow, "drawn in the same frame")
    }

    func testTheSameSceneWithoutScriptsShowsTheAuthoredValues() throws {
        _ = try Fixtures.assets()
        let scene = try Scene(fixture: "scripted", services: nil, size: SIMD2(128, 64))
        defer { scene.close() }
        let pixels = try scene.render(frames: 3) { !Fixtures.hasWEShaderSources || $0.color(atScene: SIMD2(16, 16)) != .white }

        XCTAssertEqual(pixels.color(atScene: SIMD2(8, 32)), .red)
        XCTAssertEqual(pixels.color(atScene: SIMD2(48, 32)), .black)
        XCTAssertEqual(pixels.color(atScene: SIMD2(32, 56)), .black, "hidden at load, still built")
        XCTAssertEqual(pixels.color(atScene: SIMD2(32, 8)), .blue)
        XCTAssertEqual(pixels.color(atScene: SIMD2(56, 56)), .black)
        XCTAssertEqual(pixels.litPixels(from: SIMD2(70, 20), to: SIMD2(122, 44)), 0)
        if Fixtures.hasWEShaderSources {
            XCTAssertEqual(pixels.color(atScene: SIMD2(16, 16)), .blue)
        }
    }

    // MARK: - Instances

    /// `general.clearenabled`: on unless authored false (`null` too, as 44 of WE's own scenes have it).
    func testClearEnabledDecodesWithWEsDefault() throws {
        func general(_ json: String) throws -> WESceneGeneral { try decodeTolerant(WESceneGeneral.self, from: Data(json.utf8)) }
        let context = SpatialProperties()
        XCTAssertTrue(try general("{}").clearEnabled(in: context))
        XCTAssertTrue(try general(#"{"clearenabled": null}"#).clearEnabled(in: context))
        XCTAssertTrue(try general(#"{"clearenabled": true}"#).clearEnabled(in: context))
        XCTAssertFalse(try general(#"{"clearenabled": false}"#).clearEnabled(in: context))
    }

    /// With `clearenabled` off WE doesn't clear the scene before a frame: Mover's script moves it
    /// from x = 16 to x = 48 on its third frame, and both places stay red. Once its script sets
    /// `thisScene.clearenabled` back on (frame 20), a frame shows only where it is now.
    func testClearEnabledOffKeepsTheLastFrame() throws {
        _ = try Fixtures.assets()
        let scene = try Scene(fixture: "scripted-clear", services: services(), size: SIMD2(128, 64))
        defer { scene.close() }
        let kept = try scene.render(frames: 6)
        XCTAssertEqual(kept.color(atScene: SIMD2(48, 32)), .red, "where Mover is")
        XCTAssertEqual(kept.color(atScene: SIMD2(16, 32)), .red, "where Mover was: the scene wasn't cleared")
        XCTAssertEqual(kept.color(atScene: SIMD2(100, 32)), .black)

        let cleared = try scene.render(frames: 22)
        XCTAssertEqual(cleared.color(atScene: SIMD2(48, 32)), .red)
        XCTAssertEqual(cleared.color(atScene: SIMD2(16, 32)), .black, "a cleared frame shows only the current place")
    }

    /// S22: two displays showing the same wallpaper run two runtimes that share nothing: module
    /// variables, `shared` and frame counts are their own.
    func testTwoDisplaysShareNothing() throws {
        _ = try Fixtures.assets()
        let services = services()
        let first = try Scene(fixture: "scripted-counter", services: services, size: SIMD2(64, 64), screenID: "A")
        defer { first.close() }
        let second = try Scene(fixture: "scripted-counter", services: services, size: SIMD2(64, 64), screenID: "B")
        defer { second.close() }
        _ = try first.render(frames: 10)
        _ = try second.render(frames: 3)

        let a = try XCTUnwrap(first.origin(of: "1"))
        let b = try XCTUnwrap(second.origin(of: "1"))
        XCTAssertEqual(a.x, b.x + 7, "each runtime counts its own frames")
        XCTAssertEqual(a.y, a.x, "`shared` is the runtime's own")
        XCTAssertEqual(b.y, b.x, "`shared` is the runtime's own")
        XCTAssertNotIdentical(first.renderer.scripts.wallpaper, second.renderer.scripts.wallpaper)
    }

    /// Like WE, a frame draws what its own scripts did: the draw waits for the script frame it
    /// started (plan §4.4), so there is no frame of latency.
    func testADrawShowsItsOwnScriptFrame() throws {
        _ = try Fixtures.assets()
        let scene = try Scene(fixture: "scripted-counter", services: services(), size: SIMD2(64, 64))
        defer { scene.close() }
        scene.renderer.scripts.frameWait = 5 // a loaded test machine; the app waits 4 ms
        _ = try scene.render(frames: 3)
        let before = try XCTUnwrap(scene.renderer.scripts.object("1")?.vector3(.origin)).x
        for step in 1...3 {
            scene.renderer.draw(in: scene.view)
            let drawn = try XCTUnwrap(scene.renderer.scripts.object("1")?.vector3(.origin)).x
            XCTAssertEqual(drawn, before + Float(step), "draw \(step) shows the update it ran")
        }
    }

    /// A user property only scripts read reaches `applyUserProperties` without a content rebuild.
    func testAScriptOnlyUserPropertyReachesTheScriptsWithoutARebuild() throws {
        _ = try Fixtures.assets()
        let scene = try Scene(fixture: "scripted-counter", services: services(), size: SIMD2(64, 64))
        defer { scene.close() }
        _ = try scene.render(frames: 2)
        XCTAssertEqual(scene.model.impact(of: ["offset"]), .none, "only a script reads it")

        let key = scene.model.propertyStoreKey
        WallpaperServices.shared.setUserProperties(["offset": "42"], wallpaper: key, replacing: false)
        scene.renderer.scripts.userPropertiesDidChange(["offset"])
        _ = try scene.render(frames: 2)
        XCTAssertEqual(scene.origin(of: "1")?.z, 42, "applyUserProperties({offset: 42})")
    }

    /// The watchdog stops a hung script's wallpaper (plan §1.9 P5): the renderer is told once and
    /// keeps drawing, and another display's scripts keep running.
    func testAHungScriptHaltsOnlyItsWallpaper() throws {
        _ = try Fixtures.assets()
        var configuration = SceneScriptRuntime.Configuration.standard
        configuration.frameTimeLimit = 0.3
        let services = services(configuration: configuration)
        let hung = try Scene(fixture: "scripted-hang", services: services, size: SIMD2(64, 64), screenID: "A")
        defer { hung.close() }
        let healthy = try Scene(fixture: "scripted-counter", services: services, size: SIMD2(64, 64), screenID: "B")
        defer { healthy.close() }
        var halts: [SceneScriptError?] = []
        hung.renderer.scripts.onHalt = { halts.append($0) }

        _ = try hung.render(frames: 8)
        _ = try healthy.render(frames: 4)
        XCTAssertEqual(halts.count, 1, "reported once")
        XCTAssertEqual(halts.first??.kind, .terminated)
        XCTAssertTrue(hung.renderer.scripts.state.halted)
        XCTAssertEqual(hung.origin(of: "1")?.x, 3, "the last values stay")
        XCTAssertEqual(healthy.origin(of: "1")?.x, 4, "the other display's scripts go on")
    }

    // MARK: - Objects scripts drive

    /// Sound layers under script control (`stop()`, a bound `volume`), `createLayer` of a particle
    /// system and of a sound, a bound `brightness` dimming a layer and a bound `size` growing one.
    func testScriptsDriveSoundsCreatedObjectsBrightnessAndSize() throws {
        _ = try Fixtures.assets()
        let scene = try Scene(fixture: "scripted-objects", services: services(), size: SIMD2(64, 64))
        defer { scene.close() }
        // WE applies `brightness` only under ultra post-processing (`SceneRenderSettings.appliesBrightness`).
        var settings = SceneRenderSettings()
        settings.postProcessing = .ultra
        scene.renderer.renderSettings = settings
        let pixels = try scene.render(frames: 8) { _ in scene.renderer.particleSystemCount > 0 }

        let sounds = scene.renderer.sounds
        let tone = try XCTUnwrap(sounds.playback(of: 2), "the scene's sound layer")
        XCTAssertTrue(tone.isStopped, "its script stopped it on frame 3")
        XCTAssertEqual(tone.volume, 0.5, "the volume script's return")
        let made = try XCTUnwrap(sounds.ids.first { $0 >= SceneScriptSceneDescriber.firstCreatedID }, "createLayer made a sound")
        XCTAssertEqual(sounds.playback(of: made)?.isPlaying, false, "startsilent")
        XCTAssertEqual(scene.renderer.particleSystemCount, 1, "createLayer('particles/…') made a particle system")

        XCTAssertEqual(pixels.color(atScene: SIMD2(46, 16)), .red, "the size script grew Grown from 8 to 16")
        let dimmed = pixels.rgb(atScene: SIMD2(16, 48))
        XCTAssertTrue((90...170).contains(Int(dimmed.x)) && abs(Int(dimmed.x) - Int(dimmed.y)) < 8,
                      "brightness 0.5 halves Dimmed's white: \(dimmed)")
    }

    /// `IImageLayer.alignment` and `IEffectLayer.perspective` written by scripts are drawn: Aligned
    /// (8 × 8 at x = 16) sits right of its origin once a script sets `left`, and Near (z = 15)
    /// draws larger than its 8 × 8 through the temporary camera once a script turns `perspective` on.
    func testScriptSetAlignmentAndPerspectiveAreDrawn() throws {
        _ = try Fixtures.assets()
        let plain = try Scene(fixture: "scripted-fields", services: nil, size: SIMD2(128, 64))
        let authored = try plain.render(frames: 3)
        plain.close()
        XCTAssertEqual(authored.color(atScene: SIMD2(13, 32)), .red, "centred on its origin as authored")
        XCTAssertEqual(authored.color(atScene: SIMD2(22, 32)), .black)
        let flat = authored.litPixels(from: SIMD2(70, 2), to: SIMD2(122, 62))
        XCTAssertEqual(Double(flat), 64, accuracy: 12, "Near draws flat, 8 × 8")

        let scene = try Scene(fixture: "scripted-fields", services: services(), size: SIMD2(128, 64))
        defer { scene.close() }
        let pixels = try scene.render(frames: 4)
        XCTAssertEqual(pixels.color(atScene: SIMD2(22, 32)), .red, "alignment 'left' puts the quad right of its origin")
        XCTAssertEqual(pixels.color(atScene: SIMD2(13, 32)), .black)
        let deep = pixels.litPixels(from: SIMD2(70, 2), to: SIMD2(122, 62))
        XCTAssertGreaterThan(abs(deep - flat), 20, "perspective draws Near through the temporary camera: \(deep) vs \(flat)")
    }

    // MARK: - Draw order

    func testDrawOrderPutsParticlesBetweenTheLayersAroundThem() {
        let layers = [(id: "1", order: 0), (id: "3", order: 2)]
        let systems: [(id: String?, order: Int)] = [(id: "2", order: 1)]
        let authored = SceneRendererScripts.drawOrder(layers: layers, systems: systems, scriptOrder: nil)
        XCTAssertEqual(authored.sequence, [0, 1])
        XCTAssertEqual(authored.barriers, [0, 2], "the system (order 1) draws before layer 3")

        let sorted = SceneRendererScripts.drawOrder(layers: layers, systems: systems, scriptOrder: [3, 1, 2])
        XCTAssertEqual(sorted.sequence, [1, 0], "layer 3 was sorted to the bottom")
        XCTAssertEqual(sorted.barriers, [Int.min, Int.min], "no system sits below either layer now")
    }

    // MARK: - Support

    private func services(configuration: SceneScriptRuntime.Configuration = .standard) -> SceneScriptServices {
        SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                            media: SceneScriptReplayMediaSource(), spectrum: { .silent }, configuration: configuration)
    }

    /// One scene fixture on one display: its loader, renderer and offscreen view.
    private final class Scene {
        let model: SceneContentLoader
        let renderer: SceneMetalRenderer
        let view: MTKView
        let directory: URL
        let size: SIMD2<Int>

        init(fixture: String, services: SceneScriptServices?, size: SIMD2<Int>, screenID: String = "test") throws {
            directory = Fixtures.url("Scenes/\(fixture)")
            self.size = size
            let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/\(fixture)/project.json"))
            model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            view = MTKView(frame: CGRect(x: 0, y: 0, width: size.x, height: size.y), device: device)
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = false
            view.autoResizeDrawable = false
            view.drawableSize = CGSize(width: size.x, height: size.y)
            renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: services, screenID: screenID))
            view.isPaused = true
            renderer.setPlacement(.stretch)
            renderer.setContent(try XCTUnwrap(model.metalContent()))
        }

        func close() {
            renderer.releaseContent()
            Fixtures.removeStoredSettings(for: directory)
        }

        /// Draws `frames` frames, each after the scripts finished the previous one, then more until
        /// `ready` holds, and returns the last one's pixels. Waits for the content (and layers
        /// scripts create) to be built.
        func render(frames: Int, until ready: (Pixels) -> Bool = { _ in true }) throws -> Pixels {
            let deadline = Date().addingTimeInterval(30)
            var drawn = 0
            var pixels = Pixels(bytes: [], size: size)
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                renderer.draw(in: view)
                renderer.lastCommandBuffer?.waitUntilCompleted()
                renderer.scripts.wallpaper?.waitUntilIdle()
                if renderer.hasContent { drawn += 1 }
                pixels = read()
            } while (drawn < frames || renderer.pendingScriptLayers > 0 || renderer.pendingTextRasters > 0
                     || !ready(pixels)) && Date() < deadline
            return pixels
        }

        func read() -> Pixels {
            var bytes = [UInt8](repeating: 0, count: size.x * size.y * 4)
            view.currentDrawable?.texture.getBytes(&bytes, bytesPerRow: size.x * 4,
                                                   from: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0)
            return Pixels(bytes: bytes, size: size)
        }

        func origin(of id: String) -> SIMD3<Float>? {
            renderer.scripts.wallpaper?.waitUntilIdle()
            _ = renderer.scripts.beginFrame()
            return renderer.scripts.object(id)?.vector3(.origin)
        }
    }

    enum Color: Equatable {
        case black, white, red, green, blue, yellow, other
    }

    struct Pixels {
        let bytes: [UInt8]
        let size: SIMD2<Int>

        init(bytes: [UInt8], size: SIMD2<Int>) {
            self.bytes = bytes
            self.size = size
        }

        /// An image's pixels, as BGRA rows from the top.
        init(_ image: CGImage) throws {
            size = SIMD2(image.width, image.height)
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                  | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            try XCTSkipUnless(drawn, "no bitmap context")
            self.bytes = bytes
        }

        /// The colour at a scene point (the scene is drawn stretched onto the whole view, y up).
        func color(atScene point: SIMD2<Float>) -> Color {
            let x = Int(point.x), y = size.y - 1 - Int(point.y)
            let index = (y * size.x + x) * 4
            let (b, g, r) = (bytes[index], bytes[index + 1], bytes[index + 2])
            func on(_ value: UInt8) -> Bool { value > 180 }
            func off(_ value: UInt8) -> Bool { value < 60 }
            switch (on(r), on(g), on(b)) {
            case (false, false, false) where off(r) && off(g) && off(b): return .black
            case (true, false, false) where off(g) && off(b): return .red
            case (false, true, false) where off(r) && off(b): return .green
            case (false, false, true) where off(r) && off(g): return .blue
            case (true, true, false) where off(b): return .yellow
            case (true, true, true): return .white
            default: return .other
            }
        }

        /// The colour's bytes (r, g, b) at a scene point.
        func rgb(atScene point: SIMD2<Float>) -> SIMD3<UInt8> {
            let x = Int(point.x), y = size.y - 1 - Int(point.y)
            let index = (y * size.x + x) * 4
            return SIMD3(bytes[index + 2], bytes[index + 1], bytes[index])
        }

        /// Pixels brighter than black within a scene rectangle.
        func litPixels(from low: SIMD2<Int>, to high: SIMD2<Int>) -> Int {
            var count = 0
            for sceneY in low.y...high.y {
                for sceneX in low.x...high.x {
                    let index = ((size.y - 1 - sceneY) * size.x + sceneX) * 4
                    if Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2]) > 90 { count += 1 }
                }
            }
            return count
        }
    }
}
