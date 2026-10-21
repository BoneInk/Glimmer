import XCTest
@testable import OpenWallpaperEngine

/// "Reset Config" reaches every setting Settings shows, Log Level gates `OWELog`, and
/// "Use Default Location" reports a folder change.
@MainActor
final class SettingsResetTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "owe-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private static let settingsFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "OpenWallpaperEngine/Settings")

    /// Constants Settings views pass to `@AppStorage`, by the name the source spells.
    private static let keyConstants: [String: String] = [
        "SteamCmdInstaller.autoInstallKey": SteamCmdInstaller.autoInstallKey,
        "WallpaperEngineAssetsService.autoInstallKey": WallpaperEngineAssetsService.autoInstallKey,
        "WhatsNew.hidesReleaseNotesKey": WhatsNew.hidesReleaseNotesKey,
        "AppUpdater.receivesBetaUpdatesKey": AppUpdater.receivesBetaUpdatesKey,
    ]

    /// Every `@AppStorage` key in a Settings view is reset by a tab (so by "Reset Config"), or
    /// is listed as view state.
    func testEveryAppStorageKeyInSettingsIsReset() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.settingsFolder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "the Settings sources are found")
        let pattern = try NSRegularExpression(pattern: #"@AppStorage\(\s*([^,)]+?)\s*[,)]"#)
        let registered = Set(SettingsTabReset.allPreferenceKeys)
        var found = 0
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let spelled = String(source[Range(match.range(at: 1), in: source)!])
                let key: String
                if spelled.hasPrefix("\"") {
                    key = String(spelled.dropFirst().dropLast())
                } else {
                    let resolved = Self.keyConstants[spelled]
                    XCTAssertNotNil(resolved, "\(file.lastPathComponent): add \(spelled) to keyConstants")
                    key = resolved ?? spelled
                }
                found += 1
                XCTAssertTrue(registered.contains(key) || SettingsTabReset.nonSettingViewKeys.contains(key),
                              "\(file.lastPathComponent): \(key) is not reset by Reset Config")
            }
        }
        XCTAssertGreaterThan(found, 0)
        // The registry's spelled keys match the constants the app reads.
        for key in Self.keyConstants.values { XCTAssertTrue(registered.contains(key), key) }
        // Exported preferences are reset too.
        for key in SettingsTransfer.preferenceKeys { XCTAssertTrue(registered.contains(key), key) }
    }

    /// "Reset Config" resets `GlobalSettings` and the preferences outside it, and leaves what
    /// isn't a setting.
    func testResetAllClearsEveryPreference() {
        let viewModel = GlobalSettingsViewModel()
        let saved = viewModel.settings
        defer { viewModel.settings = saved }
        var changed = GlobalSettings()
        changed.fps = 90
        changed.logLevel = .verbose
        viewModel.settings = changed
        for key in SettingsTabReset.allPreferenceKeys { defaults.set(false, forKey: key) }
        defaults.set(Data([1]), forKey: "Playlists")
        defaults.set(true, forKey: "ShowsKeyboardShortcuts")

        SettingsTabReset.resetAll(viewModel: viewModel, defaults: defaults, updater: nil)

        XCTAssertEqual(viewModel.settings, GlobalSettings())
        for key in SettingsTabReset.allPreferenceKeys { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertNotNil(defaults.object(forKey: "Playlists"))
        XCTAssertNotNil(defaults.object(forKey: "ShowsKeyboardShortcuts"))
        for tab in SettingsTab.allCases {
            XCTAssertFalse(SettingsTabReset.hasChanges(tab, settings: viewModel.settings, defaults: defaults), "\(tab)")
        }
    }

    func testLogLevelGatesSeverities() {
        let all: [OWELog.Severity] = [.debug, .info, .error]
        XCTAssertTrue(all.allSatisfy { !OWELog.logs($0, at: .none) }, "None logs nothing")
        XCTAssertEqual(all.filter { OWELog.logs($0, at: .error) }, [.error], "Errors Only logs errors only")
        XCTAssertEqual(all.filter { OWELog.logs($0, at: .verbose) }, all)
        XCTAssertNotEqual(OWELog.threshold(for: .none), OWELog.threshold(for: .error))
    }

    /// Errors Only is the default; the old key's None (the old default) migrates to it, other
    /// old choices stay, and a None saved under the new key stays None.
    func testLogLevelDefaultAndMigration() throws {
        XCTAssertEqual(GlobalSettings().logLevel, .error)
        func decode(_ json: String) throws -> GlobalSettings {
            try JSONDecoder().decode(GlobalSettings.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"logLevel":"none"}"#).logLevel, .error)
        XCTAssertEqual(try decode(#"{"logLevel":"verbose"}"#).logLevel, .verbose)
        XCTAssertEqual(try decode("{}").logLevel, .error)
        var chosen = GlobalSettings()
        chosen.logLevel = .none
        let saved = try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(chosen))
        XCTAssertEqual(saved.logLevel, .none)
    }

    func testUseDefaultLocationReportsAChange() {
        XCTAssertFalse(WallpaperStorage.resetToDefault(defaults: defaults), "already the default")
        defaults.set("/tmp/owe-custom-storage", forKey: "CustomWallpapersDirectory")
        XCTAssertEqual(WallpaperStorage.folder(defaults: defaults).path, "/tmp/owe-custom-storage")
        XCTAssertTrue(WallpaperStorage.resetToDefault(defaults: defaults))
        XCTAssertEqual(WallpaperStorage.folder(defaults: defaults), WallpaperStorage.defaultDirectory.standardizedFileURL)
    }
}
