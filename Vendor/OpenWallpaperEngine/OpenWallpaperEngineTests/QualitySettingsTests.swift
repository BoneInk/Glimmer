import XCTest
@testable import OpenWallpaperEngine

/// WE's quality settings (post-processing, reflection, shadows, volumetrics; docs/lighting-plan.md
/// §2.2, §2.6) default to what the app has always drawn, and settings saved by an older build keep
/// their values.
final class QualitySettingsTests: XCTestCase {
    func testQualitySettingsDefaultToWhatTheAppDrew() {
        let settings = GlobalSettings()
        XCTAssertEqual(settings.postProcessing, .enabled, "keeps bloom as drawn; WE's own UI default is unknown")
        XCTAssertTrue(settings.reflections)
        XCTAssertEqual(settings.shadows, .medium)
        XCTAssertEqual(settings.volumetrics, .medium)
        // The app matches the scene's detail to the display, optimises textures and draws cheaper
        // shadows by default (`GSSceneDetail`, `optimiseTextures`, `cheaperShadows`); a renderer
        // without settings draws as WE does.
        var drawn = SceneRenderSettings()
        drawn.sceneDetail = .matchDisplay
        drawn.optimiseTextures = true
        drawn.cheaperShadows = true
        // Render Resolution alone sizes the app's scene target: the display's pixels by default.
        drawn.renderResolution = .yourDisplay
        drawn.floorsAtAuthoredSize = false
        XCTAssertEqual(SceneRenderSettings(settings), drawn)
        XCTAssertEqual(GSLightingQuality.allCases.map(\.level), [0, 1, 2, 3, 4])
        XCTAssertTrue(GSPostProcessingQuality.enabled.allowsBloom)
        XCTAssertFalse(GSPostProcessingQuality.disabled.allowsBloom)
    }

    /// Settings saved before the renderer read post-processing and reflection: those two keys are
    /// left behind (they held the inert "disabled" and false), everything else is kept, and a
    /// missing or unreadable key keeps its default instead of resetting every setting.
    func testSettingsSavedBeforeKeepTheirOtherValues() throws {
        let old = #"{"otherApplicationFocused":"pause","antiAliasing":"msaa_x4","postProcessing":"disabled","reflections":false,"fps":45,"videoFramework":"metal","logLevel":"verbose","appearance":"sparkly"}"#
        let settings = try JSONDecoder().decode(GlobalSettings.self, from: Data(old.utf8))
        XCTAssertEqual(settings.otherApplicationFocused, .pause)
        XCTAssertEqual(settings.antiAliasing, .none, "saved while it did nothing: left behind (WE's key is msaa)")
        XCTAssertEqual(settings.fps, 45)
        XCTAssertEqual(settings.videoFramework, .metal)
        XCTAssertEqual(settings.logLevel, .verbose)
        XCTAssertEqual(settings.appearance, .followSystem, "an unknown value keeps the default")
        XCTAssertEqual(settings.postProcessing, .enabled)
        XCTAssertTrue(settings.reflections)
    }

    /// The particle budget is stored, read back, reaches the renderer's settings (a change rebuilds
    /// the content), and settings saved before it existed get the default.
    func testParticleBudgetPersists() throws {
        XCTAssertEqual(GlobalSettings().particleBudget, .medium)
        XCTAssertEqual(GSParticleBudget.allCases.map(\.limit), [10_000, 25_000, 50_000, nil])
        var settings = GlobalSettings()
        settings.particleBudget = .low
        let data = try JSONEncoder().encode(settings)
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(stored["particleBudget"] as? String, "low")
        let read = try JSONDecoder().decode(GlobalSettings.self, from: data)
        XCTAssertEqual(read.particleBudget, .low)
        XCTAssertEqual(SceneRenderSettings(read).particleBudget, .low)
        XCTAssertNotEqual(SceneRenderSettings(read), SceneRenderSettings(GlobalSettings()))
        let older = try JSONDecoder().decode(GlobalSettings.self, from: Data(#"{"fps":45}"#.utf8))
        XCTAssertEqual(older.particleBudget, .medium)
        let unknown = try JSONDecoder().decode(GlobalSettings.self, from: Data(#"{"particleBudget":"huge"}"#.utf8))
        XCTAssertEqual(unknown.particleBudget, .medium, "an unknown value keeps the default")
    }

    /// WE's quality presets set `shadows` to the preset's own name (`getQualityPreset`).
    func testQualityPresetsSetShadowsAsWEDoes() {
        let presets: [GSQuality] = [.low, .medium, .high, .ultra]
        let shadows: [GSLightingQuality] = presets.map(\.shadows)
        XCTAssertEqual(shadows, [.low, .medium, .high, .ultra])
    }

    /// And `volumetrics` too, the same way (`getQualityPreset` in WE's `ui/dist/scripts/scripts.js`).
    func testQualityPresetsSetVolumetricsAsWEDoes() {
        let presets: [GSQuality] = [.low, .medium, .high, .ultra]
        let volumetrics: [GSLightingQuality] = presets.map(\.volumetrics)
        XCTAssertEqual(volumetrics, [.low, .medium, .high, .ultra])
    }

    /// The Preset control shows the preset the settings hold: each preset, once applied, is the
    /// one matched, from any starting settings.
    func testAppliedPresetIsTheMatchingPreset() {
        var start = GlobalSettings()
        start.antiAliasing = .msaa_x8
        start.renderResolution = .full
        start.upscaling = .bilinear
        start.fps = 45
        start.fpsSetByUser = true
        for quality in GSQuality.allCases {
            for base in [GlobalSettings(), start] {
                let applied = GlobalSettingsViewModel.applying(quality, to: base)
                XCTAssertEqual(GlobalSettingsViewModel.matchingPreset(applied), quality)
            }
        }
    }

    /// Changing any value a preset sets so that it no longer matches shows Custom (nil); setting
    /// it back shows the preset again.
    func testChangingAPresetValueShowsCustom() {
        let high = GlobalSettingsViewModel.applying(.high, to: GlobalSettings())
        let changes: [(String, (inout GlobalSettings) -> Void)] = [
            ("anti-aliasing", { $0.antiAliasing = .msaa_x4 }),
            ("post-processing", { $0.postProcessing = .ultra }),
            ("texture resolution", { $0.textureResolution = .highPerformance }),
            ("render resolution", { $0.renderResolution = .full }),
            ("upscaling", { $0.upscaling = .bilinear }),
            ("shadows", { $0.shadows = .low }),
            ("volumetrics", { $0.volumetrics = .ultra }),
            ("fps", { $0.fps = 59 }),
            ("quality ↔ efficiency", { $0.qualityEfficiency = 5 }),
            ("particle budget", { $0.particleBudget = .unlimited }),
            ("reflections", { $0.reflections = false }),
        ]
        for (name, change) in changes {
            var settings = high
            change(&settings)
            XCTAssertNil(GlobalSettingsViewModel.matchingPreset(settings), name)
        }
        var back = high
        back.shadows = .low
        back.shadows = .high
        XCTAssertEqual(GlobalSettingsViewModel.matchingPreset(back), .high)
    }

    /// Settings a preset leaves alone, and whether the FPS was set by hand, don't change the match:
    /// a rate typed in that equals the preset's still shows the preset.
    func testValuesOutsideThePresetKeepTheMatch() {
        var settings = GlobalSettingsViewModel.applying(.medium, to: GlobalSettings())
        settings.sceneDetail = settings.sceneDetail == .full ? .matchDisplay : .full
        settings.renderScale = GSRenderScale.allCases.last { $0 != settings.renderScale } ?? settings.renderScale
        settings.fpsSetByUser = true
        XCTAssertEqual(GlobalSettingsViewModel.matchingPreset(settings), .medium)
    }

    /// Settings that came from elsewhere (an import, MCP, Restore Defaults) are matched by their
    /// values alone: a hand-made copy of the Low preset's values shows Low.
    func testSettingsMatchByValueAlone() throws {
        let low = GlobalSettingsViewModel.applying(.low, to: GlobalSettings())
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(low))
        XCTAssertEqual(GlobalSettingsViewModel.matchingPreset(decoded), .low)
        let reset = GlobalSettings()
        XCTAssertEqual(GlobalSettingsViewModel.matchingPreset(reset),
                       GSQuality.allCases.first { GlobalSettingsViewModel.applying($0, to: reset) == reset })
    }

    func testSettingsRoundTrip() throws {
        var settings = GlobalSettings()
        settings.postProcessing = .displayhdr
        settings.reflections = false
        settings.shadows = .ultra
        settings.volumetrics = .low
        let data = try JSONEncoder().encode(settings)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertTrue(keys.contains("postProcessingQuality"))
        XCTAssertTrue(keys.contains("reflection"))
        XCTAssertEqual(try JSONDecoder().decode(GlobalSettings.self, from: data), settings)
    }
}
