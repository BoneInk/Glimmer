import XCTest
@testable import OpenWallpaperEngine

/// Scene Edit / Export's Screen Saver mode: its isolated session never reaches the desktop,
/// its layer and property choices are saved per wallpaper apart from the wallpaper's own and
/// reused, Set as Screen Saver picks the scene to be drawn live with them, an earlier recording
/// migrates to that pick, and an installed video is replaced at once or not at all.
final class ScreenSaverEditorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var directory: URL!

    private static func project(id: String) -> String {
        """
        {"file": "scene.json", "title": "Saver \(id)", "type": "scene", "workshopid": "\(id)",
         "general": {"properties": {
           "speed": {"type": "slider", "text": "Speed", "value": 0.25, "min": 0, "max": 1}
         }}}
        """
    }

    override func setUpWithError() throws {
        suite = "owe-screensaver-editor-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory) // scratch cleanup
    }

    private func wallpaper(id: String = "626262") throws -> WEWallpaper {
        let folder = directory.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = Self.project(id: id)
        try Data(project.utf8).write(to: folder.appending(path: "project.json"))
        try Data("{}".utf8).write(to: folder.appending(path: "scene.json"))
        return WEWallpaper(using: try decodeTolerant(WEProject.self, from: Data(project.utf8)), where: folder)
    }

    private func save(_ values: [String: String], _ scope: WallpaperPropertyScope, of wallpaper: WEWallpaper) {
        let identity = WallpaperSettingsIdentity.resolve(wallpaper, defaults: defaults)
        defaults.set(values, forKey: identity.key(.userProperties, scope: scope))
        defaults.set(true, forKey: identity.key(.explicitUserProperties, scope: scope))
    }

    private func stored(_ scope: WallpaperPropertyScope, of wallpaper: WEWallpaper) -> [String: String]? {
        let identity = WallpaperSettingsIdentity.resolve(wallpaper, defaults: defaults)
        return defaults.dictionary(forKey: identity.key(.userProperties, scope: scope)) as? [String: String]
    }

    @MainActor
    private func makePlugin(_ store: ScreenSaverSettingsStore, videos: ScreenSaverVideoStore) -> ScreenSaverPlugin {
        ScreenSaverPlugin(store: videos,
                          installer: ScreenSaverInstaller(bundledSaver: nil, saversDirectory: directory.appending(path: "Savers"),
                                                          mayInstall: false),
                          settingsStore: store)
    }

    @MainActor
    private func makeService(_ store: ScreenSaverSettingsStore, plugin: ScreenSaverPlugin,
                             main: WEWallpaper? = nil) -> ScreenSaverSelectionService {
        let environment = ScreenSaverSelectionService.Environment(isPluginEnabled: { true }, enablePlugin: {},
                                                                  desktopWallpaper: { nil }, mainDisplayWallpaper: { main })
        return ScreenSaverSelectionService(plugin: plugin, environment: environment, store: store)
    }

    // MARK: Isolation

    /// The mode's layer and property edits go to its own store and private instance: the
    /// wallpaper's stored and running values stay as they were, no display regroups, and nothing
    /// is set as the screen saver until a recording is made.
    @MainActor
    func testScreenSaverEditsLeaveTheDesktopUntouched() throws {
        let wallpaper = try wallpaper()
        let visibility = sceneObjectVisibilityKey(objectID: 3)
        let shared: [String: String] = ["speed": "0.25", visibility: "true"]
        save(shared, .shared, of: wallpaper)
        let sharedKey = WallpaperPropertyScope.shared.runtimeKey(directory: wallpaper.settingsDirectory)
        WallpaperServices.shared.setUserProperties(shared, wallpaper: sharedKey, replacing: true)
        let store = ScreenSaverSettingsStore(defaults: defaults)
        let videos = ScreenSaverVideoStore(directory: directory.appending(path: "Videos"))
        let plugin = makePlugin(store, videos: videos)
        let service = makeService(store, plugin: plugin)

        let session = IsolatedSceneEditSession(wallpaper: wallpaper, purpose: ScreenSaverEditorModel.purpose,
                                               seededFrom: [.shared], defaults: defaults)
        let model = ScreenSaverEditorModel(session: session, seededFrom: [.shared], selectionService: service,
                                           store: store, defaults: defaults)
        XCTAssertEqual(session.values, shared)
        XCTAssertEqual(session.scope, .isolated(ScreenSaverEditorModel.purpose))
        XCTAssertNotEqual(session.instanceKey, WallpaperInstanceKey(wallpaper))

        let regrouped = expectation(forNotification: .wallpaperPropertiesDidSave, object: nil)
        regrouped.isInverted = true
        session.setLayerVisible(false, objectID: 3)
        session.setValues(["speed": "0.9"])
        model.persist()
        wait(for: [regrouped], timeout: 0.3)

        XCTAssertEqual(stored(.shared, of: wallpaper), shared)
        XCTAssertEqual(WallpaperServices.shared.userProperties(wallpaper: sharedKey), shared)
        XCTAssertEqual(WallpaperServices.shared.userProperties(wallpaper: session.runtimeKey)[visibility], "false")
        XCTAssertNil(session.instances.instance(for: WallpaperInstanceKey(wallpaper)))
        XCTAssertNil(store.selection, "nothing is the screen saver until it is set")
        XCTAssertNil(store.livePick)

        model.close()
        session.end()
        XCTAssertNil(stored(session.scope, of: wallpaper))
        XCTAssertEqual(stored(.shared, of: wallpaper), shared)
        XCTAssertEqual(WallpaperServices.shared.userProperties(wallpaper: sharedKey), shared)
    }

    // MARK: Persistence

    /// The choices are the screen saver's own, per wallpaper: the next session of that wallpaper
    /// starts from them, another wallpaper doesn't see them, and the wallpaper's own values never change.
    @MainActor
    func testChoicesArePersistedPerWallpaperAndReused() throws {
        let first = try wallpaper(id: "111")
        let second = try wallpaper(id: "222")
        save(["speed": "0.25"], .shared, of: first)
        save(["speed": "0.5"], .shared, of: second)
        let store = ScreenSaverSettingsStore(defaults: defaults)
        let videos = ScreenSaverVideoStore(directory: directory.appending(path: "Videos"))
        let plugin = makePlugin(store, videos: videos)
        let service = makeService(store, plugin: plugin)
        func open(_ wallpaper: WEWallpaper) -> ScreenSaverEditorModel {
            ScreenSaverEditorModel(session: IsolatedSceneEditSession(wallpaper: wallpaper, purpose: ScreenSaverEditorModel.purpose,
                                                                     seededFrom: [.shared], defaults: defaults),
                                   seededFrom: [.shared], selectionService: service, store: store, defaults: defaults)
        }

        // Opening and closing without a change saves nothing: the screen saver follows the wallpaper.
        let untouched = open(first)
        untouched.close()
        untouched.session.end()
        XCTAssertNil(store.values(for: WallpaperSettingsIdentity.resolve(first, defaults: defaults)))

        let hidden = sceneObjectVisibilityKey(objectID: 7)
        let edited = open(first)
        edited.session.setValues(["speed": "0.8", hidden: "false"])
        edited.close()
        edited.session.end()
        let saved = try XCTUnwrap(store.values(for: WallpaperSettingsIdentity.resolve(first, defaults: defaults)))
        XCTAssertEqual(saved, ["speed": "0.8", hidden: "false"])
        XCTAssertEqual(stored(.shared, of: first), ["speed": "0.25"], "the wallpaper's own values are untouched")

        let reopened = open(first)
        XCTAssertEqual(reopened.session.values, saved)
        reopened.session.end()
        let other = open(second)
        XCTAssertEqual(other.session.values, ["speed": "0.5"])
        other.session.end()

        // A later change to the wallpaper doesn't change the screen saver's choices.
        save(["speed": "0.1"], .shared, of: first)
        let again = open(first)
        XCTAssertEqual(again.session.values, saved)
        again.session.end()
    }

    // MARK: Setting it

    /// Set as Screen Saver: the scene is picked, not recorded. The pick and the choices are saved,
    /// nothing renders, and the plugin lists no video, so the saver shows the pick's still and its
    /// live frames. Turning the plugin off keeps the pick (there is no video to remove).
    @MainActor
    func testSettingASceneAsTheScreenSaverPicksItLive() throws {
        let wallpaper = try wallpaper()
        let store = ScreenSaverSettingsStore(defaults: defaults)
        let videos = ScreenSaverVideoStore(directory: directory.appending(path: "Videos"))
        let plugin = makePlugin(store, videos: videos)
        plugin.update(enabled: true, wallpaper: nil)
        let service = makeService(store, plugin: plugin)
        let values = ["speed": "0.7", sceneObjectVisibilityKey(objectID: 2): "false"]

        var succeeded: Bool?
        service.set(wallpaper, values: values) { succeeded = $0 }
        XCTAssertEqual(succeeded, true, "at once: nothing is recorded")
        let pick = try XCTUnwrap(store.livePick)
        XCTAssertEqual(pick.wallpaperDirectory, wallpaper.wallpaperDirectory.standardizedFileURL.path(percentEncoded: false))
        XCTAssertNil(store.selection)
        XCTAssertTrue(service.isSelected(wallpaper))
        XCTAssertEqual(store.values(for: WallpaperSettingsIdentity.resolve(wallpaper, defaults: defaults)), values)
        XCTAssertFalse(plugin.followsDesktop)
        XCTAssertEqual(plugin.livePick?.wallpaperDirectory.standardizedFileURL, wallpaper.wallpaperDirectory.standardizedFileURL)

        plugin.update(enabled: false, wallpaper: nil)
        XCTAssertNotNil(store.livePick)
        service.stopUsingSelection()
        XCTAssertNil(store.livePick)
        XCTAssertFalse(service.isSelected(wallpaper))
    }

    // MARK: Screen Saver Same as Wallpaper

    /// Settings › General › Screen Saver Same as Wallpaper reads the selection: on with nothing set,
    /// off once a wallpaper is picked, from any of the ways to set one.
    @MainActor
    func testSameAsWallpaperFollowsTheSelection() throws {
        let wallpaper = try wallpaper()
        let store = ScreenSaverSettingsStore(defaults: defaults)
        let videos = ScreenSaverVideoStore(directory: directory.appending(path: "Videos"))
        let service = makeService(store, plugin: makePlugin(store, videos: videos))
        XCTAssertTrue(service.followsDesktop, "on by default")

        service.setAsScreenSaver(wallpaper)
        XCTAssertFalse(service.followsDesktop, "a menu's Set as Screen Saver turns it off")
        service.stopUsingSelection()
        XCTAssertTrue(service.followsDesktop)

        service.pick(wallpaper, values: ["speed": "0.5"])
        XCTAssertFalse(service.followsDesktop, "the Screen Saver tab's pick turns it off")
        service.stopUsingSelection()
        XCTAssertTrue(service.followsDesktop)
    }

    /// Turning it on clears the pick.
    @MainActor
    func testTurningSameAsWallpaperOnClearsWhatIsSet() throws {
        let wallpaper = try wallpaper()
        let store = ScreenSaverSettingsStore(defaults: defaults)
        let videos = ScreenSaverVideoStore(directory: directory.appending(path: "Videos"))
        let service = makeService(store, plugin: makePlugin(store, videos: videos))
        service.pick(wallpaper, values: [:])
        var result: Bool?
        service.setFollowsDesktop(true) { result = $0 }
        XCTAssertEqual(result, true)
        XCTAssertNil(store.livePick)
        XCTAssertTrue(service.followsDesktop)
    }

    /// Turning it off sets the main display's wallpaper, with the Screen Saver tab's choices for
    /// it; with no wallpaper the screen saver can show there, it stays on.
    @MainActor
    func testTurningSameAsWallpaperOffPicksTheMainDisplaysWallpaper() throws {
        let wallpaper = try wallpaper()
        let store = ScreenSaverSettingsStore(defaults: defaults)
        let videos = ScreenSaverVideoStore(directory: directory.appending(path: "Videos"))
        let identity = WallpaperSettingsIdentity.resolve(wallpaper, defaults: defaults)
        let choices = ["speed": "0.8"]
        store.setValues(choices, for: identity)
        let service = makeService(store, plugin: makePlugin(store, videos: videos), main: wallpaper)
        XCTAssertEqual(service.wallpaperForStoppingFollowingDesktop()?.wallpaperDirectory, wallpaper.wallpaperDirectory)
        var result: Bool?
        service.setFollowsDesktop(false) { result = $0 }
        XCTAssertEqual(result, true)
        XCTAssertFalse(service.followsDesktop)
        XCTAssertTrue(service.isSelected(wallpaper))
        XCTAssertEqual(store.values(for: identity), choices, "its Screen Saver tab choices are kept")

        let empty = makeService(ScreenSaverSettingsStore(defaults: defaults), plugin: makePlugin(store, videos: videos))
        empty.stopUsingSelection()
        XCTAssertNil(empty.wallpaperForStoppingFollowingDesktop())
        empty.setFollowsDesktop(false) { result = $0 }
        XCTAssertEqual(result, false)
        XCTAssertTrue(empty.followsDesktop, "never off while the screen saver still follows the desktop")
    }

    /// General's Restore Defaults (and Reset Config) turn it back on.
    @MainActor
    func testRestoreDefaultsTurnsSameAsWallpaperOn() throws {
        let wallpaper = try wallpaper()
        let store = ScreenSaverSettingsStore(defaults: defaults)
        let videos = ScreenSaverVideoStore(directory: directory.appending(path: "Videos"))
        let service = makeService(store, plugin: makePlugin(store, videos: videos))
        let viewModel = GlobalSettingsViewModel()
        let saved = viewModel.settings
        defer { viewModel.settings = saved }
        service.pick(wallpaper, values: [:])
        XCTAssertTrue(SettingsTabReset.hasChanges(.general, settings: GlobalSettings(), defaults: defaults, screenSaver: service))
        SettingsTabReset.reset(.performance, viewModel: viewModel, defaults: defaults, updater: nil, screenSaver: service)
        XCTAssertFalse(service.followsDesktop, "another tab's reset leaves it")
        SettingsTabReset.reset(.general, viewModel: viewModel, defaults: defaults, updater: nil, screenSaver: service)
        XCTAssertTrue(service.followsDesktop)
        XCTAssertFalse(SettingsTabReset.hasChanges(.general, settings: GlobalSettings(), defaults: defaults, screenSaver: service))
        XCTAssertEqual(SettingsSearch.results(for: "Screen Saver Same as Wallpaper", locale: Locale(identifier: "en")).first?.anchor,
                       SettingsAnchor.macOS)
    }

    /// The menus' and the Details panel's Set as Screen Saver: the wallpaper at once, with its
    /// default settings: what the Screen Saver tab saved for it is cleared.
    @MainActor
    func testMenuSetUsesTheDefaultSettings() throws {
        let wallpaper = try wallpaper()
        let store = ScreenSaverSettingsStore(defaults: defaults)
        let videos = ScreenSaverVideoStore(directory: directory.appending(path: "Videos"))
        let plugin = makePlugin(store, videos: videos)
        let service = makeService(store, plugin: plugin)
        let identity = WallpaperSettingsIdentity.resolve(wallpaper, defaults: defaults)
        save(["speed": "0.3"], .shared, of: wallpaper)
        store.setValues(["speed": "0.9", sceneObjectVisibilityKey(objectID: 4): "false"], for: identity)

        var succeeded: Bool?
        service.setAsScreenSaver(wallpaper) { succeeded = $0 }
        XCTAssertEqual(succeeded, true)
        XCTAssertTrue(service.isSelected(wallpaper))
        XCTAssertEqual(store.values(for: identity), [:], "no saved choices: every layer as authored, the property defaults")
        ScreenSaverPlugin.publishPickValues(for: wallpaper, store: store)
        XCTAssertEqual(stored(ScreenSaverPlugin.pickScope, of: wallpaper), [:], "not the desktop's values either")
        XCTAssertNil(service.chromiumOffer)
    }

    /// A web wallpaper is set from the menu once the Chromium engine is there; without it the
    /// install is offered and nothing is set.
    @MainActor
    func testMenuSetOfAWebWallpaperNeedsChromium() throws {
        let folder = directory.appending(path: "web", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let web = WEWallpaper(using: WEProject(file: "index.html", preview: "p.jpg", title: "Web", type: "web"), where: folder)
        let store = ScreenSaverSettingsStore(defaults: defaults)
        let videos = ScreenSaverVideoStore(directory: directory.appending(path: "Videos"))
        let service = makeService(store, plugin: makePlugin(store, videos: videos))
        var succeeded: Bool?
        service.setAsScreenSaver(web) { succeeded = $0 }
        if ChromiumEngineInstaller.hasActiveInstall {
            XCTAssertEqual(succeeded, true)
            XCTAssertTrue(service.isSelected(web), "drawn live through Chromium")
            XCTAssertNil(service.chromiumOffer)
        } else {
            XCTAssertEqual(succeeded, false)
            XCTAssertFalse(service.isSelected(web))
            XCTAssertEqual(service.chromiumOffer?.wallpaperDirectory, folder, "the install is offered instead")
        }
    }

    /// A video wallpaper is set as the screen saver at once, picked to be drawn live: nothing is
    /// linked or copied into the saver's folder, and it keeps no values of its own.
    @MainActor
    func testSettingAVideoPicksItLiveWithoutAFile() throws {
        let folder = directory.appending(path: "video", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("movie".utf8).write(to: folder.appending(path: "clip.mp4"))
        let video = WEWallpaper(using: WEProject(file: "clip.mp4", preview: "p.jpg", title: "Clip", type: "video"), where: folder)
        let store = ScreenSaverSettingsStore(defaults: defaults)
        let videos = ScreenSaverVideoStore(directory: directory.appending(path: "Videos"))
        let plugin = makePlugin(store, videos: videos)
        plugin.update(enabled: true, wallpaper: nil)
        let service = makeService(store, plugin: plugin)
        var picked: [WEWallpaper] = []
        service.onPicked = { picked.append($0) }
        var succeeded: Bool?
        service.setAsScreenSaver(video) { succeeded = $0 }
        XCTAssertEqual(succeeded, true, "at once")
        XCTAssertTrue(service.isSelected(video))
        XCTAssertEqual(store.livePick?.wallpaperDirectory, folder.standardizedFileURL.path(percentEncoded: false))
        XCTAssertNil(store.selection)
        XCTAssertEqual(picked.map(\.wallpaperDirectory), [folder], "its still is made now (its first frame)")
        XCTAssertNil(store.values(for: WallpaperSettingsIdentity.resolve(video, defaults: defaults)), "a video plays as it is")
        XCTAssertFalse(FileManager.default.fileExists(atPath: videos.directory.path(percentEncoded: false)), "no file goes in the saver's folder")

        let model = VideoScreenSaverModel(wallpaper: video, selectionService: service)
        XCTAssertTrue(model.isScreenSaver)
        model.stopUsingAsScreenSaver()
        XCTAssertFalse(model.isScreenSaver)
        model.setAsScreenSaver()
        XCTAssertTrue(service.isSelected(video))
    }

    /// What Set as Screen Saver takes: scenes, playable video files, web pages and WebM videos
    /// (these two through Chromium), never an application.
    func testAvailability() throws {
        func make(_ type: String, _ file: String) -> WEWallpaper {
            WEWallpaper(using: WEProject(file: file, preview: "p.jpg", title: "T", type: type), where: directory.appending(path: type))
        }
        typealias Service = ScreenSaverSelectionService
        for chromium in [false, true] {
            XCTAssertEqual(Service.availability(of: make("scene", "scene.json"), chromiumInstalled: chromium), .available)
            XCTAssertEqual(Service.availability(of: make("video", "a.mp4"), chromiumInstalled: chromium), .available)
            XCTAssertEqual(Service.availability(of: make("video", "a.mov"), chromiumInstalled: chromium), .available)
            XCTAssertEqual(Service.availability(of: make("web", "index.html"), chromiumInstalled: chromium),
                           chromium ? .available : .needsChromium)
            guard case .unavailable = Service.availability(of: make("application", "a.exe"), chromiumInstalled: chromium) else {
                return XCTFail("an application can't be the screen saver")
            }
            guard case .unavailable = Service.availability(of: make("video", "a.avi"), chromiumInstalled: chromium) else {
                return XCTFail("a container the saver can't play")
            }
        }
        let webm = make("video", "a.webm")
        if WebKitVideoPlayer.handles(webm.mediaURL) {
            XCTAssertEqual(Service.availability(of: webm, chromiumInstalled: false), .needsChromium)
            XCTAssertEqual(Service.availability(of: webm, chromiumInstalled: true), .available)
        }
        XCTAssertTrue(Service.canSet(make("web", "index.html")), "the menu offers it; without Chromium it offers the install")
        XCTAssertFalse(Service.canSet(make("application", "a.exe")))
    }

    /// What an earlier version set as the screen saver (a scene's recording, a video's own file)
    /// becomes the live pick of its wallpaper.
    func testAnEarlierSelectionMigratesToTheLivePick() throws {
        let store = ScreenSaverSettingsStore(defaults: defaults)
        let recorded = Date(timeIntervalSince1970: 1_790_000_000)
        for file in ["a-rec1.mov", "v_c-video-r3-rec1790000000.mp4"] {
            store.livePick = nil
            store.selection = ScreenSaverSettingsStore.Selection(wallpaperDirectory: "/w/3810943704", fileName: file,
                                                                 width: 3840, height: 2160, recorded: recorded)
            XCTAssertTrue(store.migrateSelection(), file)
            XCTAssertNil(store.selection)
            XCTAssertEqual(store.livePick, ScreenSaverSettingsStore.LivePick(wallpaperDirectory: "/w/3810943704", picked: recorded))
            XCTAssertFalse(store.migrateSelection(), "once")
        }
    }

    /// The pick is drawn with the screen saver's own values (properties and layer edits), put in
    /// its isolated store; the wallpaper's own stay as they are.
    @MainActor
    func testThePickIsDrawnWithTheScreenSaversOwnValues() throws {
        let wallpaper = try wallpaper()
        let store = ScreenSaverSettingsStore(defaults: defaults)
        save(["speed": "0.3"], .shared, of: wallpaper)
        ScreenSaverPlugin.publishPickValues(for: wallpaper, store: store)
        XCTAssertEqual(stored(ScreenSaverPlugin.pickScope, of: wallpaper), ["speed": "0.3"], "the wallpaper's own until the screen saver has its own")

        let own = ["speed": "0.9", sceneObjectVisibilityKey(objectID: 4): "false"]
        store.setValues(own, for: WallpaperSettingsIdentity.resolve(wallpaper, defaults: defaults))
        ScreenSaverPlugin.publishPickValues(for: wallpaper, store: store)
        XCTAssertEqual(stored(ScreenSaverPlugin.pickScope, of: wallpaper), own)
        XCTAssertEqual(stored(.shared, of: wallpaper), ["speed": "0.3"])
    }
}
