import AppKit
import Carbon.HIToolbox
import Combine
import XCTest
@testable import OpenWallpaperEngine

/// Wallpaper and display profile hotkeys (WE's "wallpaper" and "profile" hotkeys): conflicts with
/// playlists, actions and each other, assigning, registering, pressing, storage and display
/// locations.
@MainActor
final class UserHotKeyTests: XCTestCase {
    private final class FakeRegistrar: HotKeyRegistering {
        var onPress: ((UInt32) -> Void)?
        var taken: Set<GlobalShortcut> = []
        var registered: [UInt32: GlobalShortcut] = [:]

        func register(_ shortcut: GlobalShortcut, id: UInt32) -> HotKeyRegistration {
            if taken.contains(shortcut) { return .takenByAnotherApp }
            registered[id] = shortcut
            return .registered
        }

        func unregister(id: UInt32) { registered[id] = nil }

        func press(_ shortcut: GlobalShortcut) {
            guard let id = registered.first(where: { $0.value == shortcut })?.key else { return }
            onPress?(id)
        }
    }

    private let ctrlOpt1 = GlobalShortcut(keyCode: UInt16(kVK_ANSI_1), key: "1", modifiers: [.control, .option])
    private let ctrlOpt2 = GlobalShortcut(keyCode: UInt16(kVK_ANSI_2), key: "2", modifiers: [.control, .option])
    private let finder = GlobalShortcutConflictFinder(appShortcuts: [], symbolicHotKeys: { [] }, standardShortcuts: [])
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "owe-user-hotkey-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func wallpaper(_ name: String) -> WEWallpaper {
        WEWallpaper(using: WEProject(file: "scene.json", preview: "p.jpg", title: name, type: "scene"),
                    where: URL(fileURLWithPath: "/tmp/owe-user-hotkey/\(name)"))
    }

    private func controller(_ model: WallpaperViewModel, _ registrar: FakeRegistrar,
                            profileNames: AnyPublisher<[String], Never>? = nil) -> UserHotKeyController {
        UserHotKeyController(viewModel: model, profileNames: profileNames, registrar: registrar, finder: finder,
                             defaults: defaults, openKeyboardSettings: {})
    }

    func testAssignRegistersPressesAndStores() {
        let model = WallpaperViewModel(persistsWallpapers: false)
        let registrar = FakeRegistrar()
        let hotKeys = controller(model, registrar)
        var pressed: [UserHotKey.Target] = []
        hotKeys.perform = { pressed.append($0.target) }
        let forest = UserHotKey.Target.wallpaper(wallpaper("Forest"), location: "DISPLAY-A")

        XCTAssertEqual(hotKeys.conflicts(for: ctrlOpt1, target: forest), [])
        hotKeys.assign(ctrlOpt1, to: forest)
        hotKeys.assign(ctrlOpt2, to: .profile(name: "Work"))
        XCTAssertEqual(Set(registrar.registered.values), [ctrlOpt1, ctrlOpt2])
        XCTAssertEqual(hotKeys.hotKey(for: wallpaper("Forest"), location: "DISPLAY-A")?.shortcut, ctrlOpt1)
        XCTAssertNil(hotKeys.hotKey(for: wallpaper("Forest"), location: "DISPLAY-B"), "a wallpaper's hotkey is its display's")
        XCTAssertEqual(hotKeys.hotKey(forProfile: "Work")?.shortcut, ctrlOpt2)

        registrar.press(ctrlOpt2)
        registrar.press(ctrlOpt1)
        XCTAssertEqual(pressed, [.profile(name: "Work"), forest])

        // Stored, and read back by the next launch.
        let reloaded = controller(WallpaperViewModel(persistsWallpapers: false), FakeRegistrar())
        XCTAssertEqual(reloaded.hotKeys, hotKeys.hotKeys)

        // Assigning again replaces it; nil and Remove clear it.
        hotKeys.assign(ctrlOpt2, to: forest, resolving: hotKeys.conflicts(for: ctrlOpt2, target: forest))
        XCTAssertEqual(hotKeys.hotKeys.map(\.target), [forest], "the profile lost the shortcut to the wallpaper")
        XCTAssertEqual(Array(registrar.registered.values), [ctrlOpt2])
        hotKeys.assign(nil, to: forest)
        XCTAssertTrue(hotKeys.hotKeys.isEmpty)
        XCTAssertTrue(registrar.registered.isEmpty)
    }

    func testConflictsWithPlaylistsActionsAndEachOther() {
        let model = WallpaperViewModel(persistsWallpapers: false)
        let playlist = WallpaperPlaylist(name: "Mix", items: [WallpaperPlaylistItem(wallpaper: wallpaper("Mix"))],
                                         shortcut: ctrlOpt1)
        model.playlists = [playlist]
        let registrar = FakeRegistrar()
        let hotKeys = controller(model, registrar)
        let actions = GlobalHotKeyController(viewModel: model, registrar: FakeRegistrar(), finder: finder,
                                             defaults: defaults, openKeyboardSettings: {})
        hotKeys.actionHotKeys = actions
        actions.userHotKeys = hotKeys
        actions.assign(ctrlOpt2, to: .mute)
        let profile = UserHotKey.Target.profile(name: "Work")

        XCTAssertEqual(hotKeys.conflicts(for: ctrlOpt1, target: profile), [.playlist(id: playlist.id, name: "Mix")])
        XCTAssertEqual(hotKeys.conflicts(for: ctrlOpt2, target: profile), [.action(.mute)])

        // Use Anyway takes it from the action; then the action and the playlist see the profile's.
        hotKeys.assign(ctrlOpt2, to: profile, resolving: [.action(.mute)])
        XCTAssertNil(actions.bindings[.mute])
        let id = hotKeys.hotKeys[0].id
        XCTAssertEqual(actions.conflicts(for: ctrlOpt2, action: .pause), [.userHotKey(id: id, title: "Work", isProfile: true)])
        let playlists = PlaylistShortcutController(viewModel: model, registrar: FakeRegistrar(), finder: finder,
                                                   openKeyboardSettings: {})
        playlists.userHotKeys = hotKeys
        let conflicts = playlists.conflicts(for: ctrlOpt2, playlistID: playlist.id)
        XCTAssertEqual(conflicts, [.userHotKey(id: id, title: "Work", isProfile: true)])
        playlists.assign(ctrlOpt2, to: playlist.id, resolving: conflicts)
        XCTAssertTrue(hotKeys.hotKeys.isEmpty, "the playlist took it from the profile")
        XCTAssertEqual(model.playlists[0].shortcut, ctrlOpt2)

        // Another app's shortcut is found by registering it.
        registrar.taken = [ctrlOpt1]
        model.playlists[0].shortcut = nil
        XCTAssertEqual(hotKeys.conflicts(for: ctrlOpt1, target: profile), [.anotherApp])
    }

    func testConflictMessagesNameTheWallpaperOrProfile() {
        let wallpaperConflict = GlobalShortcutConflict.userHotKey(id: UUID(), title: "Forest", isProfile: false)
        XCTAssertTrue(wallpaperConflict.message(forHotKey: true).contains("Forest"))
        XCTAssertNotEqual(wallpaperConflict.message(forHotKey: true), wallpaperConflict.message(forHotKey: false))
        let profileConflict = GlobalShortcutConflict.userHotKey(id: UUID(), title: "Work", isProfile: true)
        XCTAssertTrue(profileConflict.message.contains("Work"))
    }

    func testSuspendAndAnotherAppHoldingAStoredHotKey() {
        UserHotKeyStore.save([UserHotKey(shortcut: ctrlOpt1, target: .profile(name: "Work"))], to: defaults)
        let registrar = FakeRegistrar()
        registrar.taken = [ctrlOpt1]
        let hotKeys = controller(WallpaperViewModel(persistsWallpapers: false), registrar)
        XCTAssertEqual(hotKeys.unregistered, [hotKeys.hotKeys[0].id])

        registrar.taken = []
        hotKeys.assign(ctrlOpt2, to: .profile(name: "Home"))
        hotKeys.suspend()
        XCTAssertTrue(registrar.registered.isEmpty)
        hotKeys.resume()
        XCTAssertEqual(Set(registrar.registered.values), [ctrlOpt1, ctrlOpt2])
    }

    func testADeletedProfileLosesItsHotKey() {
        let names = CurrentValueSubject<[String], Never>(["Home", "Work"])
        let registrar = FakeRegistrar()
        let hotKeys = controller(WallpaperViewModel(persistsWallpapers: false), registrar,
                                 profileNames: names.eraseToAnyPublisher())
        hotKeys.assign(ctrlOpt1, to: .profile(name: "Work"))
        hotKeys.assign(ctrlOpt2, to: .wallpaper(wallpaper("Forest"), location: "DISPLAY-A"))
        names.send(["Home"])
        XCTAssertEqual(hotKeys.hotKeys.map(\.title), ["Forest"])
        XCTAssertEqual(Array(registrar.registered.values), [ctrlOpt2])
    }

    func testStorageSkipsAnUnreadableHotKey() throws {
        UserHotKeyStore.save([UserHotKey(shortcut: ctrlOpt1, target: .profile(name: "Work"))], to: defaults)
        let data = try XCTUnwrap(defaults.data(forKey: UserHotKeyStore.defaultsKey))
        var file = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var hotKeys = try XCTUnwrap(file["hotKeys"] as? [Any])
        hotKeys.insert(["shortcut": "bad"], at: 0)
        file["hotKeys"] = hotKeys
        defaults.set(try JSONSerialization.data(withJSONObject: file), forKey: UserHotKeyStore.defaultsKey)
        let loaded: [UserHotKey] = UserHotKeyStore.load(from: defaults)
        XCTAssertEqual(loaded.map(\.title), ["Work"])
    }

    func testLocationsFollowTheDisplayIdentity() {
        let connected = [DisplayIdentity(screenId: "1", identity: "AAA"), DisplayIdentity(screenId: "2", identity: "BBB")]
        XCTAssertEqual(UserHotKey.location(ofScreen: "2", connected: connected), "BBB")
        XCTAssertEqual(UserHotKey.location(ofScreen: "2/L", connected: connected), "BBB/L", "a split display's region")
        XCTAssertNil(UserHotKey.location(ofScreen: "3", connected: connected))
        // The display has another id after a reconnect; the hotkey finds it by its identity.
        let reconnected = [DisplayIdentity(screenId: "7", identity: "BBB")]
        XCTAssertEqual(UserHotKey.screenId(ofLocation: "BBB/L", connected: reconnected), "7/L")
        XCTAssertNil(UserHotKey.screenId(ofLocation: "AAA", connected: reconnected))
    }
}
