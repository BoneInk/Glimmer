import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// Headless checks that the scene pipeline actually produces what WE content needs. Known gaps are
/// recorded with XCTExpectFailure (strict), so fixing one makes its test fail until the expectation
/// is removed, and the gap can't be forgotten.
final class RenderCheckTests: XCTestCase {
    func testLoaderKeepsEveryVisibleLayer() throws {
        _ = try Fixtures.assets()
        let directory = Fixtures.url("Scenes/layers")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/layers/project.json"))
        let wallpaper = WEWallpaper(using: project, where: directory)
        defer {
            Fixtures.removeStoredSettings(for: directory)
        }
        let content = try XCTUnwrap(SceneContentLoader(wallpaper: wallpaper).metalContent())
        let ids = Set(content.layers.map(\.id))
        XCTAssertTrue(ids.contains("1"), "text layer missing; layers: \(ids)")
        // Kept, but it samples _rt_FullFrameBuffer, which is still a transparent placeholder (B1);
        // a pixel check belongs to the Phase 3 compositing work.
        // A composition layer only exists while its effect can run, which needs WE's shader sources.
        if Fixtures.hasWEShaderSources {
            XCTAssertTrue(ids.contains("3"), "composition layer missing; layers: \(ids)")
        }
        XCTAssertTrue(ids.contains("2"), "solid layer missing; layers: \(ids)")
        // Risk I18: text without effects draws through WE's `font` material.
        let text = try XCTUnwrap(content.layers.first { $0.id == "1" })
        XCTAssertEqual(text.imageMaterial?.materialPath, "materials/fonts/basefont.json")
    }

    /// 2963872291's 'Player Options' is a white solid layer sized "0 0" (a host for the music
    /// player's scripts) centred on the bottom edge at 1.4×. WE draws nothing of an empty quad; a
    /// scene-sized stand-in painted the bottom half of the screen white.
    func testZeroSizeSolidLayerDrawsNothing() throws {
        _ = try Fixtures.assets()
        let size = SIMD2(480, 272)
        let directory = Fixtures.url("Scenes/zero-size-solid")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/zero-size-solid/project.json"))
        defer { Fixtures.removeStoredSettings(for: directory) }
        let content = try XCTUnwrap(SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory)).metalContent())
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: size.x, height: size.y), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: size.x, height: size.y)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "zero-size-solid"))
        defer { renderer.releaseContent() }
        view.isPaused = true
        renderer.setPlacement(.stretch)
        renderer.setContent(content)
        var drawn = 0
        let deadline = Date().addingTimeInterval(30)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            if renderer.hasContent { drawn += 1 }
        } while drawn < 3 && Date() < deadline
        XCTAssertTrue(renderer.hasContent)
        var bytes = [UInt8](repeating: 0, count: size.x * size.y * 4)
        view.currentDrawable?.texture.getBytes(&bytes, bytesPerRow: size.x * 4,
                                               from: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0)
        // The whole frame, the bottom half included, is the blue background (bgra bytes).
        for y in stride(from: 8, to: size.y, by: 16) {
            for x in stride(from: 8, to: size.x, by: 16) {
                let i = (y * size.x + x) * 4
                XCTAssertEqual(SIMD3(bytes[i + 2], bytes[i + 1], bytes[i]), SIMD3(0, 0, 255), "pixel (\(x), \(y))")
            }
        }
    }

    /// WE sizes a textureless layer's effect buffers to its `size` (0x140209206…0x14020923c),
    /// not to the 1×1 fill its quad stretches. The fixture's effect writes the pixel's u into red:
    /// at the layer's size it ramps across the layer; on a 1×1 buffer the layer was one flat colour.
    func testSolidLayerEffectsRunAtTheLayersSize() throws {
        _ = try Fixtures.assets()
        XCTAssertEqual(SolidEffectInput.size(SIMD2(128, 64)), SIMD2(128, 64))
        XCTAssertEqual(SolidEffectInput.size(SIMD2(100.5, 0.4)), SIMD2(101, 1))
        let size = SIMD2(128, 64)
        let directory = Fixtures.url("Scenes/solid-effect")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/solid-effect/project.json"))
        defer { Fixtures.removeStoredSettings(for: directory) }
        let content = try XCTUnwrap(SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory)).metalContent())
        let layer = try XCTUnwrap(content.layers.first)
        XCTAssertEqual(layer.solidFill, SIMD4(0, 0, 1, 1))
        try XCTSkipIf(layer.weEffects.isEmpty, "no shader toolchain for the fixture's effect")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: size.x, height: size.y), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: size.x, height: size.y)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "solid-effect"))
        defer { renderer.releaseContent() }
        view.isPaused = true
        renderer.setPlacement(.stretch)
        renderer.setContent(content)
        var bytes = [UInt8](repeating: 0, count: size.x * size.y * 4)
        // (r, g, b) at a view pixel.
        func rgb(_ x: Int, _ y: Int) -> SIMD3<UInt8> {
            let i = (y * size.x + x) * 4
            return SIMD3(bytes[i + 2], bytes[i + 1], bytes[i])
        }
        let deadline = Date().addingTimeInterval(60)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            view.currentDrawable?.texture.getBytes(&bytes, bytesPerRow: size.x * 4,
                                                   from: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0)
        } while rgb(size.x - 4, 32).x == 0 && Date() < deadline
        let left = rgb(4, 32), middle = rgb(64, 32), right = rgb(size.x - 4, 32)
        XCTAssertLessThan(left.x, 16, "left \(left)")
        XCTAssertEqual(Int(middle.x), 128, accuracy: 4, "middle \(middle)")
        XCTAssertGreaterThan(right.x, 240, "right \(right)")
        XCTAssertEqual(right.z, 255, "the fill's blue under the ramp")
    }

    /// A solid layer's last effect pass draws into the scene through the layer's quad, as an
    /// image's does: its `a_Position` is the quad in layer units, centred (±64 × ±32 here), not the
    /// buffer's −1…1. 3141421197's ray-marcher takes its rays from it over `g_Texture0Resolution`;
    /// with −1…1 every pixel looked down the tunnel's dark centre and the wallpaper was black.
    func testSolidLayerLastPassSeesTheLayersPositions() throws {
        _ = try Fixtures.assets()
        let size = SIMD2(128, 64)
        let directory = Fixtures.url("Scenes/solid-position-effect")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/solid-position-effect/project.json"))
        defer { Fixtures.removeStoredSettings(for: directory) }
        let content = try XCTUnwrap(SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory)).metalContent())
        let layer = try XCTUnwrap(content.layers.first)
        XCTAssertEqual(layer.solidBlending, "translucent", "WE's solidlayer material's blending")
        try XCTSkipIf(layer.weEffects.isEmpty, "no shader toolchain for the fixture's effect")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: size.x, height: size.y), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: size.x, height: size.y)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "solid-position-effect"))
        defer { renderer.releaseContent() }
        view.isPaused = true
        renderer.setPlacement(.stretch)
        renderer.setContent(content)
        var bytes = [UInt8](repeating: 0, count: size.x * size.y * 4)
        // (r, g, b) at a view pixel.
        func rgb(_ x: Int, _ y: Int) -> SIMD3<UInt8> {
            let i = (y * size.x + x) * 4
            return SIMD3(bytes[i + 2], bytes[i + 1], bytes[i])
        }
        let deadline = Date().addingTimeInterval(60)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            view.currentDrawable?.texture.getBytes(&bytes, bytesPerRow: size.x * 4,
                                                   from: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0)
            // The white fill shows until the effect's pipelines are compiled.
        } while rgb(64, 32).x == 255 && Date() < deadline
        // x = −59.5 and +59.5 layer units: red 0.035 and 0.965; y = +27.5 (top) and −27.5: green 0.93 and 0.07.
        let topLeft = rgb(4, 4), bottomRight = rgb(size.x - 4, size.y - 4), centre = rgb(64, 32)
        XCTAssertEqual(Int(topLeft.x), 9, accuracy: 4, "top left \(topLeft)")
        XCTAssertEqual(Int(topLeft.y), 237, accuracy: 4, "top left \(topLeft)")
        XCTAssertEqual(Int(bottomRight.x), 246, accuracy: 4, "bottom right \(bottomRight)")
        XCTAssertEqual(Int(bottomRight.y), 18, accuracy: 4, "bottom right \(bottomRight)")
        XCTAssertEqual(Int(centre.x), 128, accuracy: 4, "centre \(centre)")
        XCTAssertEqual(centre.z, 255, "the fill's blue, sampled from the framebuffer")
    }

    /// WE multiplies a layer's colour by its `brightness` only under the `ultra` (or `displayhdr`)
    /// post-processing setting (engine flag 0x2000, 0x140207a2b). 2321732083's background
    /// (brightness 0.89) is as bright in WE's capture, taken with post-processing enabled, as
    /// without its brightness.
    func testBrightnessAppliesOnlyUnderUltraPostProcessing() throws {
        _ = try Fixtures.assets()
        XCTAssertFalse(SceneRenderSettings().appliesBrightness)
        let size = SIMD2(64, 64)
        let directory = Fixtures.url("Scenes/brightness")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/brightness/project.json"))
        defer { Fixtures.removeStoredSettings(for: directory) }
        let content = try XCTUnwrap(SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory)).metalContent())
        func centre(_ postProcessing: GSPostProcessingQuality) throws -> UInt8 {
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let view = MTKView(frame: CGRect(x: 0, y: 0, width: size.x, height: size.y), device: device)
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = false
            view.autoResizeDrawable = false
            view.drawableSize = CGSize(width: size.x, height: size.y)
            let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "brightness"))
            defer { renderer.releaseContent() }
            view.isPaused = true
            renderer.setPlacement(.stretch)
            var settings = SceneRenderSettings()
            settings.postProcessing = postProcessing
            renderer.renderSettings = settings
            renderer.setContent(content)
            var drawn = 0
            let deadline = Date().addingTimeInterval(30)
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                renderer.draw(in: view)
                renderer.lastCommandBuffer?.waitUntilCompleted()
                if renderer.hasContent { drawn += 1 }
            } while drawn < 3 && Date() < deadline
            var bytes = [UInt8](repeating: 0, count: size.x * size.y * 4)
            view.currentDrawable?.texture.getBytes(&bytes, bytesPerRow: size.x * 4,
                                                   from: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0)
            return bytes[(32 * size.x + 32) * 4 + 1]
        }
        XCTAssertEqual(Int(try centre(.enabled)), 255, accuracy: 1, "post-processing enabled: brightness 1")
        XCTAssertEqual(Int(try centre(.ultra)), 128, accuracy: 2, "ultra: brightness 0.5")
    }

    /// 3802900973's audio bars: a Workshop effect nested under another item's folder
    /// (`effects/workshop/<id>/workshop/<id>/…`) on a passthrough composition layer that a user
    /// property shows. With the property off the layer is hidden; with it on, the bars follow
    /// the frame's `g_AudioSpectrum*` over the scene under the layer, and silence draws none.
    func testAudioBarsOnAComposeLayerFollowTheirPropertyAndTheSpectrum() throws {
        _ = try Fixtures.assets()
        let size = SIMD2(128, 64)
        let directory = Fixtures.url("Scenes/audio-bars")
        let projectData = try Fixtures.data("Scenes/audio-bars/project.json")
        let project = try JSONDecoder().decode(WEProject.self, from: projectData)
        defer { Fixtures.removeStoredSettings(for: directory) }
        let hidden = try XCTUnwrap(SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory)).metalContent())
        XCTAssertEqual(hidden.visibility["2"], false, "the property's default hides the bars")

        let identity = WallpaperSettingsIdentity.resolve(directory: directory)
        UserDefaults.app.set(["bars": "true"], forKey: identity.key(.userProperties))
        UserDefaults.app.set(true, forKey: identity.key(.explicitUserProperties))
        let content = try XCTUnwrap(SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory)).metalContent())
        XCTAssertEqual(content.visibility["2"], true, "the property shows the bars")
        let bars = try XCTUnwrap(content.layers.first { $0.id == "2" })
        XCTAssertTrue(bars.sceneInput, "a passthrough composition layer draws over the scene under it")
        XCTAssertEqual(bars.weEffects.map(\.file), ["effects/workshop/1/workshop/2/bars/effect.json"])

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: size.x, height: size.y), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: size.x, height: size.y)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "audio-bars"))
        defer { renderer.releaseContent() }
        view.isPaused = true
        renderer.setPlacement(.stretch)
        // Band b of both channels at b/15: bar b fills the bottom b/15 of its column.
        let ramp: [Float] = (0..<64).map { Float(min($0 / 4, 15)) / 15 }
        var spectrum = AudioSpectrumSmoothing.snapshot(ramp + ramp)
        renderer.audioSpectrumFrame = { _ in spectrum }
        renderer.setContent(content)
        var bytes = [UInt8](repeating: 0, count: size.x * size.y * 4)
        func rgb(_ x: Int, _ y: Int) -> SIMD3<UInt8> {
            let i = (y * size.x + x) * 4
            return SIMD3(bytes[i + 2], bytes[i + 1], bytes[i])
        }
        func draw(until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(60)
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                renderer.draw(in: view)
                renderer.lastCommandBuffer?.waitUntilCompleted()
                view.currentDrawable?.texture.getBytes(&bytes, bytesPerRow: size.x * 4,
                                                       from: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0)
            } while !done() && Date() < deadline
        }
        // Band 15 is the last 8 columns, band 1 columns 8–15.
        draw { rgb(size.x - 4, size.y - 2) == SIMD3(255, 0, 0) }
        XCTAssertEqual(rgb(size.x - 4, size.y - 2), SIMD3(255, 0, 0), "the loudest band's bar")
        XCTAssertEqual(rgb(size.x - 4, 2), SIMD3(255, 0, 0), "a full band reaches the top")
        XCTAssertEqual(rgb(12, size.y - 2), SIMD3(255, 0, 0), "band 1 is 1/15 tall")
        XCTAssertEqual(rgb(12, size.y / 2), SIMD3(0, 0, 255), "above band 1's bar: the scene under the layer")
        XCTAssertEqual(rgb(4, size.y - 2), SIMD3(0, 0, 255), "band 0 is silent")

        spectrum = .silent
        draw { rgb(size.x - 4, size.y - 2) == SIMD3(0, 0, 255) }
        XCTAssertEqual(rgb(size.x - 4, size.y - 2), SIMD3(0, 0, 255), "silence draws no bars")
    }
}
