import XCTest
@testable import OpenWallpaperEngine

/// A test run must never read or write the user's real state: the test host is the app itself and
/// shares its bundle identifier, so without isolation tests overwrote playlists and settings.
final class AppStorageIsolationTests: XCTestCase {
    func testTheTestHostUsesAnIsolatedStore() throws {
        let store = AppStorageLocation.current
        XCTAssertTrue(store.isIsolated)
        XCTAssertFalse(store.defaults === UserDefaults.standard, "tests must not use UserDefaults.standard")
        XCTAssertFalse(UserDefaults.app === UserDefaults.standard)
        let suite = try XCTUnwrap(store.suiteName)
        XCTAssertTrue(suite.contains("isolated"), suite)
        XCTAssertNotEqual(suite, AppStorageLocation.realBundleIdentifier)

        let real = AppStorageLocation(isolationTag: nil)
        XCTAssertTrue(real.defaults === UserDefaults.standard, "the user's launch keeps the real domain")
        XCTAssertNotEqual(store.supportDirectory.standardizedFileURL, real.supportDirectory.standardizedFileURL)
        XCTAssertNotEqual(store.cachesDirectory.standardizedFileURL, real.cachesDirectory.standardizedFileURL)
        XCTAssertNotEqual(store.keychainServicePrefix, real.keychainServicePrefix)
        XCTAssertTrue(store.keychainServicePrefix.contains("isolated"))
    }

    /// The test host never calls the keychain: a run once sat for half an hour on a macOS prompt
    /// for the isolated steamcmd account item, read by `SteamCmdService.attemptCachedLogin`.
    /// Every keychain item of an isolated copy lives in memory; the user's launch keeps the keychain.
    func testTheTestHostKeepsKeychainItemsInMemory() throws {
        guard case .memory(let memory) = KeychainStore.Backend.processDefault else {
            return XCTFail("the test host must not use the system keychain")
        }
        XCTAssertTrue(memory === InMemoryKeychain.shared)
        for secret in [SteamCredentials.webAPIKey(), SteamCredentials.steamCmdAccount()] {
            guard case .memory = secret.keychain.backend else { return XCTFail("\(secret.keychain.service) uses the keychain") }
        }
        guard case .memory = KeychainStore(service: "any").backend else { return XCTFail("the default backend is memory") }
        guard case .memory = KeychainStore.Backend.for(AppStorageLocation(isolationTag: "shots")) else {
            return XCTFail("an isolated copy keeps its items in memory")
        }
        guard case .system = KeychainStore.Backend.for(AppStorageLocation(isolationTag: nil)) else {
            return XCTFail("the user's launch keeps the keychain")
        }

        let store = KeychainStore(service: "\(AppStorageLocation.current.keychainServicePrefix).guard.\(UUID().uuidString)")
        try store.set("value", forAccount: "a")
        XCTAssertEqual(InMemoryKeychain.shared.string(service: store.service, account: "a"), "value")
        try store.removeValue(forAccount: "a")
        XCTAssertNil(try store.string(forAccount: "a"))
    }

    /// `KeychainStore` is the only code that calls the keychain, so its in-memory backend covers
    /// every keychain user.
    func testOnlyKeychainStoreCallsTheKeychain() throws {
        let repository = AppIdentityLintTests.repository
        let keychainAPIs = ["SecItem", "kSecClass", "SecKeychain", "SecAccess"]
        var callers: [String] = []
        let roots = ["OpenWallpaperEngine", "OpenWallpaperEngineApp", "OpenWallpaperEngineSaver",
                     "OpenWallpaperEngineSaverExtension", "OWESaverBroker", "OWEChromiumHelper", "EditorHelper",
                     "MCPServer", "Packages"]
        for root in roots {
            let url = repository.appending(path: root, directoryHint: .isDirectory)
            guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in files where ["swift", "m", "mm", "c", "h"].contains(file.pathExtension) {
                guard !file.pathComponents.contains(where: AppIdentityLintTests.skippedFolders.contains) else { continue }
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                if keychainAPIs.contains(where: text.contains) { callers.append(file.lastPathComponent) }
            }
        }
        XCTAssertEqual(callers, ["KeychainStore.swift"])
    }

    /// An `@AppStorage` without a store uses `UserDefaults.standard`, the user's real domain even in
    /// the test host and isolated copies. The app passes `store: .app`; the editor package, which
    /// can't see `.app`, passes the store the app hands it (`WallpaperEditorServices.preferences`).
    func testEveryAppStorageNamesItsStore() throws {
        let repository = AppIdentityLintTests.repository
        let roots = ["OpenWallpaperEngine", "OpenWallpaperEngineApp", "OpenWallpaperEngineSaver",
                     "OpenWallpaperEngineSaverExtension", "OWESaverBroker", "OWEChromiumHelper", "EditorHelper",
                     "MCPServer", "Packages"]
        // `@AppStorage("key")` or `AppStorage(wrappedValue: …, "key")` with no `store:` on the line.
        let declaration = try NSRegularExpression(pattern: #"@AppStorage\(|\bAppStorage\(wrappedValue:"#)
        var leaks: [String] = []
        for root in roots {
            let url = repository.appending(path: root, directoryHint: .isDirectory)
            guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in files where file.pathExtension == "swift" {
                guard !file.pathComponents.contains(where: AppIdentityLintTests.skippedFolders.contains) else { continue }
                let text = try String(contentsOf: file, encoding: .utf8)
                for (number, line) in text.components(separatedBy: "\n").enumerated() {
                    guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//"),
                          declaration.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil,
                          !line.contains("store:") else { continue }
                    leaks.append("\(file.lastPathComponent):\(number + 1)")
                }
            }
        }
        XCTAssertEqual(leaks, [], "an @AppStorage without store: writes UserDefaults.standard")
    }

    /// Metal keeps its shader cache in `<Darwin user cache>/<bundle id>/com.apple.metal`, which
    /// every copy with the app's bundle id would share; the test host moved its Darwin folders into
    /// a subfolder of its own at launch (`DarwinUserDirectories`), so it never fills the user's.
    func testTheTestHostHasItsOwnMetalShaderCache() throws {
        let suffix = DarwinUserDirectories.suffix(isolationTag: AppStorageLocation.testsTag)
        let cacheDirectory = try XCTUnwrap(DarwinUserDirectories.cacheDirectory)
        XCTAssertEqual(cacheDirectory.lastPathComponent, suffix)
        XCTAssertEqual(FileManager.default.temporaryDirectory.standardizedFileURL.lastPathComponent, suffix)
        let metal = try XCTUnwrap(MetalShaderCache.current)
        XCTAssertTrue(metal.directory.path(percentEncoded: false).contains("/\(suffix)/"), metal.directory.path)
        XCTAssertEqual(metal.directory.lastPathComponent, "com.apple.metal")
    }

    /// A test copy is marked TEST, a local build Dev, a release nothing.
    func testTheDockBadgeTellsCopiesApart() {
        XCTAssertEqual(DockBadge.current, .test, "the test host is an isolated copy")
        XCTAssertEqual(DockBadge.kind(isIsolated: true, isReleaseBuild: true), .test)
        XCTAssertEqual(DockBadge.kind(isIsolated: true, isReleaseBuild: false), .test)
        XCTAssertEqual(DockBadge.kind(isIsolated: false, isReleaseBuild: false), .dev)
        XCTAssertEqual(DockBadge.kind(isIsolated: false, isReleaseBuild: true), .none)
    }

    /// Every badge is the system one, so the Dock keeps drawing the real, appearance-aware icon.
    @MainActor
    func testTheDockBadgeKeepsTheSystemIcon() {
        let tile = NSApp.dockTile
        defer { DockBadge.current.apply(to: tile) }
        let expected: [(DockBadge, String?)] = [(.none, nil), (.test, "TEST"), (.dev, "Dev")]
        for (kind, label) in expected {
            kind.apply(to: tile)
            XCTAssertNil(tile.contentView, "\(kind)")
            XCTAssertEqual(tile.badgeLabel, label, "\(kind)")
        }
    }

    func testDefaultLocationsLiveInTheIsolatedStore() {
        let store = AppStorageLocation.current
        XCTAssertTrue(SafeRestartStore.defaultFileURL.path.hasPrefix(store.supportDirectory.path))
        XCTAssertTrue(SceneScriptStorage.defaultDirectory.path.hasPrefix(store.supportDirectory.path))
        XCTAssertTrue(ShaderVariantTranslator.defaultCacheDirectory?.path.hasPrefix(store.cachesDirectory.path) ?? true)
        XCTAssertTrue(KeychainSecret.service("steam-web-api-key").hasPrefix(store.keychainServicePrefix + "."))
    }

    func testIsolationTagSources() {
        typealias L = AppStorageLocation
        XCTAssertNil(L.isolationTag(environment: [:], arguments: ["app"], isRunningTests: false))
        XCTAssertEqual(L.isolationTag(environment: [:], arguments: [], isRunningTests: true), "tests")
        XCTAssertEqual(L.isolationTag(environment: ["XCTestConfigurationFilePath": "/x"], arguments: [], isRunningTests: false),
                       "tests")
        XCTAssertEqual(L.isolationTag(environment: ["XCTestBundlePath": "/x"], arguments: [], isRunningTests: false), "tests")
        XCTAssertEqual(L.isolationTag(environment: ["OWE_ISOLATED_STATE": "shots"], arguments: [], isRunningTests: false),
                       "shots")
        XCTAssertEqual(L.isolationTag(environment: [:], arguments: ["app", "-OWEIsolatedState", "agent 7/x"],
                                      isRunningTests: false), "agent-7-x")
        XCTAssertNil(L.isolationTag(environment: ["OWE_ISOLATED_STATE": ""], arguments: [], isRunningTests: false),
                     "an empty tag doesn't isolate")
    }

    func testIsolatedLocationNaming() {
        let store = AppStorageLocation(isolationTag: "shots", bundleIdentifier: "app.openwallpaperengine")
        XCTAssertEqual(store.suiteName, "app.openwallpaperengine.isolated.shots")
        XCTAssertEqual(store.supportDirectory.lastPathComponent, "Open Wallpaper Engine (isolated shots)")
        XCTAssertEqual(store.cachesDirectory.lastPathComponent, "Open Wallpaper Engine (isolated shots)")
        XCTAssertEqual(store.keychainServicePrefix, "app.openwallpaperengine.isolated.shots")
    }
}
