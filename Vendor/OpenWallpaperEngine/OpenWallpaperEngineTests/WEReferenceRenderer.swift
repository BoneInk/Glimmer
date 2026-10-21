import XCTest
import MetalKit
import simd
@testable import OpenWallpaperEngine

/// Draws a library wallpaper headlessly as WE was captured (tools/peer/shoot.ps1): the real loader
/// and renderer, one 1920×1080 display at 100 % and 30 fps (`frameRate`), the wallpaper's default
/// properties and the given quality settings. The scene clock stands still until every pipeline has
/// compiled and the frame stops changing, then runs at 1 / `frameRate` s a frame to each still's
/// time; particles are seeded (`ParticleRandom`, seed 0), so they draw the same each run.
struct WEReferenceRenderer {
    static let size = SIMD2(1920, 1080)

    struct Shot {
        var time: Double
        /// Screen pixels from the top-left.
        var cursor: SIMD2<Double>
    }

    let directory: URL
    let project: WEProject
    let settings: SceneRenderSettings
    /// WE's `resolution` setting; its texture reduction is resolved for the scene on the
    /// 1920×1080 display, as WE resolves it at load (`TextureReduction`).
    var textureResolution = GSTextureResolutionQuality.highQuality
    /// Where scripts keep their storage.
    let storage: URL
    /// The capture's wall-clock time at the first shot (`WEReferenceLocalTime`), if known.
    var localTime: String?
    /// The particles' random outcome (`SceneMetalRenderer.particleSeed`); 0 is the replayable one.
    var particleSeed: UInt32 = 0
    /// The frames a second the clock steps at and the viewport asks for: WE's FPS setting.
    var frameRate = 30.0
    /// The display's size in pixels (100 %): WE's captures are `size`.
    var outputSize = WEReferenceRenderer.size

    /// The frames at `shots` (in time order), placed on the screen as WE places a scene (cover).
    func render(_ shots: [Shot]) throws -> [WEReferenceImage] {
        let restore = Self.clearStoredSettings(directory: directory)
        defer { restore() }
        let restoreTime = localTime.map(WEReferenceLocalTime.set) ?? {}
        defer { restoreTime() }
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        var settings = settings
        settings.textureReduction = TextureReduction.factor(textureResolution, outputPixels: SIMD2<Float>(outputSize),
                                                             sceneSize: model.textureReductionSceneSize)
        model.setRenderSettings(settings)
        let content = try XCTUnwrap(model.metalContent(), "\(directory.lastPathComponent): no content")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let points = CGSize(width: outputSize.x, height: outputSize.y)
        let view = MTKView(frame: CGRect(origin: .zero, size: points), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = points
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                                           media: SceneScriptReplayMediaSource(), spectrum: { .silent })
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: services, screenID: "we-reference"))
        defer { renderer.releaseContent() }
        view.isPaused = true
        renderer.setPlacement(.fill)
        renderer.renderSettings = settings
        renderer.scripts.frameWait = 5
        renderer.particleSeed = particleSeed
        var now: CFTimeInterval = 1000
        renderer.wallTime = { now }
        renderer.setContent(content)
        let deadline = Date().addingTimeInterval(60)
        while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(renderer.hasContent, "\(directory.lastPathComponent) never got its content")
        guard let first = shots.first else { return [] }

        // Settle: the clock held at zero until the frame stops changing (pipelines compile off the
        // render thread). A running clock steps at least 0.1 ms a frame (`SceneClock`), so it is held.
        renderer.holdsClock = true
        var previous: [UInt8]?
        var settled = false
        let settleDeadline = Date().addingTimeInterval(30)
        var frame = 0
        while !settled, Date() < settleDeadline {
            draw(renderer, cursor: first.cursor)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            frame += 1
            guard frame % 10 == 0, let texture = renderer.sharedFrame else { continue }
            let bytes = try TextureUploadTests.read(texture, device: device)
            settled = frame >= 30 && bytes == previous
            previous = bytes
        }
        if !settled { print("WE reference: \(directory.lastPathComponent) never settled with the clock stopped") }
        renderer.holdsClock = false

        var images: [WEReferenceImage] = []
        var time = 0.0
        let frameStep = 1 / frameRate
        for shot in shots {
            while time + frameStep / 2 < shot.time {
                now += frameStep
                time += frameStep
                draw(renderer, cursor: shot.cursor)
            }
            let texture = try XCTUnwrap(renderer.sharedFrame)
            let bytes = try TextureUploadTests.read(texture, device: device)
            let image = WEReferenceImage(width: texture.width, height: texture.height, pixels: bytes)
            images.append(image.covering(width: outputSize.x, height: outputSize.y))
        }
        return images
    }

    private func draw(_ renderer: SceneMetalRenderer, cursor: SIMD2<Double>) {
        let size = SIMD2<Float>(Float(outputSize.x), Float(outputSize.y))
        // The viewport's cursor is in points from the bottom-left.
        let point = SIMD2(Float(cursor.x), size.y - Float(cursor.y))
        renderer.renderShared([SceneViewport(drawableSize: size, pointSize: size, cursor: point,
                                             frameRateLimit: Int(frameRate.rounded()))])
        renderer.lastCommandBuffer?.waitUntilCompleted()
        renderer.scripts.wallpaper?.waitUntilIdle()
        RunLoop.main.run(until: Date())
    }

    /// Loading a wallpaper reads and stores its settings in the app's defaults. This removes what is
    /// stored, so the wallpaper loads with its default properties as WE's captures did, and returns
    /// what puts it back.
    private static func clearStoredSettings(directory: URL) -> () -> Void {
        let projectData = FileManager.default.contents(atPath: directory.appending(path: "project.json").path)
        let identity = WallpaperSettingsIdentity.resolve(directory: directory)
        var keys: [String] = []
        for family in WallpaperSettingsIdentity.Family.allCases {
            keys.append(identity.key(family))
        }
        let defaults = UserDefaults.app
        let before = keys.map { defaults.object(forKey: $0) }
        for key in keys { defaults.removeObject(forKey: key) }
        return {
            for (key, value) in zip(keys, before) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
    }
}
