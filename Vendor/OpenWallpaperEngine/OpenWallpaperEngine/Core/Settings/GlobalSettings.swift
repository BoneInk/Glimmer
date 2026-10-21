import Cocoa
import Combine
import SwiftUI
import ServiceManagement
import Metal
import OWETheming

extension GlobalSettings {
    /// The render resolution and upscaling every quality preset sets: the displays' own pixels
    /// (Your Display), drawn natively. Upscaling stays off; Low saves through its other settings. A later choice of the user's stands until a preset is applied again.
    mutating func applyResolutionPreset(_ quality: GSQuality) {
        renderResolution = .yourDisplay
        upscaling = .off
    }
}

enum GSQuality: CaseIterable {
    case low, medium, high, ultra

    /// The frame rate the preset sets (`GlobalSettings.fps`): Ultra draws at the display's refresh.
    /// WE's own presets set 10, 15, 25 and 30 (`getQualityPreset`, `ui/dist/scripts/scripts.js`);
    /// these follow the Mac's faster displays.
    var fps: Double {
        switch self {
        case .low: return 15
        case .medium: return 30
        case .high: return 60
        case .ultra: return GlobalSettings.unlimitedFPS
        }
    }
}

/// A playback rule's action (Settings › Performance › Playback). With several displays, WE
/// offers "Pause per monitor" (`pause`) and "Pause all" (`pauseAll`) for the rules about other
/// applications' windows (`PlaybackRules`); with one display only "Pause".
enum GSPlayback: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case keepRunning, mute, pause, pauseAll, stop
}

/// WE's `msaa` setting (none, x2, x4, x8): the scene pass draws multisampled and resolves into
/// `_rt_FullFrameBuffer` (`wallpaper64.exe` 0x140181dcc, 0x140183550, 0x1400d3310).
enum GSAntiAliasingQuality: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case none, msaa_x2, msaa_x4, msaa_x8

    /// Samples per pixel.
    var sampleCount: Int {
        switch self {
        case .none: return 1
        case .msaa_x2: return 2
        case .msaa_x4: return 4
        case .msaa_x8: return 8
        }
    }
}

/// WE's `postprocessing` setting (docs/lighting-plan.md §2.6): "disabled" turns bloom off,
/// "ultra" lets a scene with `bloom` and `hdr` draw in HDR, "displayhdr" also outputs HDR.
enum GSPostProcessingQuality: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case disabled, enabled, ultra, displayhdr
}

/// WE's `shadows` and `volumetrics` settings: disabled, low, medium, high, ultra.
enum GSLightingQuality: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case disabled, low, medium, high, ultra

    /// WE's number for the setting, 0 (disabled) … 4 (ultra).
    var level: Int {
        switch self {
        case .disabled: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .ultra: return 4
        }
    }
}

extension GSQuality {
    /// The `shadows` value WE's quality preset sets (`getQualityPreset` in WE's
    /// `ui/dist/scripts/scripts.js`): the preset's own name.
    var shadows: GSLightingQuality {
        switch self {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        case .ultra: return .ultra
        }
    }

    /// The `volumetrics` value the same preset sets: also the preset's own name.
    var volumetrics: GSLightingQuality { shadows }
}

/// The most particles one scene may hold (`ParticleBudget`); a scene authored with more is thinned
/// to it, every system alike.
enum GSParticleBudget: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case low, medium, high, unlimited

    /// The budget in particles; nil for no limit.
    var limit: Int? {
        switch self {
        case .low: return 10_000
        case .medium: return 25_000
        case .high: return 50_000
        case .unlimited: return nil
        }
    }
}

/// WE's "Texture Resolution" (config `resolution`: `full`, `half`, `auto`; `TextureReduction`).
/// WE's settings offer these three, labelled High Quality, High Performance and Automatic
/// (`ui/dist/scripts/scripts.js`, `textureResolutionOptions`).
enum GSTextureResolutionQuality: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case highQuality, highPerformance, automatic

    /// The setting a WE `config.json` `resolution` value means, as `wallpaper64.exe` reads it
    /// (0x1401155f6…0x14011562f): `full` and `half` exactly; anything else, including `auto`, a
    /// hand-written `quarter` or no value, is automatic.
    init(weConfigValue value: String?) {
        switch value {
        case "full": self = .highQuality
        case "half": self = .highPerformance
        default: self = .automatic
        }
    }
}

/// What the scene target is sized for (`SceneRenderResolution`); Render Resolution alone decides
/// it. `yourDisplay` draws at the displays' backing pixels (1920×1080 on a 1× 1080p display,
/// 5120×2880 on a 5K iMac), whatever the wallpaper's size; `uhd4K` draws at 4K, the long side 3840
/// at the display's shape, and the composite fits that to the display; `full` draws at the
/// wallpaper's authored size and places that onto the display as WE does. Upscaling then draws a
/// share of whichever target (`GSUpscaling`, `GSRenderScale`).
///
/// Earlier stored values (`init(storedValue:)`): "retina" and "native" (the backing pixels) and
/// "display" and "desktop" (the display's points, scaled up; `GlobalSettings.migrateFromPoints`
/// keeps their cost on a Retina display) all read as `yourDisplay`.
enum GSRenderResolution: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case yourDisplay, uhd4K, full

    /// The long side `uhd4K` draws at.
    static let uhd4KLongSide: Float = 3840

    /// The choice a stored value means, including the values earlier versions wrote; nil for an
    /// unknown value.
    init?(storedValue value: String) {
        switch value {
        case "yourDisplay", "retina", "native", "display", "desktop": self = .yourDisplay
        case "uhd4K": self = .uhd4K
        case "full": self = .full
        default: return nil
        }
    }

    /// Whether `value` is an earlier stored value that drew at the display's points: one target
    /// pixel per point, a quarter of the pixels on a 2× display.
    static func isPointsValue(_ value: String) -> Bool { value == "display" || value == "desktop" }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let resolution = GSRenderResolution(storedValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown render resolution \(value)")
        }
        self = resolution
    }
}

/// "Upscaling": the scene drawn at `GSRenderScale` of its size, which the final composite scales
/// up bilinearly. The earlier MetalFX choice ("metalFX") reads as `bilinear` at the same scale
/// (`GlobalSettings.migrateMetalFX`): measured, MetalFX cost more GPU time than drawing natively.
enum GSUpscaling: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case off, bilinear

    /// The stored value of the removed MetalFX choice.
    static let metalFXValue = "metalFX"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == Self.metalFXValue {
            self = .bilinear
        } else if let upscaling = GSUpscaling(rawValue: value) {
            self = upscaling
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown upscaling \(value)")
        }
    }
}

/// "Render scale": the share of each side of the scene target drawn when upscaling.
enum GSRenderScale: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case percent50, percent67, percent75

    var factor: Float {
        switch self {
        case .percent50: return 0.5
        case .percent67: return 2.0 / 3
        case .percent75: return 0.75
        }
    }
}

/// "Effect Detail": the size a layer's effects run at (`SceneEffectDetail`). `full` runs them at
/// the layer's texture size, as WE does; `matchDisplay` at most at the layer's size on screen in
/// the scene target. The scene target's own size is Render Resolution's alone (`GSRenderResolution`).
enum GSSceneDetail: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case matchDisplay, full
}

enum GSAppearance: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case light, dark, followSystem
}

/// The app's language: the system's order, or one of the languages the app is translated into.
/// The raw values of English and Simplified Chinese predate the others and stay as stored.
enum GSLocalization: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case followSystem
    case en_US, zh_CN
    case de, fr, es, ptBR = "pt-BR", it, ja, ko, zhHant = "zh-Hant", ru, pl, tr, uk, ar, hi

    /// The BCP 47 language the app runs in; nil to follow the system.
    var languageIdentifier: String? {
        switch self {
        case .followSystem: return nil
        case .en_US: return "en"
        case .zh_CN: return "zh-Hans"
        default: return rawValue
        }
    }

    /// The language's name in that language, as language pickers show it; nil to follow the system.
    var endonym: String? {
        languageIdentifier.map { identifier in
            Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
        }
    }

    /// Writes the choice where macOS reads an app's language (`AppleLanguages` in the app's
    /// defaults, which is also what System Settings › Language & Region sets per app). It takes
    /// effect at the next launch.
    func apply(to defaults: UserDefaults) {
        if let languageIdentifier {
            defaults.set([languageIdentifier], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }
}

/// The size of WE's "Take screenshot" (`WallpaperScreenshotService`): the display's own pixels,
/// or 4K or 8K along the display's long side, at its shape. Every pass renders at that size.
enum GSScreenshotResolution: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case display, uhd4K, uhd8K

    /// The long side a choice renders at; nil for the display's own size.
    var longSide: Int? {
        switch self {
        case .display: return nil
        case .uhd4K: return 3840
        case .uhd8K: return 7680
        }
    }

    /// The screenshot's pixels for a display of `display` pixels, no side over `maxSide` (the
    /// GPU's largest texture); the display's shape is kept.
    func pixelSize(display: SIMD2<Int>, maxSide: Int) -> SIMD2<Int> {
        guard display.x > 0, display.y > 0 else { return .zero }
        var width = Double(display.x)
        var height = Double(display.y)
        if let longSide {
            let scale = Double(longSide) / max(width, height)
            width *= scale
            height *= scale
        }
        let largest = max(width, height)
        if largest > Double(maxSide) {
            width *= Double(maxSide) / largest
            height *= Double(maxSide) / largest
        }
        return SIMD2(max(Int(width.rounded()), 1), max(Int(height.rounded()), 1))
    }
}

enum GSVideoFramework: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case avkit
    /// Draws video through the scene renderer on the GPU, so the effect stack applies to it, the
    /// way Wallpaper Engine does. The default wherever Metal is available (every Apple silicon Mac).
    case metal

    /// Metal when the Mac has a Metal device, AVKit otherwise.
    static let preferred: GSVideoFramework = MTLCreateSystemDefaultDevice() != nil ? .metal : .avkit
}

enum GSProcessPiority: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case normal, belowNormal
}

enum GSLogLevel: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case error, verbose, none
}

struct GlobalSettings: Codable, Equatable {
    /// The FPS setting's top: no limit but the display's refresh.
    static let unlimitedFPS: Double = 240

    
    // MARK: Playback
    var otherApplicationFocused = GSPlayback.keepRunning
    var otherApplicationMaximized = GSPlayback.keepRunning
    var otherApplicationFullscreen = GSPlayback.keepRunning
    var otherApplicationPlayingAudio = GSPlayback.keepRunning
    var displayAsleep = GSPlayback.keepRunning
    var laptopOnBattery = GSPlayback.keepRunning
    /// "On battery: use a lower quality preset" (`BatteryQuality`): off by default, as WE has no such setting.
    var batteryQuality = false
    /// The preset `batteryQuality` applies; Medium by default.
    var batteryQualityPreset = GSBatteryPreset.medium
    /// The frame rate cap `batteryQuality` applies; none by default.
    var batteryFrameRateCap = GSBatteryFrameRate.none
    /// Settings › Performance › Application Rules (`ApplicationRule`), in the order listed.
    var applicationRules: [ApplicationRule] = []
    
    // MARK: Quality
    /// WE's default is none (`config.json` `"msaa": "none"`).
    var antiAliasing = GSAntiAliasingQuality.none
    /// "enabled" draws WE's bloom as the app always has. WE's own UI default is unknown (its
    /// engine reads a missing key as "disabled"; docs/lighting-plan.md §5).
    var postProcessing = GSPostProcessingQuality.enabled
    var textureResolution = GSTextureResolutionQuality.automatic
    /// What the scene target is sized for (`GSRenderResolution`).
    var renderResolution = GSRenderResolution.yourDisplay
    /// "Upscaling" (`GSUpscaling`): off draws the scene at its full size.
    var upscaling = GSUpscaling.off
    /// "Render scale" while upscaling (`GSRenderScale`).
    var renderScale = GSRenderScale.percent75
    /// Effect Detail (`GSSceneDetail`); effects no larger than their layers on screen is the default.
    var sceneDetail = GSSceneDetail.matchDisplay
    /// WE's `reflection` setting (default on): the screen-space reflection copy.
    var reflections = true
    /// WE's `shadows` setting; medium is WE's default.
    var shadows = GSLightingQuality.medium
    /// WE's `volumetrics` setting, on the same scale as `shadows` [?: default taken as shadows'].
    var volumetrics = GSLightingQuality.medium
    /// "Cheaper shadows" (on by default): shadow maps at half WE's size, smoothed by the
    /// comparison filter (`SceneShadowAtlas.mapSize`).
    var cheaperShadows = true
    /// WE's FPS setting: the most frames a second a scene draws. `unlimitedFPS` (the Ultra
    /// preset's, the slider's top) draws at the display's refresh.
    var fps: Double = 30
    /// The user moved the FPS slider themselves rather than through a quality preset: their rate
    /// then wins over the Quality↔Efficiency stop's cap on smooth motion (`FramePacing.Limits`).
    var fpsSetByUser = false
    /// The Quality↔Efficiency slider's stop (`QualityEfficiency`): 1 quality … 5 efficiency.
    var qualityEfficiency = QualityEfficiency.defaultStop
    /// The particle budget per scene (`ParticleBudget`).
    var particleBudget = GSParticleBudget.medium
    /// "Optimise textures" (`TexturePreparation`): scenes' colour images are compressed once to
    /// BC7 in the background and load from that cache after. On by default.
    var optimiseTextures = true
    /// Web wallpapers render at 1 point per pixel on Retina displays (`WebPageScale`): a quarter
    /// of the pixels for pages that size their canvas by `devicePixelRatio`. Off by default.
    var webStandardResolution = false
    /// Large additive particle systems of 2D scenes draw at half resolution and are added back
    /// (`SceneRenderSettings.reducedResolutionParticles`). Off by default.
    var reducedResolutionParticles = false
    
    // MARK: Automatic Setup
    var autoStart = false
    
    // MARK: Basic Setup
    var language = GSLocalization.followSystem
    
    // MARK: macOS
    /// The Dock icon stays while no window is open (`DockPresence`). Off by default: the icon shows
    /// only while one of the app's windows is open.
    var showInDock = false
    /// The status item in the menu bar (`AppDelegate.applyAppPresence`). On by default. With this
    /// and `showInDock` off, the app runs in the background once its windows close.
    var showInMenuBar = true
    var adjustMenuBarTint = true
    /// The lock screen shows the scene wallpaper: each display's desktop picture is the scene's
    /// loading snapshot (`LockScreenPicture`). On by default; off puts the user's pictures back.
    var lockScreenPicture = true
    /// Settings › Plugins › Screen Saver: the current scene's loop video plays as the screen saver
    /// (`ScreenSaverPlugin`). On by default: the saver is installed for the user to pick.
    var screenSaver = true
    
    // MARK: Appearance
    var appearance = GSAppearance.followSystem

    // MARK: Theming
    /// Settings › General › Theming: macOS follows the wallpaper's scheme colour
    /// (`ThemingController`, docs/theming.md). Everything off by default.
    var theming = ThemingSettings()

    // MARK: Screenshots
    /// The size screenshots render at (`GSScreenshotResolution`).
    var screenshotResolution = GSScreenshotResolution.display
    /// The folder screenshots are saved in; empty for Pictures › Open Wallpaper Engine.
    var screenshotFolder = ""

    // MARK: Transitions
    /// WE's "Wallpaper browser transition" (`browsetransition`): the transition a wallpaper chosen
    /// in the library shows. None until the user picks one, as in WE.
    var browseTransition = WallpaperTransitionSettings.unset

    // MARK: Displays
    /// "Sync properties across displays": one set of user properties for a wallpaper on every
    /// display. Off is WE's default: its "Wallpaper per display" layout keeps each display's
    /// properties (`WallpaperPropertyScope`).
    var syncPropertiesAcrossDisplays = false

    // MARK: Audio
    var audioOutput = true
    /// WE's "Media integration support" (`mediaintegration`, on by default): wallpapers hear the
    /// system's Now Playing session (`MacMediaSessionSource`).
    var mediaIntegration = true
    /// WE's "Reload when changing output device": the running wallpapers reload when the default
    /// output device changes (`OutputDeviceChangeMonitor`). Capture follows the device either way.
    var reloadWhenChangingOutputDevice = true
    /// WE's "Recording threshold" (`audioinputthreshold`, 0…10 in steps of 0.1, default 0 = off):
    /// captured audio quieter than it reads as silence (`AudioSpectrumBlockTransform`).
    var audioRecordingThreshold: Double = 0

    // MARK: Video
    var videoFramework = GSVideoFramework.preferred
    
    // MARK: Advanced
    /// WE's process priority (`ProcessPriority`): the app's nice value and its threads' QoS.
    var processPiority = GSProcessPiority.normal
    /// Pauses playback while the GPU's video memory is exhausted (`VideoMemoryWatch`).
    var pauseOnVRAMExhausted = false
    /// Reopens the app after a crash (`CrashWatcher`, `CrashRelaunchPolicy`). Off by default.
    var restartAfterCrashing = false
    
    // MARK: Developer
    var logLevel = GSLogLevel.error
    
    // MARK: Misc
    var autoRefresh = true

    // MARK: Audio recording
    /// WE's "Audio recording device" (`audioinputdevice`, default "default"): nil is WE's default,
    /// which on macOS is the system output; a device records that input instead
    /// (`SystemAudioCapture.recordingDevice`).
    var audioRecordingDevice: AudioInputDevice?
    /// WE's "Recording volume" (`audioinputvolume`, 0…200, default 50): the spectrum's boost
    /// (`AudioSpectrumBlockTransform.inputVolume(setting:)`).
    var audioRecordingVolume: Double = 50

    // MARK: Media blocklist
    /// WE's media blocklist (`mediablocklist`, empty by default): the apps, by bundle id, whose
    /// now-playing sessions wallpapers don't see (`MacMediaSessionSource.setBlocklist`).
    var mediaBlocklist: [String] = []

    // MARK: Video loading
    /// WE's "Video loading" (`videoreadmode`, default from disk): video wallpapers play from their
    /// file, or from a copy read into memory once (`VideoFileSource`).
    var videoReadMode = GSVideoReadMode.fromDisk

    /// The stored keys. `postProcessing`, `reflections` and `antiAliasing` moved to new keys when
    /// the renderer started reading them: the old keys hold values saved while the settings did
    /// nothing (post-processing then defaulted to "disabled", anti-aliasing to MSAA x2), so they
    /// are left behind.
    enum CodingKeys: String, CodingKey {
        case otherApplicationFocused, otherApplicationMaximized, otherApplicationFullscreen, otherApplicationPlayingAudio
        case displayAsleep, applicationRules
        case batteryQuality, batteryQualityPreset, batteryFrameRateCap
        case laptopOnBattery, textureResolution, shadows, volumetrics, fps, fpsSetByUser, particleBudget, optimiseTextures
        case webStandardResolution, reducedResolutionParticles
        case qualityEfficiency
        case antiAliasing = "msaa"
        case renderResolution, sceneDetail, upscaling, renderScale
        case postProcessing = "postProcessingQuality"
        case reflections = "reflection"
        case autoStart, language, adjustMenuBarTint, appearance, audioOutput
        case showInDock, showInMenuBar
        case lockScreenPicture, screenSaver
        case reloadWhenChangingOutputDevice, videoFramework, processPiority, pauseOnVRAMExhausted
        case restartAfterCrashing, autoRefresh
        /// Moved when Errors Only became the default: the old `logLevel` key can't tell the old
        /// default (None) from a chosen None.
        case logLevel = "logLevelChoice"
        case syncPropertiesAcrossDisplays
        case mediaIntegration
        case cheaperShadows
        case screenshotResolution, screenshotFolder
        case audioRecordingThreshold
        case theming
        case browseTransition = "browsetransition"
        case audioRecordingDevice, audioRecordingVolume
        case mediaBlocklist
        case videoReadMode
    }
}

extension GlobalSettings {
    /// Keys settings were saved under before, read once to carry the user's choice over.
    private enum LegacyKeys: String, CodingKey { case logLevel }

    /// Reads each stored setting on its own: a key that is missing (a setting added since the
    /// settings were saved) or unreadable keeps its default, and the others are kept.
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func read<Value: Decodable>(_ key: CodingKeys, _ value: inout Value) {
            do {
                if let stored = try container.decodeIfPresent(Value.self, forKey: key) { value = stored }
            } catch {
                OWELog.error(.settings, "Setting \(key.stringValue) can't be read and keeps its default: \(error)")
            }
        }
        read(.otherApplicationFocused, &otherApplicationFocused)
        read(.otherApplicationMaximized, &otherApplicationMaximized)
        read(.otherApplicationFullscreen, &otherApplicationFullscreen)
        read(.otherApplicationPlayingAudio, &otherApplicationPlayingAudio)
        read(.displayAsleep, &displayAsleep)
        read(.laptopOnBattery, &laptopOnBattery)
        read(.batteryQuality, &batteryQuality)
        read(.batteryQualityPreset, &batteryQualityPreset)
        read(.batteryFrameRateCap, &batteryFrameRateCap)
        var ruleList = ApplicationRuleList()
        read(.applicationRules, &ruleList)
        applicationRules = ruleList.rules
        read(.antiAliasing, &antiAliasing)
        read(.postProcessing, &postProcessing)
        read(.textureResolution, &textureResolution)
        read(.renderResolution, &renderResolution)
        // The raw value, read again: an earlier points value also carries its cost over. Its
        // errors were reported by the read above.
        let fromPoints = ((try? container.decodeIfPresent(String.self, forKey: .renderResolution)) ?? nil)
            .map(GSRenderResolution.isPointsValue) ?? false
        read(.sceneDetail, &sceneDetail)
        read(.upscaling, &upscaling)
        let fromMetalFX = ((try? container.decodeIfPresent(String.self, forKey: .upscaling)) ?? nil) == GSUpscaling.metalFXValue
        read(.renderScale, &renderScale)
        read(.reflections, &reflections)
        read(.shadows, &shadows)
        read(.volumetrics, &volumetrics)
        read(.fps, &fps)
        read(.fpsSetByUser, &fpsSetByUser)
        read(.qualityEfficiency, &qualityEfficiency)
        qualityEfficiency = QualityEfficiency(stop: qualityEfficiency).stop
        read(.particleBudget, &particleBudget)
        read(.optimiseTextures, &optimiseTextures)
        read(.webStandardResolution, &webStandardResolution)
        read(.reducedResolutionParticles, &reducedResolutionParticles)
        read(.autoStart, &autoStart)
        read(.language, &language)
        read(.showInDock, &showInDock)
        read(.showInMenuBar, &showInMenuBar)
        read(.adjustMenuBarTint, &adjustMenuBarTint)
        read(.lockScreenPicture, &lockScreenPicture)
        read(.screenSaver, &screenSaver)
        read(.appearance, &appearance)
        read(.audioOutput, &audioOutput)
        read(.reloadWhenChangingOutputDevice, &reloadWhenChangingOutputDevice)
        read(.videoFramework, &videoFramework)
        read(.processPiority, &processPiority)
        read(.pauseOnVRAMExhausted, &pauseOnVRAMExhausted)
        read(.restartAfterCrashing, &restartAfterCrashing)
        if container.contains(.logLevel) {
            read(.logLevel, &logLevel)
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
                  let stored = try? legacy.decodeIfPresent(GSLogLevel.self, forKey: .logLevel),
                  stored != .none {
            // A stored None was the old default, so it becomes the new one, Errors Only.
            logLevel = stored
        }
        read(.autoRefresh, &autoRefresh)
        read(.syncPropertiesAcrossDisplays, &syncPropertiesAcrossDisplays)
        read(.mediaIntegration, &mediaIntegration)
        read(.cheaperShadows, &cheaperShadows)
        read(.screenshotResolution, &screenshotResolution)
        read(.screenshotFolder, &screenshotFolder)
        read(.audioRecordingThreshold, &audioRecordingThreshold)
        read(.theming, &theming)
        read(.browseTransition, &browseTransition)
        audioRecordingThreshold = min(max(audioRecordingThreshold, 0), 10)
        read(.audioRecordingDevice, &audioRecordingDevice)
        read(.audioRecordingVolume, &audioRecordingVolume)
        audioRecordingVolume = min(max(audioRecordingVolume, 0), 200)
        read(.mediaBlocklist, &mediaBlocklist)
        read(.videoReadMode, &videoReadMode)
        if fromPoints {
            let migration = decoder.userInfo[.settingsMigration] as? GlobalSettingsMigration
            migrateFromPoints(backingScale: migration?.mainBackingScale ?? 1)
            migration?.migrated = true
        }
        if fromMetalFX {
            migrateMetalFX()
            (decoder.userInfo[.settingsMigration] as? GlobalSettingsMigration)?.migrated = true
        }
    }
}
