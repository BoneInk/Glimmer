//
//  GlobalSettingsViewModel.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/9/2.
//

import Cocoa
import Combine
import SwiftUI
import ServiceManagement

@MainActor
class GlobalSettingsViewModel: ObservableObject {
    private static let audioPermissionAlertDismissedKey = "SuppressAudioPermissionPrompt"

    /// The user chose "Don't Ask Again" on the missing Screen Recording permission alert.
    /// Nonisolated because the audio engine reads it off the settings view model's lifetime.
    nonisolated static var isAudioPermissionAlertDismissed: Bool {
        get { UserDefaults.app.bool(forKey: audioPermissionAlertDismissedKey) }
        set { UserDefaults.app.set(newValue, forKey: audioPermissionAlertDismissedKey) }
    }

    @Published var settings: GlobalSettings
    {
        didSet {
            save()
            validate()
            OWELog.apply(logLevel: settings.logLevel)
            // Only on a change: following the system mustn't clear a language set in System Settings.
            if settings.language != oldValue.language { settings.language.apply(to: .app) }
            updateEffectiveSettings()
        }
    }

    /// The settings wallpapers render with (`BatteryQuality`): `settings`, lowered while the Mac
    /// runs on battery or in Low Power Mode when "On battery: use a lower quality preset" is on.
    /// Never saved; the controls show and edit `settings`.
    @Published private(set) var effectiveSettings: GlobalSettings

    /// The power state `effectiveSettings` follows.
    @Published private(set) var powerState: PowerState
    private let powerSource: PowerPolicySource?
    private var powerObserver: UUID?

    /// The battery quality applies now.
    var isBatteryQualityActive: Bool { BatteryQuality.applies(settings, power: powerState) }

    /// Follows a new power state: wallpapers switch quality at once, without a reload.
    func setPowerState(_ state: PowerState) {
        powerState = state
        updateEffectiveSettings()
    }

    private func updateEffectiveSettings() {
        let effective = BatteryQuality.effective(settings, power: powerState)
        if effective != effectiveSettings { effectiveSettings = effective }
    }
    
    /// The setup assistant is showing (at launch until finished, or from "Run setup again…").
    @Published var isFirstLaunch = OnboardingFlow.showsAtLaunch()

    /// The Terms of Use and Privacy Policy notice is due (`LegalNotice`): never confirmed, or the
    /// documents changed since. Shown once, on its own when setup is already done.
    @Published var needsLegalNotice = LegalNotice.isDue(in: .app)

    /// The language this process runs in; a different choice applies at the next launch.
    let languageChange: LanguageChange
    
    var didFinishLaunchingNotificationCancellable: Cancellable?
    var didCurrentWallpaperChangeCancellable: Cancellable?
    var didAddToLoginItemCancellable: Cancellable?
    var didChangeScreenSaverCancellable: Cancellable?
    var didChangeAppPresenceCancellable: Cancellable?
    
    /// `followsLaunch`: at launch, the settings that act on the system (launch at login, the menu
    /// bar tint and lock-screen pictures, the screen saver) start following the app's wallpaper.
    /// Only Open Wallpaper Engine's own settings do; the Wallpaper Editor's process reads them.
    ///
    /// `power`: the power source `effectiveSettings` follows; nil for none (always on AC).
    init(followsLaunch: Bool = true, power: PowerPolicySource? = PowerPolicyMonitor.shared) {
        let migration = GlobalSettingsMigration.current()
        let loaded: GlobalSettings = Self.loadSettings(from: UserDefaults.app.data(forKey: Self.defaultsKey),
                                                       backupDirectory: AppStorageLocation.current.supportDirectory,
                                                       migration: migration)
        self.settings = loaded
        let state = power?.policy.state ?? PowerState()
        powerState = state
        effectiveSettings = BatteryQuality.effective(loaded, power: state)
        powerSource = power
        languageChange = LanguageChange(atLaunch: loaded.language)
        powerObserver = power?.observe { [weak self] policy in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.setPowerState(policy.state) } }
        }
        OWELog.apply(logLevel: settings.logLevel)

        // Add observers
        guard followsLaunch else { return }
        // A carried-over Render Resolution is saved at once, so it is carried over once, for the
        // display the app first ran on.
        if migration.migrated { save() }
        self.didFinishLaunchingNotificationCancellable =
        NotificationCenter.default.publisher(for: NSApplication.didFinishLaunchingNotification)
            .sink { [weak self] _ in self?.didFinishLaunchingNotification() }
    }

    /// The stored settings, an earlier Render Resolution carried over for `migration`'s display.
    /// `GlobalSettings` reads each key on its own, so this only fails when
    /// the data isn't a settings object at all. The defaults are used then, and as the next save
    /// replaces the stored data, it is first copied to `settings.corrupt-<date>.json` in
    /// `backupDirectory`.
    nonisolated static func loadSettings(from data: Data?, backupDirectory: URL, now: Date = Date(),
                                         migration: GlobalSettingsMigration? = nil) -> GlobalSettings {
        guard let data else { return GlobalSettings() }
        do {
            return try (migration?.decoder() ?? JSONDecoder()).decode(GlobalSettings.self, from: data)
        } catch {
            backUpUnreadableSettings(data, error: error, backupDirectory: backupDirectory, now: now)
            return GlobalSettings()
        }
    }

    /// Copies stored settings that can't be read to `settings.corrupt-<date>.json` in
    /// `backupDirectory`, before a save replaces them.
    nonisolated private static func backUpUnreadableSettings(_ data: Data, error: Error, backupDirectory: URL, now: Date) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup: URL = backupDirectory.appending(path: "settings.corrupt-\(formatter.string(from: now)).json")
        do {
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            try data.write(to: backup, options: .atomic)
            OWELog.error(.settings, "Settings can't be read; the stored copy is at \(backup.path): \(error)")
        } catch let backupError {
            OWELog.error(.settings, "Settings can't be read (\(error)); backing up the stored copy failed: \(backupError)")
        }
    }

    deinit {
        if let powerObserver { powerSource?.removeObserver(powerObserver) }
        didFinishLaunchingNotificationCancellable?.cancel()
        didCurrentWallpaperChangeCancellable?.cancel()
        didAddToLoginItemCancellable?.cancel()
        didChangeScreenSaverCancellable?.cancel()
        didChangeAppPresenceCancellable?.cancel()
    }
    
    func didFinishLaunchingNotification() {
        self.didCurrentWallpaperChangeCancellable =
        AppDelegate.shared.wallpaperViewModel.$wallpapers
            .sink { [weak self] wallpapers in
                let mainId = WallpaperViewModel.mainScreenId()
                if let wp = wallpapers[mainId] {
                    self?.didCurrentWallpaperChange(wp)
                }
            }
        
        self.didAddToLoginItemCancellable =
        self.$settings
            .removeDuplicates { $0.autoStart == $1.autoStart }
            .map { $0.autoStart }
            .sink { [weak self] in self?.didAddToLoginItem($0) }
        
        self.didChangeScreenSaverCancellable =
        self.$settings
            .map(\.screenSaver)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                // `$settings` publishes before the property changes: the plugin reads the new
                // setting once it is set.
                DispatchQueue.main.async {
                    guard let enabled = self?.settings.screenSaver else { return }
                    AppDelegate.shared.screenSaver.update(enabled: enabled,
                                                          wallpaper: AppDelegate.shared.wallpaperViewModel.currentWallpaper)
                }
            }

        self.didChangeAppPresenceCancellable =
        self.$settings
            .map { [$0.showInDock, $0.showInMenuBar] }
            .removeDuplicates()
            .dropFirst()
            .sink { _ in
                // `$settings` publishes before the property changes.
                DispatchQueue.main.async { AppDelegate.shared.applyAppPresence() }
            }

        self.validate()
    }
    
    func didAddToLoginItem(_ added: Bool) {
        let appService = SMAppService.mainApp
        do {
            if added {
                try appService.register()
            } else {
                try appService.unregister()
            }
        } catch {
            OWELog.error(.settings, "Launch-at-login update failed: \(error)")
        }
    }
    
    func didCurrentWallpaperChange(_ newValue: WEWallpaper) {
        AppDelegate.shared.setPlacehoderWallpaper(with: newValue)
    }
    
    /// The settings when the Settings window opened: Cancel (or closing the window) goes back to
    /// them, OK keeps the changes, and the window's "Edited" badge compares against them. Changes
    /// still apply and save as they are made. Nil while the window isn't being edited.
    @Published private(set) var editSnapshot: GlobalSettings?

    /// Whether the settings differ from those the Settings window opened with.
    var hasUnconfirmedEdits: Bool { editSnapshot.map { $0 != settings } ?? false }

    /// The Settings window opened: remembers the settings Cancel goes back to. Kept when already
    /// editing, so reopening or refocusing the window doesn't confirm anything.
    func beginEditing() {
        if editSnapshot == nil { editSnapshot = settings }
    }

    /// OK: keeps the changes.
    func commitEdits() {
        editSnapshot = nil
    }

    /// Cancel, or the window closing without OK: back to the settings the window opened with.
    /// Without a snapshot, the stored settings are read again; stored data that can't be read is
    /// backed up and the settings in use are kept, so a failed read never replaces the stored
    /// settings with the defaults.
    func reset() {
        if let snapshot = editSnapshot {
            editSnapshot = nil
            if settings != snapshot { settings = snapshot }
            return
        }
        guard let data = UserDefaults.app.data(forKey: Self.defaultsKey) else { return }
        do {
            let stored = try JSONDecoder().decode(GlobalSettings.self, from: data)
            if settings != stored { settings = stored }
        } catch {
            Self.backUpUnreadableSettings(data, error: error,
                                          backupDirectory: AppStorageLocation.current.supportDirectory, now: Date())
        }
    }

    /// The `UserDefaults.app` key the settings are stored under.
    nonisolated static let defaultsKey = "GlobalSettings"

    func save() {
        do {
            let data = try JSONEncoder().encode(settings)
            OWELog.debug(.settings, "Saved settings: \(String(describing: String(data: data, encoding: .utf8)))")
            UserDefaults.app.set(data, forKey: Self.defaultsKey)
        } catch {
            OWELog.error(.settings, "Saving the settings failed: \(error)")
        }
    }

    /// Applies `quality`'s preset in one change: one save, and one update of whatever follows the
    /// settings.
    func setQuality(_ quality: GSQuality) {
        settings = Self.applying(quality, to: settings)
    }

    /// The preset whose values `settings` holds, or nil (Custom) when it matches none. Derived
    /// from the values themselves, so it follows every change: the controls, Restore Defaults, an
    /// import, MCP and the Quality ↔ Efficiency slider. Whether the FPS came from the slider or a
    /// preset (`fpsSetByUser`) is not a value the preset compares.
    nonisolated static func matchingPreset(_ settings: GlobalSettings) -> GSQuality? {
        GSQuality.allCases.first { quality in
            var applied = applying(quality, to: settings)
            applied.fpsSetByUser = settings.fpsSetByUser
            return applied == settings
        }
    }

    /// `settings` with `quality`'s preset applied.
    nonisolated static func applying(_ quality: GSQuality, to settings: GlobalSettings) -> GlobalSettings {
        var settings = settings
        settings.shadows = quality.shadows
        settings.volumetrics = quality.volumetrics
        settings.qualityEfficiency = QualityEfficiency(preset: quality).stop
        settings.fps = quality.fps
        settings.fpsSetByUser = false
        settings.applyResolutionPreset(quality)
        switch quality {
        case .low:
            settings.antiAliasing = .none
            settings.postProcessing = .disabled
            settings.textureResolution = .highQuality
            settings.reflections = false
            settings.particleBudget = .low
        case .medium:
            settings.antiAliasing = .none
            settings.postProcessing = .enabled
            settings.textureResolution = .highQuality
            settings.reflections = true
            settings.particleBudget = .medium
        case .high:
            settings.antiAliasing = .msaa_x2
            settings.postProcessing = .enabled
            settings.textureResolution = .highQuality
            settings.reflections = true
            settings.particleBudget = .high
        case .ultra:
            settings.antiAliasing = .msaa_x2
            settings.postProcessing = .ultra
            settings.textureResolution = .highQuality
            settings.reflections = true
            settings.particleBudget = .unlimited
        }
        return settings
    }
    
    /// Applies the appearance setting to the app, only when it differs from what the app has:
    /// setting `NSApp.appearance` redraws every window.
    private func validate() {
        let appearance: NSAppearance? = switch settings.appearance {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .followSystem: nil
        }
        guard NSApp.appearance?.name != appearance?.name else { return }
        NSApp.appearance = appearance
    }
}
