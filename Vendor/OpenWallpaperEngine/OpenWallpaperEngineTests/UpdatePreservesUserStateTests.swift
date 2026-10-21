import XCTest
@testable import OpenWallpaperEngine

/// Sparkle replaces only the app bundle, so an update must find everything the user had: nothing
/// the app writes lives in the bundle, and nothing it stores is keyed on the app's version.
@MainActor
final class UpdatePreservesUserStateTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appending(path: "UpdatePreservesUserState-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporary)
    }

    /// A minimal bundle with the app's identifier and the given versions.
    private func bundle(named name: String, version: String, build: String) throws -> Bundle {
        let contents: URL = temporary.appending(path: "\(name).app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": AppStorageLocation.realBundleIdentifier,
                                   "CFBundleShortVersionString": version, "CFBundleVersion": build,
                                   "CFBundlePackageType": "APPL", "CFBundleName": name]
        let data: Data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
        return try XCTUnwrap(Bundle(url: temporary.appending(path: "\(name).app")))
    }

    func testStateLocationsDoNotDependOnTheAppVersion() throws {
        let old: Bundle = try bundle(named: "Old", version: "1.0.0", build: "41")
        let new: Bundle = try bundle(named: "New", version: "1.1.0", build: "57")
        for tag in [nil, "update-test"] as [String?] {
            let before: AppStorageLocation = AppStorageLocation(isolationTag: tag, bundleIdentifier: try XCTUnwrap(old.bundleIdentifier))
            let after: AppStorageLocation = AppStorageLocation(isolationTag: tag, bundleIdentifier: try XCTUnwrap(new.bundleIdentifier))
            XCTAssertEqual(before.suiteName, after.suiteName)
            XCTAssertEqual(before.supportDirectory, after.supportDirectory)
            XCTAssertEqual(before.cachesDirectory, after.cachesDirectory)
            XCTAssertEqual(before.keychainServicePrefix, after.keychainServicePrefix)
            // None of it is inside an app bundle.
            for url in [after.supportDirectory, after.cachesDirectory] {
                XCTAssertFalse(url.path.contains(".app/"), url.path)
            }
        }
    }

    /// The first-launch flag, the setup assistant's progress and the settings, written by one
    /// version and read by the next (a new defaults instance, as a relaunch has).
    func testFirstLaunchFlagAndSettingsSurviveAVersionChange() throws {
        let suite: String = "\(AppStorageLocation.realBundleIdentifier).isolated.update-test-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let old: Bundle = try bundle(named: "Old", version: "1.0.0", build: "41")
        let new: Bundle = try bundle(named: "New", version: "1.1.0", build: "57")
        XCTAssertNotEqual(old.infoDictionary?["CFBundleVersion"] as? String, new.infoDictionary?["CFBundleVersion"] as? String)

        var settings: GlobalSettings = GlobalSettings()
        settings.syncPropertiesAcrossDisplays.toggle()
        settings.audioOutput.toggle()
        do {
            let before: UserDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            before.set(false, forKey: OnboardingFlow.showsAtLaunchKey)
            before.set(OnboardingStep.done.rawValue, forKey: OnboardingFlow.stepKey)
            before.set(try JSONEncoder().encode(settings), forKey: "GlobalSettings")
            before.synchronize()
        }

        let after: UserDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertFalse(OnboardingFlow.showsAtLaunch(defaults: after), "the setup assistant must not come back")
        XCTAssertEqual(OnboardingFlow(defaults: after).step, .done)
        let data: Data = try XCTUnwrap(after.data(forKey: "GlobalSettings"))
        let restored: GlobalSettings = try JSONDecoder().decode(GlobalSettings.self, from: data)
        XCTAssertEqual(restored.syncPropertiesAcrossDisplays, settings.syncPropertiesAcrossDisplays)
        XCTAssertEqual(restored.audioOutput, settings.audioOutput)
    }

    /// The compiled pipeline archive keeps its name across app versions (it used to include them,
    /// so every update recompiled every pipeline).
    func testPipelineArchiveKeyIgnoresTheAppVersion() {
        let key: String = EffectPipelineArchive.environmentKey(os: "Version 26.2 (Build 25C56)", toolchain: "glslang 16")
        XCTAssertEqual(key, EffectPipelineArchive.environmentKey(os: "Version 26.2 (Build 25C56)", toolchain: "glslang 16"))
        XCTAssertNotEqual(key, EffectPipelineArchive.environmentKey(os: "Version 26.3 (Build 25D5)", toolchain: "glslang 16"),
                          "a new OS build invalidates it")
        XCTAssertNotEqual(key, EffectPipelineArchive.environmentKey(os: "Version 26.2 (Build 25C56)", toolchain: "glslang 17"),
                          "a new shader toolchain invalidates it")
        XCTAssertTrue(key.contains("t\(ShaderVariantTranslator.revision)-"))
        XCTAssertTrue(key.hasSuffix("--r\(EffectPipelineArchive.revision)"))
        let info: [String: Any] = Bundle.main.infoDictionary ?? [:]
        for field in ["CFBundleShortVersionString", "CFBundleVersion"] {
            guard let value = info[field] as? String else { continue }
            XCTAssertFalse(EffectPipelineArchive.environmentKey.contains("--\(value)-"), field)
        }
    }

    /// Nothing in the app writes into its own bundle, and only the version's display and the
    /// updater read the version.
    func testSourcesNeitherWriteIntoTheBundleNorKeyOnTheVersion() throws {
        let sources: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "OpenWallpaperEngine")
        // The update prewarm matches the downloaded update's bundle by its version, and the MCP Server
        // plugin refreshes its installed owe-mcp when the app's version changes; neither keys state on it.
        let versionReaders: Set<String> = ["MainWindow.swift", "AboutUsView.swift", "AppUpdateConfiguration.swift", "AppVersion.swift",
                                           "ReleaseVersion.swift", "UpdateBundleLocator.swift",
                                           "UpdateShaderPrewarmer.swift", "AppUpdater.swift", "UpdateVersionDisplay.swift",
                                           "MCPServerPlugin.swift"]
        let bundleLocations: [String] = ["Bundle.main.bundleURL", "Bundle.main.bundlePath", "Bundle.main.resourceURL",
                                         "Bundle.main.resourcePath", "Bundle.main.executableURL"]
        let bundleReaders: Set<String> = ["AppRelauncher.swift", "ScreenSaverInstaller.swift", "CrashWatcher.swift",
                                          "ChromiumEnginePackage.swift", "AppBundleLayout.swift", "WallpaperEditorLauncher.swift"]
        var problems: [String] = []
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let text: String = try String(contentsOf: file, encoding: .utf8)
            let name: String = file.lastPathComponent
            if !versionReaders.contains(name), text.contains("CFBundleVersion") || text.contains("CFBundleShortVersionString") {
                problems.append("\(name) reads the app version")
            }
            // Relaunching opens the bundle, the crash watcher is handed its path to reopen it, the
            // screen saver installer copies the bundled .saver out to ~/Library/Screen Savers and the
            // Chromium engine copies the bundled helper apps out into its install in storage, and the
            // Wallpaper Editor's app is found inside the app and the app around it (all only read
            // the bundle); nothing else may use its location.
            if !bundleReaders.contains(name), let hit = bundleLocations.first(where: text.contains) {
                problems.append("\(name) uses \(hit)")
            }
        }
        XCTAssertEqual(problems, [])
    }
}
