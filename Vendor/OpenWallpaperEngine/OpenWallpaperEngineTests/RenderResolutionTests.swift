import XCTest
import OWEControlProtocol
@testable import OpenWallpaperEngine

/// Settings → Performance → Render Resolution (`GSRenderResolution`), Upscaling and Render Scale:
/// the scene target sized for the displays' backing pixels (Your Display), 4K at their shape, or
/// the scene's authored size (Full), whatever the scene's size, then drawn at the render scale and
/// scaled up by the composite.
final class RenderResolutionTests: XCTestCase {
    private func viewport(_ pixels: SIMD2<Float>, scale: Float = 1) -> SceneViewport {
        SceneViewport(drawableSize: pixels, pointSize: pixels / scale, cursor: nil, frameRateLimit: 30)
    }
    private var plain: SceneViewport { viewport(SIMD2(1920, 1080)) }
    private var retina: SceneViewport { viewport(SIMD2(3840, 2160), scale: 2) }
    private var fiveK: SceneViewport { viewport(SIMD2(5120, 2880), scale: 2) }
    private var ultrawide: SceneViewport { viewport(SIMD2(3440, 1440)) }
    private var macBookAir: SceneViewport { viewport(SIMD2(2880, 1800), scale: 2) }
    private let uhdScene = SIMD2<Float>(3840, 2160)
    private let qhdScene = SIMD2<Float>(2560, 1440)
    private let hdScene = SIMD2<Float>(1920, 1080)

    /// The live wallpaper's target: Render Resolution alone, no authored-size floor.
    private func target(_ scene: SIMD2<Float>, _ viewports: [SceneViewport], _ resolution: GSRenderResolution,
                        scale: Float = 1) -> SIMD2<Int> {
        let drawable = SceneRenderResolution.drawableSize(viewports, resolution: resolution, sceneSize: scene)
        let full = SceneRenderResolution.pixelsPerUnit(sceneSize: scene, drawableSize: drawable)
        return SceneRenderResolution.targetSize(sceneSize: scene,
                                                pixelsPerUnit: SceneRenderResolution.drawnPixelsPerUnit(full, scale: scale))
    }

    func testYourDisplayIsTheBackingPixelsWhateverTheScenesSize() {
        for scene in [uhdScene, qhdScene, hdScene] {
            XCTAssertEqual(target(scene, [plain], .yourDisplay), SIMD2(1920, 1080), "\(scene) on a 1× 1080p display")
            XCTAssertEqual(target(scene, [retina], .yourDisplay), SIMD2(3840, 2160), "\(scene) on a 2× 4K display")
        }
        // 5K: exactly the backing pixels, whatever the scene's size.
        for scene in [uhdScene, qhdScene, hdScene] {
            XCTAssertEqual(target(scene, [fiveK], .yourDisplay), SIMD2(5120, 2880), "\(scene) on a 2× 5K display")
        }
        XCTAssertEqual(target(SIMD2(3440, 1440), [ultrawide], .yourDisplay), SIMD2(3440, 1440), "a scene of its shape")
        // Ultrawide: a 16:9 scene covers it exactly across, its height cropped by the placement.
        XCTAssertEqual(target(uhdScene, [ultrawide], .yourDisplay), SIMD2(3440, 1935))
        XCTAssertEqual(target(qhdScene, [ultrawide], .yourDisplay), SIMD2(3440, 1935))
        // Several displays: the largest one's pixels.
        XCTAssertEqual(SceneRenderResolution.drawableSize([plain, retina], resolution: .yourDisplay, sceneSize: hdScene),
                       SIMD2(3840, 2160))
    }

    func testUHD4KIs4KAtTheDisplaysShapeWhateverTheScenesSize() {
        XCTAssertEqual(SceneRenderResolution.drawableSize([plain], resolution: .uhd4K, sceneSize: hdScene), SIMD2(3840, 2160))
        XCTAssertEqual(SceneRenderResolution.drawableSize([macBookAir], resolution: .uhd4K, sceneSize: hdScene),
                       SIMD2(3840, 2400), "16:10")
        XCTAssertEqual(SceneRenderResolution.drawableSize([ultrawide], resolution: .uhd4K, sceneSize: hdScene),
                       SIMD2(3840, 1607), "21:9")
        XCTAssertEqual(SceneRenderResolution.drawableSize([fiveK], resolution: .uhd4K, sceneSize: hdScene),
                       SIMD2(3840, 2160), "a larger display gets 4K too, scaled up by the composite")
        XCTAssertEqual(SceneRenderResolution.uhd4KSize(shapedLike: .zero), SIMD2(3840, 2160), "no display yet")
        for display in [plain, retina, fiveK] {
            // A 2K scene is drawn at 4K too: text, particles and procedural effects get the pixels.
            XCTAssertEqual(target(qhdScene, [display], .uhd4K), SIMD2(3840, 2160), "\(display.drawableSize)")
            XCTAssertEqual(target(uhdScene, [display], .uhd4K), SIMD2(3840, 2160), "\(display.drawableSize)")
            XCTAssertEqual(target(hdScene, [display], .uhd4K), SIMD2(3840, 2160), "\(display.drawableSize)")
        }
        XCTAssertEqual(target(uhdScene, [ultrawide], .uhd4K), SIMD2(3840, 2160))
        XCTAssertEqual(target(SIMD2(1440, 900), [macBookAir], .uhd4K), SIMD2(3840, 2400), "exactly 4K at 16:10")
    }

    func testFullIsTheAuthoredSize() {
        for display in [plain, retina, fiveK, ultrawide] {
            XCTAssertEqual(target(uhdScene, [display], .full), SIMD2(3840, 2160), "\(display.drawableSize)")
            XCTAssertEqual(target(qhdScene, [display], .full), SIMD2(2560, 1440), "\(display.drawableSize)")
        }
        XCTAssertEqual(target(SIMD2(20000, 20000), [plain], .full), SIMD2(16384, 16384), "only the GPU's texture limit caps it")
        XCTAssertEqual(target(SIMD2(20000, 20000), [plain], .uhd4K), SIMD2(3840, 3840), "4K covered exactly")
    }

    /// Only a target that follows a live-resizing window (the editors' previews) is quantised, so
    /// a resize doesn't reallocate it every frame.
    func testOnlyALiveResizingWindowQuantisesTheTarget() {
        let drawable = SIMD2<Float>(5120, 2880)
        let exact = SceneRenderResolution.pixelsPerUnit(sceneSize: hdScene, drawableSize: drawable)
        let windowed = SceneRenderResolution.pixelsPerUnit(sceneSize: hdScene, drawableSize: drawable, quantised: true)
        XCTAssertEqual(SceneRenderResolution.targetSize(sceneSize: hdScene, pixelsPerUnit: exact), SIMD2(5120, 2880))
        XCTAssertEqual(SceneRenderResolution.targetSize(sceneSize: hdScene, pixelsPerUnit: windowed), SIMD2(5280, 2970))
        // A window a pixel larger keeps the same quantised target.
        XCTAssertEqual(SceneRenderResolution.pixelsPerUnit(sceneSize: hdScene, drawableSize: drawable + 1, quantised: true), windowed)
    }

    func testEffectDetailNoLongerSizesTheTarget() {
        // Effect Detail Full used to keep a 4K scene at 4K on a 1080p display; the target is now
        // Render Resolution's alone, and the floor belongs to the exports and settings-less renderers.
        var settings = GlobalSettings()
        settings.sceneDetail = .full
        let render = SceneRenderSettings(settings)
        XCTAssertFalse(render.floorsAtAuthoredSize)
        let drawable = SceneRenderResolution.drawableSize([plain], resolution: render.renderResolution, sceneSize: uhdScene)
        XCTAssertEqual(SceneRenderResolution.pixelsPerUnit(sceneSize: uhdScene, drawableSize: drawable,
                                                           floorsAtAuthoredSize: render.floorsAtAuthoredSize), 0.5)
        XCTAssertTrue(SceneRenderSettings().floorsAtAuthoredSize, "a settings-less renderer draws at least the authored size")
    }

    func testRenderScaleSizes() {
        XCTAssertEqual(target(hdScene, [retina], .yourDisplay, scale: GSRenderScale.percent50.factor), SIMD2(1920, 1080))
        XCTAssertEqual(target(hdScene, [retina], .yourDisplay, scale: GSRenderScale.percent67.factor), SIMD2(2560, 1440))
        XCTAssertEqual(target(hdScene, [retina], .yourDisplay, scale: GSRenderScale.percent75.factor), SIMD2(2880, 1620))
        XCTAssertEqual(target(qhdScene, [plain], .uhd4K, scale: GSRenderScale.percent50.factor), SIMD2(1920, 1080),
                       "Upscaling draws below the chosen target; the composite scales it up")
        XCTAssertEqual(target(hdScene, [plain], .full, scale: 0.5), SIMD2(960, 540))
        XCTAssertEqual(SceneRenderResolution.drawnPixelsPerUnit(2, scale: 1), 2)
        var settings = SceneRenderSettings()
        XCTAssertEqual(settings.drawnScale, 1, "upscaling off draws the full target")
        settings.upscaling = .bilinear
        settings.renderScale = .percent67
        XCTAssertEqual(settings.drawnScale, 2.0 / 3)
    }

    func testAutomaticTextureResolutionWeighsTheSizeDrawnFor() {
        var settings = GlobalSettings()
        settings.textureResolution = .automatic
        let display = SIMD2<Float>(1920, 1080)
        settings.renderResolution = .yourDisplay
        XCTAssertEqual(SceneRenderSettings(settings, outputPixels: display, sceneSize: uhdScene).textureReduction, 2,
                       "WE's automatic: a 4K scene on a 1080p window halves its textures")
        settings.renderResolution = .uhd4K
        XCTAssertEqual(SceneRenderSettings(settings, outputPixels: display, sceneSize: uhdScene).textureReduction, 1)
        settings.renderResolution = .full
        XCTAssertEqual(SceneRenderSettings(settings, outputPixels: display, sceneSize: uhdScene).textureReduction, 1)
        XCTAssertEqual(SceneRenderSettings.renderedPixels(.full, outputPixels: display, sceneSize: nil), display,
                       "a perspective scene has no authored size to weigh")
    }

    func testThePickerNamesTheSizes() {
        let sizes = RenderResolutionSizes(screens: [.init(points: CGSize(width: 1920, height: 1080), pixels: CGSize(width: 3840, height: 2160)),
                                                    .init(points: CGSize(width: 3440, height: 1440), pixels: CGSize(width: 3440, height: 1440))])
        XCTAssertEqual(sizes.yourDisplayList, "3840×2160, 3440×1440")
        XCTAssertEqual(sizes.uhd4KList, "3840×2160, 3840×1607")
        XCTAssertEqual(sizes.mainPixels, "3840×2160")
        XCTAssertEqual(sizes.mainUHD4K, "3840×2160")
        for resolution in GSRenderResolution.allCases {
            XCTAssertFalse(sizes.label(resolution).isEmpty)
            XCTAssertFalse(sizes.summary(resolution).isEmpty)
        }
        XCTAssertTrue(sizes.label(.yourDisplay).contains("3840×2160, 3440×1440"))
        XCTAssertTrue(sizes.summary(.uhd4K).contains("3840×2160"))
    }

    func testTheSettingReachesTheRenderer() {
        var settings = GlobalSettings()
        XCTAssertEqual(settings.renderResolution, .yourDisplay, "the display's own pixels by default")
        XCTAssertEqual(settings.upscaling, .off)
        settings.renderResolution = .uhd4K
        settings.upscaling = .bilinear
        settings.renderScale = .percent50
        let render = SceneRenderSettings(settings)
        XCTAssertEqual(render.renderResolution, .uhd4K)
        XCTAssertEqual(render.upscaling, .bilinear)
        XCTAssertEqual(render.renderScale, .percent50)
        XCTAssertEqual(SceneRenderSettings().renderResolution, .yourDisplay, "a settings-less renderer draws as WE does")
    }

    private func decoded(_ json: String, backingScale: Double? = nil) throws -> (GlobalSettings, migrated: Bool) {
        let migration = backingScale.map(GlobalSettingsMigration.init(mainBackingScale:))
        let settings = try (migration?.decoder() ?? JSONDecoder()).decode(GlobalSettings.self, from: Data(json.utf8))
        return (settings, migration?.migrated ?? false)
    }

    func testStoredValuesMigrate() throws {
        func resolution(_ value: String) throws -> GSRenderResolution {
            try decoded("{\"renderResolution\":\"\(value)\"}").0.renderResolution
        }
        XCTAssertEqual(try resolution("retina"), .yourDisplay, "the backing pixels")
        XCTAssertEqual(try resolution("native"), .yourDisplay, "the backing pixels, as stored before Retina")
        XCTAssertEqual(try resolution("display"), .yourDisplay, "the points, now Your Display (plus Upscaling)")
        XCTAssertEqual(try resolution("desktop"), .yourDisplay)
        XCTAssertEqual(try resolution("full"), .full)
        XCTAssertEqual(try resolution("uhd4K"), .uhd4K)
        XCTAssertEqual(try resolution("yourDisplay"), .yourDisplay)
        XCTAssertEqual(try resolution("bogus"), .yourDisplay, "an unknown value keeps the default")
        var settings = GlobalSettings()
        settings.renderResolution = .uhd4K
        settings.upscaling = .bilinear
        settings.renderScale = .percent67
        let roundTrip = try decoded(String(decoding: JSONEncoder().encode(settings), as: UTF8.self), backingScale: 2)
        XCTAssertEqual(roundTrip.0, settings)
        XCTAssertFalse(roundTrip.migrated, "a saved value of today's is read as it is")
    }

    /// The points-based Display becomes Your Display drawn natively: Upscaling stays as it was,
    /// and on a Retina display web wallpapers stay at
    /// standard resolution, as Display drew them. Once.
    func testDisplayOnRetinaBecomesYourDisplayOnce() throws {
        let (retina, migrated) = try decoded(#"{"renderResolution":"display","upscaling":"off","renderScale":"percent75"}"#,
                                             backingScale: 2)
        XCTAssertTrue(migrated)
        XCTAssertEqual(retina.renderResolution, .yourDisplay)
        XCTAssertEqual(retina.upscaling, .off)
        XCTAssertEqual(retina.renderScale, .percent75)
        XCTAssertTrue(retina.webStandardResolution)
        XCTAssertEqual(target(hdScene, [self.retina], retina.renderResolution, scale: SceneRenderSettings(retina).drawnScale),
                       SIMD2(3840, 2160), "the backing pixels, natively")
        // Saved, it reads as it is: the migration happens once.
        let again = try decoded(String(decoding: JSONEncoder().encode(retina), as: UTF8.self), backingScale: 2)
        XCTAssertFalse(again.migrated)
        XCTAssertEqual(again.0, retina)

        // Upscaling the user turned on stays on, at their scale.
        let upscaled = try decoded(#"{"renderResolution":"desktop","upscaling":"bilinear","renderScale":"percent67"}"#,
                                   backingScale: 2).0
        XCTAssertEqual(upscaled.upscaling, .bilinear)
        XCTAssertEqual(upscaled.renderScale, .percent67)
        // On a 1× display Display and Your Display are the same size: nothing else changes.
        let (plain, plainMigrated) = try decoded(#"{"renderResolution":"display"}"#, backingScale: 1)
        XCTAssertTrue(plainMigrated, "still saved, so it isn't migrated again on a later Retina display")
        XCTAssertEqual(plain.renderResolution, .yourDisplay)
        XCTAssertEqual(plain.upscaling, .off)
        XCTAssertFalse(plain.webStandardResolution)
        // Retina drew the backing pixels: nothing to carry over.
        let (pixels, pixelsMigrated) = try decoded(#"{"renderResolution":"retina"}"#, backingScale: 2)
        XCTAssertFalse(pixelsMigrated)
        XCTAssertFalse(pixels.webStandardResolution)
    }

    func testLoadingStoredSettingsMigrates() {
        let migration = GlobalSettingsMigration(mainBackingScale: 2)
        let loaded = GlobalSettingsViewModel.loadSettings(from: Data(#"{"renderResolution":"display"}"#.utf8),
                                                          backupDirectory: FileManager.default.temporaryDirectory,
                                                          migration: migration)
        XCTAssertTrue(migration.migrated)
        XCTAssertEqual(loaded.renderResolution, .yourDisplay)
        XCTAssertEqual(loaded.upscaling, .off)
        XCTAssertTrue(loaded.webStandardResolution)
    }

    /// A first launch (no stored settings) draws natively at the display's pixels, on 1× and 2× alike.
    func testFirstLaunchDefaults() {
        let folder = FileManager.default.temporaryDirectory
        for scale in [1.0, 2.0] {
            let launch = GlobalSettingsMigration(mainBackingScale: scale)
            let settings = GlobalSettingsViewModel.loadSettings(from: nil, backupDirectory: folder, migration: launch)
            XCTAssertEqual(settings, GlobalSettings(), "\(scale)×")
            XCTAssertEqual(settings.renderResolution, .yourDisplay, "\(scale)×")
            XCTAssertEqual(settings.upscaling, .off, "\(scale)×")
            XCTAssertFalse(launch.migrated, "\(scale)×: nothing to carry over")
        }
    }

    func testPresetsDrawNatively() {
        for quality in [GSQuality.low, .medium, .high, .ultra] {
            var settings = GlobalSettings()
            settings.renderResolution = .uhd4K
            settings.upscaling = .bilinear
            settings.renderScale = .percent50
            settings.applyResolutionPreset(quality)
            XCTAssertEqual(settings.renderResolution, .yourDisplay, "\(quality)")
            XCTAssertEqual(settings.upscaling, .off, "\(quality)")
            let applied = GlobalSettingsViewModel.applying(quality, to: GlobalSettings())
            XCTAssertEqual(applied.renderResolution, .yourDisplay, "\(quality)")
            XCTAssertEqual(applied.upscaling, .off, "\(quality)")
        }
        // The user's own choice stands until a preset is applied again.
        var settings = GlobalSettingsViewModel.applying(.low, to: GlobalSettings())
        settings.upscaling = .bilinear
        XCTAssertEqual(settings.upscaling, .bilinear)
        settings.applyResolutionPreset(.low)
        XCTAssertEqual(settings.upscaling, .off, "applying a preset again overrides it")
    }

    /// The removed MetalFX Upscaling becomes bilinear Upscaling at the same render scale, once:
    /// stored settings, an imported settings file and MCP's earlier `metalfx` alike.
    @MainActor
    func testMetalFXBecomesBilinearAtTheSameScale() throws {
        let (stored, migrated) = try decoded(#"{"upscaling":"metalFX","renderScale":"percent67"}"#, backingScale: 2)
        XCTAssertTrue(migrated, "saved at once, so it is carried over (and logged) once")
        XCTAssertEqual(stored.upscaling, .bilinear)
        XCTAssertEqual(stored.renderScale, .percent67)
        XCTAssertEqual(SceneRenderSettings(stored).drawnScale, 2.0 / 3, "the scene keeps drawing at the same scale")
        let again = try decoded(String(decoding: JSONEncoder().encode(stored), as: UTF8.self), backingScale: 2)
        XCTAssertFalse(again.migrated)
        XCTAssertEqual(again.0, stored)
        XCTAssertEqual(try decoded(#"{"upscaling":"metalFX"}"#).0.upscaling, .bilinear, "without a migration context too")
        XCTAssertEqual(try decoded(#"{"upscaling":"off"}"#).0.upscaling, .off)
        XCTAssertEqual(try decoded(#"{"upscaling":"bogus"}"#).0.upscaling, .off, "an unknown value keeps the default")

        let file = #"{"format":"open-wallpaper-engine-settings","version":1,"appVersion":"1.0.0-beta.5","#
            + #""settings":{"upscaling":"metalFX","renderScale":"percent50"},"preferences":{}}"#
        let migration = GlobalSettingsMigration(mainBackingScale: 1)
        let imported = try SettingsTransfer.decode(Data(file.utf8), migration: migration)
        XCTAssertTrue(migration.migrated)
        XCTAssertEqual(imported.settings.upscaling, .bilinear)
        XCTAssertEqual(imported.settings.renderScale, .percent50)

        let setting = try LibrarySetting.named("upscaling")
        XCTAssertEqual(setting.kind, .choice(["off", "bilinear"]))
        for (given, expected) in [("off", "off"), ("bilinear", "bilinear"), ("metalfx", "bilinear"), ("MetalFX", "bilinear")] {
            XCTAssertEqual(try setting.parse(.string(given)), .string(expected), given)
        }
    }

    @MainActor
    func testMCPNamesAndEarlierValues() throws {
        let setting = try LibrarySetting.named("render_resolution")
        XCTAssertEqual(setting.kind, .choice(["your_display", "uhd4k", "full"]))
        for (given, expected) in [("your_display", "your_display"), ("UHD4K", "uhd4k"), ("4k", "uhd4k"), ("full", "full"),
                                  ("display", "your_display"), ("retina", "your_display"), ("Retina", "your_display")] {
            XCTAssertEqual(try setting.parse(.string(given)), .string(expected), given)
        }
        XCTAssertThrowsError(try setting.parse(.string("native")))
        XCTAssertThrowsError(try setting.parse(.string("8k")))
        for resolution in GSRenderResolution.allCases {
            XCTAssertEqual(try AppLibraryControlService.renderResolution(AppLibraryControlService.name(resolution)), resolution)
        }
        XCTAssertEqual(AppLibraryControlService.name(.uhd4K), "uhd4k")
        XCTAssertThrowsError(try AppLibraryControlService.renderResolution("retina"), "the setting maps earlier names first")
    }
}
