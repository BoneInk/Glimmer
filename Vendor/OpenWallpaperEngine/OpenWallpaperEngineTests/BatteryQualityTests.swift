import Combine
import XCTest
@testable import OpenWallpaperEngine

/// "On battery: use a lower quality preset" (`BatteryQuality`): on battery or in Low Power Mode
/// wallpapers render with the chosen preset and frame rate cap as an overlay; the stored settings,
/// the Preset control and what is saved stay the user's, and come back on AC.
@MainActor
final class BatteryQualityTests: XCTestCase {
    private var storedBefore: Data?

    override func setUp() async throws {
        storedBefore = UserDefaults.app.data(forKey: GlobalSettingsViewModel.defaultsKey)
    }

    override func tearDown() async throws {
        UserDefaults.app.set(storedBefore, forKey: GlobalSettingsViewModel.defaultsKey)
    }

    private static let ac = PowerState()
    private static let battery = PowerState(onBattery: true, batteryLevel: 0.8)
    private static let lowPower = PowerState(lowPowerMode: true)

    private func ultra(enabled: Bool = true, preset: GSBatteryPreset = .medium,
                       cap: GSBatteryFrameRate = .none) -> GlobalSettings {
        var settings = GlobalSettingsViewModel.applying(.ultra, to: GlobalSettings())
        settings.batteryQuality = enabled
        settings.batteryQualityPreset = preset
        settings.batteryFrameRateCap = cap
        return settings
    }

    func testDefaultsAndPersistence() throws {
        let defaults = GlobalSettings()
        XCTAssertFalse(defaults.batteryQuality, "off by default: WE has no such setting")
        XCTAssertEqual(defaults.batteryQualityPreset, .medium)
        XCTAssertEqual(defaults.batteryFrameRateCap, GSBatteryFrameRate.none)
        let settings = ultra(preset: .low, cap: .fps20)
        let read = try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(read, settings)
        let older = try JSONDecoder().decode(GlobalSettings.self, from: Data(#"{"fps":45}"#.utf8))
        XCTAssertFalse(older.batteryQuality)
        XCTAssertEqual(older.batteryQualityPreset, .medium)
    }

    func testAppliesOnBatteryAndInLowPowerModeOnlyWhenOn() {
        let on = ultra()
        XCTAssertFalse(BatteryQuality.applies(on, power: Self.ac))
        XCTAssertTrue(BatteryQuality.applies(on, power: Self.battery))
        XCTAssertTrue(BatteryQuality.applies(on, power: Self.lowPower))
        XCTAssertEqual(BatteryQuality.effective(on, power: Self.ac), on, "on AC the user's settings")
        let off = ultra(enabled: false)
        XCTAssertFalse(BatteryQuality.applies(off, power: Self.battery))
        XCTAssertEqual(BatteryQuality.effective(off, power: Self.battery), off)
    }

    /// From Ultra, the Medium battery preset gives Medium's quality values; render resolution,
    /// upscaling and texture resolution stay the user's.
    func testMediumFromUltraIsMediumsValues() {
        var settings = ultra()
        settings.renderResolution = .uhd4K
        settings.upscaling = .bilinear
        let lowered = BatteryQuality.effective(settings, power: Self.battery)
        let medium = GlobalSettingsViewModel.applying(.medium, to: settings)
        XCTAssertEqual(lowered.shadows, medium.shadows)
        XCTAssertEqual(lowered.volumetrics, medium.volumetrics)
        XCTAssertEqual(lowered.antiAliasing, medium.antiAliasing)
        XCTAssertEqual(lowered.postProcessing, medium.postProcessing)
        XCTAssertEqual(lowered.reflections, medium.reflections)
        XCTAssertEqual(lowered.particleBudget, medium.particleBudget)
        XCTAssertEqual(lowered.fps, medium.fps)
        XCTAssertEqual(lowered.qualityEfficiency, medium.qualityEfficiency)
        XCTAssertEqual(lowered.renderResolution, .uhd4K)
        XCTAssertEqual(lowered.upscaling, .bilinear)
        XCTAssertEqual(lowered.textureResolution, settings.textureResolution)
        XCTAssertNotEqual(SceneRenderSettings(lowered), SceneRenderSettings(settings), "the renderer sees the change")
    }

    /// The battery preset never raises a setting the user has lower.
    func testNeverRaisesQuality() {
        var settings = GlobalSettingsViewModel.applying(.low, to: GlobalSettings())
        settings.batteryQuality = true
        settings.batteryQualityPreset = .high
        settings.fps = 12
        XCTAssertEqual(BatteryQuality.effective(settings, power: Self.battery), settings)
    }

    /// Keep My Settings with a cap changes only the frame rate; a lowered rate is not the user's.
    func testFrameRateCapAlone() {
        var settings = ultra(preset: .keepSettings, cap: .fps20)
        settings.fpsSetByUser = true
        let lowered = BatteryQuality.effective(settings, power: Self.lowPower)
        var expected = settings
        expected.fps = 20
        expected.fpsSetByUser = false
        XCTAssertEqual(lowered, expected)
        let limits = FramePacing.Limits(lowered, power: PowerPolicy(Self.ac))
        XCTAssertEqual(limits.userLimit, 20)
        // A cap above the user's rate leaves it.
        settings.fps = 15
        XCTAssertEqual(BatteryQuality.effective(settings, power: Self.battery).fps, 15)
        XCTAssertTrue(BatteryQuality.effective(settings, power: Self.battery).fpsSetByUser)
    }

    /// The view model's overlay follows the power source live; the stored settings, what is saved
    /// and the Preset control's selection stay the user's.
    func testViewModelFollowsThePowerSource() async throws {
        let source = FakePowerSource(Self.ac)
        let model = GlobalSettingsViewModel(followsLaunch: false, power: source)
        model.settings = ultra()
        XCTAssertEqual(model.effectiveSettings, model.settings)
        XCTAssertFalse(model.isBatteryQualityActive)

        var published: [GlobalSettings] = []
        let cancellable = model.$effectiveSettings.dropFirst().sink { published.append($0) }
        defer { cancellable.cancel() }

        source.send(Self.battery)
        try await sleepUntil("the battery state", timeout: 2) { model.powerState == Self.battery }
        XCTAssertTrue(model.isBatteryQualityActive)
        XCTAssertEqual(model.effectiveSettings, BatteryQuality.lowered(model.settings))
        XCTAssertEqual(model.settings, ultra(), "the stored settings are untouched")
        XCTAssertEqual(GlobalSettingsViewModel.matchingPreset(model.settings), .ultra, "the Preset control shows the user's")
        let saved = GlobalSettingsViewModel.loadSettings(from: UserDefaults.app.data(forKey: GlobalSettingsViewModel.defaultsKey),
                                                         backupDirectory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(saved, ultra(), "the overlay is never saved")
        XCTAssertEqual(published.count, 1)

        // A setting changed on battery applies through the overlay.
        model.settings.batteryQualityPreset = .low
        XCTAssertEqual(model.effectiveSettings.fps, GSQuality.low.fps)

        source.send(Self.ac)
        try await sleepUntil("the AC state", timeout: 2) { model.powerState == Self.ac }
        XCTAssertEqual(model.effectiveSettings, model.settings, "the user's settings come back on AC")
        XCTAssertFalse(model.isBatteryQualityActive)
    }

    /// Without a power source (the Wallpaper Editor) the overlay never applies.
    func testNoPowerSourceIsAlwaysOnAC() {
        let model = GlobalSettingsViewModel(followsLaunch: false, power: nil)
        model.settings = ultra()
        XCTAssertEqual(model.powerState, PowerState())
        XCTAssertEqual(model.effectiveSettings, model.settings)
    }

    /// The Settings strings are in the catalogue in all 15 languages.
    func testSettingsStringsAreTranslated() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "OpenWallpaperEngine/Localizable.xcstrings")
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        let keys = ["On battery: use a lower quality preset", "Battery preset", "Keep My Settings",
                    "Battery frame rate cap", "%lld FPS",
                    "In use now: your Mac is on battery or in Low Power Mode.",
                    "While your Mac runs on battery or in Low Power Mode, wallpapers draw with the preset and frame rate cap below. A setting already lower stays as you set it, and your own settings come back on power.",
                    "The quality preset wallpapers use on battery. Keep My Settings changes only the frame rate.",
                    "The most frames per second wallpapers draw on battery. None leaves the frame rate to the preset."]
        for key in keys {
            let localizations = try XCTUnwrap(strings[key]?["localizations"] as? [String: Any], key)
            XCTAssertEqual(localizations.count, 15, key)
        }
    }
}

/// A power source the test drives.
private final class FakePowerSource: PowerPolicySource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: PowerPolicy
    private var observers: [UUID: @Sendable (PowerPolicy) -> Void] = [:]

    init(_ state: PowerState) { current = PowerPolicy(state) }

    var policy: PowerPolicy { lock.lock(); defer { lock.unlock() }; return current }

    func observe(_ body: @escaping @Sendable (PowerPolicy) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); observers[id] = body; lock.unlock()
        return id
    }

    func removeObserver(_ id: UUID) { lock.lock(); observers[id] = nil; lock.unlock() }

    func send(_ state: PowerState) {
        lock.lock()
        current = PowerPolicy(state)
        let callbacks = Array(observers.values)
        lock.unlock()
        callbacks.forEach { $0(PowerPolicy(state)) }
    }
}
