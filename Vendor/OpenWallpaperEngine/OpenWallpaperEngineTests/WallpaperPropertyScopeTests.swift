import XCTest
@testable import OpenWallpaperEngine

/// Per-display user properties (WE 2.8.0.42: the same wallpaper on two displays has independent
/// properties) with "Sync properties across displays": the stores, how displays share a running
/// instance, and where the sound plays.
final class WallpaperPropertyScopeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var root: URL!

    override func setUpWithError() throws {
        suite = "owe-property-scope-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        root = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root) // scratch cleanup
    }

    private func key(_ folder: String, type: String = "scene") -> WallpaperInstanceKey {
        let project = WEProject(file: "scene.json", preview: "preview.jpg", title: folder, type: type)
        return WallpaperInstanceKey(WEWallpaper(using: project, where: URL(filePath: "/tmp/owe/\(folder)")))
    }

    // MARK: - Stores

    func testEachDisplayHasItsOwnStoreStartedFromTheShared() throws {
        let identity = WallpaperSettingsIdentity(rawValue: "workshop-1")
        XCTAssertEqual(identity.key(.userProperties, scope: .shared), "SceneUserProperties.workshop-1",
                       "the shared store keeps the key properties had before displays had their own")
        XCTAssertEqual(identity.key(.userProperties, scope: .display("7")), "SceneUserProperties.workshop-1.display.7")
        defaults.set(["rain": "0.5"], forKey: identity.key(.userProperties))
        defaults.set(true, forKey: identity.key(.explicitUserProperties))
        XCTAssertEqual(identity.stored(.userProperties, scope: .display("7"), defaults: defaults) as? [String: String],
                       ["rain": "0.5"], "a display without its own properties shows the shared ones")
        identity.seed(.display("7"), defaults: defaults)
        XCTAssertEqual(defaults.dictionary(forKey: identity.key(.userProperties, scope: .display("7"))) as? [String: String],
                       ["rain": "0.5"])
        XCTAssertEqual(defaults.bool(forKey: identity.key(.explicitUserProperties, scope: .display("7"))), true)
        defaults.set(["rain": "1"], forKey: identity.key(.userProperties, scope: .display("7")))
        identity.seed(.display("7"), defaults: defaults)
        XCTAssertEqual(identity.stored(.userProperties, scope: .display("7"), defaults: defaults) as? [String: String],
                       ["rain": "1"], "seeding never overwrites a display's own properties")
        XCTAssertEqual(identity.stored(.userProperties, scope: .shared, defaults: defaults) as? [String: String],
                       ["rain": "0.5"], "nor does a display's edit reach the shared store")
    }

    /// Turning sync on keeps what the displays ran. 3802900973's audio bars, switched on for each
    /// display, went back to project.json's "off" once synced: its shared store was never saved.
    func testSyncingStartsFromTheSelectedDisplaysProperties() {
        let identity = WallpaperSettingsIdentity(rawValue: "workshop-1")
        defaults.set(["bars": "false"], forKey: identity.key(.userProperties))
        defaults.set(["bars": "true"], forKey: identity.key(.userProperties, scope: .display("2")))
        defaults.set(true, forKey: identity.key(.explicitUserProperties, scope: .display("2")))
        identity.share(.display("2"), defaults: defaults)
        XCTAssertEqual(identity.stored(.userProperties, scope: .shared, defaults: defaults) as? [String: String], ["bars": "true"])
        XCTAssertTrue(defaults.bool(forKey: identity.key(.explicitUserProperties)),
                      "saved as the user's, so a load doesn't re-derive the defaults")
        identity.share(.display("9"), defaults: defaults)
        XCTAssertEqual(identity.stored(.userProperties, scope: .shared, defaults: defaults) as? [String: String], ["bars": "true"],
                       "a display without its own properties changes nothing")

        let rain = key("rain"), snow = key("snow")
        let displays = WallpaperPropertyGroups.sharingDisplays(assignments: ["1": rain, "2": rain, "3": snow, "4": snow],
                                                               selected: "2")
        XCTAssertEqual(displays, [rain: "2", snow: "3"], "the selected display's, else the first showing the wallpaper")
    }

    func testRunningStoresAreKeptApart() {
        let directory = URL(filePath: "/tmp/owe/rain")
        XCTAssertEqual(WallpaperPropertyScope.shared.runtimeKey(directory: directory), "/tmp/owe/rain")
        XCTAssertNotEqual(WallpaperPropertyScope.display("1").runtimeKey(directory: directory),
                          WallpaperPropertyScope.display("2").runtimeKey(directory: directory))
        var stores = SceneUserPropertyStores()
        stores.set(["rain": "0"], for: WallpaperPropertyScope.display("1").runtimeKey(directory: directory), replacing: true)
        stores.set(["rain": "1"], for: WallpaperPropertyScope.display("2").runtimeKey(directory: directory), replacing: true)
        XCTAssertEqual(stores.entry(for: WallpaperPropertyScope.display("1").runtimeKey(directory: directory)).strings["rain"], "0")
        XCTAssertEqual(stores.entry(for: WallpaperPropertyScope.display("2").runtimeKey(directory: directory)).strings["rain"], "1")
    }

    func testASceneRunsTheStoreOfItsScope() {
        let wallpaper = WEWallpaper(using: WEProject(file: "scene.json", preview: "preview.jpg", title: "x", type: "scene"),
                                    where: root)
        let viewModel = SceneContentLoader(wallpaper: wallpaper, propertyScope: .display("3"))
        XCTAssertEqual(viewModel.propertyStoreKey, WallpaperPropertyScope.display("3").runtimeKey(directory: root))
        XCTAssertEqual(SceneContentLoader(wallpaper: wallpaper).propertyStoreKey, root.path)
    }

    // MARK: - Instances

    func testSyncedDisplaysShareOneInstance() {
        let rain = key("rain")
        let keys = WallpaperPropertyGroups.instanceKeys(assignments: ["1": rain, "2": rain], synced: true) { _, scope in
            ["rain": scope == .display("1") ? "0" : "1"]
        }
        XCTAssertEqual(keys["1"], rain)
        XCTAssertEqual(keys["2"], rain)
        XCTAssertEqual(keys["1"]?.properties, .shared)
    }

    func testDisplaysWithEqualPropertiesShareTheFirstOnesInstance() {
        let rain = key("rain")
        let keys = WallpaperPropertyGroups.instanceKeys(assignments: ["2": rain, "1": rain, "3": rain], synced: false) { _, scope in
            ["rain": scope == .display("3") ? "1" : "0"]
        }
        XCTAssertEqual(keys["1"]?.properties, .display("1"))
        XCTAssertEqual(keys["2"], keys["1"], "equal properties: one instance, running display 1's store")
        XCTAssertEqual(keys["3"]?.properties, .display("3"), "different properties: an instance of its own")
        XCTAssertNotEqual(keys["3"], keys["1"])
        XCTAssertEqual(keys["3"]?.wallpaper, rain)
    }

    func testDifferentWallpapersNeverShare() {
        let keys = WallpaperPropertyGroups.instanceKeys(assignments: ["1": key("a"), "2": key("b")], synced: false) { _, _ in [:] }
        XCTAssertNotEqual(keys["1"], keys["2"])
        XCTAssertEqual(keys["2"]?.properties, .display("2"))
    }

    // MARK: - Sound

    /// WE plays the same wallpaper once across displays; with different properties it runs as two
    /// instances, and only the one on the wallpaper's audible display plays.
    func testAWallpaperRunningAsTwoInstancesPlaysOnce() {
        let rain = key("rain")
        var one = rain, two = rain
        one.properties = .display("1")
        two.properties = .display("2")
        let instances = ["1": one, "2": two]
        XCTAssertEqual(WallpaperAudioRouting.audibleInstance(of: rain, instanceKeys: instances, enabledScreens: ["1", "2"],
                                                             mainScreen: "2"), two, "the main display's instance")
        XCTAssertEqual(WallpaperAudioRouting.audibleInstance(of: rain, instanceKeys: instances, enabledScreens: ["1", "2"],
                                                             mainScreen: nil), one, "else the lowest display's")
    }

    func testDifferentWallpapersEachPlay() {
        var a = key("a"), b = key("b")
        a.properties = .display("1")
        b.properties = .display("2")
        let instances = ["1": a, "2": b]
        XCTAssertEqual(WallpaperAudioRouting.audibleInstance(of: a, instanceKeys: instances, enabledScreens: ["1", "2"],
                                                             mainScreen: "2"), a)
        XCTAssertEqual(WallpaperAudioRouting.audibleInstance(of: b, instanceKeys: instances, enabledScreens: ["1", "2"],
                                                             mainScreen: "2"), b)
    }

    // MARK: - Setting

    func testSyncIsOffByDefaultAsInWE() throws {
        XCTAssertFalse(GlobalSettings().syncPropertiesAcrossDisplays)
        let stored = try JSONDecoder().decode(GlobalSettings.self, from: Data(#"{"syncPropertiesAcrossDisplays": true}"#.utf8))
        XCTAssertTrue(stored.syncPropertiesAcrossDisplays)
        XCTAssertFalse(try JSONDecoder().decode(GlobalSettings.self, from: Data("{}".utf8)).syncPropertiesAcrossDisplays)
    }

    /// The Workshop preview has no real display: it always runs the shared store.
    @MainActor
    func testThePreviewRunsTheSharedStore() {
        let preview = WallpaperViewModel(persistsWallpapers: false)
        preview.syncsPropertiesAcrossDisplays = false
        XCTAssertEqual(preview.propertyScope(for: "preview"), .shared)
        XCTAssertEqual(preview.editedPropertyScopes(of: preview.wallpaper(for: "preview")), [.shared])
    }
}
