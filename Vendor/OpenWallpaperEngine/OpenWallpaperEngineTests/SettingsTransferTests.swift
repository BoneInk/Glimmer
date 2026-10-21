import XCTest
@testable import OpenWallpaperEngine

/// Settings export and import, and "Restore Defaults" per tab, in a defaults suite of their own.
@MainActor
final class SettingsTransferTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "owe-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func changedSettings() -> GlobalSettings {
        var settings = GlobalSettings()
        settings.fps = 60
        settings.shadows = .ultra
        settings.otherApplicationFullscreen = .pauseAll
        settings.appearance = .dark
        settings.language = .ja
        settings.syncPropertiesAcrossDisplays = true
        settings.logLevel = .verbose
        return settings
    }

    /// What goes out comes back, and no secret goes out: an API key or Steam account under those
    /// names in the defaults is never read.
    func testExportImportRoundTripWithoutSecrets() throws {
        defaults.set(true, forKey: "ReclaimOriginalPackages")
        defaults.set(true, forKey: "HidesReleaseNotesAfterUpdate")
        defaults.set(false, forKey: "ReceiveBetaUpdates")
        defaults.set("SECRET-API-KEY-0123456789", forKey: "SteamWebAPIKey")
        defaults.set("secret-steam-account", forKey: "SteamLastUsername")
        let updates = SettingsTransfer.Updates(automaticallyChecksForUpdates: true, updatesAutomatically: false)

        let exported = SettingsTransfer.export(settings: changedSettings(), defaults: defaults,
                                               updates: updates, appVersion: "1.0.0 (Dev build)")
        let data = try exported.encoded()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("SECRET-API-KEY"))
        XCTAssertFalse(text.contains("secret-steam-account"))
        XCTAssertFalse(text.contains("SteamWebAPIKey"))
        XCTAssertFalse(text.contains("SteamLastUsername"))

        let imported = try SettingsTransfer.decode(data)
        XCTAssertEqual(imported, exported)
        XCTAssertEqual(imported.settings, changedSettings())
        XCTAssertEqual(imported.updates, updates)
        XCTAssertEqual(imported.preferences, ["ReclaimOriginalPackages": true, "HidesReleaseNotesAfterUpdate": true, "ReceiveBetaUpdates": false])

        let other = try XCTUnwrap(UserDefaults(suiteName: suite + ".other"))
        defer { other.removePersistentDomain(forName: suite + ".other") }
        imported.applyPreferences(to: other)
        XCTAssertTrue(other.bool(forKey: "ReclaimOriginalPackages"))
        XCTAssertTrue(other.bool(forKey: "HidesReleaseNotesAfterUpdate"))
        XCTAssertNil(other.object(forKey: "SteamWebAPIKey"))
    }

    /// Other JSON, a newer format and unknown preferences are refused or dropped.
    /// The Installed folders travel with the settings, and importing them merges into the
    /// folders there: importing the same file twice adds nothing.
    func testExportImportCarriesTheInstalledFolders() throws {
        let none = SettingsTransfer.export(settings: GlobalSettings(), defaults: defaults, updates: nil, appVersion: "1")
        XCTAssertNil(none.folders, "no folders: none in the file")

        let source = InstalledFolderStore(defaults: defaults)
        let games = try XCTUnwrap(source.update { $0.create(title: "Games") })
        source.update { $0.create(title: "Retro", in: games) }
        source.update { $0.move(items: ["workshop-1", "/library/mine"], to: games) }
        source.update { $0.setIcon(.star, of: games) }
        let exported = SettingsTransfer.export(settings: GlobalSettings(), defaults: defaults, updates: nil, appVersion: "1")
        let imported = try SettingsTransfer.decode(exported.encoded())
        XCTAssertEqual(imported.folders, source.tree)

        let otherSuite = suite + ".folders"
        let other = try XCTUnwrap(UserDefaults(suiteName: otherSuite))
        defer { other.removePersistentDomain(forName: otherSuite) }
        let target = InstalledFolderStore(defaults: other)
        let kept = try XCTUnwrap(target.update { $0.create(title: "Mine") })
        target.update { $0.move(items: ["workshop-1"], to: kept) }
        let first = target.merge(try XCTUnwrap(imported.folders).folders)
        XCTAssertEqual(first, .init(folders: 2, wallpapers: 1), "workshop-1 stays in Mine")
        XCTAssertTrue(target.merge(try XCTUnwrap(imported.folders).folders).isEmpty, "idempotent")
        XCTAssertEqual(InstalledFolderStore(defaults: other).tree.allFolders().map(\.path), ["Games", "Games / Retro", "Mine"])

        let older = try SettingsTransfer.decode(Data(#"{"format": "open-wallpaper-engine-settings", "version": 1, "appVersion": "1", "settings": {}, "preferences": {}}"#.utf8))
        XCTAssertNil(older.folders, "a file from before folders")
    }

    func testImportRefusesOtherFiles() throws {
        XCTAssertThrowsError(try SettingsTransfer.decode(Data("{\"fps\": 30}".utf8)))
        XCTAssertThrowsError(try SettingsTransfer.decode(Data("not json".utf8)))

        var newer = SettingsTransfer.export(settings: GlobalSettings(), defaults: defaults, updates: nil, appVersion: "9")
        newer.version = SettingsTransfer.currentVersion + 1
        XCTAssertThrowsError(try SettingsTransfer.decode(newer.encoded()))

        var extra = SettingsTransfer.export(settings: GlobalSettings(), defaults: defaults, updates: nil, appVersion: "1")
        extra.preferences = ["SteamWebAPIKey": true, "ReceiveBetaUpdates": true]
        XCTAssertEqual(try SettingsTransfer.decode(extra.encoded()).preferences, ["ReceiveBetaUpdates": true])
    }

    /// "Restore Defaults" resets only the shown tab's settings.
    func testResetPerTabKeepsTheOtherTabs() {
        let changed = changedSettings()

        let performance = SettingsTab.performance.resetting(changed)
        XCTAssertEqual(performance.fps, GlobalSettings().fps)
        XCTAssertEqual(performance.shadows, GlobalSettings().shadows)
        XCTAssertEqual(performance.otherApplicationFullscreen, GlobalSettings().otherApplicationFullscreen)
        XCTAssertEqual(performance.appearance, .dark)
        XCTAssertEqual(performance.language, .ja)
        XCTAssertTrue(performance.syncPropertiesAcrossDisplays)
        XCTAssertEqual(performance.logLevel, .verbose)

        let general = SettingsTab.general.resetting(changed)
        XCTAssertEqual(general.appearance, GlobalSettings().appearance)
        XCTAssertEqual(general.language, GlobalSettings().language)
        XCTAssertEqual(general.fps, 60)

        let optimizations = SettingsTab.optimizations.resetting(changed)
        XCTAssertFalse(optimizations.syncPropertiesAcrossDisplays)
        XCTAssertEqual(optimizations.logLevel, .verbose)

        XCTAssertEqual(SettingsTab.diagnostics.resetting(changed).logLevel, GlobalSettings().logLevel)
        XCTAssertEqual(SettingsTab.about.resetting(changed), changed)

        // Every tab reset in turn gives the defaults: each shown setting belongs to a tab.
        var all = changed
        for tab in SettingsTab.allCases { all = tab.resetting(all) }
        XCTAssertEqual(all, GlobalSettings())
    }

    /// Preferences kept outside `GlobalSettings` are reset with their tab, and the dots follow.
    func testResetPerTabClearsItsPreferences() {
        let viewModel = GlobalSettingsViewModel()
        let saved = viewModel.settings
        defer { viewModel.settings = saved }
        defaults.set(true, forKey: "ReclaimOriginalPackages")
        defaults.set(true, forKey: "HidesReleaseNotesAfterUpdate")
        XCTAssertTrue(SettingsTabReset.hasChanges(.optimizations, settings: GlobalSettings(), defaults: defaults))

        SettingsTabReset.reset(.optimizations, viewModel: viewModel, defaults: defaults, updater: nil)
        XCTAssertNil(defaults.object(forKey: "ReclaimOriginalPackages"))
        XCTAssertTrue(defaults.bool(forKey: "HidesReleaseNotesAfterUpdate"), "another tab's preference stays")
        XCTAssertFalse(SettingsTabReset.hasChanges(.optimizations, settings: GlobalSettings(), defaults: defaults))

        var fast = GlobalSettings()
        fast.fps = 90
        XCTAssertTrue(SettingsField.anyChanged(on: .performance, fast))
        XCTAssertFalse(SettingsField.anyChanged(on: .general, fast))
    }
}

private enum SettingsField {
    static func anyChanged(on tab: SettingsTab, _ settings: GlobalSettings) -> Bool {
        tab.fields.contains { $0.isChanged(settings) }
    }
}
