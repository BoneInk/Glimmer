import XCTest
import OWESceneEditing
import OWEEditor
@testable import OpenWallpaperEngine

/// The Wallpaper Editor as a process of its own: its launch mode and plan, the messages between
/// it and Open Wallpaper Engine, and its edits reaching the app's running wallpapers.
@MainActor
final class WallpaperEditorProcessTests: XCTestCase {
    private var folder: URL!
    private var storeDirectory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    private static let scene = Data("""
    {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
     "general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
     "objects": [{"id": 4, "image": "a.json", "origin": "0 0 0", "alpha": 1},
                 {"id": 5, "image": "b.json", "origin": "1 1 0"}]}
    """.utf8)

    override func setUp() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "EditorProcess-\(UUID().uuidString)", directoryHint: .isDirectory)
        folder = root.appending(path: "wallpaper", directoryHint: .isDirectory)
        storeDirectory = root.appending(path: "editor", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.scene.write(to: folder.appending(path: "scene.json"))
        try Data(#"{"file": "scene.json", "title": "Process", "type": "scene"}"#.utf8).write(to: folder.appending(path: "project.json"))
        suiteName = "WallpaperEditorProcessTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        defaults?.removePersistentDomain(forName: suiteName)
    }

    // MARK: Launch mode

    func testEditorModeIsParsedFromTheArguments() {
        XCTAssertEqual(AppLaunchMode.parse(["/app"]), .main)
        XCTAssertEqual(AppLaunchMode.parse(["/app", "-OWEIsolatedState", "shots"]), .main)
        XCTAssertEqual(AppLaunchMode.parse(["/app", "--wallpaper-editor", "/library/42"]),
                       .wallpaperEditor(URL(filePath: "/library/42", directoryHint: .isDirectory)))
        XCTAssertEqual(AppLaunchMode.parse(["/app", "--wallpaper-editor", "/library/a/../42/"]),
                       .wallpaperEditor(URL(filePath: "/library/42", directoryHint: .isDirectory)), "the folder is standardized")
        XCTAssertEqual(AppLaunchMode.parse(["/app", "--wallpaper-editor"]), .wallpaperEditor(nil))
        XCTAssertEqual(AppLaunchMode.parse(["/app", "--wallpaper-editor", "-OWEIsolatedState", "x"]), .wallpaperEditor(nil),
                       "an option after the flag isn't a folder")
        XCTAssertEqual(AppLaunchMode.parse(["/app", "--wallpaper-editor", ""]), .wallpaperEditor(nil))
        // The editor's own app is the editor, with or without the flag.
        let editorApp = "app.openwallpaperengine.editor"
        XCTAssertEqual(AppLaunchMode.parse(["/editor"], bundleIdentifier: editorApp), .wallpaperEditor(nil))
        XCTAssertEqual(AppLaunchMode.parse(["/editor", "--wallpaper-editor", "/library/42"], bundleIdentifier: editorApp),
                       .wallpaperEditor(URL(filePath: "/library/42", directoryHint: .isDirectory)))
        XCTAssertEqual(AppLaunchMode.parse(["/app"], bundleIdentifier: "app.openwallpaperengine"), .main)
    }

    func testTheEditorIsLaunchedWithTheFolderAndTheAppsIsolation() {
        let folder = URL(filePath: "/library/My Wallpaper", directoryHint: .isDirectory)
        let isolated = AppLaunchMode.wallpaperEditorArguments(folder: folder, isolationTag: "shots")
        XCTAssertEqual(isolated, ["--wallpaper-editor", "/library/My Wallpaper", "-OWEIsolatedState", "shots"])
        XCTAssertEqual(AppLaunchMode.parse(["/app"] + isolated), .wallpaperEditor(folder))
        XCTAssertEqual(AppStorageLocation.isolationTag(environment: [:], arguments: ["/app"] + isolated, isRunningTests: false),
                       "shots", "an isolated app opens an isolated editor")
        XCTAssertEqual(AppLaunchMode.wallpaperEditorArguments(folder: folder, isolationTag: nil),
                       ["--wallpaper-editor", "/library/My Wallpaper"])
        XCTAssertFalse(HelperRunCommand.isHelperRun(arguments: ["/app"] + isolated),
                       "the editor saves overlays and properties: it isn't a read-only helper run")
        let german = AppLaunchMode.wallpaperEditorArguments(folder: folder, isolationTag: nil, languages: ["de"])
        XCTAssertEqual(Array(german.suffix(2)), ["-AppleLanguages", "(\"de\")"], "the editor speaks the app's language")
        XCTAssertEqual(AppLaunchMode.parse(["/app"] + german), .wallpaperEditor(folder))
    }

    func testRunningProcessesAreToldApartByTheirBundleAndArguments() {
        let app = "app.openwallpaperengine", editor = "app.openwallpaperengine.editor"
        func kind(_ arguments: [String], _ bundle: String = app) -> AppProcessList.Kind {
            AppProcessList.classify(arguments: arguments, environment: [:], bundleIdentifier: bundle).kind
        }
        XCTAssertEqual(kind(["/app"]), .main)
        XCTAssertEqual(kind(["/editor", "--wallpaper-editor", "/w"], editor), .wallpaperEditor)
        XCTAssertEqual(kind(["/editor"], editor), .wallpaperEditor)
        XCTAssertEqual(kind(["/app", "--prewarm-shaders"]), .helper)
        XCTAssertEqual(kind(["/editor", "--shader-compile-helper"], editor), .helper, "the editor's own shader helper")
        XCTAssertEqual(kind(["/app", "--crash-watcher", "/a", "/b"]), .helper)
        let isolated = AppProcessList.classify(arguments: ["/app"], environment: ["OWE_ISOLATED_STATE": "shots"],
                                               bundleIdentifier: app)
        XCTAssertEqual(isolated.isolationTag, "shots")
        XCTAssertNil(AppProcessList.classify(arguments: ["/app"], environment: [:], bundleIdentifier: app).isolationTag)
    }

    // MARK: The editor's app

    func testTheEditorsAppIsInsideTheApp() throws {
        let app = URL(filePath: "/Applications/Open Wallpaper Engine.app", directoryHint: .isDirectory)
        let editor = AppBundleLayout.editorURL(inApp: app)
        XCTAssertEqual(editor.path, "/Applications/Open Wallpaper Engine.app/Contents/Helpers/Wallpaper Editor.app")
        XCTAssertEqual(AppBundleLayout.appURL(containingHelper: editor)?.path, app.path, "the editor finds the app it is in")
        XCTAssertNil(AppBundleLayout.appURL(containingHelper: app), "the app isn't inside another")
        XCTAssertNil(AppBundleLayout.appURL(containingHelper: URL(filePath: "/tmp/Helpers/X.app", directoryHint: .isDirectory)))
        XCTAssertEqual(AppBundleLayout.editorIdentifier(for: "app.openwallpaperengine"), "app.openwallpaperengine.editor")
        XCTAssertEqual(AppBundleLayout.appIdentifier(for: "app.openwallpaperengine.editor"), "app.openwallpaperengine")
        XCTAssertEqual(AppBundleLayout.appIdentifier(for: "app.openwallpaperengine"), "app.openwallpaperengine")
        XCTAssertTrue(AppBundleLayout.appBundle === Bundle.main, "the app reads its own Info.plist")
    }

    /// Both apps are small executables running the OpenWallpaperEngine framework: the code and its
    /// own resources are in the framework, once; what is per app stays in each app's bundle.
    func testTheCodeAndItsResourcesAreInTheFramework() throws {
        let framework = AppBundleLayout.framework
        XCTAssertFalse(framework === Bundle.main)
        XCTAssertEqual(framework.bundleURL.lastPathComponent, "OpenWallpaperEngine.framework")
        XCTAssertNotNil(framework.url(forResource: "default", withExtension: "metallib"), "the engine's Metal library")
        XCTAssertNotNil(framework.url(forResource: "WallpaperNotFound", withExtension: "mp4"))
        XCTAssertNotNil(framework.url(forResource: "nowPlayingAdapter", withExtension: "pl"))
        XCTAssertNil(Bundle.main.url(forResource: "default", withExtension: "metallib"), "no second Metal library in the app")
        // SwiftUI and `String(localized:)` read the strings and the asset catalog from the app's own bundle.
        XCTAssertTrue(Bundle.main.localizations.contains("de"))
        XCTAssertNotNil(Bundle.main.url(forResource: "Assets", withExtension: "car"))
        XCTAssertNotNil(Bundle.main.privateFrameworksURL.flatMap {
            Bundle(url: $0.appending(path: "OpenWallpaperEngine.framework", directoryHint: .isDirectory))
        }, "the app embeds the framework")
    }

    /// The editor's app is built and embedded: its own executable, strings and asset catalog, and
    /// the app's framework, which it links through `@executable_path/../../../../Frameworks`.
    func testTheBuiltEditorAppIsSmallAndLinksTheAppsFramework() throws {
        let editorURL = AppBundleLayout.editorURL(inApp: Bundle.main.bundleURL)
        let editor = try XCTUnwrap(Bundle(url: editorURL), "the app embeds the editor's app")
        XCTAssertEqual(editor.bundleIdentifier, AppBundleLayout.editorIdentifier(for: Bundle.main.bundleIdentifier ?? ""))
        XCTAssertEqual(editor.infoDictionary?["CFBundleShortVersionString"] as? String,
                       Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        XCTAssertTrue(editor.localizations.contains("de"))
        let ownFrameworks: URL = editorURL.appending(path: "Contents/Frameworks", directoryHint: .isDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownFrameworks.path), "no frameworks of its own")
        let executable = try XCTUnwrap(editor.executableURL)
        let size = try XCTUnwrap(try executable.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThan(size, 5_000_000, "the editor's executable only starts the framework")
    }

    func testTheEditorsAppHasItsOwnIdentity() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "EditorHelper/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "$(PRODUCT_BUNDLE_IDENTIFIER)")
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "$(MARKETING_VERSION)", "the app's version")
        XCTAssertEqual(info["CFBundleName"] as? String, AppBundleLayout.editorName)
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, AppBundleLayout.editorName)
        XCTAssertEqual(info["CFBundleExecutable"] as? String, AppBundleLayout.editorName)
        XCTAssertEqual(info["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(info["LSUIElement"] as? Bool, false, "a Dock tile and menu bar of its own")
        XCTAssertEqual(info["NSPrincipalClass"] as? String, "NSApplication")
        let icon = try XCTUnwrap(info["CFBundleIconFile"] as? String)
        XCTAssertNil(info["CFBundleIconName"], "the badged icon, not the app's from the asset catalog")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "EditorHelper/\(icon).icns").path))
        XCTAssertNil(info["SUFeedURL"], "the editor's app never updates itself")
        let project = try String(contentsOf: root.appending(path: "OpenWallpaperEngine.xcodeproj/project.pbxproj"), encoding: .utf8)
        let identifier: String = AppBundleLayout.editorIdentifier(for: AppStorageLocation.realBundleIdentifier)
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER = \"\(identifier)\";"), "the editor's id is the app's plus .editor")
    }

    func testTheEditorsAppKeepsTheAppsState() {
        let editor = AppStorageLocation(isolationTag: "shots", bundleIdentifier: "app.openwallpaperengine.editor")
        let app = AppStorageLocation(isolationTag: "shots", bundleIdentifier: "app.openwallpaperengine")
        XCTAssertEqual(editor.suiteName, app.suiteName, "the same defaults")
        XCTAssertEqual(editor.supportDirectory, app.supportDirectory)
        XCTAssertEqual(editor.cachesDirectory, app.cachesDirectory)
        XCTAssertEqual(editor.keychainServicePrefix, app.keychainServicePrefix)
    }

    func testProcessArgumentsAreReadFromTheKernelsLayout() throws {
        var bytes = withUnsafeBytes(of: Int32(3)) { Array($0) }
        bytes += Array("/Applications/OWE.app/Contents/MacOS/OWE".utf8) + [0, 0, 0, 0]
        for string in ["/Applications/OWE.app/Contents/MacOS/OWE", "--wallpaper-editor", "/w/42",
                       "OWE_ISOLATED_STATE=shots", "HOME=/Users/x"] {
            bytes += Array(string.utf8) + [0]
        }
        bytes += [0, 0]
        let parsed = try XCTUnwrap(AppProcessList.parseProcessArguments(bytes))
        XCTAssertEqual(parsed.arguments, ["/Applications/OWE.app/Contents/MacOS/OWE", "--wallpaper-editor", "/w/42"])
        XCTAssertEqual(parsed.environment["OWE_ISOLATED_STATE"], "shots")
        XCTAssertNil(AppProcessList.parseProcessArguments([1, 0]))
        let own = try XCTUnwrap(AppProcessList.launchArguments(of: ProcessInfo.processInfo.processIdentifier))
        XCTAssertEqual(own.arguments.count, ProcessInfo.processInfo.arguments.count, "this process reads as it was launched")
    }

    // MARK: Launch plan

    func testEditorModeStartsNoneOfTheMainAppsServices() {
        let main = AppLaunchPlan.plan(for: .main)
        let editor = AppLaunchPlan.plan(for: .wallpaperEditor(folder))
        XCTAssertEqual(editor.services, [.wallpaperEditorWindows])
        for service in [AppLaunchPlan.Service.desktopWallpapers, .menuBarItem, .mainWindow, .screenSaver, .lockScreenPicture,
                        .workshopSync, .updater, .crashWatcher, .safeRestart, .globalShortcuts, .playbackMonitors,
                        .editorChangeSync] {
            XCTAssertTrue(main.services.contains(service), "\(service)")
            XCTAssertFalse(editor.services.contains(service), "the editor's process doesn't start \(service)")
        }
        XCTAssertFalse(main.services.contains(.wallpaperEditorWindows), "the app opens no editor window itself")
        XCTAssertEqual(editor.activationPolicy, .regular)
    }

    func testEditorModeGetsTheEditorsDelegate() {
        let delegate = AppLaunchPlan.plan(for: .wallpaperEditor(folder)).makeDelegate()
        XCTAssertTrue(delegate is WallpaperEditorAppDelegate)
        XCTAssertFalse(delegate is AppDelegate)
        XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed?(NSApp) ?? false,
                      "the editor quits with its last window")
    }

    // MARK: Opening wallpapers

    func testARunningEditorOpensTheWallpaperTheAppAsksFor() {
        let messaging = FakeProcessMessaging()
        let channel = AppProcessChannel(isolationTag: "tests")
        var launches: [[String]] = []
        let launcher = WallpaperEditorLauncher(dependencies: .init(
            messaging: messaging, channel: channel, sender: "app", isolationTag: "tests", languages: nil,
            editorIsRunning: { true }, launch: { _, arguments, _, _ in launches.append(arguments) }))
        let windows = FakeEditorWindows()
        let requests = WallpaperEditorRequests(messaging: messaging, channel: channel, sender: "editor", windows: windows)
        requests.start()
        launcher.start()

        launcher.open(folder)
        launcher.open(folder.appending(path: "../other", directoryHint: .isDirectory))
        XCTAssertEqual(windows.opened.map(\.path),
                       [folder.standardizedFileURL.path, folder.deletingLastPathComponent().appending(path: "other").standardizedFileURL.path])
        XCTAssertTrue(launches.isEmpty, "one editor process holds every wallpaper")
    }

    func testTheAppLaunchesAnEditorAndHoldsRequestsUntilItIsReady() {
        let messaging = FakeProcessMessaging()
        let channel = AppProcessChannel(isolationTag: "tests")
        var running = false
        var launches: [(app: URL, arguments: [String], environment: [String: String])] = []
        let app = URL(filePath: "/Applications/Open Wallpaper Engine.app", directoryHint: .isDirectory)
        let launcher = WallpaperEditorLauncher(dependencies: .init(
            messaging: messaging, channel: channel, sender: "app", isolationTag: "tests",
            editorApp: AppBundleLayout.editorURL(inApp: app), languages: nil, editorIsRunning: { running },
            launch: { app, arguments, environment, _ in launches.append((app, arguments, environment)) }))
        launcher.start()
        let other = folder.deletingLastPathComponent().appending(path: "other", directoryHint: .isDirectory)

        launcher.open(folder)
        launcher.open(other)
        XCTAssertEqual(launches.count, 1, "a second request waits for the editor that is starting")
        XCTAssertEqual(launches.first?.app.path, "/Applications/Open Wallpaper Engine.app/Contents/Helpers/Wallpaper Editor.app",
                       "the editor's own app, not another instance of this one")
        XCTAssertEqual(launches.first?.arguments,
                       ["--wallpaper-editor", folder.standardizedFileURL.path, "-OWEIsolatedState", "tests"])
        XCTAssertEqual(launches.first?.environment["OWE_ISOLATED_STATE"], "tests")

        // The editor starts, takes requests and says so.
        running = true
        let windows = FakeEditorWindows()
        let requests = WallpaperEditorRequests(messaging: messaging, channel: channel, sender: "editor", windows: windows)
        requests.start()
        requests.announceReady()
        XCTAssertEqual(windows.opened.map(\.path), [other.standardizedFileURL.path])
    }

    /// An MCP client's particle restart goes to the editor's open window of the wallpaper, which
    /// answers; without one (or without the editor) the app is told no, and restarts the displays.
    func testAParticleRestartReachesTheEditorsOpenWindow() async {
        let messaging = FakeProcessMessaging()
        let channel = AppProcessChannel(isolationTag: "tests")
        var running = true
        let launcher = WallpaperEditorLauncher(dependencies: .init(
            messaging: messaging, channel: channel, sender: "app", isolationTag: "tests", languages: nil,
            editorIsRunning: { running }, launch: { _, _, _, _ in }, replyTimeout: 0.05))
        let windows = FakeEditorWindows()
        windows.open = [folder.standardizedFileURL.path]
        let requests = WallpaperEditorRequests(messaging: messaging, channel: channel, sender: "editor", windows: windows)
        requests.start()
        defer { requests.stop() }

        let restarted = await launcher.restartParticles(folder, layers: [6, 2])
        XCTAssertTrue(restarted, "the window restarts it and says so")
        XCTAssertEqual(windows.restarted, [[2, 6]])
        let other = folder.deletingLastPathComponent().appending(path: "other", directoryHint: .isDirectory)
        let noWindow = await launcher.restartParticles(other, layers: [6])
        XCTAssertFalse(noWindow, "no window of that wallpaper: no answer")
        running = false
        let noEditor = await launcher.restartParticles(folder, layers: [6])
        XCTAssertFalse(noEditor, "no editor running")
        XCTAssertEqual(windows.restarted.count, 1)
    }

    func testIsolatedProcessesOnlyHearTheirOwnTag() {
        XCTAssertNotEqual(AppProcessChannel(isolationTag: "a").name(.openWallpaper),
                          AppProcessChannel(isolationTag: nil).name(.openWallpaper))
        XCTAssertEqual(AppProcessChannel(isolationTag: nil).name(.openWallpaper).rawValue,
                       "app.openwallpaperengine.editor.open")
    }

    // MARK: Live sync

    private func makeSync(_ role: WallpaperEditorChangeSync.Role, sender: String, messaging: FakeProcessMessaging,
                          local: NotificationCenter, properties: PropertyRecorder? = nil) -> WallpaperEditorChangeSync {
        var dependencies = WallpaperEditorChangeSync.Dependencies(
            messaging: messaging, channel: AppProcessChannel(isolationTag: "tests"), sender: sender,
            store: SceneEditOverlayStore(directory: storeDirectory), local: local, defaults: defaults)
        dependencies.readScene = { _ in Self.scene }
        if let properties {
            dependencies.runningProperties = { properties.running[$0] ?? [:] }
            dependencies.setRunningProperties = { values, key in properties.set.append((key, values)) }
        }
        return WallpaperEditorChangeSync(role: role, dependencies: dependencies)
    }

    private var identity: WallpaperSettingsIdentity { WallpaperSettingsIdentity.resolve(directory: folder, defaults: defaults) }

    func testAnOverlayTheEditorSavesReloadsTheAppsWallpaper() throws {
        let messaging = FakeProcessMessaging()
        let appCenter = NotificationCenter(), editorCenter = NotificationCenter()
        let app = makeSync(.app, sender: "app", messaging: messaging, local: appCenter)
        let editor = makeSync(.editor, sender: "editor", messaging: messaging, local: editorCenter)
        app.start()
        editor.start()
        defer { app.stop(); editor.stop() }
        let received = NotificationLog(.sceneEditOverlayDidChange, in: appCenter)

        var overlay = SceneEditOverlay()
        overlay.setField("alpha", to: .number(0.5), of: 4)
        try SceneEditOverlayStore(directory: storeDirectory).save(overlay, for: identity.rawValue)
        editor.overlayDidSave(folder: folder)

        XCTAssertEqual(received.notifications.count, 1)
        let info = try XCTUnwrap(received.notifications.first?.userInfo)
        XCTAssertEqual((info["wallpaperDirectory"] as? URL)?.path, folder.standardizedFileURL.path,
                       "the instances of this wallpaper take it")
        XCTAssertEqual(info["overlay"] as? SceneEditOverlay, overlay)
        XCTAssertEqual(info["transient"] as? Bool, false, "a saved change: the instance draws it live or reloads")
        XCTAssertEqual((info["base"] as? SceneOutline)?.layers.map(\.id), [4, 5], "measured against the scene's structure")

        editor.overlayDidSave(folder: folder)
        XCTAssertEqual(received.notifications.count, 1, "the same overlay twice is applied once")
        XCTAssertTrue(messaging.posted.allSatisfy { !$0.userInfo.values.contains { $0.contains("alpha") } },
                      "messages name the wallpaper, never the edits")
    }

    func testAParticleDocumentChangeRebuildsOnlyItsSystemsInTheApp() throws {
        let messaging = FakeProcessMessaging()
        let appCenter = NotificationCenter()
        let app = makeSync(.app, sender: "app", messaging: messaging, local: appCenter)
        let editor = makeSync(.editor, sender: "editor", messaging: messaging, local: NotificationCenter())
        app.start()
        defer { app.stop() }
        let store = SceneEditOverlayStore(directory: storeDirectory)
        var overlay = SceneEditOverlay()
        overlay.setField("alpha", to: .number(0.5), of: 4)
        try store.save(overlay, for: identity.rawValue)
        editor.overlayDidSave(folder: folder)

        let particles = NotificationLog(.sceneEditParticlesDidChange, in: appCenter)
        let scenes = NotificationLog(.sceneEditOverlayDidChange, in: appCenter)
        overlay.updateParticles { $0.assets["particles/rain.json"] = .object(["maxcount": .number(10)]) }
        try store.save(overlay, for: identity.rawValue)
        editor.overlayDidSave(folder: folder)

        XCTAssertTrue(scenes.notifications.isEmpty, "the scene keeps running")
        XCTAssertEqual(particles.notifications.first?.userInfo?["paths"] as? [String], ["particles/rain.json"])
    }

    func testTheFolderWatcherReloadsAChangeWhoseMessageWasMissed() throws {
        let appCenter = NotificationCenter()
        let app = makeSync(.app, sender: "app", messaging: FakeProcessMessaging(), local: appCenter)
        let folder = self.folder!
        app.start(watch: true, runningFolders: { [folder] })
        defer { app.stop() }
        let reloaded = expectation(forNotification: .sceneEditOverlayDidChange, object: nil, notificationCenter: appCenter) { notification in
            (notification.userInfo?["overlay"] as? SceneEditOverlay)?.field("alpha", of: 5) == .number(0.25)
        }
        var overlay = SceneEditOverlay()
        overlay.setField("alpha", to: .number(0.25), of: 5)
        // Saved by another process, with no message.
        try SceneEditOverlayStore(directory: storeDirectory).save(overlay, for: identity.rawValue)
        wait(for: [reloaded], timeout: 5)
    }

    func testUserPropertiesSavedInOneProcessReachTheOthersRunningWallpaper() {
        let messaging = FakeProcessMessaging()
        let appCenter = NotificationCenter(), editorCenter = NotificationCenter()
        let recorder = PropertyRecorder()
        let key = WallpaperPropertyScope.shared.runtimeKey(directory: folder.standardizedFileURL)
        recorder.running[key] = ["speed": "1", "color": "red"]
        let app = makeSync(.app, sender: "app", messaging: messaging, local: appCenter, properties: recorder)
        let editor = makeSync(.editor, sender: "editor", messaging: messaging, local: editorCenter)
        app.start()
        editor.start()
        defer { app.stop(); editor.stop() }
        let regrouped = NotificationLog(.wallpaperPropertiesDidSave, in: appCenter)

        // The editor's Details panel saves them (`WallpaperPropertyTargets.save`).
        defaults.set(["speed": "2", "color": "red"], forKey: identity.key(.userProperties, scope: .shared))
        editorCenter.post(name: .wallpaperPropertiesDidSave, object: folder.standardizedFileURL.path)

        XCTAssertEqual(recorder.set.count, 1)
        XCTAssertEqual(recorder.set.first?.key, key)
        XCTAssertEqual(recorder.set.first?.values, ["speed": "2"], "only what changed")
        XCTAssertEqual(regrouped.notifications.count, 1, "the displays regroup")
        XCTAssertEqual(messaging.posted.filter { $0.name.rawValue.hasSuffix("properties.didSave") }.count, 1,
                       "the app doesn't send the change back")
    }

    func testTheEditorOpensTheAppsSettingsPagesOrLaunchesTheAppOnThem() {
        let messaging = FakeProcessMessaging()
        let app = makeSync(.app, sender: "app", messaging: messaging, local: NotificationCenter())
        var opened: [AppSettingsRequest] = []
        app.onOpenSettings = { opened.append($0) }
        app.start()
        var running = true
        var launched: [AppSettingsRequest] = []
        var dependencies = editorDependencies(messaging: messaging)
        dependencies.appIsRunning = { running }
        dependencies.launchAppOnSettings = { launched.append($0) }
        let editor = WallpaperEditorChangeSync(role: .editor, dependencies: dependencies)
        editor.start()
        defer { app.stop(); editor.stop() }

        editor.openSettings(.assets)
        editor.openSettings(.depthMaps)
        XCTAssertEqual(opened, [.assets, .depthMaps], "the running app shows Settings › Assets, › Plugins › Depth Maps")
        XCTAssertEqual(launched, [])
        running = false
        editor.openSettings(.depthMaps)
        XCTAssertEqual(launched, [.depthMaps], "an app that isn't running is launched on them")
        XCTAssertEqual(AppSettingsRequest.requested(by: ["/app", AppSettingsRequest.depthMaps.launchArgument]), .depthMaps)
        XCTAssertEqual(opened.count, 2)
    }

    /// The editor's window and its services (depth maps, the browsers' asset setup) run in the
    /// editor's process: none of it may make or use Open Wallpaper Engine's delegate.
    func testTheEditorsServicesNeverReachTheAppsDelegate() throws {
        var reached = 0
        AppDelegate.sharedAccessProbe = { reached += 1 }
        defer { AppDelegate.sharedAccessProbe = nil }
        var launched: [AppSettingsRequest] = []
        var dependencies = editorDependencies(messaging: FakeProcessMessaging())
        dependencies.appIsRunning = { false }
        dependencies.launchAppOnSettings = { launched.append($0) }
        let sync = WallpaperEditorChangeSync(role: .editor, dependencies: dependencies)
        let wallpaper = try XCTUnwrap(InstalledLibrary.wallpaper(at: folder, hiding: []))
        let editor = try WallpaperEditorController(wallpaper: wallpaper, host: WallpaperEditorAppDelegate.makeSceneHost(),
                                                   sync: sync)
        defer { try? editor.draft.discard(); editor.window.close() } // The isolated tests' draft.
        let services = editor.makeServices()
        let depthMaps = try XCTUnwrap(services.depthMaps)
        XCTAssertTrue(depthMaps.generator === DepthMapPlugin.generator, "the process's own generator")
        depthMaps.openPlugins()
        services.openAssetsSetup()
        XCTAssertEqual(launched, [.depthMaps, .assets], "the app's Settings, through the channel")
        XCTAssertEqual(reached, 0, "AppDelegate.shared used from the editor's services")
    }

    /// What an MCP client drives in the editor's process (an edit taken, undone and redone, the
    /// timeline, depth maps, Save as New Wallpaper, the canvas's scene) never makes or uses Open
    /// Wallpaper Engine's delegate.
    func testTheEditorsMCPPathsNeverReachTheAppsDelegate() throws {
        var reached = 0
        AppDelegate.sharedAccessProbe = { reached += 1 }
        defer { AppDelegate.sharedAccessProbe = nil }
        // Save as New Wallpaper writes into the library: a temporary one.
        let storageKey = "CustomWallpapersDirectory"
        let savedStorage = UserDefaults.app.string(forKey: storageKey)
        let library = folder.deletingLastPathComponent().appending(path: "library", directoryHint: .isDirectory)
        UserDefaults.app.set(library.path, forKey: storageKey)
        defer { UserDefaults.app.set(savedStorage, forKey: storageKey) }
        let messaging = FakeProcessMessaging()
        var dependencies = editorDependencies(messaging: messaging)
        dependencies.store = SceneEditOverlayFiles.defaultStore
        dependencies.appIsRunning = { true }
        let sync = WallpaperEditorChangeSync(role: .editor, dependencies: dependencies)
        let wallpaper = try XCTUnwrap(InstalledLibrary.wallpaper(at: folder, hiding: []))
        let identity = WallpaperSettingsIdentity.resolve(directory: wallpaper.wallpaperDirectory)
        defer { try? SceneEditOverlayFiles.defaultStore.remove(identity.rawValue) } // The isolated tests' store.
        let editor = try WallpaperEditorController(wallpaper: wallpaper, host: WallpaperEditorAppDelegate.makeSceneHost(),
                                                   sync: sync)
        defer { try? editor.draft.discard(); editor.window.close() } // The isolated tests' draft.
        func nextEvent() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

        // The canvas's scene runs with the process's own host, and takes no loading snapshots.
        let canvas = WallpaperViewModel(persistsWallpapers: false)
        canvas.sceneHost = WallpaperEditorAppDelegate.makeSceneHost()
        XCTAssertNil(SceneWallpaperView.environment(of: canvas).loadingSnapshots)

        // An MCP edit, its Undo and its Redo, taken by the window.
        var edited = SceneEditOverlay()
        let other = SceneEditSession(outline: try SceneOutline(sceneData: Self.scene), overlay: edited)
        other.setValue(.number(0.5), for: "alpha", of: 4, actionName: "Opacity")
        edited = other.overlay
        for (overlay, step) in [(edited, AppProcessChannel.OverlayStep.edit), (SceneEditOverlay(), .undo), (edited, .redo)] {
            try SceneEditOverlayFiles.draftStore.saveDraft(overlay, for: identity.rawValue)
            editor.adoptSavedOverlay(actionName: "Opacity", step: step)
            nextEvent()
            XCTAssertEqual(editor.session.overlay, overlay)
        }
        // The timeline (its tab comes forward), played, sought and paused.
        editor.controlTimeline(command: "play", seconds: nil)
        editor.controlTimeline(command: "seek", seconds: 1)
        editor.controlTimeline(command: "pause", seconds: nil)
        // Depth maps and Save as New Wallpaper, through the window's services.
        let services = editor.makeServices()
        try XCTUnwrap(services.depthMaps).openPlugins()
        _ = try services.saveAsNewWallpaper("Process (Edited)")
        XCTAssertTrue(messaging.posted.contains { $0.name.rawValue.hasSuffix("library.didChange") },
                      "the app's library hears of the copy through the channel")
        XCTAssertEqual(reached, 0, "AppDelegate.shared used from the editor's process")
    }

    private func editorDependencies(messaging: FakeProcessMessaging) -> WallpaperEditorChangeSync.Dependencies {
        WallpaperEditorChangeSync.Dependencies(
            messaging: messaging, channel: AppProcessChannel(isolationTag: "tests"), sender: "editor",
            store: SceneEditOverlayStore(directory: storeDirectory), local: NotificationCenter(), defaults: defaults)
    }
}

/// The distributed notification centre, in memory: every observer of a name hears each post.
@MainActor
private final class FakeProcessMessaging: AppProcessMessaging {
    private final class Observer {
        let name: Notification.Name
        let handler: @MainActor (String?, [String: String]) -> Void
        init(name: Notification.Name, handler: @escaping @MainActor (String?, [String: String]) -> Void) {
            self.name = name
            self.handler = handler
        }
    }

    private var observers: [Observer] = []
    private(set) var posted: [(name: Notification.Name, sender: String, userInfo: [String: String])] = []

    func post(_ name: Notification.Name, sender: String, userInfo: [String: String]) {
        posted.append((name, sender, userInfo))
        for observer in observers where observer.name == name { observer.handler(sender, userInfo) }
    }

    func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (String?, [String: String]) -> Void) -> AnyObject {
        let observer = Observer(name: name, handler: handler)
        observers.append(observer)
        return observer
    }

    func remove(_ token: AnyObject) {
        observers.removeAll { $0 === token }
    }
}

@MainActor
private final class FakeEditorWindows: WallpaperEditorWindows {
    private(set) var opened: [URL] = []
    /// The folders (paths) with an open window, and the particle restarts they took.
    var open: Set<String> = []
    private(set) var restarted: [Set<Int>] = []

    func restartParticles(of folder: URL, layers: Set<Int>) -> Bool {
        guard open.contains(folder.standardizedFileURL.path) else { return false }
        restarted.append(layers)
        return true
    }

    func showEditor(of folder: URL) -> Bool {
        opened.append(folder.standardizedFileURL)
        return true
    }
}

/// The notifications of one name a centre posts, in order, until the log goes.
private final class NotificationLog {
    private(set) var notifications: [Notification] = []
    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    init(_ name: Notification.Name, in center: NotificationCenter) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
            self?.notifications.append(notification)
        }
    }

    deinit {
        if let token { center.removeObserver(token) }
    }
}

private final class PropertyRecorder {
    var running: [String: [String: String]] = [:]
    var set: [(key: String, values: [String: String])] = []
}
